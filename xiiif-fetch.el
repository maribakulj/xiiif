;;; xiiif-fetch.el --- Request scheduler for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Scheduling layer between xiiif's interactive code and the
;; xiiif-api transport: a global concurrency cap, per-host politeness
;; intervals, Retry-After-aware retries for 429/503, deduplication of
;; identical in-flight requests, interactive-over-prefetch priorities
;; and grouped cancellation.  Backend-independent: only the public
;; xiiif-api async entry points are called, so both the url and plz
;; transports are covered.
;;
;; Entry points mirror the transport API with the same errback
;; protocol (SYMBOL URL &rest DATA):
;;
;;   (xiiif-fetch-json URL CALLBACK :errback E :priority P :group G)
;;   (xiiif-fetch-bytes URL CALLBACK ...)
;;   (xiiif-fetch-file URL DESTINATION CALLBACK ...)
;;
;; Each returns an opaque request object accepted by
;; `xiiif-fetch-cancel'; `xiiif-fetch-cancel-group' drops everything
;; tagged with a :group (the region viewer cancels the previous
;; view's group on each navigation).  `xiiif-fetch-stats' exposes
;; counters for diagnostics and tests.

;;; Code:

(require 'cl-lib)
(require 'xiiif-api)
(require 'xiiif-profiles)
(require 'xiiif-image-cache)

(defcustom xiiif-fetch-max-concurrent 4
  "Maximum number of scheduler requests in flight at once."
  :type 'integer
  :group 'xiiif)

(defcustom xiiif-fetch-host-interval 0.15
  "Minimum seconds between two request starts to the same host.
Overridden per server by the `:min-interval' key of
`xiiif-server-profiles'."
  :type 'number
  :group 'xiiif)

(defcustom xiiif-fetch-max-retries 3
  "Retry attempts for 429/503 responses before failing the request."
  :type 'integer
  :group 'xiiif)

(defcustom xiiif-fetch-retry-backoff 1.0
  "Base seconds for exponential retry backoff.
Used when a 429/503 response carries no Retry-After header: the
host is suspended for BACKOFF * 2^(ATTEMPT-1) seconds."
  :type 'number
  :group 'xiiif)


;;; ---------- state ----------

(cl-defstruct (xiiif-fetch--request
               (:constructor xiiif-fetch--request-create))
  "One scheduled fetch.  ENTRIES is a list of plists
\(:callback FN :errback FN :group G), newest first, so a
deduplicated request can fan out to several callers.  CACHE
non-nil persists a bytes result in the image cache."
  kind url destination entries priority attempts handle host cache)

(defvar xiiif-fetch--queue nil
  "Pending `xiiif-fetch--request' objects, oldest first.")

(defvar xiiif-fetch--active nil
  "In-flight `xiiif-fetch--request' objects.")

(defvar xiiif-fetch--host-last (make-hash-table :test #'equal)
  "Host -> time of the most recent request start.")

(defvar xiiif-fetch--host-until (make-hash-table :test #'equal)
  "Host -> time before which no request may start (Retry-After).")

(defvar xiiif-fetch--timer nil
  "Pending deferred-pump timer, or nil.")

(defvar xiiif-fetch--stats
  (list :started 0 :completed 0 :failed 0 :deduped 0 :retried 0
        :cache-hits 0)
  "Mutable counters behind `xiiif-fetch-stats'.")

(defun xiiif-fetch--now ()
  "Current time as a float; isolated so tests can fake the clock."
  (float-time))


;;; ---------- public API ----------

(cl-defun xiiif-fetch-json (url callback &key errback priority group)
  "Schedule an async JSON fetch of URL through the scheduler.
CALLBACK and ERRBACK follow the `xiiif-api-fetch-json-async'
conventions.  PRIORITY is `interactive' (default) or `prefetch';
prefetch requests only start while no interactive request waits.
GROUP is an arbitrary non-nil tag for `xiiif-fetch-cancel-group'.
An identical in-flight or queued JSON request is reused: one
transfer, every caller's callbacks.  Returns an opaque request
object accepted by `xiiif-fetch-cancel'."
  (xiiif-fetch--submit 'json url nil callback errback priority group))

(cl-defun xiiif-fetch-bytes (url callback &key errback priority group cache)
  "Schedule an async raw-bytes fetch of URL through the scheduler.
See `xiiif-fetch-json' for CALLBACK, ERRBACK, PRIORITY and GROUP.
With CACHE non-nil the on-disk image cache is consulted first - a
hit invokes CALLBACK immediately (before this function returns)
with zero network - and a fetched result is persisted for later
revisits."
  (if-let ((hit (and cache (xiiif-image-cache-get url))))
      (progn
        (cl-incf (plist-get xiiif-fetch--stats :cache-hits))
        (with-demoted-errors "xiiif-fetch callback error: %S"
          (funcall callback hit))
        nil)
    (xiiif-fetch--submit 'bytes url nil callback errback priority group
                         cache)))

(cl-defun xiiif-fetch-file (url destination callback &key errback priority group)
  "Schedule an async download of URL to DESTINATION.
See `xiiif-fetch-json' for CALLBACK, ERRBACK, PRIORITY and GROUP.
File downloads are never deduplicated."
  (xiiif-fetch--submit 'file url destination callback errback priority group))

(defun xiiif-fetch-cancel (request)
  "Cancel REQUEST entirely; none of its callbacks will be invoked.
REQUEST is normally a scheduler request object; for convenience a
raw transport handle from the xiiif-api layer is forwarded to
`xiiif-api-cancel', so callers holding either kind can use this
one entry point.  Safe to call with nil or an already-finished
request."
  (cond
   ((xiiif-fetch--request-p request)
    (setq xiiif-fetch--queue (delq request xiiif-fetch--queue))
    (when (memq request xiiif-fetch--active)
      (setq xiiif-fetch--active (delq request xiiif-fetch--active))
      (xiiif-api-cancel (xiiif-fetch--request-handle request)))
    (xiiif-fetch--pump))
   (request (xiiif-api-cancel request))))

(defun xiiif-fetch-cancel-group (group)
  "Cancel every queued or in-flight request tagged with GROUP.
A deduplicated request shared with other groups only sheds GROUP's
callbacks and keeps running for the remaining callers.  GROUP must
be non-nil (untagged requests cannot be cancelled this way)."
  (when group
    (dolist (req (append xiiif-fetch--queue
                         (copy-sequence xiiif-fetch--active)))
      (let ((kept (cl-remove-if
                   (lambda (entry) (equal (plist-get entry :group) group))
                   (xiiif-fetch--request-entries req))))
        (if (null kept)
            (xiiif-fetch-cancel req)
          (setf (xiiif-fetch--request-entries req) kept))))))

(defun xiiif-fetch-stats ()
  "Return a snapshot plist of scheduler counters and gauges.
Counters: :started :completed :failed :deduped :retried
:cache-hits.  Gauges: :queued :active."
  (append (copy-sequence xiiif-fetch--stats)
          (list :queued (length xiiif-fetch--queue)
                :active (length xiiif-fetch--active))))

(defun xiiif-fetch-reset ()
  "Cancel all scheduled work and clear the scheduler state."
  (dolist (req (copy-sequence xiiif-fetch--active))
    (xiiif-api-cancel (xiiif-fetch--request-handle req)))
  (when xiiif-fetch--timer
    (cancel-timer xiiif-fetch--timer)
    (setq xiiif-fetch--timer nil))
  (setq xiiif-fetch--queue nil
        xiiif-fetch--active nil
        xiiif-fetch--stats
        (list :started 0 :completed 0 :failed 0 :deduped 0 :retried 0
              :cache-hits 0))
  (clrhash xiiif-fetch--host-last)
  (clrhash xiiif-fetch--host-until))


;;; ---------- submission ----------

(defun xiiif-fetch--submit (kind url destination callback errback priority
                                 group &optional cache)
  "Queue a KIND request for URL; shared implementation.
DESTINATION only applies to `file' requests; CACHE to `bytes'
requests.  CALLBACK, ERRBACK, PRIORITY and GROUP are as in
`xiiif-fetch-json'."
  (let ((priority (or priority 'interactive)))
    (unless (memq priority '(interactive prefetch))
      (error "xiiif-fetch: invalid priority %S" priority))
    (let ((entry (list :callback callback
                       :errback (or errback #'xiiif-api--default-errback)
                       :group group))
          (existing (and (memq kind '(json bytes))
                         (xiiif-fetch--find kind url))))
      (cond
       (existing
        (cl-incf (plist-get xiiif-fetch--stats :deduped))
        (push entry (xiiif-fetch--request-entries existing))
        (when cache
          (setf (xiiif-fetch--request-cache existing) t))
        ;; An interactive rider promotes a still-queued prefetch.
        (when (and (eq priority 'interactive)
                   (eq (xiiif-fetch--request-priority existing) 'prefetch))
          (setf (xiiif-fetch--request-priority existing) 'interactive))
        existing)
       (t
        (let ((req (xiiif-fetch--request-create
                    :kind kind :url url :destination destination
                    :entries (list entry) :priority priority
                    :attempts 0 :cache cache
                    :host (xiiif-profile--url-host url))))
          (setq xiiif-fetch--queue (append xiiif-fetch--queue (list req)))
          (xiiif-fetch--pump)
          req))))))

(defun xiiif-fetch--find (kind url)
  "Return the queued or active request matching KIND and URL, or nil."
  (let ((match (lambda (req)
                 (and (eq (xiiif-fetch--request-kind req) kind)
                      (equal (xiiif-fetch--request-url req) url)))))
    (or (cl-find-if match xiiif-fetch--active)
        (cl-find-if match xiiif-fetch--queue))))


;;; ---------- dispatch ----------

(defun xiiif-fetch--host-ready-at (req)
  "Return the earliest time REQ may start, honouring host politeness."
  (let* ((host (xiiif-fetch--request-host req))
         (interval (or (xiiif-profile-min-interval
                        (xiiif-fetch--request-url req))
                       xiiif-fetch-host-interval))
         (last (and host (gethash host xiiif-fetch--host-last)))
         (until (and host (gethash host xiiif-fetch--host-until))))
    (max (or until 0)
         (if last (+ last interval) 0))))

(defun xiiif-fetch--dispatch-order ()
  "Queued requests eligible for dispatch, in start order.
While any interactive request waits, prefetch requests are held
back entirely."
  (let ((interactive
         (cl-remove-if-not
          (lambda (r) (eq (xiiif-fetch--request-priority r) 'interactive))
          xiiif-fetch--queue)))
    (or interactive xiiif-fetch--queue)))

(defun xiiif-fetch--pump ()
  "Start every queued request that capacity and politeness allow.
Schedules a deferred pump for the earliest time-blocked request."
  (let ((earliest nil)
        (progress t))
    (while progress
      (setq progress nil)
      (catch 'capacity
        (dolist (req (xiiif-fetch--dispatch-order))
          (when (memq req xiiif-fetch--queue) ; reentrant pumps race us
            (when (>= (length xiiif-fetch--active)
                      xiiif-fetch-max-concurrent)
              (throw 'capacity nil))
            (let ((ready (xiiif-fetch--host-ready-at req)))
              (if (<= ready (xiiif-fetch--now))
                  (progn
                    (xiiif-fetch--start req)
                    (setq progress t))
                (setq earliest (if earliest (min earliest ready)
                                 ready))))))))
    (when earliest
      (when xiiif-fetch--timer (cancel-timer xiiif-fetch--timer))
      (setq xiiif-fetch--timer
            (run-at-time (max 0.01 (- earliest (xiiif-fetch--now)))
                         nil #'xiiif-fetch--timer-pump)))))

(defun xiiif-fetch--timer-pump ()
  "Deferred pump entry point for `run-at-time'."
  (setq xiiif-fetch--timer nil)
  (xiiif-fetch--pump))

(defun xiiif-fetch--start (req)
  "Hand REQ to the transport and move it to the active set."
  (setq xiiif-fetch--queue (delq req xiiif-fetch--queue))
  (push req xiiif-fetch--active)
  (cl-incf (plist-get xiiif-fetch--stats :started))
  (when-let ((host (xiiif-fetch--request-host req)))
    (puthash host (xiiif-fetch--now) xiiif-fetch--host-last))
  (let* ((url (xiiif-fetch--request-url req))
         (callback (lambda (result) (xiiif-fetch--on-success req result)))
         (errback (lambda (err) (xiiif-fetch--on-error req err))))
    (setf (xiiif-fetch--request-handle req)
          (pcase (xiiif-fetch--request-kind req)
            ('json  (xiiif-api-fetch-json-async url callback errback))
            ('bytes (xiiif-api-fetch-bytes-async url callback errback))
            ('file  (xiiif-api-download-file-async
                     url (xiiif-fetch--request-destination req)
                     callback errback))))))


;;; ---------- completion ----------

(defun xiiif-fetch--on-success (req result)
  "Deliver RESULT to every caller of REQ and pump the queue."
  (when (memq req xiiif-fetch--active)
    (setq xiiif-fetch--active (delq req xiiif-fetch--active))
    (cl-incf (plist-get xiiif-fetch--stats :completed))
    (when (and (xiiif-fetch--request-cache req)
               (eq (xiiif-fetch--request-kind req) 'bytes))
      (xiiif-image-cache-put (xiiif-fetch--request-url req) result))
    (dolist (entry (reverse (xiiif-fetch--request-entries req)))
      (with-demoted-errors "xiiif-fetch callback error: %S"
        (funcall (plist-get entry :callback) result)))
    (xiiif-fetch--pump)))

(defun xiiif-fetch--retry-after (err)
  "Return the :retry-after seconds carried by ERR, or nil."
  (plist-get (nthcdr 3 err) :retry-after))

(defun xiiif-fetch--on-error (req err)
  "Retry REQ after 429/503, otherwise fail it with ERR."
  (when (memq req xiiif-fetch--active)
    (setq xiiif-fetch--active (delq req xiiif-fetch--active))
    (let ((status (and (eq (car-safe err) 'xiiif-http-error)
                       (nth 2 err))))
      (cond
       ((and (memq status '(429 503))
             (< (xiiif-fetch--request-attempts req)
                xiiif-fetch-max-retries))
        (cl-incf (xiiif-fetch--request-attempts req))
        (cl-incf (plist-get xiiif-fetch--stats :retried))
        (when-let ((host (xiiif-fetch--request-host req)))
          (puthash host
                   (+ (xiiif-fetch--now)
                      (or (xiiif-fetch--retry-after err)
                          (* xiiif-fetch-retry-backoff
                             (expt 2 (1- (xiiif-fetch--request-attempts
                                          req))))))
                   xiiif-fetch--host-until))
        (setf (xiiif-fetch--request-handle req) nil)
        ;; Retry ahead of its queued peers.
        (push req xiiif-fetch--queue))
       (t
        (cl-incf (plist-get xiiif-fetch--stats :failed))
        (dolist (entry (reverse (xiiif-fetch--request-entries req)))
          (with-demoted-errors "xiiif-fetch errback error: %S"
            (funcall (plist-get entry :errback) err))))))
    (xiiif-fetch--pump)))

(provide 'xiiif-fetch)
;;; xiiif-fetch.el ends here
