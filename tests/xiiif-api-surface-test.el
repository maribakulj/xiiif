;;; xiiif-api-surface-test.el --- Tests for the SPEC_V1.md §15 API -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; §15 fixes the names third-party code is entitled to call.  A name
;; that only sometimes exists is worse than one that never did, so the
;; first test here is simply that they are all bound - it is what makes
;; §15 a contract rather than a wish list.
;;
;; One of the nine is deliberately absent and stays absent until its
;; blocker clears:
;;
;;   xiiif-open-locus-artifact - needs locusolus/packages/protocol
;;
;; It is listed here rather than asserted on: a test that fails the day
;; a feature lands is a bad alarm.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif)
(require 'xiiif-annot)
(require 'xiiif-search)

(defconst xiiif-api-surface-test--names
  '(xiiif-open
    xiiif-open-manifest
    xiiif-open-canvas
    xiiif-search-ocr
    xiiif-select-region
    xiiif-export-content-state
    xiiif-create-annotation
    xiiif-open-external-viewer)
  "The §15 names that are delivered today.")

(defun xiiif-api-surface-test--manifest ()
  (make-xiiif-manifest
   :url "https://x/manifest" :id "https://x/manifest"
   :type "Manifest" :label "Test"
   :items '(((id . "https://x/canvas/1") (type . "Canvas")
             (label . "Folio 1")))
   :raw '((id . "https://x/manifest") (type . "Manifest"))))

;;; ---------- the contract itself ----------

(ert-deftest xiiif-api-surface/every-delivered-name-is-bound ()
  (dolist (name xiiif-api-surface-test--names)
    (should (fboundp name))))

(ert-deftest xiiif-api-surface/every-delivered-name-is-a-command ()
  ;; §15 is the Elisp API, but each of these is also something a user
  ;; invokes by name; none of them is a library-only entry point.
  (dolist (name xiiif-api-surface-test--names)
    (should (commandp name))))

;;; ---------- xiiif-search-ocr ----------

(ert-deftest xiiif-api-surface/search-ocr-is-the-search-command ()
  ;; Not a copy that can drift: the same function object.
  (should (eq (symbol-function 'xiiif-search)
              (indirect-function 'xiiif-search-ocr))))

(ert-deftest xiiif-api-surface/no-search-service-points-at-the-ocr-command ()
  (let* ((xiiif-current-manifest (xiiif-api-surface-test--manifest))
         (err (should-error (xiiif-search-ocr "cheval") :type 'user-error)))
    (should (string-match-p "xiiif-show-ocr" (cadr err)))))

;;; ---------- xiiif-export-content-state ----------

(ert-deftest xiiif-api-surface/export-content-state-round-trips ()
  "Each of the three exported forms is one `xiiif-open' understands."
  (let ((anchor (xiiif-anchor-create :manifest "https://x/manifest"
                                     :canvas "https://x/canvas/1")))
    (dolist (format '(token json url))
      (let ((text (with-temp-buffer
                    (xiiif-export-content-state format anchor)
                    (buffer-string))))
        (should (eq 'content-state (xiiif-open-target-kind text)))
        (let ((back (xiiif-content-state-parse text)))
          (should (equal "https://x/manifest" (xiiif-anchor-manifest back)))
          (should (equal "https://x/canvas/1" (xiiif-anchor-canvas back))))))))

(ert-deftest xiiif-api-surface/export-content-state-defaults-to-a-token ()
  (let* ((anchor (xiiif-anchor-create :manifest "https://x/manifest"))
         (text (with-temp-buffer
                 (xiiif-export-content-state nil anchor)
                 (buffer-string))))
    (should (equal text (xiiif-content-state-encode anchor)))))

(ert-deftest xiiif-api-surface/export-content-state-kills-when-read-only ()
  (let ((anchor (xiiif-anchor-create :manifest "https://x/manifest"))
        (kill-ring nil)
        (kill-ring-yank-pointer nil)
        (interprogram-cut-function nil)
        (interprogram-paste-function nil))
    (with-temp-buffer
      (setq buffer-read-only t)
      (xiiif-export-content-state 'token anchor)
      ;; Nothing inserted, everything preserved.
      (should (equal "" (buffer-string))))
    (should (equal (xiiif-content-state-encode anchor) (current-kill 0)))))

(ert-deftest xiiif-api-surface/export-content-state-rejects-a-bad-format ()
  (let ((anchor (xiiif-anchor-create :manifest "https://x/manifest")))
    (with-temp-buffer
      (should-error (xiiif-export-content-state 'yaml anchor)
                    :type 'user-error))))

(ert-deftest xiiif-api-surface/export-content-state-uses-the-context ()
  (let ((xiiif-current-manifest (xiiif-api-surface-test--manifest))
        (xiiif-current-canvas nil))
    (with-temp-buffer
      (xiiif-export-content-state 'token)
      (should (equal "https://x/manifest"
                     (xiiif-anchor-manifest
                      (xiiif-content-state-parse (buffer-string))))))))

;;; ---------- xiiif-open-external-viewer ----------

(ert-deftest xiiif-api-surface/external-viewer-defaults-to-mirador ()
  (let ((xiiif-current-manifest (xiiif-api-surface-test--manifest))
        (xiiif-current-canvas nil)
        (opened nil))
    (cl-letf (((symbol-function 'browse-url)
               (lambda (url) (setq opened url))))
      (with-temp-buffer
        (xiiif-open-external-viewer))
      (should (string-prefix-p "https://projectmirador.org/embed/?iiif-content="
                               opened)))))

(ert-deftest xiiif-api-surface/external-viewer-passes-the-anchor-through ()
  (let ((xiiif-current-manifest (xiiif-api-surface-test--manifest))
        (opened nil))
    (cl-letf (((symbol-function 'browse-url)
               (lambda (url) (setq opened url))))
      (xiiif-open-external-viewer
       'mirador
       (xiiif-anchor-create :manifest "https://y/manifest"
                            :canvas "https://y/canvas/9"))
      (let ((back (xiiif-content-state-parse opened)))
        (should (equal "https://y/manifest" (xiiif-anchor-manifest back)))
        (should (equal "https://y/canvas/9" (xiiif-anchor-canvas back)))))))

(ert-deftest xiiif-api-surface/external-viewer-refuses-an-unknown-viewer ()
  (let ((xiiif-current-manifest (xiiif-api-surface-test--manifest)))
    (cl-letf (((symbol-function 'browse-url)
               (lambda (_) (error "must not open anything"))))
      (should-error (xiiif-open-external-viewer 'seadragon)
                    :type 'user-error))))

;;; ---------- xiiif-create-annotation ----------

(ert-deftest xiiif-api-surface/create-annotation-takes-its-arguments ()
  "An explicit anchor, title and body reach the backend unprompted."
  (let* ((got nil)
         (anchor (xiiif-anchor-create :manifest "https://x/manifest"))
         (xiiif-annot-backend-function
          (lambda (a title body) (setq got (list a title body)))))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) (error "must not prompt"))))
      (xiiif-create-annotation anchor "Titre" "Corps"))
    (should (equal "https://x/manifest" (xiiif-anchor-manifest (nth 0 got))))
    (should (equal "Titre" (nth 1 got)))
    (should (equal "Corps" (nth 2 got)))))

(ert-deftest xiiif-api-surface/create-annotation-falls-back-to-the-context ()
  (let* ((got nil)
         (xiiif-current-manifest (xiiif-api-surface-test--manifest))
         (xiiif-current-canvas nil)
         (xiiif-annot-backend-function
          (lambda (a title _body) (setq got (cons a title)))))
    (cl-letf (((symbol-function 'read-string)
               (lambda (&rest _) "Titre saisi")))
      (with-temp-buffer
        (xiiif-create-annotation)))
    (should (equal "https://x/manifest" (xiiif-anchor-manifest (car got))))
    (should (equal "Titre saisi" (cdr got)))))

(provide 'xiiif-api-surface-test)
;;; xiiif-api-surface-test.el ends here
