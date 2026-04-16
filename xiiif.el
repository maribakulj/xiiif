;;; xiiif.el --- IIIF workbench for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Maintainer: The xiiif authors
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Homepage: https://github.com/maribakulj/xiiif
;; Keywords: hypermedia, multimedia, iiif, digital-humanities
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; xiiif is an Emacs-native workbench for the IIIF APIs, aimed at
;; GLAM, cultural heritage, research and digital-humanities users
;; who live in Emacs.  It is deliberately text-first and
;; scriptable: there is no embedded image viewer.  You open a IIIF
;; Presentation Manifest, inspect it in readable buffers, browse
;; its canvases, generate IIIF Image API URLs, download
;; derivatives, and drop links and metadata into Org.
;;
;; Entry points:
;;
;;   M-x xiiif-open-manifest      open a manifest URL
;;   M-x xiiif-browse-canvases    browse the current manifest
;;   M-x xiiif-open-canvas        open the canvas at point
;;   M-x xiiif-copy-image-url     copy a derivative URL
;;   M-x xiiif-download-image     download a derivative image
;;   M-x xiiif-insert-org-link    insert a link into Org
;;
;; Auxiliary commands:
;;
;;   M-x xiiif-show-raw-json      inspect the underlying JSON
;;   M-x xiiif-refresh            re-fetch the current manifest
;;   M-x xiiif-open-recent        pick from recently opened manifests

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'xiiif-api)
(require 'xiiif-core)
(require 'xiiif-cache)
(require 'xiiif-image)
(require 'xiiif-ui)
(require 'xiiif-org)

(defgroup xiiif nil
  "Emacs-native IIIF workbench."
  :group 'external
  :prefix "xiiif-"
  :link '(url-link "https://github.com/maribakulj/xiiif"))

(defconst xiiif-version "0.1.0"
  "Current version of the xiiif package.")


;;; ---------- helpers that resolve "what does the user mean now?" ----------

(defun xiiif--require-manifest ()
  "Return the current manifest or signal a helpful user-error."
  (or xiiif-current-manifest
      (user-error "No IIIF manifest loaded; run `xiiif-open-manifest' first")))

(defun xiiif--canvas-in-context ()
  "Return a canvas appropriate to the current buffer.
Falls back to `xiiif-current-canvas' when no buffer context applies."
  (cond
   ((and (derived-mode-p 'xiiif-canvas-list-mode)
         (tabulated-list-get-id)))
   ((and (derived-mode-p 'xiiif-canvas-mode)
         (bound-and-true-p xiiif-ui--canvas)))
   (t xiiif-current-canvas)))

(defun xiiif--require-canvas ()
  "Return a canvas or signal a helpful user-error."
  (or (xiiif--canvas-in-context)
      (user-error "No canvas selected; open one with `xiiif-open-canvas'")))

(defun xiiif--fetch-and-parse (url)
  "Fetch URL and return a parsed `xiiif-manifest'."
  (let ((json (xiiif-api-fetch-json url)))
    (xiiif-parse-manifest json url)))


;;; ---------- user-facing commands ----------

;;;###autoload
(defun xiiif-open-manifest (url)
  "Fetch the IIIF Manifest at URL and display its overview buffer."
  (interactive
   (list (read-string "IIIF Manifest URL: "
                      (car xiiif-recent-manifests))))
  (message "Fetching %s..." url)
  (condition-case err
      (let ((manifest (xiiif--fetch-and-parse url)))
        (xiiif-cache-set-manifest manifest)
        (xiiif-cache-set-canvas nil)
        (xiiif-ui-render-manifest manifest)
        (message "Loaded %s (%d canvas%s)"
                 (xiiif-manifest-title manifest)
                 (length (xiiif-manifest-canvases manifest))
                 (if (= 1 (length (xiiif-manifest-canvases manifest))) "" "es")))
    (xiiif-network-error
     (user-error "Network error for %s: %s"
                 (nth 1 err) (or (nth 2 err) "unknown")))
    (xiiif-http-error
     (user-error "HTTP %s for %s" (nth 2 err) (nth 1 err)))
    (xiiif-parse-error
     (user-error "Could not parse %s: %s"
                 (nth 1 err) (or (nth 2 err) "unknown")))))

;;;###autoload
(defun xiiif-browse-canvases ()
  "Browse the canvases of the current manifest."
  (interactive)
  (xiiif-ui-render-canvases (xiiif--require-manifest)))

;;;###autoload
(defun xiiif-open-canvas (&optional canvas)
  "Open CANVAS (default: canvas at point or current canvas) in a detail buffer."
  (interactive)
  (let ((target (or canvas (xiiif--require-canvas))))
    (xiiif-cache-set-canvas target)
    (xiiif-ui-render-canvas target)))

;;;###autoload
(defun xiiif-copy-image-url (&optional with-options)
  "Copy an IIIF Image API URL for the contextual canvas.

With a prefix argument WITH-OPTIONS, prompt for region, size, rotation,
quality and format instead of using defaults."
  (interactive "P")
  (let* ((canvas (xiiif--require-canvas))
         (url (if with-options
                  (xiiif-image-url
                   canvas
                   :region   (read-string "Region: "
                                          xiiif-image-default-region)
                   :size     (read-string "Size: "
                                          xiiif-image-default-size)
                   :rotation (read-string "Rotation: "
                                          xiiif-image-default-rotation)
                   :quality  (read-string "Quality: "
                                          xiiif-image-default-quality)
                   :format   (read-string "Format: "
                                          xiiif-image-default-format))
                (xiiif-image-url canvas))))
    (unless url (user-error "Canvas has no image service"))
    (kill-new url)
    (message "Copied %s" url)))

;;;###autoload
(defun xiiif-download-image ()
  "Download an IIIF Image API derivative of the contextual canvas."
  (interactive)
  (xiiif-ui-download-canvas-image (xiiif--require-canvas)))

;;;###autoload
(defun xiiif-copy-manifest-url ()
  "Copy the URL of the current manifest to the kill ring."
  (interactive)
  (let ((url (xiiif-manifest-url (xiiif--require-manifest))))
    (unless url (user-error "Current manifest has no URL"))
    (kill-new url)
    (message "Copied %s" url)))

;;;###autoload
(defun xiiif-insert-org-link (&optional kind)
  "Insert an Org link for the current xiiif context at point.

KIND is one of `manifest', `canvas', `image' or `metadata'; when
called interactively, the user is prompted."
  (interactive
   (list (intern (completing-read
                  "Insert: "
                  '("manifest" "canvas" "image" "metadata")
                  nil t nil nil "manifest"))))
  (let ((manifest (xiiif--require-manifest))
        (canvas   (xiiif--canvas-in-context)))
    (pcase kind
      ('manifest (xiiif-org-insert-manifest manifest))
      ('canvas
       (unless canvas (user-error "No canvas in context"))
       (xiiif-org-insert-canvas manifest canvas))
      ('image
       (unless canvas (user-error "No canvas in context"))
       (xiiif-org-insert-image canvas))
      ('metadata (xiiif-org-insert-metadata manifest canvas))
      (_ (user-error "Unknown insert kind: %s" kind)))))

;;;###autoload
(defun xiiif-show-raw-json ()
  "Show the raw JSON of the current context (manifest or canvas)."
  (interactive)
  (cond
   ((derived-mode-p 'xiiif-canvas-mode)
    (xiiif-ui-show-json (xiiif-canvas-raw xiiif-ui--canvas)
                        (xiiif-canvas-title xiiif-ui--canvas)))
   ((and (derived-mode-p 'xiiif-canvas-list-mode)
         (tabulated-list-get-id))
    (let ((c (tabulated-list-get-id)))
      (xiiif-ui-show-json (xiiif-canvas-raw c) (xiiif-canvas-title c))))
   (t
    (let ((m (xiiif--require-manifest)))
      (xiiif-ui-show-json (xiiif-manifest-raw m) (xiiif-manifest-title m))))))

;;;###autoload
(defun xiiif-refresh ()
  "Re-fetch the current manifest and redisplay the active buffer."
  (interactive)
  (let* ((m (xiiif--require-manifest))
         (url (xiiif-manifest-url m)))
    (unless url (user-error "Current manifest has no URL to refresh"))
    (let ((fresh (xiiif--fetch-and-parse url)))
      (xiiif-cache-set-manifest fresh)
      (cond
       ((derived-mode-p 'xiiif-canvas-list-mode)
        (xiiif-ui-render-canvases fresh))
       ((derived-mode-p 'xiiif-canvas-mode)
        ;; Re-resolve by ID when possible.
        (let* ((id (and xiiif-ui--canvas (xiiif-canvas-id xiiif-ui--canvas)))
               (match (and id (cl-find id (xiiif-manifest-canvases fresh)
                                       :key #'xiiif-canvas-id :test #'equal))))
          (if match
              (progn (xiiif-cache-set-canvas match)
                     (xiiif-ui-render-canvas match))
            (xiiif-ui-render-manifest fresh))))
       (t (xiiif-ui-render-manifest fresh)))
      (message "Refreshed %s" (xiiif-manifest-title fresh)))))

;;;###autoload
(defun xiiif-open-recent ()
  "Pick a recently opened manifest URL and open it."
  (interactive)
  (xiiif-cache-load)
  (unless xiiif-recent-manifests
    (user-error "No recent IIIF manifests"))
  (let ((url (completing-read "Recent manifest: "
                              xiiif-recent-manifests nil t)))
    (xiiif-open-manifest url)))

;; Load the persisted history (if any) eagerly so
;; `xiiif-open-manifest' can default to the last URL.
(xiiif-cache-load)

(provide 'xiiif)
;;; xiiif.el ends here
