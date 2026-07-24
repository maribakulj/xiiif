;;; xiiif-download-test.el --- Tests for async download + bulk queue -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercises the Sprint 2 work: `xiiif-api-download-file-async',
;; `xiiif-image-download-async' and the bulk queue driving
;; `xiiif-download-marked'.  `url-retrieve' is monkey-patched with a
;; deterministic stub so the suite stays offline and synchronous.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-api)
(require 'xiiif-image)
(require 'xiiif-core)
(require 'xiiif)

(defvar xiiif-download-test--fixtures nil
  "Alist of (URL . BYTES).  The stub `url-retrieve' serves matches.")

(defun xiiif-download-test--stub (url callback &optional _cbargs _silent _inhibit-cookies)
  "Call CALLBACK immediately with a synthesized response for URL.
Looks up bytes in `xiiif-download-test--fixtures' and fabricates an
HTTP/1.1 200 response.  Returns a temp buffer as handle."
  (let* ((bytes (or (cdr (assoc url xiiif-download-test--fixtures))
                    (error "no fixture for %s" url)))
         (buf (generate-new-buffer " *xiiif-stub*")))
    (with-current-buffer buf
      (set-buffer-multibyte nil)
      (insert "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\n\r\n")
      (insert bytes)
      (goto-char (point-min))
      (run-at-time 0 nil
                   (lambda ()
                     (with-current-buffer buf
                       (funcall callback nil)))))
    buf))

(defmacro xiiif-download-test--with-stub (fixtures &rest body)
  "Install the stub `url-retrieve' and run BODY with FIXTURES."
  (declare (indent 1) (debug (form body)))
  `(let ((xiiif-download-test--fixtures ,fixtures)
         (xiiif-api-backend 'url)
         (xiiif-fetch-host-interval 0))
     (cl-letf (((symbol-function 'url-retrieve)
                #'xiiif-download-test--stub))
       ,@body)))

(defun xiiif-download-test--wait-for (pred &optional timeout)
  "Pump timers until PRED returns non-nil, at most TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 1.0))))
    (while (and (not (funcall pred))
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall pred)))


;;; ---- xiiif-api-download-file-async ----

(ert-deftest xiiif-api-download-file-async/writes-bytes ()
  (let* ((tmp (make-temp-file "xiiif-dl-"))
         (got nil))
    (unwind-protect
        (xiiif-download-test--with-stub
            '(("http://x/a.jpg" . "JPEGBYTES"))
          (xiiif-api-download-file-async
           "http://x/a.jpg" tmp
           (lambda (path) (setq got path)))
          (should (xiiif-download-test--wait-for (lambda () got)))
          (should (equal tmp got))
          (should (equal "JPEGBYTES"
                         (with-temp-buffer
                           (set-buffer-multibyte nil)
                           (insert-file-contents-literally tmp)
                           (buffer-string)))))
      (ignore-errors (delete-file tmp)))))

(ert-deftest xiiif-api-download-file-async/invalid-url-calls-errback ()
  (let (captured)
    (xiiif-api-download-file-async
     "not-a-url" "/tmp/x"
     (lambda (_p) (error "callback should not fire"))
     (lambda (err) (setq captured err)))
    (should (eq 'xiiif-network-error (nth 0 captured)))))


;;; ---- xiiif-image-download-async ----

(ert-deftest xiiif-image-download-async/builds-url-and-saves ()
  (let* ((tmp (make-temp-file "xiiif-img-"))
         (service (make-xiiif-image-service
                   :id "http://img.example/svc"
                   :type "ImageService3"
                   :profile "level1"))
         (got nil))
    (unwind-protect
        (xiiif-download-test--with-stub
            '(("http://img.example/svc/full/!256,256/0/default.jpg"
               . "IMG"))
          (xiiif-image-download-async
           service tmp
           (lambda (path) (setq got path))
           :size "!256,256")
          (should (xiiif-download-test--wait-for (lambda () got)))
          (should (equal tmp got)))
      (ignore-errors (delete-file tmp)))))

(ert-deftest xiiif-image-download-async/no-service-calls-errback ()
  (let (captured)
    (xiiif-image-download-async
     nil "/tmp/x"
     (lambda (_) (error "callback should not fire"))
     :errback (lambda (err) (setq captured err)))
    (should (eq 'xiiif-error (nth 0 captured)))))


;;; ---- bulk queue ----

(defun xiiif-download-test--canvas (slug &optional with-service)
  (make-xiiif-canvas
   :id (format "http://x/c/%s" slug)
   :label slug
   :image-service (and with-service
                       (make-xiiif-image-service
                        :id (format "http://img.example/%s" slug)))))

(ert-deftest xiiif-download-queue/saves-and-skips ()
  "Two canvases have services, one does not; queue must save 2, skip 1."
  (let* ((dir (make-temp-file "xiiif-bulk-" t))
         (cs (list (xiiif-download-test--canvas "a" t)
                   (xiiif-download-test--canvas "b" nil)
                   (xiiif-download-test--canvas "c" t))))
    (unwind-protect
        (xiiif-download-test--with-stub
            '(("http://img.example/a/full/max/0/default.jpg" . "A")
              ("http://img.example/c/full/max/0/default.jpg" . "C"))
          (xiiif--download-queue-run cs dir "max" "jpg")
          (should (xiiif-download-test--wait-for
                   (lambda ()
                     (= 2 (length (directory-files dir nil "\\.jpg\\'"))))
                   2.0))
          (let ((files (directory-files dir nil "\\.jpg\\'")))
            (should (equal 2 (length files)))
            ;; Index prefix is 1-based and uses 3-digit zero padding.
            (should (cl-find-if (lambda (f) (string-prefix-p "001-a" f)) files))
            (should (cl-find-if (lambda (f) (string-prefix-p "003-c" f)) files))))
      (dolist (f (directory-files dir t "^[^.]"))
        (ignore-errors (delete-file f)))
      (ignore-errors (delete-directory dir)))))

(ert-deftest xiiif-download-queue/empty-is-noop ()
  (let ((dir (make-temp-file "xiiif-bulk-empty-" t)))
    (unwind-protect
        (xiiif-download-test--with-stub nil
          ;; Should finish immediately without errors.
          (xiiif--download-queue-run nil dir "max" "jpg"))
      (ignore-errors (delete-directory dir)))))


;;; ---- cancellation ----

(ert-deftest xiiif-api-cancel/accepts-nil-and-dead ()
  (should-not (xiiif-api-cancel nil))
  (let ((buf (generate-new-buffer " *xiiif-cancel-test*")))
    (kill-buffer buf)
    (should-not (xiiif-api-cancel buf))))

(ert-deftest xiiif-api-cancel/kills-live-buffer ()
  (let ((buf (generate-new-buffer " *xiiif-cancel-live*")))
    (xiiif-api-cancel buf)
    (should-not (buffer-live-p buf))))


(provide 'xiiif-download-test)
;;; xiiif-download-test.el ends here
