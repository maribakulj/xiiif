;;; xiiif-annot.el --- Anchored notes for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Turn the place you are looking at into a note in your vault
;; (Spec C3).  `xiiif-annot-create' builds the canonical anchor of
;; the current context - the region viewer's exact view, or the
;; canvas / manifest in a detail buffer - prompts for a title and
;; body, and hands it to `xiiif-annot-backend-function'.
;;
;; The package ships one backend, `xiiif-annot-org-store', which
;; appends an Org entry whose PROPERTIES drawer records the full
;; anchor (`:XIIIF_MANIFEST:', `:XIIIF_CANVAS:', `:XIIIF_REGION:',
;; `:XIIIF_CONTENT_STATE:'), followed by the manifest link, the
;; region's Image API link and a Content State URL.
;; `xiiif-annot-visit' reads that drawer back and reopens exactly the
;; view.  Personal backends (Denote, Markdown, an Obsidian vault)
;; live in user config; the package only provides the extension point
;; and the generic Org backend.  Org is loaded lazily.

;;; Code:

(require 'subr-x)
(require 'xiiif-core)
(require 'xiiif-region)
(require 'xiiif-anchor)
(require 'xiiif-image)
(require 'xiiif-cache)
(require 'xiiif-org)
(require 'xiiif-view)

(declare-function org-entry-get "org" (pom property &optional inherit literal-nil))
(declare-function xiiif--open-anchor "xiiif" (anchor))

(defcustom xiiif-annot-org-file
  (expand-file-name "xiiif/notes.org" user-emacs-directory)
  "Org file to which `xiiif-annot-org-store' appends anchored notes."
  :type 'file
  :group 'xiiif)

