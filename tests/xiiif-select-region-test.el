;;; xiiif-select-region-test.el --- Tests for numeric region selection -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Spec §23 asks that the rendered image never be the only way to know
;; where a view is, or to reach a region.  Two things follow, and both
;; are tested here: the coordinates are readable at the prompt, and a
;; region stays reachable off a graphic display.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-region)
(require 'xiiif-view)
(require 'xiiif)

;;; ---------- the validity rule ----------

(ert-deftest xiiif-select-region/valid-rectangles ()
  (dolist (spec '("0,0,100,100" "10,20,30,40" "0,0,100,100%" "5.5,6,7,8"))
    (should (xiiif-region-valid-p (xiiif-region-from-string spec)))))

(ert-deftest xiiif-select-region/degenerate-rectangles-are-refused ()
  ;; Zero extent, negative extent, negative origin: each is a typo, and
  ;; each would otherwise reach a server as a request for nothing.
  (dolist (spec '("0,0,0,100" "0,0,100,0" "0,0,-5,10" "-1,0,10,10"))
    (should-not (xiiif-region-valid-p (xiiif-region-from-string spec)))))

(ert-deftest xiiif-select-region/percent-must-stay-inside-the-canvas ()
  (should-not (xiiif-region-valid-p (xiiif-region-from-string "50,0,60,10%")))
  (should-not (xiiif-region-valid-p (xiiif-region-from-string "0,90,10,20%")))
  ;; The same numbers as pixels are fine - there is no bound to check.
  (should (xiiif-region-valid-p (xiiif-region-from-string "50,0,60,10"))))

;;; ---------- in the viewer ----------

(defun xiiif-select-region-test--info ()
  (make-xiiif-image-info :width 6000 :height 4000))

(defmacro xiiif-select-region-test--with-viewer (&rest body)
  "Run BODY in a viewer buffer with rendering stubbed out."
  (declare (indent 0) (debug (body)))
  `(cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
             ((symbol-function 'xiiif-view--render) #'ignore)
             ((symbol-function 'xiiif-fetch-cancel-group) #'ignore))
     (with-temp-buffer
       (rename-buffer xiiif-view--buffer t)
       (xiiif-view-mode)
       (setq xiiif-view--info (xiiif-select-region-test--info)
             xiiif-view--service (make-xiiif-image-service :id "https://img/svc"))
       (xiiif-view--navigate
        (make-xiiif-view-state :manifest-url "https://x/manifest"
                               :canvas-id "https://x/canvas/1"
                               :x 0 :y 0 :w 6000 :h 4000 :level 0))
       ,@body)))

(ert-deftest xiiif-select-region/viewer-moves-to-the-typed-region ()
  (xiiif-select-region-test--with-viewer
    (xiiif-view-select-region "1000,500,400,300")
    (let ((s xiiif-view--state))
      ;; The view is fitted around the request, so the exact width is
      ;; the window's; what must hold is that the request is covered.
      (should (<= (xiiif-view-state-x s) 1000))
      (should (<= (xiiif-view-state-y s) 500))
      (should (>= (+ (xiiif-view-state-x s) (xiiif-view-state-w s)) 1400))
      (should (>= (+ (xiiif-view-state-y s) (xiiif-view-state-h s)) 800))
      ;; Identity is preserved: this is still the same canvas.
      (should (equal "https://x/canvas/1" (xiiif-view-state-canvas-id s)))
      (should (equal "https://x/manifest" (xiiif-view-state-manifest-url s))))))

(ert-deftest xiiif-select-region/viewer-prompt-shows-the-current-region ()
  "The default at the prompt is where the view already is.
This is the whole of §23's second sentence: the coordinates are
knowable without looking at the picture."
  (xiiif-select-region-test--with-viewer
    (let (initial)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (_prompt &optional init &rest _)
                   (setq initial init)
                   "10,20,30,40")))
        (call-interactively #'xiiif-view-select-region))
      (should (xiiif-region-from-string initial))
      (should (equal initial
                     (xiiif-region-to-string
                      (make-xiiif-region :x 0 :y 0 :w 6000 :h 4000)))))))

(ert-deftest xiiif-select-region/viewer-refuses-nonsense ()
  (xiiif-select-region-test--with-viewer
    (let ((before xiiif-view--state))
      (should-error (xiiif-view-select-region "not a region") :type 'user-error)
      (should-error (xiiif-view-select-region "0,0,0,10") :type 'user-error)
      ;; A refused region leaves the view exactly where it was.
      (should (eq before xiiif-view--state)))))

;;; ---------- outside the viewer ----------

(defun xiiif-select-region-test--canvas ()
  (make-xiiif-canvas
   :id "https://x/canvas/1" :label "Folio 1"
   :image-service (make-xiiif-image-service :id "https://img/svc")))

(ert-deftest xiiif-select-region/opens-the-viewer-focused ()
  (let ((xiiif-current-manifest
         (make-xiiif-manifest :url "https://x/manifest" :id "https://x/manifest"
                              :type "Manifest" :label "Test"))
        (opened nil))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'xiiif-canvas-image-service)
               (lambda (_) (make-xiiif-image-service :id "https://img/svc")))
              ((symbol-function 'xiiif-view-load-canvas)
               (lambda (murl cid _svc &optional region)
                 (setq opened (list murl cid region)))))
      (with-temp-buffer
        (xiiif-select-region "100,200,300,400"
                             (xiiif-select-region-test--canvas))))
    (should (equal "https://x/manifest" (nth 0 opened)))
    (should (equal "https://x/canvas/1" (nth 1 opened)))
    (should (equal "100,200,300,400" (xiiif-region-to-string (nth 2 opened))))))

(ert-deftest xiiif-select-region/off-a-graphic-display-the-url-is-still-reachable ()
  "No picture is no reason to lose the region: it goes to the kill ring."
  (let ((kill-ring nil)
        (kill-ring-yank-pointer nil)
        (interprogram-cut-function nil)
        (interprogram-paste-function nil)
        (xiiif-current-manifest nil))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil))
              ((symbol-function 'xiiif-view-load-canvas)
               (lambda (&rest _) (error "must not open a viewer"))))
      (with-temp-buffer
        (xiiif-select-region "100,200,300,400"
                             (xiiif-select-region-test--canvas))))
    (should (string-match-p "/100,200,300,400/" (current-kill 0)))))

(ert-deftest xiiif-select-region/percent-reaches-the-image-api-as-pct ()
  (let ((kill-ring nil)
        (kill-ring-yank-pointer nil)
        (interprogram-cut-function nil)
        (interprogram-paste-function nil))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) nil)))
      (with-temp-buffer
        (xiiif-select-region "10,20,30,40%"
                             (xiiif-select-region-test--canvas))))
    (should (string-match-p "/pct:10,20,30,40/" (current-kill 0)))))

(ert-deftest xiiif-select-region/refuses-nonsense-before-any-canvas-work ()
  (cl-letf (((symbol-function 'xiiif-canvas-image-service)
             (lambda (_) (error "must not be reached"))))
    (with-temp-buffer
      (should-error (xiiif-select-region "nope"
                                         (xiiif-select-region-test--canvas))
                    :type 'user-error)
      (should-error (xiiif-select-region "0,0,10,0"
                                         (xiiif-select-region-test--canvas))
                    :type 'user-error))))

(ert-deftest xiiif-select-region/is-bound-and-is-a-command ()
  ;; §15 lists it; §23 requires it be reachable by name.
  (should (commandp 'xiiif-select-region))
  (should (commandp 'xiiif-view-select-region))
  (should (eq 'xiiif-view-select-region
              (lookup-key xiiif-view-mode-map (kbd "r")))))

(provide 'xiiif-select-region-test)
;;; xiiif-select-region-test.el ends here
