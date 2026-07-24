;;; xiiif-annot-test.el --- Tests for anchored notes -*- lexical-binding: t; -*-

;;; Commentary:

;; The Org backend round-trip (create -> re-readable entry -> visit),
;; context-anchor selection, the metadata block enrichment, and a
;; pluggable custom backend.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-core)
(require 'xiiif-region)
(require 'xiiif-anchor)
(require 'xiiif-annot)
(require 'xiiif-org)

;;; ---- Org entry generation ----

(ert-deftest xiiif-annot/org-entry-has-drawer-and-links ()
  (let* ((anchor (xiiif-anchor-create
                  :manifest "https://x/m" :canvas "https://x/c/1"
                  :region '(100 150 400 300) :label "Folio 1"))
         (entry (xiiif-annot--org-entry anchor "My note" "Some body")))
    (should (string-match-p "^\\* My note$" entry))
    (should (string-match-p ":XIIIF_MANIFEST: https://x/m" entry))
    (should (string-match-p ":XIIIF_CANVAS: https://x/c/1" entry))
    (should (string-match-p ":XIIIF_REGION: 100,150,400,300" entry))
    (should (string-match-p ":XIIIF_CONTENT_STATE: [A-Za-z0-9_-]+" entry))
    (should (string-match-p "Some body" entry))
    ;; The drawer immediately follows the headline.
    (should (string-match-p "\\* My note\n:PROPERTIES:" entry))))

(ert-deftest xiiif-annot/org-entry-omits-region-when-absent ()
  (let* ((anchor (xiiif-anchor-create :manifest "https://x/m"))
         (entry (xiiif-annot--org-entry anchor "T" "")))
    (should-not (string-match-p ":XIIIF_REGION:" entry))
    (should-not (string-match-p ":XIIIF_CANVAS:" entry))))


;;; ---- store + visit round-trip ----

(ert-deftest xiiif-annot/store-and-anchor-at-point-round-trip ()
  (let* ((tmp (make-temp-file "xiiif-annot-" nil ".org"))
         (xiiif-annot-org-file tmp)
         (anchor (xiiif-anchor-create
                  :manifest "https://x/m" :canvas "https://x/c/1"
                  :region '(10 20 30 40))))
    (unwind-protect
        (progn
          (xiiif-annot-org-store anchor "Roundtrip" "body text")
          (with-current-buffer (find-file-noselect tmp)
            (require 'org)
            (org-mode)
            (goto-char (point-min))
            (should (search-forward "* Roundtrip" nil t))
            (let ((back (xiiif-annot--anchor-at-point)))
              (should (equal "https://x/m" (xiiif-anchor-manifest back)))
              (should (equal "https://x/c/1" (xiiif-anchor-canvas back)))
              (let ((r (xiiif-anchor-region back)))
                (should (= 10 (xiiif-region-x r)))
                (should (= 40 (xiiif-region-h r)))))
            (kill-buffer)))
      (ignore-errors (delete-file tmp)))))

(ert-deftest xiiif-annot/anchor-at-point-percent-region ()
  (let* ((tmp (make-temp-file "xiiif-annot-" nil ".org"))
         (xiiif-annot-org-file tmp)
         (anchor (xiiif-anchor-create
                  :manifest "https://x/m" :canvas "https://x/c/1"
                  :region (make-xiiif-region :x 5 :y 6 :w 7 :h 8
                                             :unit 'percent))))
    (unwind-protect
        (progn
          (xiiif-annot-org-store anchor "Pct" "")
          (with-current-buffer (find-file-noselect tmp)
            (require 'org)
            (org-mode)
            (goto-char (point-min))
            (let ((back (xiiif-annot--anchor-at-point)))
              (should (eq 'percent
                          (xiiif-region-unit (xiiif-anchor-region back)))))
            (kill-buffer)))
      (ignore-errors (delete-file tmp)))))

(ert-deftest xiiif-annot/store-appends-second-note ()
  (let* ((tmp (make-temp-file "xiiif-annot-" nil ".org"))
         (xiiif-annot-org-file tmp))
    (unwind-protect
        (progn
          (xiiif-annot-org-store
           (xiiif-anchor-create :manifest "https://x/m") "First" "")
          (xiiif-annot-org-store
           (xiiif-anchor-create :manifest "https://x/m2") "Second" "")
          (with-current-buffer (find-file-noselect tmp)
            (goto-char (point-min))
            (should (search-forward "* First" nil t))
            (should (search-forward "* Second" nil t))
            (kill-buffer)))
      (ignore-errors (delete-file tmp)))))


;;; ---- context anchor ----

(ert-deftest xiiif-annot/context-anchor-prefers-view-state ()
  (with-temp-buffer
    (xiiif-view-mode)
    (setq xiiif-view--state
          (make-xiiif-view-state :manifest-url "https://x/m"
                                 :canvas-id "https://x/c/1"
                                 :x 1 :y 2 :w 3 :h 4))
    (let ((anchor (xiiif-annot--context-anchor)))
      (should (equal "https://x/c/1" (xiiif-anchor-canvas anchor)))
      (should (= 1 (xiiif-region-x (xiiif-anchor-region anchor)))))))

(ert-deftest xiiif-annot/context-anchor-canvas ()
  (let ((xiiif-current-manifest
         (make-xiiif-manifest :url "https://x/m" :id "https://x/m"
                              :label "M"))
        (xiiif-current-canvas
         (make-xiiif-canvas :id "https://x/c/1" :label "Folio 1")))
    (with-temp-buffer
      (let ((anchor (xiiif-annot--context-anchor)))
        (should (equal "https://x/m" (xiiif-anchor-manifest anchor)))
        (should (equal "https://x/c/1" (xiiif-anchor-canvas anchor)))
        (should-not (xiiif-anchor-region anchor))))))

(ert-deftest xiiif-annot/context-anchor-none-signals ()
  (let ((xiiif-current-manifest nil)
        (xiiif-current-canvas nil))
    (with-temp-buffer
      (should-error (xiiif-annot--context-anchor) :type 'user-error))))


;;; ---- pluggable backend ----

(ert-deftest xiiif-annot/custom-backend-invoked ()
  (let* ((captured nil)
         (xiiif-annot-backend-function
          (lambda (anchor title body)
            (setq captured (list anchor title body)))))
    (xiiif-annot-create-for-anchor
     (xiiif-anchor-create :manifest "https://x/m") "T" "B")
    (should (equal "T" (nth 1 captured)))
    (should (equal "B" (nth 2 captured)))
    (should (xiiif-anchor-p (nth 0 captured)))))

(ert-deftest xiiif-annot/create-for-anchor-rejects-empty-title ()
  (let ((xiiif-annot-backend-function
         (lambda (&rest _) (error "must not be called"))))
    (should-error (xiiif-annot-create-for-anchor
                   (xiiif-anchor-create :manifest "m") "  " "body")
                  :type 'user-error)))


;;; ---- metadata block enrichment ----

(ert-deftest xiiif-annot/metadata-block-carries-region-and-state ()
  (let* ((manifest (make-xiiif-manifest :url "https://x/m" :id "https://x/m"
                                        :label "M"))
         (canvas (make-xiiif-canvas :id "https://x/c/1" :label "Folio 1"))
         (region (make-xiiif-region :x 1 :y 2 :w 3 :h 4))
         (block (xiiif-org-metadata-block manifest canvas region)))
    (should (string-match-p ":region: 1,2,3,4" block))
    (should (string-match-p ":content-state: [A-Za-z0-9_-]+" block))
    (should (string-match-p ":canvas-id: https://x/c/1" block))))

(ert-deftest xiiif-annot/viewer-annotate-hook-wired ()
  (should (eq xiiif-view-annotate-function
              #'xiiif-annot-create-for-anchor)))

(provide 'xiiif-annot-test)
;;; xiiif-annot-test.el ends here
