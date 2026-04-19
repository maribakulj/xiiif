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
;;   M-x xiiif-show-info-json     inspect the Image API info.json
;;   M-x xiiif-refresh            re-fetch the current manifest
;;   M-x xiiif-open-recent        pick from recently opened manifests
;;   M-x xiiif-retry-last         re-issue the last failed fetch

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'xiiif-profiles)
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

(defun xiiif--load-resource-async (url on-manifest on-collection)
  "Fetch URL asynchronously and dispatch to ON-MANIFEST or ON-COLLECTION.
The right callback is chosen by `xiiif-resource-kind'.  If JSON is
neither a Manifest nor a Collection, a message is shown and no
callback is invoked.  Errors are reported via `message'."
  (message "xiiif: fetching %s..." url)
  (xiiif-api-fetch-json-async
   url
   (lambda (json)
     (condition-case err
         (pcase (xiiif-resource-kind json)
           ('manifest   (funcall on-manifest
                                 (xiiif-parse-manifest json url)))
           ('collection (funcall on-collection
                                 (xiiif-parse-collection json url)))
           (_ (message "xiiif: %s is neither a Manifest nor a Collection"
                       url)))
       (xiiif-parse-error
        (message "xiiif: could not parse %s (%s)"
                 url (or (nth 2 err) "parse error")))
       (error
        (message "xiiif: failed to render %s: %s"
                 url (error-message-string err)))))))


;;; ---------- user-facing commands ----------

;;;###autoload
(defun xiiif-open-manifest (url)
  "Fetch the IIIF resource at URL asynchronously and show its primary buffer.

Despite the name (kept for back-compat), this command auto-detects
whether URL points at a Manifest or a Collection and dispatches to
the appropriate buffer."
  (interactive
   (list (read-string "IIIF Manifest or Collection URL: "
                      (car xiiif-recent-manifests))))
  (xiiif--load-resource-async
   url
   (lambda (manifest)
     (xiiif-cache-set-manifest manifest)
     (xiiif-cache-set-canvas nil)
     (xiiif-ui-render-manifest manifest)
     (let ((n (length (xiiif-manifest-canvases manifest))))
       (message "xiiif: loaded %s (%d canvas%s)"
                (xiiif-manifest-title manifest)
                n (if (= 1 n) "" "es"))))
   (lambda (collection)
     (xiiif-cache-set-collection collection)
     (xiiif-ui-render-collection collection)
     (let ((n (length (xiiif-collection-children collection))))
       (message "xiiif: loaded collection %s (%d item%s)"
                (xiiif-collection-title collection)
                n (if (= 1 n) "" "s"))))))

;;;###autoload
(defalias 'xiiif-open #'xiiif-open-manifest
  "Alias for `xiiif-open-manifest', whose name predates Collection support.")

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
(defun xiiif-show-info-json (&optional target)
  "Fetch and display the Image API info.json for TARGET.
TARGET may be a URL string, a `xiiif-image-service', a `xiiif-canvas',
or nil to use the contextual canvas."
  (interactive)
  (let ((service (or target (xiiif--require-canvas))))
    (message "xiiif: fetching info.json...")
    (xiiif-image-fetch-info-async
     service
     (lambda (info)
       (xiiif-ui-render-info info)
       (message "xiiif: loaded info.json for %s"
                (or (xiiif-image-info-id info) "image service"))))))

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
  "Show the raw JSON of the current xiiif context.
