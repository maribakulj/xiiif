;;; xiiif-api.el --- HTTP/JSON transport for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; HTTP/JSON transport with two switchable backends (see
;; `xiiif-api-backend'): the built-in `url.el' (universal fallback,
;; zero dependencies) and, when installed, the GNU ELPA `plz'
;; package (curl-based: robust TLS and redirects, HTTP/2, downloads
;; streamed to disk).  Exposes both a synchronous helper
;; (`xiiif-api-fetch-json', useful for scripting and tests) and a
;; non-blocking version (`xiiif-api-fetch-json-async', used by all
;; interactive commands so Emacs stays responsive on slow
;; manifests).  All transport, HTTP-status and JSON-decode errors
;; are translated into the dedicated `xiiif-' error symbols defined
;; in xiiif-errors.el, so higher layers only need to handle
;; well-typed failures, whichever backend serves the request.

;;; Code:

(require 'json)
(require 'url)
(require 'url-http)
(require 'xiiif-errors)
(require 'xiiif-profiles)
(require 'xiiif-http-cache)

(defcustom xiiif-api-timeout 30
  "Timeout in seconds for synchronous IIIF HTTP requests."
  :type 'integer
  :group 'xiiif)

(defcustom xiiif-api-user-agent
  (format "xiiif.el/0.3.0 Emacs/%s" emacs-version)
  "User-Agent string used for IIIF HTTP requests."
  :type 'string
  :group 'xiiif)

(defcustom xiiif-api-max-body-size (* 50 1024 1024)
  "Maximum response body size in bytes accepted by xiiif fetches.
When a response advertises a larger body via `Content-Length', the
fetch fails with a `xiiif-body-too-large' error instead of handing
the oversized body to the JSON parser or image decoder.  Set to nil
to disable the guard."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'xiiif)

(defcustom xiiif-api-backend 'auto
  "HTTP transport backend used for IIIF requests.
`auto' uses the GNU ELPA `plz' package (curl-based: robust TLS and
redirects, HTTP/2 multiplexing) when it is installed and curl is
found, falling back to the built-in `url' library otherwise.  Force
one of the two with `url' or `plz'.  When set to `plz' but plz or
curl is missing, xiiif warns once and uses `url'.

The public fetch API is identical under both backends: same
functions, same callback and errback protocol, same cancellable
handles (`xiiif-api-cancel' accepts either kind)."
  :type '(choice (const :tag "plz when available, else url" auto)
                 (const :tag "Built-in url library" url)
                 (const :tag "plz (curl)" plz))
  :group 'xiiif)

;; plz is strictly optional; everything below is resolved at runtime
;; and only reached once (require 'plz nil t) has succeeded.
(declare-function plz "plz")
(declare-function plz-error-p "plz")
(declare-function plz-error-response "plz")
(declare-function plz-error-curl-error "plz")
(declare-function plz-error-message "plz")
(declare-function plz-response-status "plz")
(declare-function plz-response-headers "plz")
(declare-function plz-response-body "plz")
(defvar plz-curl-program)

(defvar xiiif-api--plz-warned nil
  "Non-nil once the plz-unavailable fallback warning has been shown.")

(defun xiiif-api--plz-available-p ()
  "Return non-nil when the `plz' backend is usable.
plz is looked up at runtime and is never a package dependency."
  (and (require 'plz nil t)
       (executable-find plz-curl-program)
       t))

(defun xiiif-api--backend ()
  "Return the effective transport backend, the symbol `url' or `plz'."
  (pcase xiiif-api-backend
    ('url 'url)
    ('plz (if (xiiif-api--plz-available-p)
              'plz
            (unless xiiif-api--plz-warned
              (setq xiiif-api--plz-warned t)
              (display-warning
               'xiiif
               "xiiif-api-backend is plz, but the plz package or curl is unavailable; using url"
               :warning))
            'url))
    (_ (if (xiiif-api--plz-available-p) 'plz 'url))))

(defun xiiif-api--backend-for (url)
  "Return the transport backend to use for URL.
file:// URLs always go through the url backend: curl can read
them, but plz's HTTP response parsing does not apply to them."
  (if (and (stringp url) (string-prefix-p "file://" url))
      'url
    (xiiif-api--backend)))

(defun xiiif-api--valid-url-p (url)
  "Return non-nil if URL looks like a supported URL.
Accepts http(s):// and file:// schemes.  file:// URLs are mostly
useful for reading local IIIF fixtures during development; downloads
through `url-copy-file' also honour them."
  (and (stringp url)
       (string-match-p "\\`\\(?:https?\\|file\\)://[^[:space:]]+\\'" url)))

(defun xiiif-api--status-code ()
  "Parse the HTTP status code from the current `url' response buffer.
Point must be at the beginning of the buffer.  Returns an integer or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
      (string-to-number (match-string 1)))))

(defun xiiif-api--skip-headers ()
  "Move point past the HTTP header section in a `url' response buffer."
  (goto-char (point-min))
  (unless (re-search-forward "\r?\n\r?\n" nil t)
    (signal 'xiiif-parse-error (list "malformed HTTP response: no body"))))

(defun xiiif-api--decode-body ()
  "Return the body of the current `url' buffer as a decoded string."
  (xiiif-api--skip-headers)
  (decode-coding-region (point) (point-max) 'utf-8 t))

(defun xiiif-api--parse-json (body url)
  "Parse BODY as JSON or signal `xiiif-parse-error' with URL context.
Uses the native `json-parse-string' when the running Emacs provides
it (much faster on large manifests), configured to produce the same
shapes as the pure-Elisp reader: alists with symbol keys, vectors,
`:json-false' for false and nil for null.  Falls back to
`json-read-from-string' otherwise."
  (condition-case err
      (if (fboundp 'json-parse-string)
          (json-parse-string body
                             :object-type 'alist
                             :array-type 'array
                             :null-object nil
                             :false-object :json-false)
        (let ((json-object-type 'alist)
              (json-array-type  'vector)
              (json-key-type    'symbol)
              (json-false       :json-false)
              (json-null        nil))
          (json-read-from-string body)))
    (error
     (signal 'xiiif-parse-error
             (list url (error-message-string err))))))

(defun xiiif-api--content-type ()
  "Return the Content-Type header value of the current response buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward
           "^Content-Type:[ \t]*\\([^\r\n;]+\\)" nil t)
      (downcase (string-trim (match-string 1))))))

(defun xiiif-api--header-value (name)
  "Return the value of response header NAME in the current buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward
           (format "^%s:[ \t]*\\(.*?\\)[ \t]*\r?$"
                   (regexp-quote name))
           nil t)
      (match-string 1))))

(defun xiiif-api--retry-after-seconds (value)
  "Parse a Retry-After header VALUE into seconds, or nil.
VALUE may be a delay in seconds or an HTTP date."
  (when (stringp value)
    (let ((trimmed (string-trim value)))
      (cond
       ((string-match-p "\\`[0-9]+\\'" trimmed)
        (string-to-number trimmed))
       (t (ignore-errors
            (max 0 (- (float-time (date-to-time trimmed))
                      (float-time)))))))))

(defun xiiif-api--http-error-data (url status &optional retry-after)
  "Build `xiiif-http-error' data for URL and STATUS.
When RETRY-AFTER (seconds) is non-nil it is appended as a
`:retry-after' pair so schedulers can honour the server's demand."
  (append (list url status)
          (and retry-after (list :retry-after retry-after))))

(defun xiiif-api--check-body-size (url)
  "Signal `xiiif-body-too-large' when the response body is oversized.
The current buffer must be a `url' response buffer.  The check only
fires when `xiiif-api-max-body-size' is non-nil and the response
advertises a larger body via `Content-Length'; the error data is
\(URL LENGTH LIMIT)."
  (when xiiif-api-max-body-size
    (let* ((header (xiiif-api--header-value "Content-Length"))
           (length (and header (string-to-number header))))
      (when (and length (> length xiiif-api-max-body-size))
        (signal 'xiiif-body-too-large
                (list url length xiiif-api-max-body-size))))))

(defun xiiif-api--warn-content-type (url ct)
  "Emit a lazy warning when CT is present and does not look like JSON."
  (when (and ct (not (string-match-p
                       "\\(?:application/ld\\+json\\|application/json\\|\\+json\\)"
                       ct)))
    (display-warning
     'xiiif
     (format "Unexpected Content-Type %S from %s (parsing as JSON anyway)"
             ct url)
     :warning)))

(defun xiiif-api--cached-json-or-error (url)
  "Return the cached JSON body for URL after a 304 response.
Signals `xiiif-http-error' when no cache entry backs the 304."
  (let ((entry (xiiif-http-cache-lookup url)))
    (unless entry
      (signal 'xiiif-http-error
              (list url 304 "304 without cache entry")))
    (xiiif-api--parse-json (plist-get entry :body) url)))

(defun xiiif-api--response-json (url)
  "Parse the current `url' response buffer as IIIF JSON for URL.
Signals `xiiif-http-error' on non-4xx/5xx responses (other than
304, which is served from the on-disk cache) and `xiiif-parse-error'
on invalid JSON.  A mismatching Content-Type triggers a lazy
`display-warning' but is not treated as an error.  On 2xx responses
that carry an `ETag' or `Last-Modified' validator, the decoded body
is persisted via `xiiif-http-cache-store' for future conditional
fetches."
  (let ((status (xiiif-api--status-code))
        (ct     (xiiif-api--content-type)))
    (cond
     ((eql status 304)
      (xiiif-api--cached-json-or-error url))
     ((and status (or (< status 200) (>= status 400)))
      (signal 'xiiif-http-error
              (xiiif-api--http-error-data
               url status
               (xiiif-api--retry-after-seconds
                (xiiif-api--header-value "Retry-After")))))
     (t
      (xiiif-api--check-body-size url)
      (xiiif-api--warn-content-type url ct)
      (let ((body (xiiif-api--decode-body))
            (etag (xiiif-api--header-value "ETag"))
            (lm   (xiiif-api--header-value "Last-Modified")))
        (when (or etag lm)
          (xiiif-http-cache-store url body etag lm))
        (xiiif-api--parse-json body url))))))

(defun xiiif-api--request-headers (&optional url)
  "Return the HTTP request header alist used by every xiiif call.
When URL matches an entry in `xiiif-server-profiles', any explicit
`:headers' are appended and, if the profile declares `:auth', an
`Authorization' header is resolved via `auth-source' and appended
last (so an explicit `:headers' entry still wins for the same
header name).  Conditional cache validators
(`If-None-Match' / `If-Modified-Since') are appended when a cached
entry exists for URL."
  (let* ((base
          `(("Accept"     . "application/ld+json, application/json")
            ("User-Agent" . ,xiiif-api-user-agent)))
         (profile-headers (xiiif-profile-headers url))
         (auth (unless (assoc-string "Authorization" profile-headers t)
                 (xiiif-profile-auth-header url)))
         (conditional (and url (xiiif-http-cache-conditional-headers url))))
    (append base
            profile-headers
            (and auth (list auth))
            conditional)))

(defun xiiif-api-fetch-json (url)
  "Fetch URL synchronously and return parsed JSON.

Signals `xiiif-network-error' on transport failure,
`xiiif-http-error' on non-2xx responses, and
`xiiif-parse-error' on invalid JSON.  Dispatches to the transport
backend selected by `xiiif-api-backend'.

For a non-blocking version, see `xiiif-api-fetch-json-async'."
  (unless (xiiif-api--valid-url-p url)
    (signal 'xiiif-network-error (list url "invalid URL")))
  (if (eq (xiiif-api--backend-for url) 'plz)
      (xiiif-api--plz-fetch-json url)
    (xiiif-api--url-fetch-json url)))

(defun xiiif-api--url-fetch-json (url)
  "url.el backend for `xiiif-api-fetch-json'."
  (let* ((url-request-extra-headers (xiiif-api--request-headers url))
         (url-mime-accept-string
          "application/ld+json, application/json")
         (buffer (condition-case err
                     (url-retrieve-synchronously url t t xiiif-api-timeout)
                   (error
                    (signal 'xiiif-network-error
                            (list url (error-message-string err)))))))
    (unwind-protect
        (progn
          (unless (buffer-live-p buffer)
            (signal 'xiiif-network-error (list url "no response")))
          (with-current-buffer buffer
            (xiiif-api--response-json url)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defvar xiiif-api-last-error nil
  "The most recent asynchronous fetch error as a list (SYMBOL URL &rest DATA).
Used by `xiiif-retry-last' to re-attempt the offending request.")

(defun xiiif-api-error-hint (err)
  "Return a human-readable message for ERR.
ERR is the list (ERROR-SYMBOL URL &rest DATA) produced by the
`xiiif-api' errback protocol."
  (pcase-let* ((`(,sym ,url . ,rest) err)
               (detail (car rest)))
    (pcase sym
      ('xiiif-body-too-large
       (format "xiiif: response from %s is too large (%s > %s bytes)"
               url detail (cadr rest)))
      ('xiiif-http-error
       (pcase detail
         (401 (format "xiiif: %s requires authentication (HTTP 401)" url))
         (403 (format "xiiif: access denied to %s (HTTP 403)" url))
         (404 (format "xiiif: not found: %s (HTTP 404)" url))
         (410 (format "xiiif: resource gone: %s (HTTP 410)" url))
         (429 (format "xiiif: rate limited: %s (HTTP 429, try later)" url))
         ((and (pred numberp) code (guard (>= code 500)))
          (format "xiiif: upstream error %s at %s" code url))
         (code (format "xiiif: HTTP %s for %s" code url))))
      ('xiiif-parse-error
       (format "xiiif: could not parse %s (%s)"
               (or url "?") (or detail "invalid JSON")))
      ('xiiif-network-error
       (format "xiiif: network error for %s%s"
               (or url "?")
               (if detail (format ": %s" detail) "")))
      (_ (format "xiiif: %s for %s%s"
                 (or sym 'xiiif-error)
                 (or url "?")
                 (if detail (format ": %s" detail) ""))))))

(defun xiiif-api--default-errback (err)
  "Default async error reporter: record ERR and show a tailored message.
Subsequent calls to `xiiif-retry-last' will re-issue the offending URL."
  (setq xiiif-api-last-error err)
  (message "%s" (xiiif-api-error-hint err)))

(defun xiiif-api-fetch-json-async (url callback &optional errback)
  "Fetch URL asynchronously.

On success, CALLBACK is called with the parsed JSON value.
On failure, ERRBACK is called with a list (ERROR-SYMBOL URL &rest DATA);
when ERRBACK is nil, `xiiif-api--default-errback' shows a message.

Returns a cancellable handle - the `url-retrieve' response buffer
under the url backend, the curl process object under plz - or nil
when the URL was invalid.  Both CALLBACK and ERRBACK run on
Emacs's main thread, so they may update buffers and UI directly.
To cancel an in-flight request, pass the returned handle to
`xiiif-api-cancel'."
  (let ((errback (or errback #'xiiif-api--default-errback)))
    (if (not (xiiif-api--valid-url-p url))
        (progn
          (funcall errback (list 'xiiif-network-error url "invalid URL"))
          nil)
      (if (eq (xiiif-api--backend-for url) 'plz)
          (xiiif-api--plz-fetch-json-async url callback errback)
        (xiiif-api--url-fetch-json-async url callback errback)))))

(defun xiiif-api--url-fetch-json-async (url callback errback)
  "url.el backend for `xiiif-api-fetch-json-async'."
  (let ((url-request-extra-headers (xiiif-api--request-headers url))
        (url-mime-accept-string
         "application/ld+json, application/json"))
    (condition-case err
        (url-retrieve
         url
         (lambda (status)
           (let ((response-buffer (current-buffer)))
             (unwind-protect
                 (condition-case handler-err
                     (let ((net-err (plist-get status :error)))
                       (when net-err
                         (signal 'xiiif-network-error
                                 (list url (error-message-string
                                            net-err))))
                       (funcall callback
                                (xiiif-api--response-json url)))
                   (xiiif-error
                    (funcall errback handler-err))
                   (error
                    (funcall errback
                             (list 'xiiif-error url
                                   (error-message-string handler-err)))))
               (when (buffer-live-p response-buffer)
                 (kill-buffer response-buffer)))))
         nil t t)
      (error
       (funcall errback
                (list 'xiiif-network-error url
                      (error-message-string err)))
       nil))))

(defun xiiif-api-cancel (handle)
  "Cancel an in-flight request referenced by HANDLE.
HANDLE is the value returned by an asynchronous xiiif-api fetch: a
`url-retrieve' response buffer under the url backend, or a curl
process object under plz.  Killing the buffer (or deleting the
process) aborts the callback chain.  For plz the stored callbacks
are neutralised before the process is killed, so the kill artifact
reaches no user code; as a second line of defence the plz error
router also recognises killed-process events.  Safe to call with
nil, a dead buffer or a dead process."
  (cond
   ((processp handle)
    (when (process-live-p handle)
      ;; plz keeps THEN/ELSE as process properties; blank them so
      ;; the sentinel's response handling becomes a no-op.
      (when (process-get handle :plz-then)
        (process-put handle :plz-then #'ignore))
      (when (process-get handle :plz-else)
        (process-put handle :plz-else #'ignore))
      (delete-process handle)))
   ((buffer-live-p handle)
    (let ((proc (get-buffer-process handle)))
      (when proc (delete-process proc)))
    (kill-buffer handle))))

(defun xiiif-api-fetch-bytes-async (url callback &optional errback)
  "Fetch URL asynchronously and pass the raw body to CALLBACK.

The body is delivered as a unibyte string suitable for `create-image'
with the DATA-P argument.  On failure, ERRBACK (or the default
reporter) is called with the same (ERROR-SYMBOL URL &rest DATA)
shape used by `xiiif-api-fetch-json-async'.  Returns the same kind
of cancellable handle, or nil when the URL was invalid."
  (let ((errback (or errback #'xiiif-api--default-errback)))
    (if (not (xiiif-api--valid-url-p url))
        (progn
          (funcall errback (list 'xiiif-network-error url "invalid URL"))
          nil)
      (if (eq (xiiif-api--backend-for url) 'plz)
          (xiiif-api--plz-fetch-bytes-async url callback errback)
        (xiiif-api--url-fetch-bytes-async url callback errback)))))

(defun xiiif-api--url-fetch-bytes-async (url callback errback)
  "url.el backend for `xiiif-api-fetch-bytes-async'."
  (condition-case err
      (url-retrieve
       url
       (lambda (status)
         (let ((buf (current-buffer)))
           (unwind-protect
               (condition-case handler-err
                   (let ((net-err (plist-get status :error)))
                     (when net-err
                       (signal 'xiiif-network-error
                               (list url (error-message-string
                                          net-err))))
                     (let ((code (xiiif-api--status-code)))
                       (when (and code (or (< code 200) (>= code 400)))
                         (signal 'xiiif-http-error
                                 (xiiif-api--http-error-data
                                  url code
                                  (xiiif-api--retry-after-seconds
                                   (xiiif-api--header-value
                                    "Retry-After"))))))
                     (xiiif-api--check-body-size url)
                     (xiiif-api--skip-headers)
                     (set-buffer-multibyte nil)
                     (funcall callback
                              (buffer-substring-no-properties
                               (point) (point-max))))
                 (xiiif-error
                  (funcall errback handler-err))
                 (error
                  (funcall errback
                           (list 'xiiif-error url
                                 (error-message-string handler-err)))))
             (when (buffer-live-p buf) (kill-buffer buf)))))
       nil t t)
    (error
     (funcall errback
              (list 'xiiif-network-error url
                    (error-message-string err)))
     nil)))

;;; ---------- plz backend ----------
;;
;; Optional curl-based transport via the GNU ELPA `plz' package.
;; Reached only when `xiiif-api--backend-for' returns `plz', which
;; implies (require 'plz nil t) has already succeeded.  Every entry
;; point translates plz's error objects into the xiiif errback
;; protocol (SYMBOL URL &rest DATA) so callers see no difference
;; from the url backend.

(defun xiiif-api--call-guarded (errback url thunk)
  "Run THUNK, routing signals to ERRBACK using the errback protocol.
xiiif errors pass through unchanged; anything else is wrapped as
\(`xiiif-error' URL MESSAGE)."
  (condition-case handler-err
      (funcall thunk)
    (xiiif-error (funcall errback handler-err))
    (error (funcall errback
                    (list 'xiiif-error url
                          (error-message-string handler-err))))))

(defun xiiif-api--plz-headers (url)
  "Return the request headers for URL, escaped for plz.
plz writes each header into a curl --config file as a naively
double-quoted string; literal backslashes and double quotes in a
value - ETag validators are always quoted - would corrupt the
config line and make curl drop the header silently.  Escape them
with the backslash sequences curl's config parser understands."
  (mapcar (lambda (header)
            (cons (car header)
                  (replace-regexp-in-string
                   "\"" "\\\\\""
                   (replace-regexp-in-string
                    "\\\\" "\\\\\\\\" (cdr header)))))
          (xiiif-api--request-headers url)))

(defun xiiif-api--plz-check-body-size (url body)
  "Signal `xiiif-body-too-large' when BODY exceeds the configured limit.
Unlike the url backend's `Content-Length' check, this measures the
actual BODY delivered for URL."
  (when xiiif-api-max-body-size
    (let ((size (string-bytes body)))
      (when (> size xiiif-api-max-body-size)
        (signal 'xiiif-body-too-large
                (list url size xiiif-api-max-body-size))))))

(defun xiiif-api--plz-response-json (url resp)
  "Parse the successful plz response RESP for URL as IIIF JSON.
Mirrors `xiiif-api--response-json': size guard, Content-Type
warning, conditional-cache store on validator headers, then JSON
parse."
  (let* ((headers (plz-response-headers resp))
         (body    (plz-response-body resp))
         (ct      (alist-get 'content-type headers))
         (etag    (alist-get 'etag headers))
         (lm      (alist-get 'last-modified headers)))
    (xiiif-api--plz-check-body-size url body)
    (xiiif-api--warn-content-type url (and ct (downcase ct)))
    (when (or etag lm)
      (xiiif-http-cache-store url body etag lm))
    (xiiif-api--parse-json body url)))

(defun xiiif-api--plz-cancelled-p (plz-err)
  "Return non-nil when PLZ-ERR reflects a cancelled request.
`xiiif-api-cancel' deletes the curl process; plz then reports a
killed or interrupted process through the else callback, which
must stay silent to match the url backend's cancel semantics."
  (and (null (plz-error-response plz-err))
       (null (plz-error-curl-error plz-err))
       (member (plz-error-message plz-err)
               '("curl process killed" "curl process interrupted"))))

(defun xiiif-api--plz-error (url plz-err)
  "Translate PLZ-ERR into an errback protocol list for URL.
Returns nil when PLZ-ERR reflects a cancelled request, in which
case nothing should be invoked."
  (let* ((resp   (plz-error-response plz-err))
         (status (and resp (plz-response-status resp)))
         (curl   (plz-error-curl-error plz-err)))
    (cond
     ((xiiif-api--plz-cancelled-p plz-err) nil)
     (status
      (cons 'xiiif-http-error
            (xiiif-api--http-error-data
             url status
             (xiiif-api--retry-after-seconds
              (alist-get 'retry-after (plz-response-headers resp))))))
     (curl (list 'xiiif-network-error url
                 (or (cdr curl) (format "curl error %s" (car curl)))))
     (t (list 'xiiif-network-error url
              (or (plz-error-message plz-err) "unknown plz error"))))))

(defun xiiif-api--plz-signal (url err)
  "Re-signal the caught `plz-error' ERR as a xiiif error for URL.
ERR is the condition-case value (SYMBOL MESSAGE PLZ-ERROR)."
  (let* ((plz-err (nth 2 err))
         (translated
          (or (and (plz-error-p plz-err)
                   (xiiif-api--plz-error url plz-err))
              (list 'xiiif-network-error url
                    (error-message-string err)))))
    (signal (car translated) (cdr translated))))

(defun xiiif-api--plz-fetch-json (url)
  "plz backend for `xiiif-api-fetch-json'."
  (condition-case err
      (xiiif-api--plz-response-json
       url
       (plz 'get url
         :headers (xiiif-api--plz-headers url)
         :as 'response
         :timeout xiiif-api-timeout))
    (plz-error
     (let* ((plz-err (nth 2 err))
            (resp    (and (plz-error-p plz-err)
                          (plz-error-response plz-err)))
            (status  (and resp (plz-response-status resp))))
       (if (eql status 304)
           (xiiif-api--cached-json-or-error url)
         (xiiif-api--plz-signal url err))))))

(defun xiiif-api--plz-fetch-json-async (url callback errback)
  "plz backend for `xiiif-api-fetch-json-async'."
  (condition-case err
      (plz 'get url
        :headers (xiiif-api--plz-headers url)
        :as 'response
        :then (lambda (resp)
                (xiiif-api--call-guarded
                 errback url
                 (lambda ()
                   (funcall callback
                            (xiiif-api--plz-response-json url resp)))))
        :else (lambda (plz-err)
                (let* ((resp   (plz-error-response plz-err))
                       (status (and resp (plz-response-status resp))))
                  (if (eql status 304)
                      (xiiif-api--call-guarded
                       errback url
                       (lambda ()
                         (funcall callback
                                  (xiiif-api--cached-json-or-error url))))
                    (when-let ((e (xiiif-api--plz-error url plz-err)))
                      (funcall errback e))))))
    (error
     (funcall errback
              (list 'xiiif-network-error url (error-message-string err)))
     nil)))

(defun xiiif-api--plz-fetch-bytes-async (url callback errback)
  "plz backend for `xiiif-api-fetch-bytes-async'."
  (condition-case err
      (plz 'get url
        :headers (xiiif-api--plz-headers url)
        :as 'binary
        :then (lambda (body)
                (xiiif-api--call-guarded
                 errback url
                 (lambda ()
                   (xiiif-api--plz-check-body-size url body)
                   (funcall callback body))))
        :else (lambda (plz-err)
                (when-let ((e (xiiif-api--plz-error url plz-err)))
                  (funcall errback e))))
    (error
     (funcall errback
              (list 'xiiif-network-error url (error-message-string err)))
     nil)))

(defun xiiif-api--plz-download-file (url destination)
  "plz backend for `xiiif-api-download-file'.
The body is streamed by curl to a temporary file - never held in
Emacs memory - then moved over DESTINATION."
  (let (tmp)
    (unwind-protect
        (condition-case err
            (progn
              (setq tmp (plz 'get url
                          :headers (xiiif-api--plz-headers url)
                          :as 'file
                          :timeout xiiif-api-timeout))
              (copy-file tmp destination t)
              destination)
          (plz-error
           (xiiif-api--plz-signal url err)))
      (when (and tmp (file-exists-p tmp))
        (ignore-errors (delete-file tmp))))))

(defun xiiif-api--plz-download-file-async (url destination callback errback)
  "plz backend for `xiiif-api-download-file-async'.
The body is streamed by curl to a temporary file, then moved over
DESTINATION."
  (condition-case err
      (plz 'get url
        :headers (xiiif-api--plz-headers url)
        :as 'file
        :then (lambda (tmp)
                (xiiif-api--call-guarded
                 errback url
                 (lambda ()
                   (unwind-protect
                       (copy-file tmp destination t)
                     (when (file-exists-p tmp)
                       (ignore-errors (delete-file tmp))))
                   (funcall callback destination))))
        :else (lambda (plz-err)
                (when-let ((e (xiiif-api--plz-error url plz-err)))
                  (funcall errback e))))
    (error
     (funcall errback
              (list 'xiiif-network-error url (error-message-string err)))
     nil)))


;;; ---------- file downloads ----------

(defun xiiif-api-download-file (url destination)
  "Download URL to DESTINATION synchronously, overwriting if it exists.
Any headers declared by a matching `xiiif-server-profiles' entry
are applied to the request.  Returns DESTINATION on success or
signals a xiiif error (`xiiif-network-error', or `xiiif-http-error'
under the plz backend, which distinguishes HTTP failures).

Kept for scripting; interactive commands should use
`xiiif-api-download-file-async' to avoid blocking Emacs."
  (unless (xiiif-api--valid-url-p url)
    (signal 'xiiif-network-error (list url "invalid URL")))
  (if (eq (xiiif-api--backend-for url) 'plz)
      (xiiif-api--plz-download-file url destination)
    (let ((url-request-extra-headers (xiiif-api--request-headers url)))
      (condition-case err
          (progn
            (url-copy-file url destination t)
            destination)
        (error
         (signal 'xiiif-network-error
                 (list url (error-message-string err))))))))

(defun xiiif-api-download-file-async (url destination callback &optional errback)
  "Download URL to DESTINATION asynchronously.

On success, CALLBACK is called with the absolute path of the saved
file.  On failure, ERRBACK (or the default reporter) is called with
the same (ERROR-SYMBOL URL &rest DATA) shape used by
`xiiif-api-fetch-json-async'.

Parent directories of DESTINATION are created if missing.  Any
headers declared by a matching `xiiif-server-profiles' entry are
applied to the request.  Under the plz backend the body is streamed
by curl straight to disk instead of transiting through an Emacs
buffer."
  (let* ((errback (or errback #'xiiif-api--default-errback))
         (dest    (expand-file-name destination))
         (dir     (file-name-directory dest)))
    (when (and dir (not (file-directory-p dir)))
      (make-directory dir t))
    (if (not (xiiif-api--valid-url-p url))
        (progn
          (funcall errback (list 'xiiif-network-error url "invalid URL"))
          nil)
      (if (eq (xiiif-api--backend-for url) 'plz)
          (xiiif-api--plz-download-file-async url dest callback errback)
        (xiiif-api-fetch-bytes-async
         url
         (lambda (bytes)
           (condition-case err
               (let ((coding-system-for-write 'binary))
                 (with-temp-file dest
                   (set-buffer-multibyte nil)
                   (insert bytes))
                 (funcall callback dest))
             (error
              (funcall errback
                       (list 'xiiif-error url
                             (error-message-string err))))))
         errback)))))

(provide 'xiiif-api)
;;; xiiif-api.el ends here
