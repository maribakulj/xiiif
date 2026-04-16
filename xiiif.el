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
  "Fetch URL synchronously and return a parsed `xiiif-manifest'.
Kept as an escape hatch for scripting; interactive commands use
the asynchronous path via `xiiif--load-manifest-async'."
  (let ((json (xiiif-api-fetch-json url)))
    (xiiif-parse-manifest json url)))

(defun xiiif--load-manifest-async (url on-manifest)
  "Fetch URL asynchronously and call ON-MANIFEST with a `xiiif-manifest'.
Errors are reported via `message' and do not call ON-MANIFEST."
  (message "xiiif: fetching %s..." url)
  (xiiif-api-fetch-json-async
   url
   (lambda (json)
     (condition-case err
         (funcall on-manifest (xiiif-parse-manifest json url))
       (xiiif-parse-error
        (message "xiiif: %s is not a IIIF manifest (%s)"
                 url (or (nth 2 err) "parse error")))
       (error
        (message "xiiif: failed to render %s: %s"
                 url (error-message-string err)))))
   (lambda (err)
     (pcase-let* ((`(,sym ,u . ,rest) err))
       (pcase sym
         ('xiiif-http-error
          (message "xiiif: HTTP %s for %s" (car rest) u))
         (_
          (message "xiiif: %s for %s%s"
                   sym u
                   (if rest (format ": %s" (car rest)) ""))))))))


;;; ---------- user-facing commands ----------

;;;###autoload
(defun xiiif-open-manifest (url)
  "Fetch the IIIF Manifest at URL asynchronously and show the overview buffer."
  (interactive
   (list (read-string "IIIF Manifest URL: "
                      (car xiiif-recent-manifests))))
  (xiiif--load-manifest-async
   url
   (lambda (manifest)
     (xiiif-cache-set-manifest manifest)
     (xiiif-cache-set-canvas nil)
     (xiiif-ui-render-manifest manifest)
     (let ((n (length (xiiif-manifest-canvases manifest))))
       (message "xiiif: loaded %s (%d canvas%s)"
                (xiiif-manifest-title manifest)
                n (if (= 1 n) "" "es"))))))

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
  "Re-fetch the current manifest asynchronously and redisplay.
Remembers the pre-refresh buffer mode and, when refreshing from the
canvas detail buffer, re-resolves the canvas by id in the fresh data."
  (interactive)
  (let* ((m (xiiif--require-manifest))
         (url (xiiif-manifest-url m))
         (mode major-mode)
         (canvas-id (and (derived-mode-p 'xiiif-canvas-mode)
                         xiiif-ui--canvas
                         (xiiif-canvas-id xiiif-ui--canvas))))
    (unless url (user-error "Current manifest has no URL to refresh"))
    (xiiif--load-manifest-async
     url
     (lambda (fresh)
       (xiiif-cache-set-manifest fresh)
       (cond
        ((eq mode 'xiiif-canvas-list-mode)
         (xiiif-ui-render-canvases fresh))
        ((eq mode 'xiiif-canvas-mode)
         (let ((match (and canvas-id
                           (cl-find canvas-id (xiiif-manifest-canvases fresh)
                                    :key #'xiiif-canvas-id :test #'equal))))
           (if match
               (progn (xiiif-cache-set-canvas match)
                      (xiiif-ui-render-canvas match))
             (xiiif-ui-render-manifest fresh))))
        (t (xiiif-ui-render-manifest fresh)))
       (message "xiiif: refreshed %s" (xiiif-manifest-title fresh))))))

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
