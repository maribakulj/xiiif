;;; xiiif-mirador-test.el --- Tests for the Mirador handoff and Content State import -*- lexical-binding: t; -*-

;;; Commentary:

;; Command-level coverage: `xiiif-open-in-mirador' builds a precise
;; Content State URL from context, and `xiiif-open-content-state'
;; navigates to the anchored canvas.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-core)
(require 'xiiif-anchor)
(require 'xiiif)

(defun xiiif-mirador-test--manifest ()
  (make-xiiif-manifest
   :url "https://x/manifest" :id "https://x/manifest"
   :type "Manifest" :label "Test"
   :items '(((id . "https://x/canvas/1") (type . "Canvas")
             (label . "Folio 1")))
   :raw '((id . "https://x/manifest") (type . "Manifest")
          (items . [((id . "https://x/canvas/1") (type . "Canvas")
                     (label . "Folio 1"))]))))


(ert-deftest xiiif-mirador/manifest-only-handoff ()
  (let ((xiiif-current-manifest (xiiif-mirador-test--manifest))
        (xiiif-current-canvas nil)
        (opened nil))
    (cl-letf (((symbol-function 'browse-url)
               (lambda (url) (setq opened url))))
      (with-temp-buffer
        (xiiif-open-in-mirador))
      (should (string-prefix-p "https://projectmirador.org/embed/?iiif-content="
                               opened))
      ;; The encoded token round-trips back to a manifest anchor.
      (let ((anchor (xiiif-content-state-parse opened)))
        (should (equal "https://x/manifest"
                       (xiiif-anchor-manifest anchor)))
        (should-not (xiiif-anchor-canvas anchor))))))

(ert-deftest xiiif-mirador/precise-canvas-handoff ()
  (let ((xiiif-current-manifest (xiiif-mirador-test--manifest))
        (xiiif-current-canvas
         (make-xiiif-canvas :id "https://x/canvas/1" :label "Folio 1"))
        (opened nil))
    (cl-letf (((symbol-function 'browse-url)
               (lambda (url) (setq opened url))))
      (with-temp-buffer
        (xiiif-open-in-mirador))
      (let ((anchor (xiiif-content-state-parse opened)))
        (should (equal "https://x/manifest"
                       (xiiif-anchor-manifest anchor)))
        (should (equal "https://x/canvas/1"
                       (xiiif-anchor-canvas anchor)))))))

(ert-deftest xiiif-mirador/explicit-anchor-with-region ()
  (let ((xiiif-current-manifest (xiiif-mirador-test--manifest))
        (opened nil))
    (cl-letf (((symbol-function 'browse-url)
               (lambda (url) (setq opened url))))
      (xiiif-open-in-mirador
       (xiiif-anchor-create :manifest "https://x/manifest"
                            :canvas "https://x/canvas/1"
                            :region '(50 60 70 80)))
      (let* ((anchor (xiiif-content-state-parse opened))
             (r (xiiif-anchor-region anchor)))
        (should (= 50 (xiiif-region-x r)))
        (should (= 80 (xiiif-region-h r)))))))

(ert-deftest xiiif-mirador/no-manifest-signals ()
  (let ((xiiif-current-manifest nil)
        (xiiif-current-canvas nil))
    (with-temp-buffer
      (should-error (xiiif-open-in-mirador) :type 'user-error))))


;;; ---- Content State import navigation ----

(ert-deftest xiiif-open-content-state/current-manifest-jumps-to-canvas ()
  "When the anchor's manifest is already loaded, the canvas opens
without a network load."
  (let* ((m (xiiif-mirador-test--manifest))
         (xiiif-current-manifest m)
         (rendered nil))
    (cl-letf (((symbol-function 'xiiif-ui-render-canvas)
               (lambda (canvas) (setq rendered canvas)))
              ((symbol-function 'xiiif-cache-set-canvas) #'ignore)
              ((symbol-function 'xiiif--load-resource-async)
               (lambda (&rest _) (error "must not load; manifest is current"))))
      (let ((token (xiiif-content-state-encode
                    (xiiif-anchor-create
                     :manifest "https://x/manifest"
                     :canvas "https://x/canvas/1"
                     :region '(1 2 3 4)))))
        (xiiif-open-content-state token))
      (should (xiiif-canvas-p rendered))
      (should (equal "https://x/canvas/1" (xiiif-canvas-id rendered))))))

(ert-deftest xiiif-open-content-state/other-manifest-loads-then-jumps ()
  (let ((xiiif-current-manifest nil)
        (loaded-url nil)
        (rendered nil))
    (cl-letf (((symbol-function 'xiiif-ui-render-canvas)
               (lambda (canvas) (setq rendered canvas)))
              ((symbol-function 'xiiif-cache-set-canvas) #'ignore)
              ((symbol-function 'xiiif-cache-set-manifest) #'ignore)
              ((symbol-function 'run-hook-with-args) #'ignore)
              ((symbol-function 'xiiif--load-resource-async)
               (lambda (url on-manifest _on-collection)
                 (setq loaded-url url)
                 (funcall on-manifest (xiiif-mirador-test--manifest)))))
      (let ((token (xiiif-content-state-encode
                    (xiiif-anchor-create
                     :manifest "https://x/manifest"
                     :canvas "https://x/canvas/1"))))
        (xiiif-open-content-state token))
      (should (equal "https://x/manifest" loaded-url))
      (should (equal "https://x/canvas/1" (xiiif-canvas-id rendered))))))

(ert-deftest xiiif-open-content-state/empty-signals ()
  (should-error (xiiif-open-content-state "  ") :type 'user-error))

(provide 'xiiif-mirador-test)
;;; xiiif-mirador-test.el ends here