Picks canvas, manifest, collection item or collection automatically
based on the active buffer."
  (interactive)
  (cond
   ((derived-mode-p 'xiiif-canvas-mode)
    (xiiif-ui-show-json (xiiif-canvas-raw xiiif-ui--canvas)
                        (xiiif-canvas-title xiiif-ui--canvas)))
   ((and (derived-mode-p 'xiiif-canvas-list-mode)
         (tabulated-list-get-id))
    (let ((c (tabulated-list-get-id)))
      (xiiif-ui-show-json (xiiif-canvas-raw c) (xiiif-canvas-title c))))
   ((derived-mode-p 'xiiif-collection-mode)
    (let ((c (or (tabulated-list-get-id) xiiif-ui--collection)))
      (cond
       ((xiiif-collection-item-p c)
        (xiiif-ui-show-json
         `((id . ,(xiiif-collection-item-id c))
           (type . ,(xiiif-collection-item-type c))
           (label . ,(xiiif-collection-item-label c)))
         (xiiif-collection-item-title c)))
       ((xiiif-collection-p c)
        (xiiif-ui-show-json (xiiif-collection-raw c)
                            (xiiif-collection-title c))))))
   (xiiif-current-manifest
    (xiiif-ui-show-json (xiiif-manifest-raw xiiif-current-manifest)
                        (xiiif-manifest-title xiiif-current-manifest)))
   (xiiif-current-collection
    (xiiif-ui-show-json (xiiif-collection-raw xiiif-current-collection)
                        (xiiif-collection-title xiiif-current-collection)))
   (t (user-error "No xiiif context to show JSON for"))))

(defun xiiif--refresh-source ()
  "Return (URL . MODE) for what `xiiif-refresh' should re-fetch.
URL is the source URL of the resource feeding the current buffer.
Signals `user-error' if there is nothing to refresh."
  (let ((mode major-mode))
    (cond
     ((eq mode 'xiiif-collection-mode)
      (cons (xiiif-collection-url
             (or xiiif-ui--collection
                 (or xiiif-current-collection
                     (user-error "No collection in this buffer to refresh"))))
            mode))
     ((or (memq mode '(xiiif-manifest-mode xiiif-canvas-list-mode xiiif-canvas-mode))
          xiiif-current-manifest)
      (cons (xiiif-manifest-url
             (or xiiif-current-manifest
                 (user-error "No manifest to refresh")))
            mode))
     (t (user-error "Nothing to refresh in this buffer")))))

;;;###autoload
(defun xiiif-refresh ()
  "Re-fetch the current resource asynchronously and redisplay.
Works for the manifest overview, the canvas browser, the canvas
detail buffer (re-resolved by id) and the collection browser."
  (interactive)
  (pcase-let* ((`(,url . ,mode) (xiiif--refresh-source))
               (canvas-id (and (eq mode 'xiiif-canvas-mode)
                               xiiif-ui--canvas
                               (xiiif-canvas-id xiiif-ui--canvas))))
    (unless url
      (user-error "Current resource has no URL to refresh"))
    (xiiif--load-resource-async
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
       (message "xiiif: refreshed %s" (xiiif-manifest-title fresh)))
     (lambda (fresh)
       (xiiif-cache-set-collection fresh)
       (xiiif-ui-render-collection fresh)
       (message "xiiif: refreshed %s" (xiiif-collection-title fresh))))))

;;;###autoload
(defun xiiif-open-recent ()
  "Pick a recently opened IIIF resource URL and open it."
  (interactive)
  (xiiif-cache-load)
  (unless xiiif-recent-manifests
    (user-error "No recent IIIF resources"))
  (let ((url (completing-read "Recent IIIF resource: "
                              xiiif-recent-manifests nil t)))
    (xiiif-open-manifest url)))

;;;###autoload
(defun xiiif-retry-last ()
  "Re-issue the most recent failed xiiif fetch.
Uses the URL stored in `xiiif-api-last-error'.  The error slot is
cleared before the retry, so a second failure is reported fresh."
  (interactive)
  (unless xiiif-api-last-error
    (user-error "No recent xiiif error to retry"))
  (let ((url (nth 1 xiiif-api-last-error)))
    (unless url
      (user-error "Last error has no URL to retry"))
    (setq xiiif-api-last-error nil)
    (xiiif-open-manifest url)))

;; Load the persisted history (if any) eagerly so
;; `xiiif-open-manifest' can default to the last URL.
(xiiif-cache-load)

(provide 'xiiif)
;;; xiiif.el ends here
