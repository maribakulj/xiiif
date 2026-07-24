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

(defconst xiiif-test--collection-fixture
  (expand-file-name
   "../examples/sample-collection.json"
   (file-name-directory (or load-file-name buffer-file-name))))

(defun xiiif-test--read-json (path)
  "Return PATH parsed as JSON in the alist shape xiiif uses."
  (let ((json-object-type 'alist)
        (json-array-type  'vector)
        (json-key-type    'symbol)
        (json-null        nil))
    (json-read-file path)))

(defun xiiif-test--load-fixture ()
  "Return the sample manifest parsed into an alist."
  (xiiif-test--read-json xiiif-test--fixture))

(defun xiiif-test--load-collection-fixture ()
  "Return the sample collection parsed into an alist."
  (xiiif-test--read-json xiiif-test--collection-fixture))

;;; ---- locale-derived preferred languages ----

(defmacro xiiif-core-test--with-locale (value &rest body)
  "Run BODY with LANG/LC_ALL/LC_MESSAGES set to VALUE (or all cleared)."
  (declare (indent 1) (debug t))
  `(let ((process-environment (copy-sequence process-environment)))
     (setenv "LC_ALL" nil)
     (setenv "LC_MESSAGES" nil)
     (setenv "LANG" ,value)
     ,@body))

(ert-deftest xiiif--locale-language/parses-lang ()
  (xiiif-core-test--with-locale "fr_FR.UTF-8"
    (should (equal "fr" (xiiif--locale-language))))
  (xiiif-core-test--with-locale "de_DE.UTF-8"
    (should (equal "de" (xiiif--locale-language))))
  (xiiif-core-test--with-locale "en"
    (should (equal "en" (xiiif--locale-language)))))

(ert-deftest xiiif--locale-language/ignores-c-posix-and-empty ()
  (xiiif-core-test--with-locale "C"
    (should-not (xiiif--locale-language)))
  (xiiif-core-test--with-locale "POSIX"
    (should-not (xiiif--locale-language)))
  (xiiif-core-test--with-locale nil
    (should-not (xiiif--locale-language))))

(ert-deftest xiiif--default-preferred-languages/prepends-locale ()
  (xiiif-core-test--with-locale "fr_FR.UTF-8"
    (should (equal '("fr" "en" "none" "und")
                   (xiiif--default-preferred-languages))))
  ;; English locale must not duplicate the base "en".
  (xiiif-core-test--with-locale "en_US.UTF-8"
    (should (equal '("en" "none" "und")
                   (xiiif--default-preferred-languages))))
  ;; No locale falls back to the base list.
  (xiiif-core-test--with-locale nil
    (should (equal '("en" "none" "und")
                   (xiiif--default-preferred-languages)))))


;;; ---- label string ----

(ert-deftest xiiif-label-string/nil ()
  (should (equal "" (xiiif-label-string nil))))

(ert-deftest xiiif-label-string/plain ()
  (should (equal "hello" (xiiif-label-string "hello"))))

(ert-deftest xiiif-label-string/language-map-prefers-en ()
  ;; Pin the preference list so the assertion does not depend on the
  ;; load-time locale-derived default.
  (let ((xiiif-preferred-languages '("en" "none" "und")))
    (should (equal "Title"
                   (xiiif-label-string
                    '((en . ["Title"]) (fr . ["Titre"])))))))

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
                                                                         (profile . "level1"))))))]))]))])))
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



;;; ---- collections ----

(ert-deftest xiiif-collection-p-json/detects-v3 ()
  (should (xiiif-collection-p-json
           (xiiif-test--load-collection-fixture))))

(ert-deftest xiiif-collection-p-json/detects-v2 ()
  (should (xiiif-collection-p-json
           '((@id . "http://x/c") (@type . "sc:Collection")))))

(ert-deftest xiiif-resource-kind/dispatches ()
  (should (eq 'collection
              (xiiif-resource-kind
               (xiiif-test--load-collection-fixture))))
  (should (eq 'manifest
              (xiiif-resource-kind
               (xiiif-test--load-fixture))))
  (should (null (xiiif-resource-kind '((foo . "bar"))))))

(ert-deftest xiiif-parse-collection/v3-children ()
  (let* ((c (xiiif-parse-collection
             (xiiif-test--load-collection-fixture)
             "https://example.org/iiif/collection/top"))
         (children (xiiif-collection-children c)))
    (should (xiiif-collection-p c))
    (should (equal "Sample Top-Level Collection"
                   (xiiif-collection-title c)))
    (should (= 3 (length children)))
    (let ((first (car children)))
      (should (equal "Manifest"
                     (xiiif-collection-item-type first)))
      (should (equal "A Sample Illuminated Book"
                     (xiiif-collection-item-title first))))
    (let ((third (nth 2 children)))
      (should (equal "Collection"
                     (xiiif-collection-item-type third))))))

(ert-deftest xiiif-parse-collection/v2-merges-collections-and-manifests ()
  (let* ((v2 '((@id . "http://x/c")
               (@type . "sc:Collection")
               (label . "Coll")
               (collections . [((@id . "http://x/c1")
                                (@type . "sc:Collection")
                                (label . "Sub"))])
               (manifests . [((@id . "http://x/m1")
                              (@type . "sc:Manifest")
                              (label . "M1"))
                             ((@id . "http://x/m2")
                              (@type . "sc:Manifest")
                              (label . "M2"))])))
         (c (xiiif-parse-collection v2 "http://x/c"))
         (children (xiiif-collection-children c)))
    (should (= 3 (length children)))
    ;; Sub-collections come first by convention.
    (should (equal "Collection"
                   (xiiif-collection-item-type (car children))))
    (should (equal "M1"
                   (xiiif-collection-item-title (nth 1 children))))))

(ert-deftest xiiif-parse-collection/rejects-non-collection ()
  (should-error
   (xiiif-parse-collection (xiiif-test--load-fixture)
                           "http://x/m")
   :type 'xiiif-parse-error))



;;; ---- thumbnail URL extraction ----

(ert-deftest xiiif-canvas-thumbnail-url/v3-array ()
  (let ((canvas (make-xiiif-canvas
                 :id "http://x/c1"
                 :thumbnail [((id . "http://x/thumb.jpg")
                              (type . "Image"))])))
    (should (equal "http://x/thumb.jpg"
                   (xiiif-canvas-thumbnail-url canvas)))))

(ert-deftest xiiif-canvas-thumbnail-url/v2-string ()
  (let ((canvas (make-xiiif-canvas
                 :id "http://x/c1"
                 :thumbnail "http://x/thumb.jpg")))
    (should (equal "http://x/thumb.jpg"
                   (xiiif-canvas-thumbnail-url canvas)))))

(ert-deftest xiiif-canvas-thumbnail-url/v2-object ()
  (let ((canvas (make-xiiif-canvas
                 :id "http://x/c1"
                 :thumbnail '((@id . "http://x/thumb.jpg")
                              (@type . "dctypes:Image")))))
    (should (equal "http://x/thumb.jpg"
                   (xiiif-canvas-thumbnail-url canvas)))))

(ert-deftest xiiif-canvas-thumbnail-url/synthesized-from-service ()
  "Canvases without a declared thumbnail fall back to an Image API derivative."
  (let ((canvas (make-xiiif-canvas
                 :id "http://x/c1"
                 :image-service (make-xiiif-image-service
                                 :id "https://example.org/iiif/image/x"))))
    (should (equal "https://example.org/iiif/image/x/full/!200,200/0/default.jpg"
                   (xiiif-canvas-thumbnail-url canvas)))
    (should (equal "https://example.org/iiif/image/x/full/!512,512/0/default.jpg"
                   (xiiif-canvas-thumbnail-url canvas "!512,512")))))

(ert-deftest xiiif-canvas-thumbnail-url/nil-when-nothing ()
  (let ((canvas (make-xiiif-canvas :id "http://x/c1")))
    (should (null (xiiif-canvas-thumbnail-url canvas)))))

(provide 'xiiif-core-test)
;;; xiiif-core-test.el ends here
