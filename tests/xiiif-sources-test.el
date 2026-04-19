;;; xiiif-sources-test.el --- Tests for xiiif-sources -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the source registry lookup and URL building.

;;; Code:

(require 'ert)
(require 'xiiif-sources)


;;; ---- built-in registry ----

(ert-deftest xiiif-sources/defaults-are-well-formed ()
  "Every shipped source has a :label and a URL builder."
  (dolist (entry xiiif-sources)
    (let ((plist (cdr entry)))
      (should (plist-get plist :label))
      (should (or (plist-get plist :manifest-url)
                  (plist-get plist :manifest-url-fn))))))

(ert-deftest xiiif-source-names/lists-every-key ()
  (should (memq 'gallica (xiiif-source-names)))
  (should (memq 'wellcome (xiiif-source-names)))
  (should (memq 'ia (xiiif-source-names))))


;;; ---- URL building ----

(ert-deftest xiiif-source-build-manifest-url/gallica-ark ()
  (let ((source (xiiif-source-get 'gallica)))
    (should (equal
             "https://gallica.bnf.fr/iiif/ark:/12148/btv1b84539771/manifest.json"
             (xiiif-source-build-manifest-url
              source "ark:/12148/btv1b84539771")))))

(ert-deftest xiiif-source-build-manifest-url/prefers-fn-over-format ()
  (let ((source '(:label "Custom"
                  :manifest-url     "https://x/%s/manifest"
                  :manifest-url-fn  (lambda (id)
                                      (format "https://x/fn/%s" id)))))
    (should (equal "https://x/fn/abc"
                   (xiiif-source-build-manifest-url source "abc")))))

(ert-deftest xiiif-source-build-manifest-url/signals-without-builder ()
  (let ((source '(:label "Broken")))
    (should-error (xiiif-source-build-manifest-url source "abc")
                  :type 'user-error)))


;;; ---- custom source can be added at runtime ----

(ert-deftest xiiif-sources/custom-entry-roundtrip ()
  (let ((xiiif-sources
         '((demo :label "Demo"
                 :prompt "Demo id: "
                 :manifest-url "https://demo.example.org/iiif/%s/manifest"
                 :notes "test fixture"))))
    (let ((source (xiiif-source-get 'demo)))
      (should (equal "Demo" (xiiif-source-label source)))
      (should (equal "https://demo.example.org/iiif/42/manifest"
                     (xiiif-source-build-manifest-url source "42"))))))

(provide 'xiiif-sources-test)
;;; xiiif-sources-test.el ends here
