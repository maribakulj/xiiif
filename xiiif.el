;;; xiiif.el --- IIIF workbench for Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Maintainer: The xiiif authors
;; Version: 0.4.0
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
;;   M-x xiiif-open-source        open from a named registered source
;;   M-x xiiif-browse-canvases    browse the current manifest
;;   M-x xiiif-open-canvas        open the canvas at point
;;   M-x xiiif-copy-image-url     copy a derivative URL
;;   M-x xiiif-download-image     download a derivative image
;;   M-x xiiif-download-marked    bulk-download marked canvases
;;   M-x xiiif-insert-org-link    insert a link into Org
;;
;; Auxiliary commands:
;;
;;   M-x xiiif-show-raw-json      inspect the underlying JSON
;;   M-x xiiif-show-info-json     inspect the Image API info.json
;;   M-x xiiif-show-annotations   inspect canvas annotations
;;   M-x xiiif-refresh            re-fetch the current manifest
;;   M-x xiiif-open-recent        pick from recently opened manifests
;;   M-x xiiif-retry-last         re-issue the last failed fetch
;;   M-x xiiif-export-citation    export a BibTeX or CSL-JSON citation

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(require 'xiiif-errors)
(require 'xiiif-url)
(require 'xiiif-profiles)
(require 'xiiif-http-cache)
(require 'xiiif-api)
(require 'xiiif-fetch)
(require 'xiiif-core)
(require 'xiiif-region)
(require 'xiiif-anchor)
(require 'xiiif-osd)
(require 'xiiif-view)
(require 'xiiif-cache)
(require 'xiiif-image)
(require 'xiiif-annotations)
(require 'xiiif-ocr)
(require 'xiiif-sources)
(require 'xiiif-ui)
(require 'xiiif-locus)
(require 'xiiif-review)
(require 'xiiif-org)
(require 'xiiif-annot)
(require 'xiiif-batch)
(require 'xiiif-cite)
(require 'xiiif-upgrade)
(require 'xiiif-search)

(defgroup xiiif nil
  "Emacs-native IIIF workbench."
  :group 'external
  :prefix "xiiif-"
  :link '(url-link "https://github.com/maribakulj/xiiif"))

(defconst xiiif-version "0.4.0"
  "Current version of the xiiif package.")


;;; ---------- public hooks (extensibility) ----------

(defcustom xiiif-after-load-manifest-hook nil
  "Abnormal hook run after a manifest is loaded by `xiiif-open-manifest'
or refreshed by `xiiif-refresh'.
Each function receives the `xiiif-manifest' struct as its single
argument.  Runs after the cache is updated and the overview buffer
is rendered."
  :type 'hook :group 'xiiif)

(defcustom xiiif-after-load-collection-hook nil
  "Abnormal hook run after a collection is loaded by `xiiif-open-manifest'.
Each function receives the `xiiif-collection' struct as its single
argument."
  :type 'hook :group 'xiiif)

(defcustom xiiif-after-render-canvas-hook nil
  "Abnormal hook run after the canvas detail buffer is rendered.
Each function runs inside the canvas buffer and receives the
`xiiif-canvas' struct as its single argument.  Useful for enriching
the view with a lightweight annotation, an extra section, or a
third-party link."
  :type 'hook :group 'xiiif)


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

(defun xiiif--load-resource-async (url on-manifest on-collection &optional on-canvas)
  "Fetch URL asynchronously and dispatch on what it turns out to be.
The right callback is chosen by `xiiif-resource-kind'.  ON-CANVAS is
optional: callers that only make sense for a Manifest or a Collection
omit it, and a Canvas then reports as unsupported rather than being
forced into the wrong buffer.  Errors are reported via `message'.
Goes through the `xiiif-fetch' scheduler; returns a request object
for `xiiif-fetch-cancel'."
  (message "xiiif: fetching %s..." url)
  (xiiif-fetch-json
   url
   (lambda (json)
     (condition-case err
         (pcase (xiiif-resource-kind json)
           ('manifest   (funcall on-manifest
                                 (xiiif-parse-manifest json url)))
           ('collection (funcall on-collection
                                 (xiiif-parse-collection json url)))
           ('canvas (if on-canvas
                        (funcall on-canvas (xiiif-parse-canvas json))
                      (message "xiiif: %s is a Canvas; this command needs a Manifest"
                               url)))
           (_ (message "xiiif: %s is not a Manifest, Collection or Canvas"
                       url)))
       (xiiif-parse-error
        (message "xiiif: could not parse %s (%s)"
                 url (or (nth 2 err) "parse error")))
       (error
        (message "xiiif: failed to render %s: %s"
                 url (error-message-string err)))))))

(defvar-local xiiif--inflight nil
  "Cancellable handle of the in-flight request tied to this buffer, or nil.
A `xiiif-fetch' request object (or a raw transport handle).
Populated by `xiiif-refresh' so a subsequent refresh can cancel the
previous request.")

(defun xiiif--cancel-inflight ()
  "Cancel the request tracked by `xiiif--inflight' in the current buffer."
  (when xiiif--inflight
    (xiiif-fetch-cancel xiiif--inflight)
    (setq xiiif--inflight nil)))


;;; ---------- user-facing commands ----------

;;;###autoload
(defun xiiif-open-manifest (url)
  "Fetch the IIIF resource at URL asynchronously and show its primary buffer.

Despite the name (kept for back-compat), this command auto-detects
whether URL points at a Manifest, a Collection or a standalone
Canvas, and dispatches to the appropriate buffer.  `xiiif-open' is
the wider entry point: it takes Content State tokens too."
  (interactive
   (list (read-string "IIIF Manifest, Collection or Canvas URL: "
                      (car xiiif-recent-manifests))))
  (xiiif--load-resource-async
   url
   (lambda (manifest)
     (xiiif-cache-set-manifest manifest)
     (xiiif-cache-set-canvas nil)
     (xiiif-ui-render-manifest manifest)
     (run-hook-with-args 'xiiif-after-load-manifest-hook manifest)
     (let ((n (xiiif-manifest-canvas-count manifest)))
       (message "xiiif: loaded %s (%d canvas%s)"
                (xiiif-manifest-title manifest)
                n (if (= 1 n) "" "es"))))
   (lambda (collection)
     (xiiif-cache-set-collection collection)
     (xiiif-ui-render-collection collection)
     (run-hook-with-args 'xiiif-after-load-collection-hook collection)
     (let ((n (length (xiiif-collection-children collection))))
       (message "xiiif: loaded collection %s (%d item%s)"
                (xiiif-collection-title collection)
                n (if (= 1 n) "" "s"))))
   (lambda (canvas)
     (xiiif-cache-set-canvas canvas)
     (xiiif-ui-render-canvas canvas)
     (message "xiiif: loaded canvas %s"
              (or (xiiif-label-string (xiiif-canvas-label canvas)) "")))))

;;;###autoload
(defun xiiif-open-target-kind (target)
  "Return `content-state' or `resource' for TARGET, or nil when neither.
Classification is on the shape of the string, before any network
call: a Content State is self-describing, so recognising it costs
nothing, while telling a Manifest URL from a Canvas URL is not
possible without fetching - `xiiif--load-resource-async' settles
that half once the JSON is in hand."
  (when (stringp target)
    (let ((trimmed (string-trim target)))
      (cond
       ((string-blank-p trimmed) nil)
       ;; Raw Content State JSON, or a viewer URL carrying one.
       ((string-prefix-p "{" trimmed) 'content-state)
       ((string-match-p "[?&]iiif-content=" trimmed) 'content-state)
       ((xiiif-url-allowed-p trimmed) 'resource)
       ;; Anything left that is not a URL at all: try it as a bare
       ;; base64url token rather than refusing outright.
       ((not (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*:" trimmed))
        'content-state)))))

;;;###autoload
(defun xiiif-open (target)
  "Open TARGET, whatever kind of IIIF reference it is.

TARGET may be the URL of a Manifest, a Collection or a Canvas, a
IIIF Content State token, a viewer URL carrying `iiif-content=', or
raw Content State JSON.  This is the single entry point of
`SPEC_V1.md' §15; the narrower commands remain available when the
kind is already known."
  (interactive
   (list (read-string "IIIF URL, Content State or token: "
                      (car xiiif-recent-manifests))))
  (pcase (xiiif-open-target-kind target)
    ('content-state (xiiif-open-content-state target))
    ('resource      (xiiif-open-manifest target))
    ;; Only a string carrying a scheme reaches here, so the URL policy
    ;; has a reason and it is the actionable half of the message.
    (_ (let ((trimmed (and (stringp target) (string-trim target))))
         (if (and trimmed (not (string-blank-p trimmed)))
             (user-error "Cannot open %s: %s" trimmed
                         (xiiif-url-refusal-message
                          (xiiif-url-refusal trimmed)))
           (user-error "Nothing to open"))))))

;;;###autoload
(defun xiiif-open-source ()
  "Pick a registered IIIF source and open a manifest by identifier.
Sources live in `xiiif-sources'; each entry declares an identifier
prompt and a URL template.  The built URL is handed off to
`xiiif-open-manifest', which auto-detects Manifest vs Collection."
  (interactive)
  (unless xiiif-sources
    (user-error "`xiiif-sources' is empty; add entries with `customize'"))
  (let* ((source (xiiif-sources-read))
         (prompt (or (plist-get source :prompt) "Identifier: "))
         (id     (read-string prompt)))
    (when (string-blank-p id)
      (user-error "No identifier entered"))
    (xiiif-open-manifest
     (xiiif-source-build-manifest-url source id))))

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
(defun xiiif-view-canvas (&optional canvas)
  "Open the step-by-step region viewer on CANVAS.
CANVAS defaults to the canvas at point or the current canvas.  Off a
graphic display, or when the canvas exposes no Image API service,
falls back to the canvas detail buffer."
  (interactive)
  (let* ((canvas (or canvas (xiiif--require-canvas)))
         (service (xiiif-canvas-image-service canvas)))
    (cond
     ((not service)
      (xiiif-open-canvas canvas)
      (message "xiiif: canvas has no Image API service; opened detail view"))
     ((not (display-graphic-p))
      (xiiif-open-canvas canvas)
      (message "xiiif: no graphic display; opened canvas detail"))
     (t
      (xiiif-view-load-canvas
       (and xiiif-current-manifest (xiiif-manifest-url xiiif-current-manifest))
       (xiiif-canvas-id canvas) service)))))

;;;###autoload
(defun xiiif-select-region (&optional spec canvas)
  "Focus a region of CANVAS given numerically as X,Y,W,H or X,Y,W,H%.

SPEC is prompted for when omitted; CANVAS defaults to the contextual
one.  In the region viewer this moves the view; elsewhere it opens
the viewer already focused there.

Off a graphic display, or on a canvas with no Image API service, the
region's Image API URL goes to the kill ring instead - a region you
cannot see is still a region you can cite, and `SPEC_V1.md' §23 asks
that the rendered image never be the only way to reach one."
  (interactive)
  (if (derived-mode-p 'xiiif-view-mode)
      (call-interactively #'xiiif-view-select-region)
    (let* ((canvas (or canvas (xiiif--require-canvas)))
           (spec (or spec (read-string "Region X,Y,W,H[%]: ")))
           (region (xiiif-region-from-string spec)))
      (unless region
        (user-error "Not a region: %s (expected X,Y,W,H or X,Y,W,H%%)" spec))
      (unless (xiiif-region-valid-p region)
        (user-error "Region %s has a non-positive or out-of-canvas extent"
                    (xiiif-region-to-string region)))
      (let ((service (xiiif-canvas-image-service canvas)))
        (if (and service (display-graphic-p))
            (xiiif-view-load-canvas
             (and xiiif-current-manifest
                  (xiiif-manifest-url xiiif-current-manifest))
             (xiiif-canvas-id canvas) service region)
          (let ((url (xiiif-image-url
                      canvas :region (xiiif-region-to-image-api region))))
            (unless url
              (user-error "Canvas has no image service and no display"))
            (kill-new url)
            (message "xiiif: region %s copied as %s"
                     (xiiif-region-to-string region) url)))))))

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
(defun xiiif-download-marked (directory &optional size format)
  "Download every marked canvas in the canvas browser to DIRECTORY.

SIZE and FORMAT override the defaults from `xiiif-image-default-size'
and `xiiif-image-default-format'.  Files are named
\"<INDEX>-<SLUG>.<FORMAT>\" where SLUG is derived from the canvas
label.  Canvases without an image service are skipped silently.

Downloads run asynchronously one at a time so Emacs stays responsive;
a progress reporter advances as each file arrives."
  (interactive
   (progn
     (unless (derived-mode-p 'xiiif-canvas-list-mode)
       (user-error "Run this from the canvas browser"))
     (list (read-directory-name "Download marked to: "
                                xiiif-image-download-directory)
           (read-string (format "Size (default %s): "
                                xiiif-image-default-size)
                        nil nil xiiif-image-default-size)
           (read-string (format "Format (default %s): "
                                xiiif-image-default-format)
                        nil nil xiiif-image-default-format))))
  (let ((marked (xiiif-ui--marked-canvases)))
    (unless marked
      (user-error "No canvases marked (press m or t on rows first)"))
    (let ((dir (expand-file-name directory)))
      (unless (file-directory-p dir) (make-directory dir t))
      (xiiif--download-queue-run marked dir size format))))

(defun xiiif--download-queue-run (canvases dir size format)
  "Download CANVASES to DIR asynchronously, one at a time.
SIZE and FORMAT are forwarded to `xiiif-image-download-async'.
Canvases without an image service are counted as skipped."
  (let* ((total    (length canvases))
         (progress (make-progress-reporter
                    (format "xiiif: downloading %d canvas%s"
                            total (if (= 1 total) "" "es"))
                    0 total))
         (state    (list :saved 0 :skipped 0 :index 0)))
    (cl-labels
        ((finish ()
           (progress-reporter-done progress)
           (let ((saved   (plist-get state :saved))
                 (skipped (plist-get state :skipped)))
             (message "xiiif: saved %d canvas%s to %s%s"
                      saved (if (= 1 saved) "" "es") dir
                      (if (> skipped 0)
                          (format " (%d skipped)" skipped) ""))))
         (advance ()
           (let ((i (plist-get state :index)))
             (progress-reporter-update progress i)
             (if (>= i total)
                 (finish)
               (step))))
         (bump (key)
           (plist-put state key (1+ (plist-get state key))))
         (step ()
           (let* ((i (plist-get state :index))
                  (canvas (nth i canvases)))
             (plist-put state :index (1+ i))
             (if (not (xiiif-canvas-image-service canvas))
                 (progn (bump :skipped) (advance))
               (let ((dest (expand-file-name
                            (format "%03d-%s.%s"
                                    (1+ i)
                                    (xiiif-canvas-filesystem-slug canvas)
                                    format)
                            dir)))
                 (xiiif-image-download-async
                  canvas dest
                  (lambda (_path)
                    (bump :saved) (advance))
                  :errback
                  (lambda (err)
                    (message "xiiif: skipped %s (%s)"
                             (xiiif-canvas-title canvas)
                             (xiiif-api-error-hint err))
                    (bump :skipped) (advance))
                  :size size :format format))))))
      (if (zerop total) (finish) (step)))))

;;;###autoload
(defun xiiif-show-ocr (&optional canvas ref)
  "Fetch and display an OCR/ALTO/hOCR sidecar for the contextual canvas.
When the canvas exposes more than one OCR ref, prompts to pick one.
CANVAS and REF are passed explicitly when invoked non-interactively
by `xiiif-ui--ocr-refresh'."
  (interactive)
  (let* ((c (or canvas (xiiif--require-canvas)))
         (refs (xiiif-canvas-ocr-refs c)))
    (unless refs
      (user-error "No OCR (ALTO/hOCR/text) seeAlso on this canvas"))
    (let ((chosen
           (or ref
               (if (= 1 (length refs))
                   (car refs)
                 (let* ((table (mapcar
                                (lambda (r)
                                  (cons (format "[%s] %s"
                                                (plist-get r :format)
                                                (or (plist-get r :label)
                                                    (plist-get r :url)))
                                        r))
                                refs))
                        (pick (completing-read "OCR source: "
                                               (mapcar #'car table)
                                               nil t)))
                   (cdr (assoc pick table)))))))
      (message "xiiif: fetching OCR...")
      (xiiif-ocr-fetch-async
       chosen
       (lambda (enriched)
         (xiiif-ui-render-ocr c enriched)
         (message "xiiif: OCR (%s) for %s"
                  (plist-get enriched :format)
                  (xiiif-canvas-title c)))))))

;;;###autoload
(defun xiiif-show-annotations (&optional canvas)
  "Fetch and display non-painting annotations for the contextual canvas.
Inline AnnotationPages are rendered immediately; external references
are resolved asynchronously and merged in document order.
CANVAS is passed explicitly when invoked non-interactively by
`xiiif-ui--annotations-refresh'."
  (interactive)
  (let ((canvas (or canvas (xiiif--require-canvas))))
    (message "xiiif: collecting annotations...")
    (xiiif-annotations-collect
     canvas
     (lambda (annotations)
       (xiiif-ui-render-annotations canvas annotations)
       (message "xiiif: %d annotation%s on %s"
                (length annotations)
                (if (= 1 (length annotations)) "" "s")
                (xiiif-canvas-title canvas))))))

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
(defun xiiif-show-structures ()
  "Open the structural navigator for the current manifest.
Shows `structures' (v2) and `Range' (v3) hierarchies in a dedicated
`*XIIIF Structures*' buffer.  RET descends into a range's first
canvas or opens the canvas at point."
  (interactive)
  (xiiif-ui-render-structures (xiiif--require-manifest)))

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
     ((or (memq mode '(xiiif-manifest-mode xiiif-canvas-list-mode
                       xiiif-canvas-mode xiiif-structures-mode))
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
detail buffer (re-resolved by id) and the collection browser.
A pending refresh on the same buffer is cancelled first so rapid
presses do not race."
  (interactive)
  (pcase-let* ((`(,url . ,mode) (xiiif--refresh-source))
               (canvas-id (and (eq mode 'xiiif-canvas-mode)
                               xiiif-ui--canvas
                               (xiiif-canvas-id xiiif-ui--canvas)))
               (origin (current-buffer)))
    (unless url
      (user-error "Current resource has no URL to refresh"))
    (when (buffer-live-p origin)
      (with-current-buffer origin (xiiif--cancel-inflight)))
    (setq xiiif--inflight
          (xiiif--load-resource-async
     url
     (lambda (fresh)
       (xiiif-cache-set-manifest fresh)
       (cond
        ((eq mode 'xiiif-canvas-list-mode)
         (xiiif-ui-render-canvases fresh))
        ((eq mode 'xiiif-canvas-mode)
         (let ((match (xiiif-manifest-find-canvas fresh canvas-id)))
           (if match
               (progn (xiiif-cache-set-canvas match)
                      (xiiif-ui-render-canvas match))
             (xiiif-ui-render-manifest fresh))))
        ((eq mode 'xiiif-structures-mode)
         (if (xiiif-manifest-structures fresh)
             (xiiif-ui-render-structures fresh)
           (xiiif-ui-render-manifest fresh)))
        (t (xiiif-ui-render-manifest fresh)))
       (run-hook-with-args 'xiiif-after-load-manifest-hook fresh)
       (message "xiiif: refreshed %s" (xiiif-manifest-title fresh)))
     (lambda (fresh)
       (xiiif-cache-set-collection fresh)
       (xiiif-ui-render-collection fresh)
       (run-hook-with-args 'xiiif-after-load-collection-hook fresh)
       (message "xiiif: refreshed %s" (xiiif-collection-title fresh)))))))

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
(defun xiiif-toggle-thumbnails ()
  "Toggle inline thumbnail rendering in the canvas detail buffer.
Re-renders the current canvas, if any, to pick up the new setting."
  (interactive)
  (setq xiiif-ui-show-thumbnails (not xiiif-ui-show-thumbnails))
  (message "xiiif: thumbnails %s"
           (if xiiif-ui-show-thumbnails "enabled" "disabled"))
  (when (and xiiif-current-canvas
             (derived-mode-p 'xiiif-canvas-mode))
    (xiiif-ui-render-canvas xiiif-current-canvas)))

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

(defcustom xiiif-mirador-base-url
  "https://projectmirador.org/embed/"
  "Base URL of the Mirador viewer used by `xiiif-open-in-mirador'.
A IIIF Content State token is appended as `?iiif-content=<token>'."
  :type 'string
  :group 'xiiif)

(defun xiiif--context-anchor ()
  "Return a canonical anchor for the current xiiif context, or nil.
Includes the canvas (and its region, when the point is on a search
hit or annotation carrying one) when a canvas is in context, so the
handoff is as precise as the current view allows."
  (let ((m (xiiif--require-manifest))
        (c (xiiif--canvas-in-context)))
    (xiiif-anchor-create
     :manifest (or (xiiif-manifest-url m) (xiiif-manifest-id m))
     :canvas   (and c (xiiif-canvas-id c))
     :label    (if c (xiiif-canvas-title c) (xiiif-manifest-title m)))))

;;;###autoload
(defun xiiif-open-in-mirador (&optional anchor)
  "Open the current manifest in an external Mirador viewer.
With no ANCHOR, builds one from context: the current canvas when
one is open (a precise canvas handoff), else the whole manifest.
ANCHOR, a canonical anchor plist (see `xiiif-anchor-create'), forces
an exact canvas+region handoff.  Uses `browse-url' so Emacs's
configured external browser is respected.  Signals `user-error'
when no manifest is loaded."
  (interactive)
  (let* ((anchor (or anchor (xiiif--context-anchor)))
         (url (xiiif-content-state-url anchor xiiif-mirador-base-url)))
    (unless (xiiif-anchor-manifest anchor)
      (user-error "Current manifest has no URL"))
    (browse-url url)
    (message "xiiif: opening %s in Mirador"
             (or (xiiif-anchor-label anchor) "manifest"))))

;;;###autoload
(defun xiiif-open-in-openseadragon (&optional canvas region)
  "Open CANVAS in OpenSeadragon, framed on REGION when given.

CANVAS defaults to the contextual one.  OpenSeadragon views a single
image, so this needs a canvas with an Image API service; for a whole
work, `xiiif-open-in-mirador' is the handoff.  Writes a small local
page and opens it with `browse-url' - see `xiiif-osd' for why the
Mirador-style URL handoff is not available here."
  (interactive)
  (let* ((canvas (or canvas (xiiif--require-canvas)))
         (service (xiiif-canvas-image-service canvas)))
    (unless service
      (user-error "Canvas has no Image API service; \
`xiiif-open-in-mirador' hands off the manifest instead"))
    (xiiif-osd-open service region (xiiif-canvas-title canvas))
    (message "xiiif: opening %s in OpenSeadragon"
             (xiiif-canvas-title canvas))))

(defcustom xiiif-default-external-viewer 'auto
  "Viewer used by `xiiif-open-external-viewer' when none is named.
`auto' follows Spec §8 and picks by capability: OpenSeadragon when a
canvas with an Image API service is in context - deep zoom on one
image is what it is for - and Mirador otherwise, since a whole work
is what it is for.  The chosen viewer is always named in the echo
area, so `auto' is never silent about what it did."
  :type '(choice (const :tag "Detect from context" auto)
                 (const :tag "Always Mirador" mirador)
                 (const :tag "Always OpenSeadragon" openseadragon))
  :group 'xiiif)

(defun xiiif--external-viewer-for-context (anchor)
  "Return the viewer `auto' selects for ANCHOR or the current context.
An explicit ANCHOR is a manifest+canvas+region location, which is
Mirador's currency; without one, a canvas that can be zoomed wins."
  (let ((canvas (and (null anchor) (xiiif--canvas-in-context))))
    (if (and canvas (xiiif-canvas-image-service canvas))
        'openseadragon
      'mirador)))

;;;###autoload
(defun xiiif-open-external-viewer (&optional viewer anchor)
  "Hand the current xiiif location off to an external IIIF VIEWER.

VIEWER is `mirador', `openseadragon', or nil to follow
`xiiif-default-external-viewer'.  ANCHOR forces an exact handoff;
with none, one is built from context.  This is the name
`SPEC_V1.md' §15 gives the handoff, and the one to call from
third-party code: the viewer-specific commands stay available, but
only this one keeps working as viewers are added."
  (interactive)
  (pcase (or viewer
             (if (eq xiiif-default-external-viewer 'auto)
                 (xiiif--external-viewer-for-context anchor)
               xiiif-default-external-viewer))
    ('mirador (xiiif-open-in-mirador anchor))
    ('openseadragon
     (if anchor
         ;; OpenSeadragon addresses an image, not a location, so an
         ;; anchor has to be resolved to the canvas it points at.
         (let ((canvas (and xiiif-current-manifest
                            (xiiif-manifest-find-canvas
                             xiiif-current-manifest
                             (xiiif-anchor-canvas anchor)))))
           (unless canvas
             (user-error "Anchor's canvas is not in the current manifest; \
`mirador' takes an anchor directly"))
           (xiiif-open-in-openseadragon canvas (xiiif-anchor-region anchor)))
       (xiiif-open-in-openseadragon)))
    (other (user-error "Unknown external viewer: %s" other))))

(defun xiiif--open-anchor (anchor)
  "Navigate to the location described by ANCHOR.
When ANCHOR carries a region and the display is graphic, the region
viewer opens on it; otherwise the canvas detail buffer does.  The
manifest is loaded first when it is not the current one."
  (let ((manifest-url (xiiif-anchor-manifest anchor))
        (canvas-id    (xiiif-anchor-canvas anchor))
        (region       (xiiif-anchor-region anchor)))
    (unless manifest-url
      (user-error "Anchor has no manifest URL"))
    (let ((current (and xiiif-current-manifest
                        (equal (xiiif-manifest-url xiiif-current-manifest)
                               manifest-url)
                        xiiif-current-manifest)))
      (if current
          (xiiif--open-anchor-canvas current manifest-url canvas-id region)
        (xiiif--load-resource-async
         manifest-url
         (lambda (manifest)
           (xiiif-cache-set-manifest manifest)
           (run-hook-with-args 'xiiif-after-load-manifest-hook manifest)
           (xiiif--open-anchor-canvas manifest manifest-url canvas-id region))
         (lambda (collection)
           (xiiif-cache-set-collection collection)
           (xiiif-ui-render-collection collection)))))))

(defun xiiif--open-anchor-canvas (manifest manifest-url canvas-id region)
  "Open CANVAS-ID within MANIFEST, focusing on REGION when possible.
Falls back to the canvas detail buffer without a region or off a
graphic display, and to the manifest overview when the canvas is
absent."
  (let* ((canvas (and canvas-id
                      (xiiif-manifest-find-canvas manifest canvas-id)))
         (service (and canvas (xiiif-canvas-image-service canvas))))
    (cond
     ((and canvas region service (display-graphic-p))
      (xiiif-cache-set-canvas canvas)
      (xiiif-view-load-canvas manifest-url canvas-id service region))
     (canvas
      (xiiif-cache-set-canvas canvas)
      (xiiif-ui-render-canvas canvas))
     (t (xiiif-ui-render-manifest manifest)))))

;;;###autoload
(defun xiiif-open-content-state (token)
  "Open the location encoded in a IIIF Content State TOKEN.
TOKEN may be a viewer URL carrying an `iiif-content=' parameter, a
bare base64url Content State token, or the raw Content State JSON.
Loads the referenced manifest and jumps to the anchored canvas."
  (interactive (list (read-string "Content State URL or token: ")))
  (when (string-blank-p token)
    (user-error "Empty Content State token"))
  (xiiif--open-anchor (xiiif-content-state-parse token)))

;;;###autoload
(defun xiiif-export-content-state (&optional format anchor)
  "Export the current xiiif location as a IIIF Content State.

FORMAT is `token' (the base64url form, and the default), `json'
\(the Annotation document itself) or `url' (a viewer URL carrying
the token); interactively the user is prompted.  ANCHOR overrides
the context.  Like `xiiif-export-citation': inserted at point when
the buffer is writable, copied to the kill ring otherwise.

The result round-trips through `xiiif-open' in all three forms."
  (interactive
   (list (intern (completing-read
                  "Content State format: "
                  '("token" "json" "url") nil t nil nil "token"))))
  (let* ((anchor (or anchor (xiiif--context-anchor)))
         (text (pcase (or format 'token)
                 ('token (xiiif-content-state-encode anchor))
                 ('json  (xiiif-content-state-json anchor))
                 ('url   (xiiif-content-state-url anchor))
                 (other (user-error "Unknown Content State format: %s" other)))))
    (if buffer-read-only
        (progn
          (kill-new text)
          (message "xiiif: Content State (%s) copied to kill ring"
                   (or format 'token)))
      (insert text)
      (message "xiiif: Content State (%s) inserted" (or format 'token)))))

;;;###autoload
(defun xiiif-export-citation (&optional format)
  "Export the current manifest as a citation in FORMAT.

FORMAT is `bibtex' or `csl-json'; interactively the user is prompted.
When the current buffer is writable the citation is inserted at point;
otherwise it is copied to the kill ring and a notification is shown."
  (interactive
   (list (intern (completing-read
                  "Citation format: "
                  '("bibtex" "csl-json") nil t nil nil "bibtex"))))
  (let* ((manifest (xiiif--require-manifest))
         (text (pcase format
                 ('bibtex   (xiiif-citation-bibtex manifest))
                 ('csl-json (xiiif-citation-csl-json manifest))
                 (_ (user-error "Unknown citation format: %s" format)))))
    (if buffer-read-only
        (progn
          (kill-new text)
          (message "xiiif: %s citation copied to kill ring" format))
      (insert text)
      (unless (string-suffix-p "\n" text) (insert "\n"))
      (message "xiiif: %s citation inserted" format))))

;; Load the persisted history (if any) eagerly so
;; `xiiif-open-manifest' can default to the last URL.
(xiiif-cache-load)

(provide 'xiiif)
;;; xiiif.el ends here
