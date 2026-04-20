;;; xiiif-ui-test.el --- Tests for the UI renderers -*- lexical-binding: t; -*-

;;; Commentary:

;; Render each buffer kind on a synthetic struct and verify the
;; buffer enters the expected major mode, contains key markers in
;; its text, and that relevant buffer-local state is populated.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-core)
(require 'xiiif-ui)
(require 'xiiif)

(defun xiiif-ui-test--manifest ()
  (make-xiiif-manifest
   :url      "http://x/m"
   :id       "http://x/m"
   :type     "Manifest"
   :label    "UI Test Manifest"
   :summary  "A tiny manifest used only in tests."
   :metadata nil
   :items    '(((id . "http://x/c1") (type . "Canvas")
                (label . "Folio 1")))
   :raw      '((id . "http://x/m") (type . "Manifest"))))

(defun xiiif-ui-test--canvas ()
  (make-xiiif-canvas
   :id       "http://x/c1"
   :type     "Canvas"
   :label    "Folio 1"
   :width    1000 :height 2000
   :image-service (make-xiiif-image-service
                   :id "http://img.example/svc"
                   :type "ImageService3"
                   :profile "level1")
   :raw      '((id . "http://x/c1") (type . "Canvas"))))

(defun xiiif-ui-test--collection ()
  (make-xiiif-collection
   :url   "http://x/col"
   :id    "http://x/col"
   :type  "Collection"
   :label "UI Test Collection"
   :items '(((id . "http://x/m1") (type . "Manifest") (label . "M1"))
            ((id . "http://x/m2") (type . "Manifest") (label . "M2")))
   :raw   '((id . "http://x/col") (type . "Collection"))))

(defmacro xiiif-ui-test--in-temp (buf-const &rest body)
  "Run BODY, then kill the buffer named by BUF-CONST."
  (declare (indent 1) (debug t))
  `(unwind-protect
       (progn ,@body)
     (when (get-buffer ,buf-const) (kill-buffer ,buf-const))))


;;; ---- manifest overview ----

(ert-deftest xiiif-ui/manifest-overview-rendering ()
  (let ((xiiif-ui-show-thumbnails nil))
    (xiiif-ui-test--in-temp xiiif-ui--manifest-buffer
      (xiiif-ui-render-manifest (xiiif-ui-test--manifest))
      (with-current-buffer xiiif-ui--manifest-buffer
        (should (derived-mode-p 'xiiif-manifest-mode))
        (goto-char (point-min))
        (should (search-forward "UI Test Manifest" nil t))
        (should (search-forward "Canvases (1)" nil t))))))


;;; ---- canvas browser ----

(ert-deftest xiiif-ui/canvas-browser-rendering ()
  (xiiif-ui-test--in-temp xiiif-ui--canvases-buffer
    (xiiif-ui-render-canvases (xiiif-ui-test--manifest))
    (with-current-buffer xiiif-ui--canvases-buffer
      (should (derived-mode-p 'xiiif-canvas-list-mode))
      (should (= 1 (length tabulated-list-entries)))
      (let ((id (car (car tabulated-list-entries))))
        (should (xiiif-canvas-p id))
        (should (equal "http://x/c1" (xiiif-canvas-id id)))))))


;;; ---- canvas detail fires the hook ----

(ert-deftest xiiif-ui/canvas-detail-fires-hook ()
  (let* ((xiiif-ui-show-thumbnails nil)
         (captured nil)
         (xiiif-after-render-canvas-hook
          (list (lambda (c) (setq captured c)))))
    (xiiif-ui-test--in-temp xiiif-ui--canvas-buffer
      (xiiif-ui-render-canvas (xiiif-ui-test--canvas))
      (should (xiiif-canvas-p captured))
      (with-current-buffer xiiif-ui--canvas-buffer
        (should (derived-mode-p 'xiiif-canvas-mode))
        (should xiiif-ui--canvas)))))


;;; ---- collection browser ----

(ert-deftest xiiif-ui/collection-rendering ()
  (xiiif-ui-test--in-temp xiiif-ui--collection-buffer
    (xiiif-ui-render-collection (xiiif-ui-test--collection))
    (with-current-buffer xiiif-ui--collection-buffer
      (should (derived-mode-p 'xiiif-collection-mode))
      (should (= 2 (length tabulated-list-entries))))))


;;; ---- structures ----

(ert-deftest xiiif-ui/structures-rendering ()
  (let* ((m (make-xiiif-manifest
             :url "http://x/m" :id "http://x/m"
             :type "Manifest" :label "M"
             :items '(((id . "http://x/c1") (type . "Canvas") (label . "A")))
             :raw `((id . "http://x/m") (type . "Manifest")
                    (structures .
                      [((id . "http://x/r1")
                        (type . "Range")
                        (label . "Root")
                        (items . [((id . "http://x/c1") (type . "Canvas"))]))])))))
    (xiiif-ui-test--in-temp xiiif-ui--structures-buffer
      (xiiif-ui-render-structures m)
      (with-current-buffer xiiif-ui--structures-buffer
        (should (derived-mode-p 'xiiif-structures-mode))
        (goto-char (point-min))
        (should (search-forward "Root" nil t))
        (should (search-forward "A" nil t))))))


;;; ---- annotations buffer ----

(ert-deftest xiiif-ui/annotations-empty-rendering ()
  (xiiif-ui-test--in-temp xiiif-ui--annotations-buffer
    (xiiif-ui-render-annotations (xiiif-ui-test--canvas) nil)
    (with-current-buffer xiiif-ui--annotations-buffer
      (should (derived-mode-p 'xiiif-annotations-mode))
      (goto-char (point-min))
      (should (search-forward "No annotations" nil t)))))


;;; ---- info.json buffer ----

(ert-deftest xiiif-ui/info-rendering ()
  (let ((info (make-xiiif-image-info
               :id "http://img.example/svc"
               :type "ImageService3"
               :protocol "http://iiif.io/api/image"
               :profile "level1"
               :width 6000 :height 4000
               :sizes nil :tiles nil
               :preferred-formats nil :formats '("jpg")
               :qualities '("default") :extra-features nil
               :rights nil :raw nil)))
    (xiiif-ui-test--in-temp xiiif-ui--info-buffer
      (xiiif-ui-render-info info)
      (with-current-buffer xiiif-ui--info-buffer
        (should (derived-mode-p 'xiiif-info-mode))
        (goto-char (point-min))
        (should (search-forward "http://img.example/svc" nil t))
        (should (search-forward "level1" nil t))))))


;;; ---- OCR sidecar ----

(ert-deftest xiiif-ui/ocr-rendering ()
  (xiiif-ui-test--in-temp xiiif-ui--ocr-buffer
    (xiiif-ui-render-ocr
     (xiiif-ui-test--canvas)
     '(:url "http://x/ocr.xml" :format alto :label "ALTO"
       :text "hello world" :body "<alto/>"))
    (with-current-buffer xiiif-ui--ocr-buffer
      (should (derived-mode-p 'xiiif-ocr-mode))
      (goto-char (point-min))
      (should (search-forward "hello world" nil t))
      (should (search-forward "ALTO" nil t)))))


(provide 'xiiif-ui-test)
;;; xiiif-ui-test.el ends here