(defcustom xiiif-annot-backend-function #'xiiif-annot-org-store
  "Function storing an anchored note.
Called with (ANCHOR TITLE BODY): ANCHOR is a canonical anchor plist
\(see `xiiif-anchor-create'), TITLE and BODY are strings.  Replace it
to route notes to Denote, a Markdown vault, or any other target."
  :type 'function
  :group 'xiiif)


;;; ---------- context anchor ----------

(defun xiiif-annot--context-anchor ()
  "Return the canonical anchor of the current xiiif context.
The region viewer's exact view wins; otherwise the current canvas,
otherwise the current manifest.  Signals when nothing is loaded."
  (cond
   ((and (derived-mode-p 'xiiif-view-mode)
         (bound-and-true-p xiiif-view--state))
    (xiiif-view-state-to-anchor xiiif-view--state))
   (xiiif-current-canvas
    (xiiif-anchor-create
     :manifest (and xiiif-current-manifest
                    (or (xiiif-manifest-url xiiif-current-manifest)
                        (xiiif-manifest-id xiiif-current-manifest)))
     :canvas (xiiif-canvas-id xiiif-current-canvas)
     :label (xiiif-canvas-title xiiif-current-canvas)))
   (xiiif-current-manifest
    (xiiif-anchor-create
     :manifest (or (xiiif-manifest-url xiiif-current-manifest)
                   (xiiif-manifest-id xiiif-current-manifest))
     :label (xiiif-manifest-title xiiif-current-manifest)))
   (t (user-error "No xiiif context to anchor a note to"))))

(defun xiiif-annot--region-image-url (anchor)
  "Return the Image API URL for ANCHOR's region, or nil.
Resolvable only when ANCHOR's manifest is the current one, so the
canvas - and thus its image service - can be found."
  (when-let* ((manifest-url (xiiif-anchor-manifest anchor))
              (canvas-id (xiiif-anchor-canvas anchor))
              (m (and xiiif-current-manifest
                      (equal (xiiif-manifest-url xiiif-current-manifest)
                             manifest-url)
                      xiiif-current-manifest))
              (canvas (xiiif-manifest-find-canvas m canvas-id))
              (service (xiiif-canvas-image-service canvas)))
    (let ((region (xiiif-anchor-region anchor)))
      (xiiif-image-url service
                       :region (if region
                                   (xiiif-region-to-image-api region)
                                 "full")
                       :size "max"))))


;;; ---------- Org backend ----------

(defun xiiif-annot--org-entry (anchor title body)
  "Return the Org entry string for ANCHOR with TITLE and BODY."
  (let* ((manifest (xiiif-anchor-manifest anchor))
         (canvas   (xiiif-anchor-canvas anchor))
         (region   (xiiif-anchor-region anchor))
         (label    (or (xiiif-anchor-label anchor) title))
         (image    (xiiif-annot--region-image-url anchor))
         (content-state (xiiif-content-state-encode anchor))
         (lines nil))
    (push (format "* %s" title) lines)
    (push ":PROPERTIES:" lines)
    (when manifest
      (push (format ":XIIIF_MANIFEST: %s" manifest) lines))
    (when canvas
      (push (format ":XIIIF_CANVAS: %s" canvas) lines))
    (when region
      (push (format ":XIIIF_REGION: %s" (xiiif-region-to-string region)) lines))
    (push (format ":XIIIF_CONTENT_STATE: %s" content-state) lines)
    (push ":END:" lines)
    (when manifest
      (push (xiiif-org--link manifest label) lines))
    (when image
      (push (format "Region image: %s" (xiiif-org--link image "Image API")) lines))
    (push (format "Content State: %s"
                  (xiiif-content-state-url anchor))
          lines)
    (when (and body (not (string-blank-p body)))
      (push "" lines)
      (push (string-trim-right body) lines))
    (concat (mapconcat #'identity (nreverse lines) "\n") "\n")))

;;;###autoload
(defun xiiif-annot-org-store (anchor title body)
  "Append an Org entry for ANCHOR with TITLE and BODY to the notes file.
The target is `xiiif-annot-org-file'; its directory is created if
missing.  This is the default `xiiif-annot-backend-function'."
  (xiiif-org--require)
  (let* ((file (expand-file-name xiiif-annot-org-file))
         (dir (file-name-directory file)))
    (when (and dir (not (file-directory-p dir)))
      (make-directory dir t))
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (unless (or (bobp) (looking-back "\n\n" (max (point-min) (- (point) 2))))
        (insert "\n"))
      (insert (xiiif-annot--org-entry anchor title body))
      (save-buffer))
    (message "xiiif: note saved to %s" (abbreviate-file-name file))))


;;; ---------- create ----------

(defun xiiif-annot-create-for-anchor (anchor &optional title body)
  "Store a note for ANCHOR, prompting for TITLE and BODY when omitted.
Delegates to `xiiif-annot-backend-function'.  Wired into the viewer
as `xiiif-view-annotate-function'."
  (let ((title (or title
                   (read-string "Note title: "
                                (or (xiiif-anchor-label anchor) ""))))
        (body (or body (read-string "Note body (optional): "))))
    (when (string-blank-p title)
      (user-error "A note needs a title"))
    (funcall xiiif-annot-backend-function anchor title body)))

;;;###autoload
(defun xiiif-annot-create ()
  "Create an anchored note for the current xiiif context.
Available in the region viewer (also on `a') and in the canvas
detail buffer; builds the anchor, prompts for a title and body, and
delegates to `xiiif-annot-backend-function'."
  (interactive)
  (xiiif-annot-create-for-anchor (xiiif-annot--context-anchor)))

;;;###autoload
(defun xiiif-create-annotation (&optional anchor title body)
  "Create an anchored note, on ANCHOR when given, else on the context.

TITLE and BODY are prompted for when omitted.  This is the name
`SPEC_V1.md' §15 gives note creation; it takes its arguments so that
one name serves both the interactive command and calling code, where
`xiiif-annot-create' is the keymap-bound command and
`xiiif-annot-create-for-anchor' the anchor-taking one."
  (interactive)
  (xiiif-annot-create-for-anchor (or anchor (xiiif-annot--context-anchor))
                                 title body))


;;; ---------- visit ----------

(defun xiiif-annot--anchor-at-point ()
  "Return the anchor recorded in the Org entry at point, or nil."
  (require 'org)
  (let ((manifest (org-entry-get (point) "XIIIF_MANIFEST"))
        (canvas   (org-entry-get (point) "XIIIF_CANVAS"))
        (region   (org-entry-get (point) "XIIIF_REGION"))
        (state    (org-entry-get (point) "XIIIF_CONTENT_STATE")))
    (cond
     (manifest
      (xiiif-anchor-create
       :manifest manifest
       :canvas canvas
       :region (and region (xiiif-region-from-string region))))
     (state (xiiif-content-state-parse state)))))

;;;###autoload
(defun xiiif-annot-visit ()
  "Reopen the xiiif location recorded in the Org entry at point.
Reads the anchor from the PROPERTIES drawer and navigates to it -
the region viewer when a region is present, else the canvas detail."
  (interactive)
  (let ((anchor (xiiif-annot--anchor-at-point)))
    (unless anchor
      (user-error "No xiiif anchor in the Org entry at point"))
    (xiiif--open-anchor anchor)))


;; Wire the viewer's annotate key to the note-creation path unless the
;; user has already chosen their own.
(unless xiiif-view-annotate-function
  (setq xiiif-view-annotate-function #'xiiif-annot-create-for-anchor))

(provide 'xiiif-annot)
;;; xiiif-annot.el ends here
