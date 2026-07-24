;;; xiiif-view-integration-test.el --- Viewer integration wiring -*- lexical-binding: t; -*-

;;; Commentary:

;; Command-level wiring of the region viewer into the rest of xiiif:
;; the `v' bindings, `xiiif-view-canvas' fallbacks, search RET and
;; annotation RET routing a region to the viewer, and Content State
;; import jumping into the viewer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-core)
(require 'xiiif-view)
(require 'xiiif-search)
(require 'xiiif-anchor)
(require 'xiiif)

(defun xiiif-view-int--canvas (&optional with-service)
  (make-xiiif-canvas
   :id "https://x/c/1" :label "Folio 1" :width 6000 :height 4000
   :image-service (and with-service
                       (make-xiiif-image-service :id "https://img/svc"))
   :raw '((id . "https://x/c/1") (type . "Canvas"))))


;;; ---- keybindings ----

(ert-deftest xiiif-view-int/canvas-detail-v-binding ()
  (should (eq 'xiiif-view-canvas
              (lookup-key xiiif-canvas-mode-map (kbd "v")))))

(ert-deftest xiiif-view-int/canvas-browser-v-binding ()
  (should (eq 'xiiif-view-canvas
              (lookup-key xiiif-canvas-list-mode-map (kbd "v")))))

(ert-deftest xiiif-view-int/annotation-ret-binding ()
  (should (eq 'xiiif-ui--annotation-view-at-point
              (lookup-key xiiif-annotations-mode-map (kbd "RET")))))


;;; ---- xiiif-view-canvas fallbacks ----

(ert-deftest xiiif-view-int/view-canvas-no-service-falls-back ()
  (let ((opened nil))
    (cl-letf (((symbol-function 'xiiif-open-canvas)
               (lambda (c) (setq opened c)))
              ((symbol-function 'xiiif-view-load-canvas)
               (lambda (&rest _) (error "must not open viewer"))))
      (xiiif-view-canvas (xiiif-view-int--canvas nil))
      (should (xiiif-canvas-p opened)))))

(ert-deftest xiiif-view-int/view-canvas-no-graphics-falls-back ()
  (let ((opened nil))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil))
              ((symbol-function 'xiiif-open-canvas)
               (lambda (c) (setq opened c)))
              ((symbol-function 'xiiif-view-load-canvas)
               (lambda (&rest _) (error "must not open viewer"))))
      (xiiif-view-canvas (xiiif-view-int--canvas t))
      (should (xiiif-canvas-p opened)))))

(ert-deftest xiiif-view-int/view-canvas-opens-viewer ()
  (let ((loaded nil))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'xiiif-view-load-canvas)
               (lambda (m c s &optional r) (setq loaded (list m c s r)))))
      (let ((xiiif-current-manifest
             (make-xiiif-manifest :url "https://x/m" :id "https://x/m")))
        (xiiif-view-canvas (xiiif-view-int--canvas t)))
      (should (equal "https://x/m" (nth 0 loaded)))
      (should (equal "https://x/c/1" (nth 1 loaded)))
      (should (null (nth 3 loaded))))))


;;; ---- search RET routes region to viewer ----

(ert-deftest xiiif-view-int/search-ret-with-region-opens-viewer ()
  (let* ((manifest (make-xiiif-manifest
                    :url "https://x/m" :id "https://x/m"
                    :items (list '((id . "https://x/c/1") (type . "Canvas")))
                    :raw '((id . "https://x/m") (type . "Manifest")
                           (items . [((id . "https://x/c/1") (type . "Canvas"))]))))
         (hit (make-xiiif-search-hit
               :canvas-id "https://x/c/1"
               :region (make-xiiif-region :x 200 :y 300 :w 120 :h 90)))
         (loaded nil))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'tabulated-list-get-id) (lambda () hit))
              ((symbol-function 'xiiif-manifest-find-canvas)
               (lambda (_m _id) (xiiif-view-int--canvas t)))
              ((symbol-function 'xiiif-view-load-canvas)
               (lambda (m c s &optional r) (setq loaded (list m c s r)))))
      (with-temp-buffer
        (setq-local xiiif-search--manifest manifest)
        (xiiif-search--open-at-point))
      (should (equal "https://x/m" (nth 0 loaded)))
      (should (xiiif-region-p (nth 3 loaded)))
      (should (= 200 (xiiif-region-x (nth 3 loaded)))))))

(ert-deftest xiiif-view-int/search-ret-without-region-opens-detail ()
  (let* ((manifest (make-xiiif-manifest :url "https://x/m" :id "https://x/m"))
         (hit (make-xiiif-search-hit :canvas-id "https://x/c/1" :region nil))
         (opened nil))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'tabulated-list-get-id) (lambda () hit))
              ((symbol-function 'xiiif-manifest-find-canvas)
               (lambda (_m _id) (xiiif-view-int--canvas t)))
              ((symbol-function 'xiiif-open-canvas)
               (lambda (c) (setq opened c)))
              ((symbol-function 'xiiif-view-load-canvas)
               (lambda (&rest _) (error "must not open viewer"))))
      (with-temp-buffer
        (setq-local xiiif-search--manifest manifest)
        (xiiif-search--open-at-point))
      (should (xiiif-canvas-p opened)))))


;;; ---- annotation RET routes region to viewer ----

(ert-deftest xiiif-view-int/annotation-ret-with-region-opens-viewer ()
  (let ((loaded nil))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'xiiif-view-load-canvas)
               (lambda (m c s &optional r) (setq loaded (list m c s r)))))
      (with-temp-buffer
        (setq-local xiiif-ui--annotations-canvas (xiiif-view-int--canvas t))
        (let ((xiiif-current-manifest
               (make-xiiif-manifest :url "https://x/m" :id "https://x/m")))
          (insert (propertize "an annotation\n"
                              'xiiif-annotation-region
                              (make-xiiif-region :x 5 :y 6 :w 7 :h 8)))
          (goto-char (point-min))
          (xiiif-ui--annotation-view-at-point)))
      (should (= 5 (xiiif-region-x (nth 3 loaded)))))))


;;; ---- Content State import jumps into the viewer ----

(ert-deftest xiiif-view-int/content-state-region-opens-viewer ()
  (let* ((manifest (make-xiiif-manifest :url "https://x/m" :id "https://x/m"))
         (anchor (xiiif-anchor-create
                  :manifest "https://x/m" :canvas "https://x/c/1"
                  :region '(100 100 400 400)))
         (token (xiiif-content-state-encode anchor))
         (loaded nil))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'xiiif-manifest-find-canvas)
               (lambda (_m _id) (xiiif-view-int--canvas t)))
              ((symbol-function 'xiiif-cache-set-canvas) #'ignore)
              ((symbol-function 'xiiif-view-load-canvas)
               (lambda (m c s &optional r) (setq loaded (list m c s r)))))
      (let ((xiiif-current-manifest manifest))
        (xiiif-open-content-state token))
      (should (equal "https://x/m" (nth 0 loaded)))
      (should (xiiif-region-p (nth 3 loaded)))
      (should (= 100 (xiiif-region-x (nth 3 loaded)))))))

(provide 'xiiif-view-integration-test)
;;; xiiif-view-integration-test.el ends here
