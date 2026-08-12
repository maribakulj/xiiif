;;; xiiif-open-test.el --- Tests for the xiiif-open dispatcher -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `xiiif-open' is the single entry point of SPEC_V1.md §15.  Two things
;; decide where a target goes: its shape, settled here without touching
;; the network, and — for anything that turns out to be a URL — the type
;; of the JSON it returns, settled by `xiiif-resource-kind'.

;;; Code:

(require 'ert)
(require 'xiiif)

;;; ---------- shape classification, no network ----------

(ert-deftest xiiif-open/urls-are-resources ()
  (dolist (target '("https://example.org/iiif/manifest.json"
                    "https://example.org/iiif/collection"
                    "https://example.org/iiif/canvas/1"
                    "file:///tmp/m.json"))
    (should (eq 'resource (xiiif-open-target-kind target)))))

(ert-deftest xiiif-open/content-state-is-recognised-in-its-three-shapes ()
  ;; Raw JSON, a viewer URL carrying the parameter, and a bare token.
  (should (eq 'content-state (xiiif-open-target-kind "{\"@context\":\"x\"}")))
  (should (eq 'content-state
              (xiiif-open-target-kind
               "https://viewer.example/?iiif-content=eyJAY29udGV4dCI6IngifQ")))
  (should (eq 'content-state (xiiif-open-target-kind "eyJAY29udGV4dCI6IngifQ"))))

(ert-deftest xiiif-open/a-viewer-url-is-content-state-not-a-manifest ()
  ;; It is a perfectly good https URL; the parameter is what decides.
  (let ((url "https://viewer.example/index.html?manifest=x&iiif-content=eyJ9"))
    (should (eq 'content-state (xiiif-open-target-kind url)))))

(ert-deftest xiiif-open/refused-urls-are-not-silently-retried-as-tokens ()
  ;; A URL the policy refuses must fail as a URL, not fall through to
  ;; base64 decoding, which would bury the reason it was refused.
  (should-not (xiiif-open-target-kind "http://169.254.169.254/latest/"))
  (should-not (xiiif-open-target-kind "ftp://example.org/m.json"))
  (should-not (xiiif-open-target-kind "http://127.0.0.1/iiif/m")))

(ert-deftest xiiif-open/empty-and-non-strings-classify-as-nothing ()
  (dolist (target (list "" "   " nil 42))
    (should-not (xiiif-open-target-kind target))))

(ert-deftest xiiif-open/unclassifiable-input-is-a-user-error ()
  (should-error (xiiif-open "") :type 'user-error)
  (should-error (xiiif-open "http://169.254.169.254/latest/") :type 'user-error))

(ert-deftest xiiif-open/a-refusal-says-why-and-what-to-change ()
  ;; A bare \"cannot open this\" is unactionable: the reason the policy
  ;; gave is the whole value of having a policy that can be relaxed.
  (let ((private (cadr (should-error (xiiif-open "http://127.0.0.1/iiif/m")
                                     :type 'user-error)))
        (scheme (cadr (should-error (xiiif-open "ftp://example.org/m.json")
                                    :type 'user-error))))
    (should (string-match-p "xiiif-url-allow-private-hosts" private))
    (should (string-match-p "xiiif-url-allowed-schemes" scheme))))

;;; ---------- routing ----------

(ert-deftest xiiif-open/routes-to-the-right-command ()
  (let (calls)
    (cl-letf (((symbol-function 'xiiif-open-manifest)
               (lambda (url) (push (cons 'manifest url) calls)))
              ((symbol-function 'xiiif-open-content-state)
               (lambda (token) (push (cons 'content-state token) calls))))
      (xiiif-open "https://example.org/iiif/m")
      (xiiif-open "{\"@context\":\"x\"}")
      (should (equal '((content-state . "{\"@context\":\"x\"}")
                       (manifest . "https://example.org/iiif/m"))
                     calls)))))

;;; ---------- a standalone Canvas is a IIIF entry point ----------

(ert-deftest xiiif-open/canvas-json-is-recognised ()
  (should (eq 'canvas (xiiif-resource-kind '((type . "Canvas") (id . "c1")))))
  ;; IIIF 2 spells it `@type'; the parser keeps JSON keys as symbols.
  (should (eq 'canvas (xiiif-resource-kind '((@type . "sc:Canvas"))))))

(ert-deftest xiiif-open/canvas-wins-over-the-manifest-fallback ()
  ;; A Canvas carries `items' too. Without ordering, the v2 fallback for
  ;; a root that omits its type would claim it as a Manifest.
  (let ((canvas '((type . "Canvas") (id . "c1") (items . []))))
    (should (eq 'canvas (xiiif-resource-kind canvas)))))

(ert-deftest xiiif-open/manifests-and-collections-still-classify ()
  (should (eq 'manifest (xiiif-resource-kind '((type . "Manifest") (items . [])))))
  (should (eq 'collection (xiiif-resource-kind '((type . "Collection") (items . []))))))

(ert-deftest xiiif-open/unknown-json-classifies-as-nothing ()
  (should-not (xiiif-resource-kind '((type . "Annotation")))))

(provide 'xiiif-open-test)
;;; xiiif-open-test.el ends here
