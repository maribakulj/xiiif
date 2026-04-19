;;; xiiif-cite-test.el --- Tests for xiiif-cite -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for BibTeX and CSL-JSON citation export.

;;; Code:

(require 'ert)
(require 'json)
(require 'xiiif-core)
(require 'xiiif-cite)

(defconst xiiif-cite-test--fixture
  (expand-file-name
   "../examples/sample-manifest.json"
   (file-name-directory (or load-file-name buffer-file-name))))

(defun xiiif-cite-test--manifest ()
  "Return the sample manifest as a `xiiif-manifest' struct."
  (let* ((json-object-type 'alist)
         (json-array-type  'vector)
         (json-key-type    'symbol)
         (json-null        nil)
         (raw (json-read-file xiiif-cite-test--fixture)))
    (xiiif-parse-manifest raw "https://example.org/iiif/book1/manifest")))


;;; ---- metadata extraction ----

(ert-deftest xiiif-citation-metadata/pulls-known-labels ()
  (let* ((m (xiiif-cite-test--manifest))
         (meta (xiiif-citation-metadata m)))
    (should (equal "A Sample Illuminated Book"
                   (alist-get 'title meta)))
    (should (equal "Jane Doe"
                   (alist-get 'author meta)))
    (should (equal "2024" (alist-get 'date meta)))
    (should (equal "2024" (alist-get 'year meta)))
    (should (equal "CC BY 4.0" (alist-get 'rights meta)))
    (should (equal "https://example.org/iiif/book1/manifest"
                   (alist-get 'url meta)))))

(ert-deftest xiiif-citation-metadata/case-insensitive-label ()
  "Even lower-case labels in metadata are picked up."
  (let* ((raw '((id . "http://x/m")
                (type . "Manifest")
                (label . "Weird Manifest")
                (metadata . [((label . "creator") (value . "Alice"))
                             ((label . "Issued")  (value . "1892"))])))
         (m (xiiif-parse-manifest raw "http://x/m"))
         (meta (xiiif-citation-metadata m)))
    (should (equal "Alice" (alist-get 'author meta)))
    (should (equal "1892"  (alist-get 'year meta)))))

(ert-deftest xiiif-citation--year/extracts-four-digit ()
  (should (equal "1892" (xiiif-citation--year "circa 1892")))
  (should (equal "2024" (xiiif-citation--year "2024-03-15")))
  (should (null (xiiif-citation--year "unknown"))))


;;; ---- BibTeX ----

(ert-deftest xiiif-citation-bibtex/contains-core-fields ()
  (let* ((m (xiiif-cite-test--manifest))
         (text (xiiif-citation-bibtex m)))
    (should (string-match-p "@misc{doe2024," text))
    (should (string-match-p "title = {A Sample Illuminated Book}" text))
    (should (string-match-p "author = {Jane Doe}" text))
    (should (string-match-p "year = {2024}" text))
    (should (string-match-p
             "url = {https://example.org/iiif/book1/manifest}"
             text))
    (should (string-match-p "note = {IIIF Manifest}" text))))

(ert-deftest xiiif-citation-bibtex/escapes-braces ()
  "Braces inside field values are stripped so the entry stays balanced."
  (let* ((raw '((id . "http://x/m") (type . "Manifest")
                (label . "A {weird} title")
                (metadata . [((label . "Author") (value . "{Mx} X"))])))
         (m (xiiif-parse-manifest raw "http://x/m"))
         (text (xiiif-citation-bibtex m)))
    ;; No opening brace appears inside any `= {...}' field value.
    (should-not (string-match-p "= {[^}]*{" text))))

(ert-deftest xiiif-citation--bibtex-key/fallback-uses-title-word ()
  (let ((meta '((title . "Some Rare Manuscript")
                (author . nil) (year . nil))))
    (should (equal "manuscript"
                   (xiiif-citation--bibtex-key meta)))))


;;; ---- CSL-JSON ----

(ert-deftest xiiif-citation-csl-json/round-trips ()
  (let* ((m (xiiif-cite-test--manifest))
         (text (xiiif-citation-csl-json m))
         (parsed (let ((json-object-type 'alist)
                       (json-array-type 'vector))
                   (json-read-from-string text))))
    (should (equal "A Sample Illuminated Book"
                   (alist-get 'title parsed)))
    (should (equal "manuscript"
                   (alist-get 'type parsed)))
    (should (equal "https://example.org/iiif/book1/manifest"
                   (alist-get 'URL parsed)))
    (let ((authors (alist-get 'author parsed)))
      (should (vectorp authors))
      (should (equal "Jane Doe"
                     (alist-get 'family (aref authors 0)))))
    (let ((dp (alist-get 'date-parts (alist-get 'issued parsed))))
      (should (equal 2024 (aref (aref dp 0) 0))))))

(provide 'xiiif-cite-test)
;;; xiiif-cite-test.el ends here
