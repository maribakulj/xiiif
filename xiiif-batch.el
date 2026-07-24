;;; xiiif-batch.el --- Batch / external-control surface for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A prompt-free surface an external process - the research agent via
;; `emacsclient --eval', a shell script - can drive without any
;; interactive UI (Spec D).  Four entry points cover the loop:
;;
;;   (xiiif-batch-open URL)        load and render a manifest, return
;;                                 a serialisable summary
;;   (xiiif-batch-goto ANCHOR)     navigate to an anchor or a Content
;;                                 State token/URL
;;   (xiiif-batch-current-view)    the anchor of the current view, or nil
;;   (xiiif-batch-annotate A T B)  store an anchored note, no prompts
;;
;; None of these read from the minibuffer; failures are signalled
;; (never a muted `user-error'), so `emacsclient -e' sees the error.
;; This is the pull direction only: the agent reads and writes the
;; view state.  No server or socket lives in xiiif; a real-time
;; "follow mode" would be built in user config.

;;; Code:

(require 'xiiif-core)
(require 'xiiif-errors)
(require 'xiiif-api)
(require 'xiiif-cache)
(require 'xiiif-ui)
(require 'xiiif-anchor)
(require 'xiiif-view)
(require 'xiiif-annot)

;;;###autoload
(defun xiiif-batch-open (url)
  "Load the IIIF manifest at URL synchronously and render it.
Returns a serialisable summary alist:
  (title . STRING) (url . STRING) (id . STRING)
  (canvases . INTEGER) (structures . BOOLEAN)
Signals a xiiif error when URL is not a manifest.

Example:
  emacsclient -e \\='(xiiif-batch-open \"https://example.org/iiif/m\")\\='"
  (xiiif-batch--summary (xiiif-batch--load-manifest url)))

(defun xiiif-batch--load-manifest (url)
  "Fetch and render the manifest at URL synchronously; return it.
Signals `xiiif-error' when the resource is not a manifest."
  (let ((json (xiiif-api-fetch-json url)))
    (pcase (xiiif-resource-kind json)
      ('manifest
       (let ((manifest (xiiif-parse-manifest json url)))
         (xiiif-cache-set-manifest manifest)
         (xiiif-cache-set-canvas nil)
         (xiiif-ui-render-manifest manifest)
         manifest))
      ('collection
       (signal 'xiiif-error
               (list url "resource is a collection, not a manifest")))
      (_ (signal 'xiiif-error
                 (list url "resource is neither a manifest nor a collection"))))))

(defun xiiif-batch--summary (manifest)
  "Return the serialisable summary alist for MANIFEST."
  (list (cons 'title      (xiiif-manifest-title manifest))
        (cons 'url        (xiiif-manifest-url manifest))
        (cons 'id         (xiiif-manifest-id manifest))
        (cons 'canvases   (xiiif-manifest-canvas-count manifest))
        (cons 'structures (and (xiiif-manifest-structures manifest) t))))

(defun xiiif-batch--resolve-anchor (anchor)
  "Return ANCHOR as an anchor plist, parsing a Content State string.
Signals `xiiif-error' when ANCHOR is neither."
  (cond
   ((stringp anchor) (xiiif-content-state-parse anchor))
   ((xiiif-anchor-p anchor) anchor)
   (t (signal 'xiiif-error
              (list "not an anchor or Content State token" anchor)))))

;;;###autoload
(defun xiiif-batch-goto (anchor)
  "Navigate to ANCHOR and return the resolved anchor plist.
ANCHOR is a canonical anchor plist (see `xiiif-anchor-create') or a
Content State URL/token string.  The manifest is loaded
synchronously when it is not the current one; the region viewer
opens on a region anchor when the display is graphic, otherwise the
canvas detail buffer does.

Example:
  emacsclient -e \\='(xiiif-batch-goto \"https://mirador/?iiif-content=...\")\\='"
  (let* ((anchor (xiiif-batch--resolve-anchor anchor))
         (manifest-url (xiiif-anchor-manifest anchor))
         (canvas-id    (xiiif-anchor-canvas anchor))
         (region       (xiiif-anchor-region anchor)))
    (unless manifest-url
      (signal 'xiiif-error (list "anchor has no manifest URL" anchor)))
    (let* ((manifest
            (if (and xiiif-current-manifest
                     (equal (xiiif-manifest-url xiiif-current-manifest)
                            manifest-url))
                xiiif-current-manifest
              (xiiif-batch--load-manifest manifest-url)))
           (canvas (and canvas-id
                        (xiiif-manifest-find-canvas manifest canvas-id)))
           (service (and canvas (xiiif-canvas-image-service canvas))))
      (cond
       ((and canvas region service (display-graphic-p))
        (xiiif-cache-set-canvas canvas)
        (xiiif-view-load-canvas manifest-url canvas-id service region))
       (canvas
        (xiiif-cache-set-canvas canvas)
        (xiiif-ui-render-canvas canvas))
       (t (xiiif-ui-render-manifest manifest))))
    anchor))

;;;###autoload
(defun xiiif-batch-current-view ()
  "Return the canonical anchor of the current view, or nil.
Prefers the region viewer's exact view, then the current canvas,
then the current manifest.

Example:
  emacsclient -e \\='(xiiif-batch-current-view)\\='"
  (let ((view-buffer (get-buffer xiiif-view--buffer)))
    (cond
     ((and view-buffer
           (buffer-local-value 'xiiif-view--state view-buffer))
      (xiiif-view-state-to-anchor
       (buffer-local-value 'xiiif-view--state view-buffer)))
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
     (t nil))))

;;;###autoload
(defun xiiif-batch-annotate (anchor title body)
  "Store an anchored note for ANCHOR with TITLE and BODY, no prompts.
ANCHOR is an anchor plist or a Content State token/URL; TITLE must
be non-blank.  Delegates to `xiiif-annot-backend-function' and
returns the resolved anchor.  Signals a xiiif error on a blank
title.

Example:
  emacsclient -e \\='(xiiif-batch-annotate
                     (xiiif-batch-current-view) \"Lettrine\" \"note body\")\\='"
  (let ((anchor (xiiif-batch--resolve-anchor anchor)))
    (when (or (null title) (string-blank-p title))
      (signal 'xiiif-error (list "annotation needs a non-blank title")))
    (funcall xiiif-annot-backend-function anchor title (or body ""))
    anchor))

(provide 'xiiif-batch)
;;; xiiif-batch.el ends here
