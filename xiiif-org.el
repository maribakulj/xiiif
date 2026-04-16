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
  "Insert an Org link for MANIFEST at point."
  (xiiif-org--require)
  (insert (xiiif-org-manifest-link manifest)))

;;;###autoload
(defun xiiif-org-insert-canvas (manifest canvas)
  "Insert an Org link for CANVAS in MANIFEST at point."
  (xiiif-org--require)
  (insert (xiiif-org-canvas-link manifest canvas)))

;;;###autoload
(defun xiiif-org-insert-image (canvas)
  "Insert an Org link to the default image derivative of CANVAS at point."
  (xiiif-org--require)
  (let ((link (xiiif-org-image-link canvas)))
    (unless link (user-error "Canvas has no image service"))
    (insert link)))

;;;###autoload
(defun xiiif-org-insert-metadata (manifest &optional canvas)
  "Insert an Org metadata block for MANIFEST (and optional CANVAS) at point."
  (xiiif-org--require)
  (insert (xiiif-org-metadata-block manifest canvas) "\n"))

(provide 'xiiif-org)
;;; xiiif-org.el ends here
