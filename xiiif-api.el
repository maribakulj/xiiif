;;; xiiif-api.el --- HTTP/JSON transport for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Thin wrapper around `url.el' that fetches a IIIF resource and
;; returns it as a parsed JSON value (alist).  Exposes both a
;; synchronous helper (`xiiif-api-fetch-json', useful for scripting
;; and tests) and a non-blocking version (`xiiif-api-fetch-json-async',
;; used by all interactive commands so Emacs stays responsive on slow
;; manifests).  All transport, HTTP-status and JSON-decode errors are
;; translated into the dedicated `xiiif-' error symbols defined here,
;; so higher layers only need to handle well-typed failures.

;;; Code:

(require 'json)
(require 'url)
(require 'url-http)
(require 'xiiif-errors)
(require 'xiiif-profiles)

(defcustom xiiif-api-timeout 30
  "Timeout in seconds for synchronous IIIF HTTP requests."
  :type 'integer
  :group 'xiiif)

(defcustom xiiif-api-user-agent
  (format "xiiif.el/0.1.0 Emacs/%s" emacs-version)
  "User-Agent string used for IIIF HTTP requests."
  :type 'string
  :group 'xiiif)

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
  "Parse BODY as JSON or signal `xiiif-parse-error' with URL context."
  (condition-case err
      (let ((json-object-type 'alist)
            (json-array-type  'vector)
            (json-key-type    'symbol)
            (json-false       :json-false)
            (json-null        nil))
        (json-read-from-string body))
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

(defun xiiif-api--response-json (url)
  "Parse the current `url' response buffer as IIIF JSON for URL.
Signals `xiiif-http-error' on non-2xx responses and
`xiiif-parse-error' on invalid JSON.  A mismatching Content-Type is
reported via `display-warning' but not treated as an error."
  (let ((status (xiiif-api--status-code))
        (ct     (xiiif-api--content-type)))
    (when (and status (or (< status 200) (>= status 400)))
      (signal 'xiiif-http-error (list url status)))
    (xiiif-api--warn-content-type url ct)
    (xiiif-api--parse-json (xiiif-api--decode-body) url)))

(defun xiiif-api--request-headers (&optional url)
  "Return the HTTP request header alist used by every xiiif call.
When URL matches an entry in `xiiif-server-profiles', any explicit
`:headers' are appended and, if the profile declares `:auth', an
`Authorization' header is resolved via `auth-source' and appended
last (so an explicit `:headers' entry still wins for the same
header name)."
  (let* ((base
          `(("Accept"     . "application/ld+json, application/json")
            ("User-Agent" . ,xiiif-api-user-agent)))
         (profile-headers (xiiif-profile-headers url))
         (auth (unless (assoc-string "Authorization" profile-headers t)
                 (xiiif-profile-auth-header url))))
    (append base
            profile-headers
            (and auth (list auth)))))

(defun xiiif-api-fetch-json (url)
  "Fetch URL synchronously and return parsed JSON.

Signals `xiiif-network-error' on transport failure,
`xiiif-http-error' on non-2xx responses, and
`xiiif-parse-error' on invalid JSON.

For a non-blocking version, see `xiiif-api-fetch-json-async'."
  (unless (xiiif-api--valid-url-p url)
    (signal 'xiiif-network-error (list url "invalid URL")))
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

Returns the `url-retrieve' response buffer (a cancellable handle)
or nil when the URL was invalid.  Both CALLBACK and ERRBACK run on
Emacs's main thread, so they may update buffers and UI directly.
To cancel an in-flight request, pass the returned handle to
`xiiif-api-cancel'."
  (let ((errback (or errback #'xiiif-api--default-errback)))
    (if (not (xiiif-api--valid-url-p url))
        (progn
          (funcall errback (list 'xiiif-network-error url "invalid URL"))
          nil)
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
           nil))))))

(defun xiiif-api-cancel (handle)
  "Cancel an in-flight request referenced by HANDLE.
HANDLE is the buffer returned by `xiiif-api-fetch-json-async' or
`xiiif-api-fetch-bytes-async'.  Killing the buffer tears down the
underlying process, which aborts the sentinel and therefore the
callback chain.  Safe to call with nil or a dead buffer."
  (when (buffer-live-p handle)
    (let ((proc (get-buffer-process handle)))
      (when proc (delete-process proc)))
    (kill-buffer handle)))

(defun xiiif-api-fetch-bytes-async (url callback &optional errback)
  "Fetch URL asynchronously and pass the raw body to CALLBACK.

The body is delivered as a unibyte string suitable for `create-image'
with the DATA-P argument.  On failure, ERRBACK (or the default
reporter) is called with the same (ERROR-SYMBOL URL &rest DATA)
shape used by `xiiif-api-fetch-json-async'."
  (let ((errback (or errback #'xiiif-api--default-errback)))
    (if (not (xiiif-api--valid-url-p url))
        (funcall errback (list 'xiiif-network-error url "invalid URL"))
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
                             (signal 'xiiif-http-error (list url code))))
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
                        (error-message-string err))))))))

(defun xiiif-api-download-file (url destination)
  "Download URL to DESTINATION synchronously, overwriting if it exists.
Any headers declared by a matching `xiiif-server-profiles' entry
are applied to the request.  Returns DESTINATION on success or
signals an `xiiif-network-error'.

Kept for scripting; interactive commands should use
`xiiif-api-download-file-async' to avoid blocking Emacs."
  (unless (xiiif-api--valid-url-p url)
    (signal 'xiiif-network-error (list url "invalid URL")))
  (let ((url-request-extra-headers (xiiif-api--request-headers url)))
    (condition-case err
        (progn
          (url-copy-file url destination t)
          destination)
      (error
       (signal 'xiiif-network-error
               (list url (error-message-string err)))))))

(defun xiiif-api-download-file-async (url destination callback &optional errback)
  "Download URL to DESTINATION asynchronously.

On success, CALLBACK is called with the absolute path of the saved
file.  On failure, ERRBACK (or the default reporter) is called with
the same (ERROR-SYMBOL URL &rest DATA) shape used by
`xiiif-api-fetch-json-async'.

Parent directories of DESTINATION are created if missing.  Any
headers declared by a matching `xiiif-server-profiles' entry are
applied to the request."
  (let* ((errback (or errback #'xiiif-api--default-errback))
         (dest    (expand-file-name destination))
         (dir     (file-name-directory dest)))
    (when (and dir (not (file-directory-p dir)))
      (make-directory dir t))
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
     errback)))

(provide 'xiiif-api)
;;; xiiif-api.el ends here
