;;; xiiif-batch-test.el --- Tests for the batch scripting surface -*- lexical-binding: t; -*-

;;; Commentary:

;; Exercises the prompt-free Spec D surface entirely in batch: load a
;; fixture manifest over file://, read the current-view anchor, drive
;; xiiif-batch-goto with an anchor and a Content State token, and run
;; the full acceptance flow (open -> anchor -> Content State -> org
;; note) with no interaction.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif)

(defconst xiiif-batch-test--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of this test file, captured at load time.")

(defconst xiiif-batch-test--manifest-url
  (concat "file://"
          (expand-file-name "../examples/sample-manifest.json"
                            xiiif-batch-test--dir)))

(defconst xiiif-batch-test--collection-url
  (concat "file://"
          (expand-file-name "../examples/sample-collection.json"
                            xiiif-batch-test--dir)))

(defmacro xiiif-batch-test--clean-state (&rest body)
  "Run BODY with fresh session state and no leftover buffers."
  (declare (indent 0) (debug t))
  `(let ((xiiif-current-manifest nil)
         (xiiif-current-canvas nil)
         (xiiif-current-collection nil))
     (unwind-protect
         (progn ,@body)
       (dolist (name (list xiiif-ui--manifest-buffer
                           xiiif-ui--canvas-buffer
                           "*XIIIF View*"))
         (when (get-buffer name) (kill-buffer name))))))


;;; ---- open ----

(ert-deftest xiiif-batch/open-returns-summary ()
  (xiiif-batch-test--clean-state
    (let ((summary (xiiif-batch-open xiiif-batch-test--manifest-url)))
      (should (equal "A Sample Illuminated Book" (alist-get 'title summary)))
      (should (= 2 (alist-get 'canvases summary)))
      (should (eq t (alist-get 'structures summary)))
      (should (stringp (alist-get 'id summary)))
      ;; The manifest is now the current one.
      (should (equal xiiif-batch-test--manifest-url
                     (xiiif-manifest-url xiiif-current-manifest))))))

(ert-deftest xiiif-batch/open-rejects-non-manifest ()
  (xiiif-batch-test--clean-state
    (should-error (xiiif-batch-open xiiif-batch-test--collection-url)
                  :type 'xiiif-error)))


;;; ---- current-view ----

(ert-deftest xiiif-batch/current-view-nil-when-empty ()
  (xiiif-batch-test--clean-state
    (should-not (xiiif-batch-current-view))))

(ert-deftest xiiif-batch/current-view-manifest-then-canvas ()
  (xiiif-batch-test--clean-state
    (xiiif-batch-open xiiif-batch-test--manifest-url)
    ;; With only a manifest loaded, the anchor is manifest-level.
    (let ((anchor (xiiif-batch-current-view)))
      (should (xiiif-anchor-p anchor))
      (should-not (xiiif-anchor-canvas anchor)))
    ;; After selecting a canvas, the anchor names it.
    (let ((canvas (car (xiiif-manifest-canvases xiiif-current-manifest))))
      (setq xiiif-current-canvas canvas)
      (let ((anchor (xiiif-batch-current-view)))
        (should (equal (xiiif-canvas-id canvas)
                       (xiiif-anchor-canvas anchor)))))))


;;; ---- goto ----

(ert-deftest xiiif-batch/goto-anchor-renders-canvas ()
  (xiiif-batch-test--clean-state
    (xiiif-batch-open xiiif-batch-test--manifest-url)
    (let* ((canvas-id "https://example.org/iiif/book1/canvas/p2")
           (anchor (xiiif-anchor-create
                    :manifest xiiif-batch-test--manifest-url
                    :canvas canvas-id)))
      (xiiif-batch-goto anchor)
      ;; Batch has no graphic display: the canvas detail buffer opens.
      (should (equal canvas-id (xiiif-canvas-id xiiif-current-canvas))))))

(ert-deftest xiiif-batch/goto-accepts-content-state-token ()
  (xiiif-batch-test--clean-state
    (xiiif-batch-open xiiif-batch-test--manifest-url)
    (let* ((anchor (xiiif-anchor-create
                    :manifest xiiif-batch-test--manifest-url
                    :canvas "https://example.org/iiif/book1/canvas/p1"))
           (token (xiiif-content-state-encode anchor))
           (result (xiiif-batch-goto token)))
      (should (equal "https://example.org/iiif/book1/canvas/p1"
                     (xiiif-anchor-canvas result)))
      (should (equal "https://example.org/iiif/book1/canvas/p1"
                     (xiiif-canvas-id xiiif-current-canvas))))))

(ert-deftest xiiif-batch/goto-loads-manifest-when-not-current ()
  (xiiif-batch-test--clean-state
    ;; No manifest loaded yet; goto must load it synchronously.
    (let ((anchor (xiiif-anchor-create
                   :manifest xiiif-batch-test--manifest-url
                   :canvas "https://example.org/iiif/book1/canvas/p1")))
      (xiiif-batch-goto anchor)
      (should (equal xiiif-batch-test--manifest-url
                     (xiiif-manifest-url xiiif-current-manifest))))))


;;; ---- annotate ----

(ert-deftest xiiif-batch/annotate-writes-note-no-prompts ()
  (xiiif-batch-test--clean-state
    (let* ((tmp (make-temp-file "xiiif-batch-" nil ".org"))
           (xiiif-annot-org-file tmp))
      (unwind-protect
          (let ((anchor (xiiif-anchor-create
                         :manifest xiiif-batch-test--manifest-url
                         :canvas "https://example.org/iiif/book1/canvas/p1"
                         :region '(10 20 30 40))))
            (xiiif-batch-annotate anchor "Batch note" "written by a script")
            (with-current-buffer (find-file-noselect tmp)
              (goto-char (point-min))
              (should (search-forward "* Batch note" nil t))
              (should (search-forward "written by a script" nil t))
              (kill-buffer)))
        (ignore-errors (delete-file tmp))))))

(ert-deftest xiiif-batch/annotate-blank-title-signals ()
  (xiiif-batch-test--clean-state
    (should-error
     (xiiif-batch-annotate (xiiif-anchor-create :manifest "m") "  " "b")
     :type 'xiiif-error)))


;;; ---- full acceptance flow (Spec D) ----

(ert-deftest xiiif-batch/acceptance-open-anchor-state-note ()
  "A non-interactive session loads a manifest, produces an anchor,
converts it to Content State and creates an Org note - no prompts."
  (xiiif-batch-test--clean-state
    (let* ((tmp (make-temp-file "xiiif-batch-accept-" nil ".org"))
           (xiiif-annot-org-file tmp))
      (unwind-protect
          (progn
            ;; 1. open
            (let ((summary (xiiif-batch-open xiiif-batch-test--manifest-url)))
              (should (= 2 (alist-get 'canvases summary))))
            ;; 2. select a canvas and read the anchor
            (setq xiiif-current-canvas
                  (car (xiiif-manifest-canvases xiiif-current-manifest)))
            (let* ((anchor (xiiif-batch-current-view))
                   ;; 3. anchor -> Content State -> anchor
                   (token (xiiif-content-state-encode anchor))
                   (back (xiiif-content-state-parse token)))
              (should (equal (xiiif-anchor-canvas anchor)
                             (xiiif-anchor-canvas back)))
              ;; 4. create a note from the round-tripped anchor
              (xiiif-batch-annotate back "Auto note" "agent body")
              (with-current-buffer (find-file-noselect tmp)
                (goto-char (point-min))
                (should (search-forward "* Auto note" nil t))
                (should (search-forward ":XIIIF_CANVAS:" nil t))
                (kill-buffer))))
        (ignore-errors (delete-file tmp))))))

(provide 'xiiif-batch-test)
;;; xiiif-batch-test.el ends here
