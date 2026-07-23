;;; xiiif-backend-test.el --- Tests for the switchable HTTP backend -*- lexical-binding: t; -*-

;;; Commentary:

;; Covers backend selection (`xiiif-api-backend' x plz availability)
;; and the plz code paths using a faked plz API, so the suite runs
;; without plz installed and without touching the network.  The
;; companion file xiiif-backend-plz-integration-test.el exercises
;; the same paths against the real plz + curl when available.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-api)
(require 'xiiif-http-cache)

;; When plz is installed, build REAL plz structs for the fakes: the
;; struct accessors called inside xiiif-api may have been inlined by
;; their compiler macros (depending on load order), in which case
;; cl-letf stubs on the accessors would be bypassed and hand-rolled
;; fake objects would fail the inlined type checks.  Only when plz is
;; completely absent do we provide a minimal stand-in API - plain
;; defuns are never inlined, so the same code paths work unchanged.
(unless (require 'plz nil t)
  (define-error 'plz-error "plz error")
  (define-error 'plz-curl-error "plz: Curl error" 'plz-error)
  (define-error 'plz-http-error "plz: HTTP error" 'plz-error)
  (defun plz-error-p (x) (eq (car-safe x) 'fake-plz-error))
  (defun plz-error-response (e) (plist-get (cdr e) :response))
  (defun plz-error-curl-error (e) (plist-get (cdr e) :curl-error))
  (defun plz-error-message (e) (plist-get (cdr e) :message))
  (defun plz-response-status (r) (plist-get (cdr r) :status))
  (defun plz-response-headers (r) (plist-get (cdr r) :headers))
  (defun plz-response-body (r) (plist-get (cdr r) :body))
  (cl-defun make-plz-error (&rest plist) (cons 'fake-plz-error plist))
  (cl-defun make-plz-response (&rest plist)
    (cons 'fake-plz-response plist)))

(defun xiiif-backend-test--resp (&rest plist)
  "Build a (real or stand-in) plz response from PLIST."
  (apply #'make-plz-response plist))

(defun xiiif-backend-test--err (&rest plist)
  "Build a (real or stand-in) plz error from PLIST."
  (apply #'make-plz-error plist))

(defmacro xiiif-backend-test--with-fake-plz (plz-fn &rest body)
  "Run BODY with backend `plz' available and `plz' replaced by PLZ-FN."
  (declare (indent 1) (debug (form body)))
  `(cl-letf (((symbol-function 'xiiif-api--plz-available-p)
              (lambda () t))
             ((symbol-function 'plz) ,plz-fn))
     (let ((xiiif-api-backend 'plz)
           (xiiif-http-cache-enabled nil))
       ,@body)))


;;; ---- backend selection ----

(ert-deftest xiiif-api--backend/url-forced ()
  (cl-letf (((symbol-function 'xiiif-api--plz-available-p)
             (lambda () t)))
    (let ((xiiif-api-backend 'url))
      (should (eq 'url (xiiif-api--backend))))))

(ert-deftest xiiif-api--backend/auto-picks-plz-when-available ()
  (cl-letf (((symbol-function 'xiiif-api--plz-available-p)
             (lambda () t)))
    (let ((xiiif-api-backend 'auto))
      (should (eq 'plz (xiiif-api--backend))))))

(ert-deftest xiiif-api--backend/auto-falls-back-to-url ()
  (cl-letf (((symbol-function 'xiiif-api--plz-available-p)
             (lambda () nil)))
    (let ((xiiif-api-backend 'auto))
      (should (eq 'url (xiiif-api--backend))))))

(ert-deftest xiiif-api--backend/plz-unavailable-warns-once-uses-url ()
  (let ((warnings 0))
    (cl-letf (((symbol-function 'xiiif-api--plz-available-p)
               (lambda () nil))
              ((symbol-function 'display-warning)
               (lambda (&rest _) (cl-incf warnings))))
      (let ((xiiif-api-backend 'plz)
            (xiiif-api--plz-warned nil))
        (should (eq 'url (xiiif-api--backend)))
        (should (eq 'url (xiiif-api--backend)))
        (should (= 1 warnings))))))

(ert-deftest xiiif-api--backend-for/file-urls-always-use-url ()
  (cl-letf (((symbol-function 'xiiif-api--plz-available-p)
             (lambda () t)))
    (let ((xiiif-api-backend 'plz))
      (should (eq 'url (xiiif-api--backend-for "file:///tmp/m.json")))
      (should (eq 'plz (xiiif-api--backend-for "https://x/m.json"))))))

(ert-deftest xiiif-api-fetch-json-async/dispatches-per-backend ()
  (let ((routed nil))
    (cl-letf (((symbol-function 'xiiif-api--plz-available-p)
               (lambda () t))
              ((symbol-function 'xiiif-api--plz-fetch-json-async)
               (lambda (&rest _) (setq routed 'plz)))
              ((symbol-function 'xiiif-api--url-fetch-json-async)
               (lambda (&rest _) (setq routed 'url))))
      (let ((xiiif-api-backend 'plz))
        (xiiif-api-fetch-json-async "http://x/m" #'ignore #'ignore)
        (should (eq 'plz routed)))
      (let ((xiiif-api-backend 'url))
        (xiiif-api-fetch-json-async "http://x/m" #'ignore #'ignore)
        (should (eq 'url routed))))))


(ert-deftest xiiif-api--plz-headers/escapes-curl-config-metachars ()
  "Backslashes and double quotes in header values must be escaped:
plz writes headers into a curl --config file as naively quoted
strings, and an unescaped ETag validator would be dropped by curl
\(breaking conditional revalidation silently)."
  (cl-letf (((symbol-function 'xiiif-api--request-headers)
             (lambda (_url)
               '(("If-None-Match" . "\"tag\\1\"")
                 ("Accept" . "application/json")))))
    (should (equal '(("If-None-Match" . "\\\"tag\\\\1\\\"")
                     ("Accept" . "application/json"))
                   (xiiif-api--plz-headers "http://x")))))


;;; ---- plz JSON path ----

(ert-deftest xiiif-plz/json-success-parses-and-caches ()
  (let ((stored nil)
        (got nil)
        (sent-headers nil))
    (xiiif-backend-test--with-fake-plz
        (lambda (_method _url &rest kw)
          (setq sent-headers (plist-get kw :headers))
          (funcall (plist-get kw :then)
                   (xiiif-backend-test--resp
                    :status 200
                    :headers '((content-type . "application/json")
                               (etag . "\"e1\""))
                    :body "{\"a\": 1}"))
          'fake-process)
      (cl-letf (((symbol-function 'xiiif-http-cache-store)
                 (lambda (url _body etag _lm)
                   (setq stored (list url etag)))))
        (xiiif-api-fetch-json-async
         "http://x/m" (lambda (json) (setq got json)) #'ignore)))
    (should (equal 1 (alist-get 'a got)))
    (should (equal '("http://x/m" "\"e1\"") stored))
    (should (assoc-string "User-Agent" sent-headers t))))

(ert-deftest xiiif-plz/json-http-error-translated ()
  (let ((captured nil))
    (xiiif-backend-test--with-fake-plz
        (lambda (_method _url &rest kw)
          (funcall (plist-get kw :else)
                   (xiiif-backend-test--err
                    :response (xiiif-backend-test--resp :status 404)))
          'fake-process)
      (xiiif-api-fetch-json-async
       "http://x/m"
       (lambda (_) (error "callback should not fire"))
       (lambda (err) (setq captured err))))
    (should (equal '(xiiif-http-error "http://x/m" 404) captured))))

(ert-deftest xiiif-plz/json-304-served-from-cache ()
  (let ((got nil))
    (xiiif-backend-test--with-fake-plz
        (lambda (_method _url &rest kw)
          (funcall (plist-get kw :else)
                   (xiiif-backend-test--err
                    :response (xiiif-backend-test--resp :status 304)))
          'fake-process)
      (cl-letf (((symbol-function 'xiiif-http-cache-lookup)
                 (lambda (_url) '(:body "{\"cached\": true}"))))
        (xiiif-api-fetch-json-async
         "http://x/m" (lambda (json) (setq got json)) #'ignore)))
    (should (eq t (alist-get 'cached got)))))

(ert-deftest xiiif-plz/json-304-without-entry-errback ()
  (let ((captured nil))
    (xiiif-backend-test--with-fake-plz
        (lambda (_method _url &rest kw)
          (funcall (plist-get kw :else)
                   (xiiif-backend-test--err
                    :response (xiiif-backend-test--resp :status 304)))
          'fake-process)
      (cl-letf (((symbol-function 'xiiif-http-cache-lookup)
                 (lambda (_url) nil)))
        (xiiif-api-fetch-json-async
         "http://x/m"
         (lambda (_) (error "callback should not fire"))
         (lambda (err) (setq captured err)))))
    (should (eq 'xiiif-http-error (nth 0 captured)))
    (should (equal 304 (nth 2 captured)))))

(ert-deftest xiiif-plz/curl-error-translated ()
  (let ((captured nil))
    (xiiif-backend-test--with-fake-plz
        (lambda (_method _url &rest kw)
          (funcall (plist-get kw :else)
                   (xiiif-backend-test--err
                    :curl-error '(7 . "Failed to connect to host.")))
          'fake-process)
      (xiiif-api-fetch-json-async
       "http://x/m"
       (lambda (_) (error "callback should not fire"))
       (lambda (err) (setq captured err))))
    (should (equal '(xiiif-network-error "http://x/m"
                     "Failed to connect to host.")
                   captured))))

(ert-deftest xiiif-plz/cancelled-request-invokes-nothing ()
  (let ((fired nil))
    (xiiif-backend-test--with-fake-plz
        (lambda (_method _url &rest kw)
          (funcall (plist-get kw :else)
                   (xiiif-backend-test--err
                    :message "curl process killed"))
          'fake-process)
      (xiiif-api-fetch-json-async
       "http://x/m"
       (lambda (_) (setq fired 'callback))
       (lambda (_) (setq fired 'errback))))
    (should-not fired)))

(ert-deftest xiiif-plz/sync-json-success ()
  (let ((got nil))
    (xiiif-backend-test--with-fake-plz
        (lambda (_method _url &rest _kw)
          (xiiif-backend-test--resp
           :status 200
           :headers '((content-type . "application/json"))
           :body "{\"a\": 2}"))
      (setq got (xiiif-api-fetch-json "http://x/m")))
    (should (equal 2 (alist-get 'a got)))))

(ert-deftest xiiif-plz/sync-json-http-error-signals ()
  (xiiif-backend-test--with-fake-plz
      (lambda (_method _url &rest _kw)
        (signal 'plz-http-error
                (list "HTTP error"
                      (xiiif-backend-test--err
                       :response (xiiif-backend-test--resp :status 500)))))
    (let ((err (should-error (xiiif-api-fetch-json "http://x/m")
                             :type 'xiiif-http-error)))
      (should (equal 500 (nth 2 err))))))


;;; ---- plz bytes path ----

(ert-deftest xiiif-plz/bytes-success ()
  (let ((got nil))
    (xiiif-backend-test--with-fake-plz
        (lambda (_method _url &rest kw)
          (funcall (plist-get kw :then) "rawbytes")
          'fake-process)
      (xiiif-api-fetch-bytes-async
       "http://x/i.jpg" (lambda (bytes) (setq got bytes)) #'ignore))
    (should (equal "rawbytes" got))))

(ert-deftest xiiif-plz/bytes-oversized-errback ()
  (let ((captured nil))
    (xiiif-backend-test--with-fake-plz
        (lambda (_method _url &rest kw)
          (funcall (plist-get kw :then) "0123456789ABCDEF")
          'fake-process)
      (let ((xiiif-api-max-body-size 8))
        (xiiif-api-fetch-bytes-async
         "http://x/i.jpg"
         (lambda (_) (error "callback should not fire"))
         (lambda (err) (setq captured err)))))
    (should (equal '(xiiif-body-too-large "http://x/i.jpg" 16 8)
                   captured))))


;;; ---- plz file download path ----

(ert-deftest xiiif-plz/download-file-async-streams-and-moves ()
  (let* ((tmp (make-temp-file "xiiif-plz-src-"))
         (dest (expand-file-name
                "xiiif-plz-dest.bin" temporary-file-directory))
         (got nil))
    (unwind-protect
        (progn
          (with-temp-file tmp (insert "streamed"))
          (xiiif-backend-test--with-fake-plz
              (lambda (_method _url &rest kw)
                (funcall (plist-get kw :then) tmp)
                'fake-process)
            (xiiif-api-download-file-async
             "http://x/big.tif" dest
             (lambda (path) (setq got path)) #'ignore))
          (should (equal dest got))
          (should (file-exists-p dest))
          (with-temp-buffer
            (insert-file-contents dest)
            (should (equal "streamed" (buffer-string))))
          ;; The curl-side temporary file is cleaned up.
          (should-not (file-exists-p tmp)))
      (when (file-exists-p tmp) (delete-file tmp))
      (when (file-exists-p dest) (delete-file dest)))))


;;; ---- cancellation handle ----

(ert-deftest xiiif-api-cancel/process-handle ()
  (let ((proc (make-process :name "xiiif-cancel-test"
                            :command '("sleep" "5")
                            :noquery t)))
    (should (process-live-p proc))
    (xiiif-api-cancel proc)
    (should-not (process-live-p proc))))

(ert-deftest xiiif-api-cancel/nil-and-dead-are-safe ()
  (xiiif-api-cancel nil)
  (let ((buf (generate-new-buffer " *dead*")))
    (kill-buffer buf)
    (xiiif-api-cancel buf))
  (should t))

(provide 'xiiif-backend-test)
;;; xiiif-backend-test.el ends here
