;;; xiiif-annotations-collect-test.el --- Tests for annotation orchestration -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercises `xiiif-annotations-collect', which must merge inline
;; AnnotationPages with external pages fetched asynchronously and
;; deliver the final list in document order.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-core)
(require 'xiiif-api)
(require 'xiiif-annotations)

(defvar xiiif-annotations-test--fixtures nil)

(defun xiiif-annotations-test--stub (url callback &optional _cbargs _silent _inhibit-cookies)
  (let* ((json (or (cdr (assoc url xiiif-annotations-test--fixtures))
                   (error "no fixture for %s" url)))
         (buf (generate-new-buffer " *xiiif-anno-stub*")))
    (with-current-buffer buf
      (set-buffer-multibyte nil)
      (insert "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n")
      (insert json)
      (run-at-time 0 nil
                   (lambda ()
                     (with-current-buffer buf
                       (funcall callback nil)))))
    buf))

(defmacro xiiif-annotations-test--with (fixtures &rest body)
  (declare (indent 1) (debug (form body)))
  `(let ((xiiif-annotations-test--fixtures ,fixtures))
     (cl-letf (((symbol-function 'url-retrieve)
                #'xiiif-annotations-test--stub))
       ,@body)))

(defun xiiif-annotations-test--wait-for (pred)
  (let ((deadline (+ (float-time) 2.0)))
    (while (and (not (funcall pred))
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall pred)))


(ert-deftest xiiif-annotations-collect/inline-only ()
  (let* ((canvas (make-xiiif-canvas
                  :id "http://x/c1"
                  :raw '((id . "http://x/c1")
                         (type . "Canvas")
                         (annotations
                          .
                          [((id . "http://x/ap")
                            (type . "AnnotationPage")
                            (items . [((id . "http://x/a1")
                                       (motivation . "commenting")
                                       (target . "http://x/c1")
                                       (body . ((type . "TextualBody")
                                                (value . "one"))))]))]))))
         (got nil))
    (xiiif-annotations-collect
     canvas (lambda (annos) (setq got annos)))
    (should (xiiif-annotations-test--wait-for (lambda () got)))
    (should (= 1 (length got)))
    (should (equal "one" (xiiif-annotation-body-value (car got))))))


(ert-deftest xiiif-annotations-collect/external-fetched ()
  (let* ((canvas (make-xiiif-canvas
                  :id "http://x/c1"
                  :raw '((id . "http://x/c1")
                         (type . "Canvas")
                         (annotations
                          .
                          [((id . "http://x/external")
                            (type . "AnnotationPage"))]))))
         (got :not-called))
    (xiiif-annotations-test--with
        '(("http://x/external"
           .
           "{\"id\":\"http://x/ap\",\"type\":\"AnnotationPage\",\"items\":[{\"id\":\"http://x/a2\",\"motivation\":\"tagging\",\"target\":\"http://x/c1\",\"body\":{\"type\":\"TextualBody\",\"value\":\"tag\"}}]}"))
      (xiiif-annotations-collect
       canvas (lambda (annos) (setq got annos))))
    (should (xiiif-annotations-test--wait-for
             (lambda () (not (eq got :not-called)))))
    (should (= 1 (length got)))
    (should (equal "tag" (xiiif-annotation-body-value (car got))))))


(ert-deftest xiiif-annotations-collect/empty-fires-callback ()
  (let ((canvas (make-xiiif-canvas :id "http://x/c" :raw nil))
        (got :not-called))
    (xiiif-annotations-collect canvas (lambda (a) (setq got a)))
    (should (equal nil got))))


(ert-deftest xiiif-annotations-collect/mixed-preserves-order ()
  (let* ((canvas (make-xiiif-canvas
                  :id "http://x/c1"
                  :raw `((id . "http://x/c1")
                         (type . "Canvas")
                         (annotations
                          .
                          [((id . "http://x/inline")
                            (type . "AnnotationPage")
                            (items . [((id . "http://x/a-inline")
                                       (motivation . "commenting")
                                       (target . "http://x/c1")
                                       (body . ((type . "TextualBody")
                                                (value . "inline"))))]))
                           ((id . "http://x/ext")
                            (type . "AnnotationPage"))]))))
         (got :not-called))
    (xiiif-annotations-test--with
        '(("http://x/ext"
           .
           "{\"id\":\"http://x/apext\",\"type\":\"AnnotationPage\",\"items\":[{\"id\":\"http://x/a-ext\",\"motivation\":\"tagging\",\"target\":\"http://x/c1\",\"body\":{\"type\":\"TextualBody\",\"value\":\"external\"}}]}"))
      (xiiif-annotations-collect
       canvas (lambda (annos) (setq got annos))))
    (should (xiiif-annotations-test--wait-for
             (lambda () (not (eq got :not-called)))))
    (should (equal '("inline" "external")
                   (mapcar #'xiiif-annotation-body-value got)))))


(provide 'xiiif-annotations-collect-test)
;;; xiiif-annotations-collect-test.el ends here
