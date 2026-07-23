;;; xiiif-fetch-test.el --- Tests for the request scheduler -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercises xiiif-fetch entirely offline: the xiiif-api transport is
;; replaced with a recording stub, the scheduler clock and timers are
;; driven by hand.  Covers the concurrency cap, per-host politeness,
;; profile :min-interval overrides, deduplication, priorities,
;; grouped cancellation and Retry-After honouring.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-fetch)

(defvar xiiif-fetch-test--calls nil
  "Recorded transport calls, newest first.
Each is a plist (:kind K :url U :destination D :callback CB
:errback EB :handle H).")

(defvar xiiif-fetch-test--now 1000.0)

(defvar xiiif-fetch-test--timers nil
  "Fake timers, each (:delay SECS :fn FN :args ARGS).")

(defvar xiiif-fetch-test--cancelled nil
  "Handles passed to the stubbed `xiiif-api-cancel'.")

(defun xiiif-fetch-test--record (kind url dest cb eb)
  (let* ((handle (list 'handle kind url))
         (call (list :kind kind :url url :destination dest
                     :callback cb :errback eb :handle handle)))
    (push call xiiif-fetch-test--calls)
    handle))

(defmacro xiiif-fetch-test--with (&rest body)
  "Run BODY against a stubbed transport, clock and timer wheel."
  (declare (indent 0) (debug (body)))
  `(let ((xiiif-fetch-test--calls nil)
         (xiiif-fetch-test--now 1000.0)
         (xiiif-fetch-test--timers nil)
         (xiiif-fetch-test--cancelled nil)
         (xiiif-fetch-host-interval 0)
         (xiiif-fetch-max-concurrent 4)
         (xiiif-fetch-max-retries 3)
         (xiiif-fetch-retry-backoff 1.0)
         (xiiif-server-profiles nil))
     (cl-letf (((symbol-function 'xiiif-fetch--now)
                (lambda () xiiif-fetch-test--now))
               ((symbol-function 'xiiif-api-fetch-json-async)
                (lambda (url cb eb)
                  (xiiif-fetch-test--record 'json url nil cb eb)))
               ((symbol-function 'xiiif-api-fetch-bytes-async)
                (lambda (url cb eb)
                  (xiiif-fetch-test--record 'bytes url nil cb eb)))
               ((symbol-function 'xiiif-api-download-file-async)
                (lambda (url dest cb &optional eb)
                  (xiiif-fetch-test--record 'file url dest cb eb)))
               ((symbol-function 'xiiif-api-cancel)
                (lambda (handle)
                  (push handle xiiif-fetch-test--cancelled)))
               ((symbol-function 'run-at-time)
                (lambda (delay _repeat fn &rest args)
                  (let ((timer (list :delay delay :fn fn :args args)))
                    (push timer xiiif-fetch-test--timers)
                    timer)))
               ((symbol-function 'cancel-timer)
                (lambda (timer)
                  (setq xiiif-fetch-test--timers
                        (delq timer xiiif-fetch-test--timers)))))
       (unwind-protect
           (progn ,@body)
         (xiiif-fetch-reset)))))

(defun xiiif-fetch-test--started ()
  "URLs handed to the transport, oldest first."
  (mapcar (lambda (c) (plist-get c :url))
          (reverse xiiif-fetch-test--calls)))

(defun xiiif-fetch-test--call-for (url)
  "Most recent transport call for URL."
  (cl-find-if (lambda (c) (equal (plist-get c :url) url))
              xiiif-fetch-test--calls))

(defun xiiif-fetch-test--complete (url result)
  "Invoke the success callback of the transport call for URL."
  (funcall (plist-get (xiiif-fetch-test--call-for url) :callback) result))

(defun xiiif-fetch-test--fail (url err)
  "Invoke the errback of the transport call for URL."
  (funcall (plist-get (xiiif-fetch-test--call-for url) :errback) err))

(defun xiiif-fetch-test--fire-timers ()
  "Run every pending fake timer once."
  (let ((timers xiiif-fetch-test--timers))
    (setq xiiif-fetch-test--timers nil)
    (dolist (timer (nreverse timers))
      (apply (plist-get timer :fn) (plist-get timer :args)))))


;;; ---- concurrency cap ----

(ert-deftest xiiif-fetch/concurrency-cap ()
  (xiiif-fetch-test--with
    (let ((xiiif-fetch-max-concurrent 2))
      (dotimes (i 3)
        (xiiif-fetch-json (format "http://h/%d" i) #'ignore))
      (should (equal '("http://h/0" "http://h/1")
                     (xiiif-fetch-test--started)))
      (xiiif-fetch-test--complete "http://h/0" '((ok . t)))
      (should (equal '("http://h/0" "http://h/1" "http://h/2")
                     (xiiif-fetch-test--started))))))


;;; ---- per-host politeness ----

(ert-deftest xiiif-fetch/host-interval-respected ()
  (xiiif-fetch-test--with
    (let ((xiiif-fetch-host-interval 10))
      (xiiif-fetch-json "http://slow/1" #'ignore)
      (xiiif-fetch-json "http://slow/2" #'ignore)
      (xiiif-fetch-json "http://other/1" #'ignore)
      ;; Same host throttled; a different host is unaffected.
      (should (equal '("http://slow/1" "http://other/1")
                     (xiiif-fetch-test--started)))
      (should xiiif-fetch-test--timers)
      ;; Not yet: the interval has not elapsed.
      (setq xiiif-fetch-test--now 1005.0)
      (xiiif-fetch-test--fire-timers)
      (should (= 2 (length (xiiif-fetch-test--started))))
      (setq xiiif-fetch-test--now 1010.5)
      (xiiif-fetch-test--fire-timers)
      (should (equal '("http://slow/1" "http://other/1" "http://slow/2")
                     (xiiif-fetch-test--started))))))

(ert-deftest xiiif-fetch/profile-min-interval-overrides ()
  (xiiif-fetch-test--with
    (let ((xiiif-server-profiles '(("gallica" . (:min-interval 5)))))
      (xiiif-fetch-json "http://gallica.example/1" #'ignore)
      (xiiif-fetch-json "http://gallica.example/2" #'ignore)
      (should (= 1 (length (xiiif-fetch-test--started))))
      (setq xiiif-fetch-test--now 1005.1)
      (xiiif-fetch-test--fire-timers)
      (should (= 2 (length (xiiif-fetch-test--started)))))))


;;; ---- deduplication ----

(ert-deftest xiiif-fetch/dedup-same-url-one-transfer ()
  (xiiif-fetch-test--with
    (let (got1 got2)
      (xiiif-fetch-json "http://h/m" (lambda (r) (setq got1 r)))
      (xiiif-fetch-json "http://h/m" (lambda (r) (setq got2 r)))
      (should (= 1 (length xiiif-fetch-test--calls)))
      (should (= 1 (plist-get (xiiif-fetch-stats) :deduped)))
      (xiiif-fetch-test--complete "http://h/m" '((a . 1)))
      (should (equal '((a . 1)) got1))
      (should (equal '((a . 1)) got2)))))

(ert-deftest xiiif-fetch/no-dedup-across-kinds ()
  (xiiif-fetch-test--with
    (xiiif-fetch-json "http://h/r" #'ignore)
    (xiiif-fetch-bytes "http://h/r" #'ignore)
    (should (= 2 (length xiiif-fetch-test--calls)))))


;;; ---- priorities ----

(ert-deftest xiiif-fetch/interactive-before-prefetch ()
  (xiiif-fetch-test--with
    (let ((xiiif-fetch-max-concurrent 1))
      (xiiif-fetch-json "http://h/busy" #'ignore)
      (xiiif-fetch-json "http://h/pre" #'ignore :priority 'prefetch)
      (xiiif-fetch-json "http://h/inter" #'ignore)
      (should (equal '("http://h/busy") (xiiif-fetch-test--started)))
      (xiiif-fetch-test--complete "http://h/busy" nil)
      ;; The later interactive request outranks the earlier prefetch.
      (should (equal '("http://h/busy" "http://h/inter")
                     (xiiif-fetch-test--started)))
      (xiiif-fetch-test--complete "http://h/inter" nil)
      (should (equal '("http://h/busy" "http://h/inter" "http://h/pre")
                     (xiiif-fetch-test--started))))))

(ert-deftest xiiif-fetch/waiting-interactive-blocks-prefetch ()
  "A time-blocked interactive request still holds prefetch back."
  (xiiif-fetch-test--with
    (let ((xiiif-fetch-host-interval 10))
      (xiiif-fetch-json "http://h/1" #'ignore)
      (xiiif-fetch-json "http://h/2" #'ignore)        ; blocked 10s
      (xiiif-fetch-json "http://other/pre" #'ignore :priority 'prefetch)
      (should (equal '("http://h/1") (xiiif-fetch-test--started)))
      (setq xiiif-fetch-test--now 1010.5)
      (xiiif-fetch-test--fire-timers)
      ;; Once the interactive request departs, prefetch may follow.
      (should (equal '("http://h/1" "http://h/2" "http://other/pre")
                     (xiiif-fetch-test--started))))))

(ert-deftest xiiif-fetch/dedup-promotes-queued-prefetch ()
  (xiiif-fetch-test--with
    (let ((xiiif-fetch-max-concurrent 1))
      (xiiif-fetch-json "http://h/busy" #'ignore)
      (xiiif-fetch-json "http://h/p" #'ignore :priority 'prefetch)
      (xiiif-fetch-json "http://h/q" #'ignore)
      ;; Riding an interactive request onto the queued prefetch
      ;; promotes it ahead of other interactive work already queued?
      ;; No - it only joins the interactive class, keeping FIFO order.
      (xiiif-fetch-json "http://h/p" #'ignore)
      (xiiif-fetch-test--complete "http://h/busy" nil)
      (should (equal '("http://h/busy" "http://h/p")
                     (xiiif-fetch-test--started))))))


;;; ---- grouped cancellation ----

(ert-deftest xiiif-fetch/cancel-group-queued-silent ()
  (xiiif-fetch-test--with
    (let ((xiiif-fetch-max-concurrent 1)
          (fired nil))
      (xiiif-fetch-json "http://h/busy" #'ignore)
      (xiiif-fetch-json "http://h/a"
                        (lambda (_) (setq fired t))
                        :errback (lambda (_) (setq fired t))
                        :group 'view)
      (xiiif-fetch-cancel-group 'view)
      (xiiif-fetch-test--complete "http://h/busy" nil)
      (should (equal '("http://h/busy") (xiiif-fetch-test--started)))
      (should-not fired))))

(ert-deftest xiiif-fetch/cancel-group-active-cancels-transport ()
  (xiiif-fetch-test--with
    (xiiif-fetch-json "http://h/a" #'ignore :group 'view)
    (let ((handle (plist-get (xiiif-fetch-test--call-for "http://h/a")
                             :handle)))
      (xiiif-fetch-cancel-group 'view)
      (should (memq handle xiiif-fetch-test--cancelled))
      (should (zerop (plist-get (xiiif-fetch-stats) :active))))))

(ert-deftest xiiif-fetch/cancel-group-keeps-shared-request ()
  (xiiif-fetch-test--with
    (let (kept dropped)
      (xiiif-fetch-json "http://h/m" (lambda (_) (setq dropped t))
                        :group 'old)
      (xiiif-fetch-json "http://h/m" (lambda (r) (setq kept r))
                        :group 'new)
      (xiiif-fetch-cancel-group 'old)
      ;; The shared transfer survives for the remaining group.
      (should-not xiiif-fetch-test--cancelled)
      (xiiif-fetch-test--complete "http://h/m" '((a . 1)))
      (should (equal '((a . 1)) kept))
      (should-not dropped))))


;;; ---- Retry-After and backoff ----

(ert-deftest xiiif-fetch/retry-after-honoured ()
  (xiiif-fetch-test--with
    (let (got)
      (xiiif-fetch-json "http://h/m" (lambda (r) (setq got r)))
      (xiiif-fetch-test--fail
       "http://h/m" '(xiiif-http-error "http://h/m" 429 :retry-after 30))
      ;; Requeued, not failed; host suspended for 30s.
      (should (= 1 (length xiiif-fetch-test--calls)))
      (should (= 1 (plist-get (xiiif-fetch-stats) :retried)))
      (setq xiiif-fetch-test--now 1015.0)
      (xiiif-fetch-test--fire-timers)
      (should (= 1 (length xiiif-fetch-test--calls)))
      (setq xiiif-fetch-test--now 1030.5)
      (xiiif-fetch-test--fire-timers)
      (should (= 2 (length xiiif-fetch-test--calls)))
      (xiiif-fetch-test--complete "http://h/m" '((a . 1)))
      (should (equal '((a . 1)) got)))))

(ert-deftest xiiif-fetch/backoff-without-retry-after ()
  (xiiif-fetch-test--with
    (let ((xiiif-fetch-retry-backoff 2.0))
      (xiiif-fetch-json "http://h/m" #'ignore)
      (xiiif-fetch-test--fail "http://h/m"
                              '(xiiif-http-error "http://h/m" 503))
      ;; First retry: 2 * 2^0 = 2s of host suspension.
      (setq xiiif-fetch-test--now 1001.0)
      (xiiif-fetch-test--fire-timers)
      (should (= 1 (length xiiif-fetch-test--calls)))
      (setq xiiif-fetch-test--now 1002.1)
      (xiiif-fetch-test--fire-timers)
      (should (= 2 (length xiiif-fetch-test--calls))))))

(ert-deftest xiiif-fetch/retries-exhausted-fails-with-original-error ()
  (xiiif-fetch-test--with
    (let ((xiiif-fetch-max-retries 1)
          (captured nil))
      (xiiif-fetch-json "http://h/m" #'ignore
                        :errback (lambda (err) (setq captured err)))
      (xiiif-fetch-test--fail "http://h/m"
                              '(xiiif-http-error "http://h/m" 429))
      (setq xiiif-fetch-test--now 1002.0)
      (xiiif-fetch-test--fire-timers)
      (should (= 2 (length xiiif-fetch-test--calls)))
      (xiiif-fetch-test--fail "http://h/m"
                              '(xiiif-http-error "http://h/m" 429))
      ;; Retries exhausted: the original error reaches the errback.
      (should (equal '(xiiif-http-error "http://h/m" 429) captured))
      (should (= 1 (plist-get (xiiif-fetch-stats) :failed))))))

(ert-deftest xiiif-fetch/non-retryable-error-fails-immediately ()
  (xiiif-fetch-test--with
    (let ((captured nil))
      (xiiif-fetch-json "http://h/m" #'ignore
                        :errback (lambda (err) (setq captured err)))
      (xiiif-fetch-test--fail "http://h/m"
                              '(xiiif-http-error "http://h/m" 404))
      (should (equal '(xiiif-http-error "http://h/m" 404) captured))
      (should (= 1 (length xiiif-fetch-test--calls))))))


;;; ---- misc ----

(ert-deftest xiiif-fetch/file-download-passes-destination ()
  (xiiif-fetch-test--with
    (let (got)
      (xiiif-fetch-file "http://h/i.jpg" "/tmp/i.jpg"
                        (lambda (path) (setq got path)))
      (let ((call (xiiif-fetch-test--call-for "http://h/i.jpg")))
        (should (eq 'file (plist-get call :kind)))
        (should (equal "/tmp/i.jpg" (plist-get call :destination))))
      (xiiif-fetch-test--complete "http://h/i.jpg" "/tmp/i.jpg")
      (should (equal "/tmp/i.jpg" got)))))

(ert-deftest xiiif-fetch/synchronous-errback-keeps-scheduler-sane ()
  "A transport that errbacks during the start call (invalid URL
under the url backend) must not wedge the queue."
  (xiiif-fetch-test--with
    (let ((captured nil))
      (cl-letf (((symbol-function 'xiiif-api-fetch-json-async)
                 (lambda (url _cb eb)
                   (if (string-match-p "bad" url)
                       (progn
                         (funcall eb (list 'xiiif-network-error url
                                           "invalid URL"))
                         nil)
                     (xiiif-fetch-test--record 'json url nil _cb eb)))))
        (xiiif-fetch-json "http://h/bad" #'ignore
                          :errback (lambda (err) (setq captured err)))
        (should (equal '(xiiif-network-error "http://h/bad" "invalid URL")
                       captured))
        (should (zerop (plist-get (xiiif-fetch-stats) :active)))
        ;; The scheduler keeps serving later requests.
        (xiiif-fetch-json "http://h/good" #'ignore)
        (should (equal '("http://h/good")
                       (xiiif-fetch-test--started)))))))

;;; ---- image cache integration ----

(defmacro xiiif-fetch-test--with-image-cache (&rest body)
  "Run BODY inside the scheduler harness with a temp image cache."
  (declare (indent 0) (debug (body)))
  `(xiiif-fetch-test--with
     (let* ((dir (make-temp-file "xiiif-fetch-imgc-" t))
            (xiiif-image-cache-directory dir)
            (xiiif-image-cache-enabled t))
       (unwind-protect
           (progn ,@body)
         (when (file-directory-p dir)
           (dolist (f (directory-files dir t "^[^.]"))
             (ignore-errors (delete-file f)))
           (ignore-errors (delete-directory dir)))))))

(ert-deftest xiiif-fetch/bytes-cache-stores-fetched-result ()
  (xiiif-fetch-test--with-image-cache
    (let (got)
      (xiiif-fetch-bytes "http://h/i.jpg" (lambda (b) (setq got b))
                         :cache t)
      (should (= 1 (length xiiif-fetch-test--calls)))
      (xiiif-fetch-test--complete "http://h/i.jpg" "imagebytes")
      (should (equal "imagebytes" got))
      (should (equal "imagebytes"
                     (xiiif-image-cache-get "http://h/i.jpg"))))))

(ert-deftest xiiif-fetch/bytes-cache-hit-skips-network ()
  (xiiif-fetch-test--with-image-cache
    (xiiif-image-cache-put "http://h/i.jpg" "cachedbytes")
    (let (got)
      (should-not (xiiif-fetch-bytes "http://h/i.jpg"
                                     (lambda (b) (setq got b))
                                     :cache t))
      ;; Delivered synchronously, zero transport calls.
      (should (equal "cachedbytes" got))
      (should-not xiiif-fetch-test--calls)
      (should (= 1 (plist-get (xiiif-fetch-stats) :cache-hits))))))

(ert-deftest xiiif-fetch/bytes-without-cache-flag-not-persisted ()
  (xiiif-fetch-test--with-image-cache
    (xiiif-fetch-bytes "http://h/i.jpg" #'ignore)
    (xiiif-fetch-test--complete "http://h/i.jpg" "imagebytes")
    (should-not (xiiif-image-cache-get "http://h/i.jpg"))))


(ert-deftest xiiif-fetch/stats-gauges ()
  (xiiif-fetch-test--with
    (let ((xiiif-fetch-max-concurrent 1))
      (xiiif-fetch-json "http://h/1" #'ignore)
      (xiiif-fetch-json "http://h/2" #'ignore)
      (let ((stats (xiiif-fetch-stats)))
        (should (= 1 (plist-get stats :active)))
        (should (= 1 (plist-get stats :queued)))
        (should (= 1 (plist-get stats :started))))
      (xiiif-fetch-test--complete "http://h/1" nil)
      (xiiif-fetch-test--complete "http://h/2" nil)
      (let ((stats (xiiif-fetch-stats)))
        (should (zerop (plist-get stats :active)))
        (should (zerop (plist-get stats :queued)))
        (should (= 2 (plist-get stats :completed)))))))

(provide 'xiiif-fetch-test)
;;; xiiif-fetch-test.el ends here
