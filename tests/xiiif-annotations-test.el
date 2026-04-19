;;; xiiif-annotations-test.el --- Tests for xiiif-annotations -*- lexical-binding: t; -*-

;;; Commentary:

;; Coverage for annotation body/target extraction and AnnotationPage parsing.

;;; Code:

(require 'ert)
(require 'xiiif-core)
(require 'xiiif-annotations)


;;; ---- body / target helpers ----

(ert-deftest xiiif-parse-annotation/text-body ()
  (let ((a (xiiif-parse-annotation
            '((id . "http://x/a1")
              (motivation . "commenting")
              (target . "http://x/c1")
              (body . ((type . "TextualBody")
                       (value . "Hello world")
                       (language . "en")))))))
    (should (equal "http://x/a1" (xiiif-annotation-id a)))
    (should (equal "commenting"  (xiiif-annotation-motivation a)))
    (should (equal "http://x/c1" (xiiif-annotation-target a)))
    (should (equal "Hello world" (xiiif-annotation-body-value a)))
    (should (equal "TextualBody" (xiiif-annotation-body-type a)))
    (should (equal "en"          (xiiif-annotation-body-lang a)))))

(ert-deftest xiiif-parse-annotation/specific-resource-target ()
  (let ((a (xiiif-parse-annotation
            '((id . "http://x/a2")
              (motivation . "tagging")
              (target . ((source . "http://x/c1")
                         (selector . ((type . "FragmentSelector")))))
              (body . ((type . "TextualBody")
                       (value . "marginalia")))))))
    (should (equal "http://x/c1" (xiiif-annotation-target a)))
    (should (equal "marginalia"  (xiiif-annotation-body-value a)))))

(ert-deftest xiiif-parse-annotation/string-body ()
  (let ((a (xiiif-parse-annotation
            '((id . "http://x/a3")
              (motivation . "linking")
              (target . "http://x/c1")
              (body . "http://example.org/resource")))))
    (should (equal "http://example.org/resource"
                   (xiiif-annotation-body-value a)))
    (should (null (xiiif-annotation-body-type a)))))

(ert-deftest xiiif-parse-annotation/array-body-takes-first ()
  (let ((a (xiiif-parse-annotation
            '((id . "http://x/a4")
              (motivation . "commenting")
              (target . "http://x/c1")
              (body . [((type . "TextualBody") (value . "primary"))
                       ((type . "TextualBody") (value . "secondary"))])))))
    (should (equal "primary" (xiiif-annotation-body-value a)))))


;;; ---- page + canvas extraction ----

(ert-deftest xiiif-parse-annotation-page/multiple ()
  (let* ((page '((id . "http://x/ap")
                 (type . "AnnotationPage")
                 (items . [((id . "http://x/a1")
                            (motivation . "commenting")
                            (target . "http://x/c1")
                            (body . ((type . "TextualBody")
                                     (value . "one"))))
                           ((id . "http://x/a2")
                            (motivation . "tagging")
                            (target . "http://x/c1")
                            (body . ((type . "TextualBody")
                                     (value . "two"))))])))
         (anns (xiiif-parse-annotation-page page)))
    (should (= 2 (length anns)))
    (should (equal "one" (xiiif-annotation-body-value (car anns))))
    (should (equal "two" (xiiif-annotation-body-value (cadr anns))))))

(ert-deftest xiiif-canvas-annotation-refs/classifies ()
  (let* ((raw '((id . "http://x/c1")
                (type . "Canvas")
                (annotations . [((id . "http://x/ap-inline")
                                 (type . "AnnotationPage")
                                 (items . [((id . "http://x/a")
                                            (motivation . "commenting")
                                            (target . "http://x/c1")
                                            (body . ((value . "hi"))))]))
                                ((id . "http://x/ap-external")
                                 (type . "AnnotationPage"))])))
         (canvas (make-xiiif-canvas :id "http://x/c1" :raw raw))
         (refs (xiiif-canvas-annotation-refs canvas)))
    (should (= 2 (length refs)))
    (should (plist-get (car refs) :inline))
    (should-not (plist-get (car refs) :url))
    (should-not (plist-get (cadr refs) :inline))
    (should (equal "http://x/ap-external"
                   (plist-get (cadr refs) :url)))))

(provide 'xiiif-annotations-test)
;;; xiiif-annotations-test.el ends here
