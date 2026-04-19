;;; xiiif-org.el --- Org mode integration for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Functions that push xiiif data into an Org buffer as links and
;; small metadata blocks.  Nothing here assumes Org is loaded until
;; an insertion command actually runs, so the rest of the package
;; stays usable in Org-free setups.

;;; Code:

(require 'subr-x)
(require 'xiiif-core)
(require 'xiiif-image)
(require 'xiiif-cache)

(defun xiiif-org--require ()
  "Make sure Org is loaded before inserting."
  (unless (featurep 'org)
    (require 'org)))

(defun xiiif-org--emit (text)
  "Insert TEXT at point if the current buffer is writable.
Otherwise put TEXT on the kill-ring and notify the user; this lets
the org-insert commands be bound inside read-only xiiif buffers."
  (if buffer-read-only
      (progn
        (kill-new text)
        (message "xiiif: copied to kill ring (buffer is read-only)"))
    (insert text)))

(defun xiiif-org--link (target description)
  "Return a formatted Org link to TARGET with DESCRIPTION."
  (format "[[%s][%s]]" target (or description target)))

(defun xiiif-org-manifest-link (manifest)
  "Return an Org link string for MANIFEST."
  (xiiif-org--link (or (xiiif-manifest-url manifest)
                       (xiiif-manifest-id manifest))
                   (xiiif-manifest-title manifest)))

(defun xiiif-org-canvas-link (manifest canvas)
  "Return an Org link string for CANVAS in MANIFEST.
The link target is the canvas ID if available, otherwise the manifest URL."
  (xiiif-org--link (or (xiiif-canvas-id canvas)
                       (xiiif-manifest-url manifest))
                   (xiiif-canvas-title canvas)))

(defun xiiif-org-image-link (canvas &optional description)
  "Return an Org link string for the default image derivative of CANVAS."
  (let ((url (xiiif-image-url canvas)))
    (when url
      (xiiif-org--link url (or description
                               (xiiif-canvas-title canvas))))))

(defun xiiif-org-metadata-block (manifest &optional canvas)
  "Return an Org metadata block for MANIFEST and optional CANVAS as a string."
  (let ((lines (list "#+begin_xiiif")))
    (push (format ":title: %s" (xiiif-manifest-title manifest)) lines)
    (when (xiiif-manifest-url manifest)
      (push (format ":manifest: %s" (xiiif-manifest-url manifest)) lines))
    (when canvas
      (push (format ":canvas-label: %s" (xiiif-canvas-title canvas)) lines)
      (when (xiiif-canvas-id canvas)
        (push (format ":canvas-id: %s" (xiiif-canvas-id canvas)) lines))
      (when-let ((img (xiiif-image-url canvas)))
        (push (format ":image: %s" img) lines)))
    (push ":notes:" lines)
    (push "#+end_xiiif" lines)
    (mapconcat #'identity (nreverse lines) "\n")))


;;;###autoload
(defun xiiif-org-insert-manifest (manifest)
  "Insert (or kill-ring-copy) an Org link for MANIFEST.
Inserts at point in a writable buffer; copies to the kill-ring when
the current buffer is read-only (e.g. inside a xiiif overview)."
  (xiiif-org--require)
  (xiiif-org--emit (xiiif-org-manifest-link manifest)))

;;;###autoload
(defun xiiif-org-insert-canvas (manifest canvas)
  "Insert (or kill-ring-copy) an Org link for CANVAS in MANIFEST."
  (xiiif-org--require)
  (xiiif-org--emit (xiiif-org-canvas-link manifest canvas)))

;;;###autoload
(defun xiiif-org-insert-image (canvas)
  "Insert (or kill-ring-copy) an Org link to the default image derivative of CANVAS."
  (xiiif-org--require)
  (let ((link (xiiif-org-image-link canvas)))
    (unless link (user-error "Canvas has no image service"))
    (xiiif-org--emit link)))

;;;###autoload
(defun xiiif-org-insert-metadata (manifest &optional canvas)
  "Insert (or kill-ring-copy) an Org metadata block for MANIFEST and CANVAS."
  (xiiif-org--require)
  (xiiif-org--emit (concat (xiiif-org-metadata-block manifest canvas) "\n")))


;;; ---------- org-capture integration ----------

;; These helpers are meant to be referenced from an `org-capture-templates'
;; entry; see README for a worked example.  They read from the package's
;; session state (`xiiif-current-manifest', `xiiif-current-canvas') so the
;; template resolves the right resource at capture time.

;;;###autoload
(defun xiiif-org-capture-headline (&optional manifest)
  "Return a headline string derived from MANIFEST (or the current one).
Signals a user-error when no manifest is loaded, so an org-capture
template never silently succeeds on empty state."
  (let ((m (or manifest xiiif-current-manifest)))
    (unless m
      (user-error "xiiif: no manifest loaded for org-capture"))
    (xiiif-manifest-title m)))

;;;###autoload
(defun xiiif-org-capture-body (&optional manifest canvas)
  "Return an Org capture body for MANIFEST and optional CANVAS.

The body contains:
- a manifest link on its own line,
- a canvas link when CANVAS (or `xiiif-current-canvas') is set,
- a `#+begin_xiiif' metadata block with a `:notes:' line.

Intended for use as `%(xiiif-org-capture-body)' inside an
`org-capture-templates' entry."
  (xiiif-org--require)
  (let* ((m (or manifest xiiif-current-manifest))
         (c (or canvas   xiiif-current-canvas)))
    (unless m
      (user-error "xiiif: no manifest loaded for org-capture"))
    (let ((lines (list (xiiif-org-manifest-link m))))
      (when c
        (push (xiiif-org-canvas-link m c) lines))
      (push "" lines)
      (push (xiiif-org-metadata-block m c) lines)
      (mapconcat #'identity (nreverse lines) "\n"))))

(provide 'xiiif-org)
;;; xiiif-org.el ends here
