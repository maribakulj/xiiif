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



;;; ---- structures / ranges ----

(ert-deftest xiiif-manifest-structures/v3-tree ()
  "The v3 fixture carries a two-level Range tree with one canvas per leaf."
  (let* ((m (xiiif-parse-manifest (xiiif-test--load-fixture)
                                  "https://example.org/manifest"))
         (structures (xiiif-manifest-structures m)))
    (should (= 1 (length structures)))
    (let* ((top (car structures))
           (children (xiiif-range-sub-ranges top)))
      (should (xiiif-range-p top))
      (should (equal "Book structure" (xiiif-range-title top)))
      (should (= 2 (length children)))
      (should (equal "Front matter"
                     (xiiif-range-title (nth 0 children))))
      (should (equal '("https://example.org/iiif/book1/canvas/p1")
                     (xiiif-range-canvas-ids (nth 0 children))))
      (should (equal "https://example.org/iiif/book1/canvas/p2"
                     (xiiif-range-first-canvas-id (nth 1 children)))))))

(ert-deftest xiiif-manifest-structures/v2-resolves-ids ()
  "v2 ranges use `ranges' references; `structures' must only surface tops."
  (let* ((v2 `((@id . "http://x/m")
               (@type . "sc:Manifest")
               (label . "Old Book")
               (sequences . [((@id . "http://x/m/seq") (@type . "sc:Sequence")
                              (canvases . [((@id . "http://x/m/c1")
                                            (@type . "sc:Canvas")
                                            (label . "p1"))]))])
               (structures . [((@id . "http://x/r/top")
                               (@type . "sc:Range")
                               (label . "Top")
                               (ranges . ["http://x/r/chap1"]))
                              ((@id . "http://x/r/chap1")
                               (@type . "sc:Range")
                               (label . "Chapter 1")
                               (canvases . ["http://x/m/c1"]))])))
         (m (xiiif-parse-manifest v2 "http://x/m"))
         (structures (xiiif-manifest-structures m)))
    (should (= 1 (length structures)))
    (let* ((top (car structures))
           (chap (car (xiiif-range-sub-ranges top))))
      (should (equal "Top" (xiiif-range-title top)))
      (should (equal "Range" (xiiif-range-type top)))
      (should (null (xiiif-range-canvas-ids top)))
      (should (equal "Chapter 1" (xiiif-range-title chap)))
      (should (equal '("http://x/m/c1") (xiiif-range-canvas-ids chap))))))

(ert-deftest xiiif-manifest-structures/nil-without-structures ()
  (let* ((raw '((id . "http://x/m") (type . "Manifest") (label . "x")))
         (m (xiiif-parse-manifest raw "http://x/m")))
    (should (null (xiiif-manifest-structures m)))))

(ert-deftest xiiif-manifest-structures/v2-handles-cycle ()
  "A cyclic v2 range reference does not hang the parser."
  (let* ((v2 `((@id . "http://x/m")
               (@type . "sc:Manifest")
               (label . "Cyclic")
               (structures . [((@id . "http://x/r/top") (@type . "sc:Range")
                               (label . "Top") (ranges . ["http://x/r/a"]))
                              ((@id . "http://x/r/a") (@type . "sc:Range")
                               (label . "A") (ranges . ["http://x/r/b"]))
                              ((@id . "http://x/r/b") (@type . "sc:Range")
                               (label . "B") (ranges . ["http://x/r/a"]))])))
         (m (xiiif-parse-manifest v2 "http://x/m"))
         (structures (xiiif-manifest-structures m)))
    (should (= 1 (length structures)))
    (let* ((top (car structures))
           (a   (car (xiiif-range-sub-ranges top)))
           (b   (car (xiiif-range-sub-ranges a))))
      (should (equal "Top" (xiiif-range-title top)))
      (should (equal "A"   (xiiif-range-title a)))
      (should (equal "B"   (xiiif-range-title b)))
      ;; B -> A would recurse, but the visited guard drops the back-edge.
      (should (null (xiiif-range-sub-ranges b))))))

(ert-deftest xiiif-range-first-canvas-id/walks-sub-ranges ()
  (let ((leaf (make-xiiif-range :canvas-ids '("http://x/c1"))))
    (should (equal "http://x/c1"
                   (xiiif-range-first-canvas-id
                    (make-xiiif-range :sub-ranges (list leaf)))))))

(ert-deftest xiiif-manifest-find-canvas/looks-up-by-id ()
  (let* ((m (xiiif-parse-manifest (xiiif-test--load-fixture)
                                  "https://example.org/manifest"))
         (hit (xiiif-manifest-find-canvas
               m "https://example.org/iiif/book1/canvas/p2")))
    (should hit)
    (should (equal "Folio 1v" (xiiif-canvas-title hit)))
    (should (null (xiiif-manifest-find-canvas m "http://x/nope")))))

(provide 'xiiif-core-test)
;;; xiiif-core-test.el ends here
