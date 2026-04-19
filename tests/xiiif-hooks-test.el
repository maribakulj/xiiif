;;; xiiif-hooks-test.el --- Tests for xiiif extensibility hooks -*- lexical-binding: t; -*-

;;; Commentary:

;; Verifies that the three public hooks are defined and that the UI
;; renderers fire them with the right argument.  The async load path
;; is not exercised here (no HTTP); we feed structs directly into
;; the renderer that the hook is attached to.

;;; Code:

(require 'ert)
(require 'xiiif-core)
(require 'xiiif-ui)
(require 'xiiif)


;;; ---- hook definitions ----

(ert-deftest xiiif-hooks/declared-as-hooks ()
  (dolist (hook '(xiiif-after-load-manifest-hook
                  xiiif-after-load-collection-hook
                  xiiif-after-render-canvas-hook))
    (should (boundp hook))
    (should (null (symbol-value hook)))))


;;; ---- canvas render fires the hook ----

(ert-deftest xiiif-after-render-canvas-hook/fires-with-canvas ()
  (let* ((canvas (make-xiiif-canvas
                  :id "http://x/c1"
                  :label '((en . ["Folio"]))
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

(provide 'xiiif-hooks-test)
;;; xiiif-hooks-test.el ends here
