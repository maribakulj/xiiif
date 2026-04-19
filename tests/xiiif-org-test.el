;;; xiiif-org-test.el --- Tests for xiiif-org -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests on the Org-capture helpers; the simpler link
;; builders are exercised indirectly by xiiif-core-test.

;;; Code:

(require 'ert)
(require 'json)
(require 'xiiif-core)
(require 'xiiif-org)
(require 'xiiif-cache)

(defconst xiiif-org-test--fixture
  (expand-file-name
   "../examples/sample-manifest.json"
   (file-name-directory (or load-file-name buffer-file-name))))

(defun xiiif-org-test--manifest ()
  (let* ((json-object-type 'alist)
         (json-array-type  'vector)
         (json-key-type    'symbol)
         (json-null        nil)
         (raw (json-read-file xiiif-org-test--fixture)))
    (xiiif-parse-manifest raw "https://example.org/iiif/book1/manifest")))


;;; ---- metadata block ----

(ert-deftest xiiif-org-metadata-block/manifest-only ()
  (let* ((m (xiiif-org-test--manifest))
         (out (xiiif-org-metadata-block m)))
    (should (string-match-p ":title: A Sample Illuminated Book" out))
    (should (string-match-p
             ":manifest: https://example.org/iiif/book1/manifest"
             out))
    (should (string-match-p "^#\\+begin_xiiif" out))
    (should (string-match-p "^#\\+end_xiiif" out))))


;;; ---- org-capture helpers ----

(ert-deftest xiiif-org-capture-headline/errors-without-manifest ()
  (let ((xiiif-current-manifest nil))
    (should-error (xiiif-org-capture-headline) :type 'user-error)))

(ert-deftest xiiif-org-capture-headline/uses-current ()
  (let ((xiiif-current-manifest (xiiif-org-test--manifest)))
    (should (equal "A Sample Illuminated Book"
                   (xiiif-org-capture-headline)))))

(ert-deftest xiiif-org-capture-body/manifest-link-and-block ()
  (let* ((xiiif-current-manifest (xiiif-org-test--manifest))
         (xiiif-current-canvas nil)
         (text (xiiif-org-capture-body)))
    (should (string-match-p
             "\\[\\[https://example.org/iiif/book1/manifest\\]"
             text))
    (should (string-match-p "^#\\+begin_xiiif" text))
    (should (string-match-p ":title: A Sample Illuminated Book" text))
    ;; Without a canvas, no canvas-id line is emitted.
    (should-not (string-match-p ":canvas-id:" text))))

(ert-deftest xiiif-org-capture-body/includes-canvas-when-set ()
  (let* ((m (xiiif-org-test--manifest))
         (c (car (xiiif-manifest-canvases m)))
         (xiiif-current-manifest m)
         (xiiif-current-canvas c)
         (text (xiiif-org-capture-body)))
    (should (string-match-p ":canvas-label: Folio 1r" text))
    (should (string-match-p
             ":canvas-id: https://example.org/iiif/book1/canvas/p1"
             text))))

(provide 'xiiif-org-test)
;;; xiiif-org-test.el ends here
