;;; xiiif-smoke-test.el --- Regression smoke tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Catch the "it crashes at keystroke" class of bugs: every symbol
;; referenced from keymaps, README or documented commands must be
;; bound after `(require 'xiiif)'.

;;; Code:

(require 'ert)
(require 'xiiif)


;;; ---- commands promised by the package ----

(ert-deftest xiiif-smoke/autoloaded-commands-defined ()
  (dolist (sym '(xiiif-open-manifest
                 xiiif-open
                 xiiif-open-source
                 xiiif-browse-canvases
                 xiiif-open-canvas
                 xiiif-view-canvas
                 xiiif-copy-image-url
                 xiiif-download-image
                 xiiif-download-marked
                 xiiif-show-info-json
                 xiiif-show-annotations
                 xiiif-show-structures
                 xiiif-insert-org-link
                 xiiif-export-citation
                 xiiif-copy-manifest-url
                 xiiif-show-raw-json
                 xiiif-refresh
                 xiiif-open-recent
                 xiiif-retry-last
                 xiiif-toggle-thumbnails
                 xiiif-cache-clear
                 xiiif-cache-clear-http
                 xiiif-open-in-mirador
                 xiiif-open-content-state
                 xiiif-search
                 xiiif-upgrade-manifest
                 xiiif-upgrade-collection))
    (should (fboundp sym))))


;;; ---- symbols referenced by keymaps and renderers ----

(ert-deftest xiiif-smoke/internal-helpers-defined ()
  (dolist (sym '(xiiif-canvas-filesystem-slug
                 xiiif-image--slug
                 xiiif-annotations-collect
                 xiiif-parse-annotation-page
                 xiiif-ui-render-annotations
                 xiiif-ui-render-canvas
                 xiiif-ui-render-manifest
                 xiiif-ui-render-collection
                 xiiif-ui-render-structures
                 xiiif-ui-render-info))
    (should (fboundp sym))))


;;; ---- buffer name constants ----

(ert-deftest xiiif-smoke/buffer-constants-defined ()
  (dolist (sym '(xiiif-ui--manifest-buffer
                 xiiif-ui--canvases-buffer
                 xiiif-ui--canvas-buffer
                 xiiif-ui--collection-buffer
                 xiiif-ui--info-buffer
                 xiiif-ui--structures-buffer
                 xiiif-ui--annotations-buffer))
    (should (boundp sym))
    (should (stringp (symbol-value sym)))))


;;; ---- modules loaded by `(require 'xiiif)' ----

(ert-deftest xiiif-smoke/modules-loaded ()
  (dolist (feat '(xiiif-errors
                  xiiif-profiles
                  xiiif-http-cache
                  xiiif-api
                  xiiif-core
                  xiiif-cache
                  xiiif-image
                  xiiif-annotations
                  xiiif-ocr
                  xiiif-sources
                  xiiif-ui
                  xiiif-org
                  xiiif-cite
                  xiiif-upgrade
                  xiiif-search))
    (should (featurep feat))))


;;; ---- xiiif-canvas-filesystem-slug (C3 regression) ----

(ert-deftest xiiif-canvas-filesystem-slug/uses-label ()
  (let ((c (make-xiiif-canvas :id "http://x/c/42"
                              :label "Folio 1r")))
    (should (equal "Folio_1r" (xiiif-canvas-filesystem-slug c)))))

(ert-deftest xiiif-canvas-filesystem-slug/language-map-label ()
  (let ((c (make-xiiif-canvas :id "http://x/c/42"
                              :label '((en . ["Folio 1r"])))))
    (should (equal "Folio_1r" (xiiif-canvas-filesystem-slug c)))))

(ert-deftest xiiif-canvas-filesystem-slug/falls-back-to-id-tail ()
  (let ((c (make-xiiif-canvas :id "http://x/c/p42" :label nil)))
    (should (equal "p42" (xiiif-canvas-filesystem-slug c)))))

(ert-deftest xiiif-canvas-filesystem-slug/never-empty ()
  (let ((c (make-xiiif-canvas :id "" :label "")))
    (should (equal "canvas" (xiiif-canvas-filesystem-slug c)))))

(ert-deftest xiiif-canvas-filesystem-slug/strips-punct ()
  (let ((c (make-xiiif-canvas :id "http://x/c/z" :label "p.1 (recto)")))
    (should (equal "p.1_recto" (xiiif-canvas-filesystem-slug c)))))


;;; ---- hook (C6 regression) ----

(ert-deftest xiiif-smoke/render-canvas-fires-hook ()
  (let* ((canvas (make-xiiif-canvas
                  :id "http://x/c1"
                  :label "Folio"
                  :raw '((id . "http://x/c1") (type . "Canvas"))))
         (captured nil)
         (xiiif-after-render-canvas-hook
          (list (lambda (c) (setq captured c)))))
    (unwind-protect
        (progn
          (xiiif-ui-render-canvas canvas)
          (should (xiiif-canvas-p captured))
          (should (equal "http://x/c1" (xiiif-canvas-id captured))))
      (when (get-buffer xiiif-ui--canvas-buffer)
        (kill-buffer xiiif-ui--canvas-buffer)))))


;;; ---- file:// URL acceptance (C7 regression) ----

(ert-deftest xiiif-smoke/file-url-accepted ()
  (should (xiiif-api--valid-url-p "file:///tmp/manifest.json")))


(provide 'xiiif-smoke-test)
;;; xiiif-smoke-test.el ends here
