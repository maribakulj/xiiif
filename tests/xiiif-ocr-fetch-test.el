;;; xiiif-ocr-fetch-test.el --- Tests for OCR async fetch -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercises `xiiif-ocr-fetch-async' end-to-end with a stubbed
;; `url-retrieve'; complements the pure-parser tests already in
;; `xiiif-ocr-test.el'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-core)
(require 'xiiif-api)
(require 'xiiif-ocr)

(defvar xiiif-ocr-fetch-test--fixtures nil)

(defun xiiif-ocr-fetch-test--stub (url callback &optional _cbargs _silent _inhibit-cookies)
  (let* ((body (or (cdr (assoc url xiiif-ocr-fetch-test--fixtures))
                   (error "no fixture for %s" url)))
         (buf (generate-new-buffer " *xiiif-ocr-stub*")))
    (with-current-buffer buf
      (set-buffer-multibyte nil)
      (insert "HTTP/1.1 200 OK\r\nContent-Type: application/xml\r\n\r\n")
      (insert body)
      (run-at-time 0 nil
                   (lambda ()
                     (with-current-buffer buf
                       (funcall callback nil)))))
    buf))

(defmacro xiiif-ocr-fetch-test--with (fixtures &rest body)
  (declare (indent 1) (debug (form body)))
  `(let ((xiiif-ocr-fetch-test--fixtures ,fixtures)
         (xiiif-api-backend 'url)
         (xiiif-fetch-host-interval 0))
     (cl-letf (((symbol-function 'url-retrieve)
                #'xiiif-ocr-fetch-test--stub))
       ,@body)))

(defun xiiif-ocr-fetch-test--wait-for (pred)
  (let ((deadline (+ (float-time) 2.0)))
    (while (and (not (funcall pred))
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall pred)))


(ert-deftest xiiif-ocr-fetch-async/extracts-alto ()
  (let ((ref '(:url "http://x/ocr.xml"
               :format alto
               :label "ALTO OCR"))
        (got nil))
    (xiiif-ocr-fetch-test--with
        '(("http://x/ocr.xml"
           . "<alto><TextLine><String CONTENT=\"hello\"/></TextLine></alto>"))
      (xiiif-ocr-fetch-async
       ref (lambda (r) (setq got r))))
    (should (xiiif-ocr-fetch-test--wait-for (lambda () got)))
    (should (equal "hello" (plist-get got :text)))
    (should (string-match-p "<alto>" (plist-get got :body)))
    (should (equal 'alto (plist-get got :format)))))


(ert-deftest xiiif-ocr-fetch-async/respects-extract-flag ()
  "When `xiiif-ocr-extract-text' is nil, return the raw body as text."
  (let ((ref '(:url "http://x/ocr.xml" :format alto))
        (got nil)
        (xiiif-ocr-extract-text nil))
    (xiiif-ocr-fetch-test--with
        '(("http://x/ocr.xml"
           . "<alto><TextLine><String CONTENT=\"hi\"/></TextLine></alto>"))
      (xiiif-ocr-fetch-async
       ref (lambda (r) (setq got r))))
    (should (xiiif-ocr-fetch-test--wait-for (lambda () got)))
    (should (string-match-p "<alto>" (plist-get got :text)))))


(provide 'xiiif-ocr-fetch-test)
;;; xiiif-ocr-fetch-test.el ends here
