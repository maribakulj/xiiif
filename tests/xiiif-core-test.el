;;; xiiif-core-test.el --- Tests for xiiif-core -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for parsing and label extraction.  Run with:
;;
;;   emacs -batch -L . -L tests -l tests/xiiif-core-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'json)
(require 'xiiif-core)

(defconst xiiif-test--fixture
  (expand-file-name
   "../examples/sample-manifest.json"
   (file-name-directory (or load-file-name buffer-file-name))))

(defun xiiif-test--load-fixture ()
  "Return the sample manifest parsed into an alist."
  (let ((json-object-type 'alist)
        (json-array-type  'vector)
        (json-key-type    'symbol)
        (json-null        nil))
    (json-read-file xiiif-test--fixture)))

;;; ---- label string ----

(ert-deftest xiiif-label-string/nil ()
  (should (equal "" (xiiif-label-string nil))))

(ert-deftest xiiif-label-string/plain ()
  (should (equal "hello" (xiiif-label-string "hello"))))

(ert-deftest xiiif-label-string/language-map-prefers-en ()
  (should (equal "Title"
                 (xiiif-label-string
                  '((en . ["Title"]) (fr . ["Titre"]))))))

(ert-deftest xiiif-label-string/language-map-falls-back ()
  (let ((xiiif-preferred-languages '("en" "none")))
    (should (equal "Titre"
                   (xiiif-label-string
                    '((fr . ["Titre"])))))))

(ert-deftest xiiif-label-string/joins-array ()
  (should (equal "one two"
                 (xiiif-label-string ["one" "two"]))))

;;; ---- metadata pairs ----

(ert-deftest xiiif-metadata-pairs/basic ()
  (let* ((m (xiiif-test--load-fixture))
         (pairs (xiiif-metadata-pairs (alist-get 'metadata m))))
    (should (assoc "Author" pairs))
    (should (equal "Jane Doe" (cdr (assoc "Author" pairs))))
    (should (equal "2024"     (cdr (assoc "Date" pairs))))))

;;; ---- manifest parsing ----

(ert-deftest xiiif-parse-manifest/detects-non-manifest ()
  (should-error
   (xiiif-parse-manifest '((foo . "bar")) "http://x")
   :type 'xiiif-parse-error))

(ert-deftest xiiif-parse-manifest/basic-fields ()
  (let* ((m (xiiif-parse-manifest (xiiif-test--load-fixture)
                                  "https://example.org/manifest")))
    (should (xiiif-manifest-p m))
    (should (equal "https://example.org/manifest"
                   (xiiif-manifest-url m)))
    (should (equal "Manifest" (xiiif-manifest-type m)))
    (should (equal "A Sample Illuminated Book"
                   (xiiif-manifest-title m)))))

(ert-deftest xiiif-parse-manifest/v2-sequences ()
  "A minimal v2-shaped manifest should still produce canvases."
  (let* ((v2 '((@id . "http://x/m")
               (@type . "sc:Manifest")
               (label . "Old Book")
               (sequences . [((@id . "http://x/m/seq")
                              (@type . "sc:Sequence")
                              (canvases .
                                        [((@id . "http://x/m/c1")
                                          (@type . "sc:Canvas")
                                          (label . "p1")
                                          (width . 100)
                                          (height . 200)
                                          (images .
                                                  [((@id . "http://x/a1")
                                                    (@type . "oa:Annotation")
                                                    (motivation . "sc:painting")
                                                    (resource .
                                                              ((@id . "http://x/img/full/full/0/default.jpg")
                                                               (@type . "dctypes:Image")
                                                               (service .
                                                                        ((@id . "http://x/img")
                                                                         (@type . "ImageService2")
                                                                         (profile . "level1"))))))]))])))]))))
         (m (xiiif-parse-manifest v2 "http://x/m"))
         (canvases (xiiif-manifest-canvases m)))
    (should (= 1 (length canvases)))
    (let ((c (car canvases)))
      (should (equal "http://x/m/c1" (xiiif-canvas-id c)))
      (should (equal 100 (xiiif-canvas-width c)))
      (should (xiiif-image-service-p (xiiif-canvas-image-service c)))
      (should (equal "http://x/img"
                     (xiiif-image-service-id
                      (xiiif-canvas-image-service c)))))))

;;; ---- canvas extraction ----

(ert-deftest xiiif-manifest-canvases/v3 ()
  (let* ((m (xiiif-parse-manifest (xiiif-test--load-fixture)
                                  "https://example.org/manifest"))
         (canvases (xiiif-manifest-canvases m)))
    (should (= 2 (length canvases)))
    (let ((first (car canvases)))
      (should (equal "Folio 1r" (xiiif-canvas-title first)))
      (should (equal 1200 (xiiif-canvas-width first)))
      (should (equal 1800 (xiiif-canvas-height first)))
      (should (xiiif-image-service-p (xiiif-canvas-image-service first)))
      (should (equal "https://example.org/iiif/image/book1-p1"
                     (xiiif-image-service-id
                      (xiiif-canvas-image-service first)))))))

(ert-deftest xiiif-manifest-canvases/empty ()
  "A manifest without items returns an empty canvas list gracefully."
  (let* ((raw '((id . "http://x/m") (type . "Manifest") (label . "x")))
         (m (xiiif-parse-manifest raw "http://x/m")))
    (should (null (xiiif-manifest-canvases m)))))

(provide 'xiiif-core-test)
;;; xiiif-core-test.el ends here
