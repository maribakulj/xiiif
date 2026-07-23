;;; xiiif-ui.el --- Buffers and major modes for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Three buffers make up the xiiif UI:
;;
;;   *XIIIF Manifest*   - overview of the currently open manifest
;;   *XIIIF Canvases*   - tabulated list of its canvases
;;   *XIIIF Canvas*     - detail view for one canvas, with image service
;;
;; All three share the same keybinding vocabulary: RET opens, g
;; refreshes, y copies a URL, d downloads an image, i inserts into
;; Org, J shows the raw JSON, q quits.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'json)

(require 'xiiif-core)
(require 'xiiif-api)
(require 'xiiif-cache)
(require 'xiiif-image)
(require 'xiiif-annotations)
(require 'xiiif-ocr)

(defconst xiiif-ui--manifest-buffer    "*XIIIF Manifest*")
(defconst xiiif-ui--canvases-buffer    "*XIIIF Canvases*")
(defconst xiiif-ui--canvas-buffer      "*XIIIF Canvas*")
(defconst xiiif-ui--collection-buffer  "*XIIIF Collection*")
(defconst xiiif-ui--info-buffer        "*XIIIF Image Info*")
(defconst xiiif-ui--structures-buffer  "*XIIIF Structures*")
(defconst xiiif-ui--annotations-buffer "*XIIIF Annotations*")
(defconst xiiif-ui--ocr-buffer         "*XIIIF OCR*")

(defface xiiif-heading
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for section headings in xiiif buffers.")

(defface xiiif-key
  '((t :inherit font-lock-variable-name-face))
  "Face for field labels in xiiif buffers.")

(defface xiiif-hint
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for in-buffer key hints.")


;;; ---------- small rendering helpers ----------

(defun xiiif-ui--insert-heading (text)
  "Insert TEXT as a section heading."
  (insert (propertize text 'face 'xiiif-heading) "\n")
  (insert (propertize (make-string (length text) ?-) 'face 'xiiif-heading))
  (insert "\n"))

(defun xiiif-ui--insert-field (label value)
  "Insert a one-line LABEL: VALUE pair, skipping empty values."
  (when (and value (not (string-empty-p (format "%s" value))))
    (insert (propertize (format "%-10s " (concat label ":"))
                        'face 'xiiif-key))
    (insert (format "%s" value) "\n")))

(defun xiiif-ui--insert-hints (pairs)
  "Insert a one-line hint summary from PAIRS of (KEY . DESCRIPTION)."
  (insert (propertize
           (mapconcat (lambda (p) (format "[%s] %s" (car p) (cdr p)))
                      pairs "   ")
           'face 'xiiif-hint))
  (insert "\n\n"))

(defun xiiif-ui--size (canvas)
  "Return a short WxH string for CANVAS, or an empty string."
  (let ((w (xiiif-canvas-width canvas))
        (h (xiiif-canvas-height canvas)))
    (if (and w h) (format "%sx%s" w h) "")))


;;; ---------- manifest overview ----------

(defvar xiiif-manifest-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g")   #'xiiif-refresh)
    (define-key map (kbd "RET") #'xiiif-browse-canvases)
    (define-key map (kbd "c")   #'xiiif-browse-canvases)
    (define-key map (kbd "s")   #'xiiif-show-structures)
    (define-key map (kbd "J")   #'xiiif-show-raw-json)
    (define-key map (kbd "y")   #'xiiif-copy-manifest-url)
    (define-key map (kbd "i")   #'xiiif-insert-org-link)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `xiiif-manifest-mode'.")

(define-derived-mode xiiif-manifest-mode special-mode "XIIIF-Manifest"
  "Major mode for the IIIF manifest overview buffer."
  (buffer-disable-undo)
  (setq-local truncate-lines t))

(defun xiiif-ui-render-manifest (manifest)
  "Render MANIFEST into the overview buffer and display it."
  (let ((buf (get-buffer-create xiiif-ui--manifest-buffer)))
    (with-current-buffer buf
      (xiiif-manifest-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (xiiif-ui--insert-hints
         '(("RET" . "canvases") ("y" . "copy URL")
           ("J" . "raw JSON")   ("i" . "org link")
           ("g" . "refresh")    ("q" . "quit")))
        (xiiif-ui--insert-heading (xiiif-manifest-title manifest))
        (xiiif-ui--insert-field "URL"  (xiiif-manifest-url manifest))
        (xiiif-ui--insert-field "ID"   (xiiif-manifest-id manifest))
        (xiiif-ui--insert-field "Type" (xiiif-manifest-type manifest))
        (let ((summary (xiiif-label-string (xiiif-manifest-summary manifest))))
          (unless (string-empty-p summary)
            (insert "\n")
            (xiiif-ui--insert-heading "Summary")
            (insert summary "\n")))
        (let ((pairs (xiiif-metadata-pairs (xiiif-manifest-metadata manifest))))
          (when pairs
            (insert "\n")
            (xiiif-ui--insert-heading "Metadata")
            (dolist (pair pairs)
              (xiiif-ui--insert-field (car pair) (cdr pair)))))
        (progn
          (insert "\n")
          (xiiif-ui--insert-heading
           (format "Canvases (%d)"
                   (xiiif-manifest-canvas-count manifest)))
          (insert "Press RET or c to browse.\n"))
        (let ((structures (xiiif-manifest-structures manifest)))
          (when structures
            (insert "\n")
            (xiiif-ui--insert-heading
             (format "Structures (%d)" (length structures)))
            (insert "Press s to open the structural navigator.\n")))
        (goto-char (point-min))))
    (pop-to-buffer-same-window buf)))


;;; ---------- canvas browser ----------

(defvar xiiif-canvas-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'xiiif-ui--open-canvas-at-point)
    (define-key map (kbd "o")   #'xiiif-ui--open-canvas-at-point)
    (define-key map (kbd "y")   #'xiiif-ui--copy-image-url-at-point)
    (define-key map (kbd "d")   #'xiiif-ui--download-image-at-point)
    (define-key map (kbd "i")   #'xiiif-ui--insert-org-link-at-point)
    (define-key map (kbd "m")   #'xiiif-ui--mark-canvas)
    (define-key map (kbd "u")   #'xiiif-ui--unmark-canvas)
    (define-key map (kbd "U")   #'xiiif-ui--unmark-all-canvases)
    (define-key map (kbd "t")   #'xiiif-ui--toggle-mark-canvas)
    (define-key map (kbd "D")   #'xiiif-download-marked)
    (define-key map (kbd "g")   #'xiiif-refresh)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `xiiif-canvas-list-mode'.")

(define-derived-mode xiiif-canvas-list-mode tabulated-list-mode "XIIIF-Canvases"
  "Major mode for browsing the canvases of a IIIF manifest."
  (setq tabulated-list-format
        [("#"     4  nil :right-align t)
         ("Label" 48 t)
         ("Size"  12 nil)
         ("Img"   3  nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key nil)
  (tabulated-list-init-header))

(defun xiiif-ui--canvas-row (index canvas)
  "Build a tabulated-list row from INDEX and CANVAS."
  (list canvas
        (vector (number-to-string index)
                (xiiif-canvas-title canvas)
                (xiiif-ui--size canvas)
                (if (xiiif-canvas-image-service canvas) "yes" "-"))))

(defun xiiif-ui-render-canvases (manifest)
  "Render the canvas browser for MANIFEST and display it."
  (let ((buf (get-buffer-create xiiif-ui--canvases-buffer))
        (canvases (xiiif-manifest-canvases manifest)))
    (with-current-buffer buf
      (xiiif-canvas-list-mode)
      (setq-local xiiif-ui--manifest manifest)
      (setq tabulated-list-entries
            (cl-loop for c in canvases
                     for i from 1
                     collect (xiiif-ui--canvas-row i c)))
      (tabulated-list-print t)
      (setq-local mode-line-misc-info
                  (list (format "  %s  [%d]"
                                (xiiif-manifest-title manifest)
                                (length canvases)))))
    (pop-to-buffer-same-window buf)
    (message "%d canvas%s   [RET] open  [y] copy  [d] download  [m] mark  [D] bulk download  [i] org  [g] refresh  [q] quit"
             (length canvases)
             (if (= 1 (length canvases)) "" "es"))))

(defvar-local xiiif-ui--manifest nil
  "The `xiiif-manifest' backing the current canvas list buffer.")

(defun xiiif-ui--canvas-at-point ()
  "Return the `xiiif-canvas' at point in a canvas list, or nil."
  (and (derived-mode-p 'xiiif-canvas-list-mode)
       (tabulated-list-get-id)))

(defun xiiif-ui--open-canvas-at-point ()
  "Open the canvas at point in a canvas list buffer."
  (interactive)
  (let ((canvas (xiiif-ui--canvas-at-point)))
    (unless canvas (user-error "No canvas on this line"))
    (xiiif-cache-set-canvas canvas)
    (xiiif-ui-render-canvas canvas)))

(defun xiiif-ui--copy-image-url-at-point ()
  "Copy the default Image API URL for the canvas at point."
  (interactive)
  (let ((canvas (xiiif-ui--canvas-at-point)))
    (unless canvas (user-error "No canvas on this line"))
    (let ((url (xiiif-image-url canvas)))
      (unless url (user-error "Canvas has no image service"))
      (kill-new url)
      (message "Copied: %s" url))))

(defun xiiif-ui--download-image-at-point ()
  "Download the image for the canvas at point."
  (interactive)
  (let ((canvas (xiiif-ui--canvas-at-point)))
    (unless canvas (user-error "No canvas on this line"))
    (xiiif-ui-download-canvas-image canvas)))

(defun xiiif-ui--insert-org-link-at-point ()
  "Insert an Org link for the canvas at point."
  (interactive)
  (let ((canvas (xiiif-ui--canvas-at-point)))
    (unless canvas (user-error "No canvas on this line"))
    (xiiif-cache-set-canvas canvas)
    (call-interactively #'xiiif-insert-org-link)))


;;; ---------- mark helpers ----------

(defconst xiiif-ui--mark-tag "*"
  "Single-character tag used to mark a canvas in the canvas browser.")

(defun xiiif-ui--canvas-marked-p ()
  "Return non-nil when the canvas on the current line is marked."
  (and (derived-mode-p 'xiiif-canvas-list-mode)
       (save-excursion
         (beginning-of-line)
         (char-equal (char-after) (aref xiiif-ui--mark-tag 0)))))

(defun xiiif-ui--mark-canvas ()
  "Mark the canvas on the current line and advance."
  (interactive)
  (unless (xiiif-ui--canvas-at-point)
    (user-error "No canvas on this line"))
  (tabulated-list-put-tag xiiif-ui--mark-tag t))

(defun xiiif-ui--unmark-canvas ()
  "Unmark the canvas on the current line and advance."
  (interactive)
  (unless (xiiif-ui--canvas-at-point)
    (user-error "No canvas on this line"))
  (tabulated-list-put-tag " " t))

(defun xiiif-ui--toggle-mark-canvas ()
  "Toggle the mark on the canvas on the current line and advance."
  (interactive)
  (if (xiiif-ui--canvas-marked-p)
      (xiiif-ui--unmark-canvas)
    (xiiif-ui--mark-canvas)))

(defun xiiif-ui--unmark-all-canvases ()
  "Remove every mark in the current canvas browser."
  (interactive)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (when (xiiif-ui--canvas-at-point)
        (tabulated-list-put-tag " "))
      (forward-line 1))))

(defun xiiif-ui--marked-canvases ()
  "Return the list of `xiiif-canvas' structs currently marked."
  (save-excursion
    (goto-char (point-min))
    (let (result)
      (while (not (eobp))
        (let ((canvas (xiiif-ui--canvas-at-point)))
          (when (and canvas (xiiif-ui--canvas-marked-p))
            (push canvas result)))
        (forward-line 1))
      (nreverse result))))


;;; ---------- canvas detail ----------

(defvar xiiif-canvas-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "y")   #'xiiif-copy-image-url)
    (define-key map (kbd "d")   #'xiiif-download-image)
    (define-key map (kbd "i")   #'xiiif-insert-org-link)
    (define-key map (kbd "I")   #'xiiif-show-info-json)
    (define-key map (kbd "a")   #'xiiif-show-annotations)
    (define-key map (kbd "O")   #'xiiif-show-ocr)
    (define-key map (kbd "J")   #'xiiif-show-raw-json)
    (define-key map (kbd "g")   #'xiiif-refresh)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `xiiif-canvas-mode'.")

(define-derived-mode xiiif-canvas-mode special-mode "XIIIF-Canvas"
  "Major mode for the IIIF canvas detail buffer."
  (buffer-disable-undo)
  (setq-local truncate-lines t))

(defcustom xiiif-ui-show-thumbnails t
  "When non-nil, render the canvas thumbnail inline in the canvas detail buffer.
The inline preview is only attempted on graphic displays."
  :type 'boolean
  :group 'xiiif)

(defcustom xiiif-ui-thumbnail-size "!200,200"
  "IIIF Image API `size' segment used when synthesizing a canvas thumbnail.
Only used as a fallback when the canvas does not declare its own
`thumbnail' field."
  :type 'string
  :group 'xiiif)

(defvar-local xiiif-ui--thumbnail-generation 0
  "Render generation of the canvas detail buffer.
Bumped on every re-render so a thumbnail callback started against an
earlier rendering can detect that its marker no longer points into
the current content and drop the insert.")
(put 'xiiif-ui--thumbnail-generation 'permanent-local t)

(defvar-local xiiif-ui--thumbnail-inflight nil
  "Cancellable handle of the in-flight thumbnail fetch, or nil.")
(put 'xiiif-ui--thumbnail-inflight 'permanent-local t)

(defun xiiif-ui--insert-thumbnail-async (canvas buffer marker)
  "Fetch a thumbnail for CANVAS and insert it at MARKER in BUFFER.
Does nothing on text-only displays or when CANVAS has no usable URL.
The response is dropped when BUFFER has been re-rendered or killed in
the meantime: `xiiif-ui-render-canvas' cancels the stored handle and
bumps the generation this closure captures."
  (when (and (display-graphic-p)
             (buffer-live-p buffer))
    (let ((url (xiiif-canvas-thumbnail-url
                canvas xiiif-ui-thumbnail-size))
          (generation (buffer-local-value
                       'xiiif-ui--thumbnail-generation buffer)))
      (when url
        (let ((handle
               (xiiif-api-fetch-bytes-async
                url
                (lambda (bytes)
                  (when (and (buffer-live-p buffer)
                             (= generation
                                (buffer-local-value
                                 'xiiif-ui--thumbnail-generation buffer)))
                    (with-current-buffer buffer
                      (setq xiiif-ui--thumbnail-inflight nil)
                      (save-excursion
                        (goto-char marker)
                        (let ((inhibit-read-only t))
                          (condition-case _
                              (insert-image (create-image bytes nil t))
                            (error
                             (insert
                              (propertize "(could not render thumbnail)"
                                          'face 'xiiif-hint)))))))))
                (lambda (_err) nil))))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (setq xiiif-ui--thumbnail-inflight handle))))))))

(defun xiiif-ui-render-canvas (canvas)
  "Render the canvas detail buffer for CANVAS and display it.
When `xiiif-ui-show-thumbnails' is non-nil on a graphic display,
fetches a small preview asynchronously and inserts it at the end."
  (let ((buf (get-buffer-create xiiif-ui--canvas-buffer))
        (service (xiiif-canvas-image-service canvas))
        thumb-marker)
    (with-current-buffer buf
      (xiiif-api-cancel xiiif-ui--thumbnail-inflight)
      (setq xiiif-ui--thumbnail-inflight nil)
      (cl-incf xiiif-ui--thumbnail-generation)
      (xiiif-canvas-mode)
      (setq-local xiiif-ui--canvas canvas)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (xiiif-ui--insert-hints
         '(("y" . "copy URL") ("d" . "download")
           ("i" . "org link") ("I" . "info.json")
           ("J" . "raw JSON") ("q" . "quit")))
        (xiiif-ui--insert-heading (xiiif-canvas-title canvas))
        (xiiif-ui--insert-field "ID"     (xiiif-canvas-id canvas))
        (xiiif-ui--insert-field "Type"   (xiiif-canvas-type canvas))
        (xiiif-ui--insert-field "Size"   (xiiif-ui--size canvas))
        (xiiif-ui--insert-field "Image"  (xiiif-canvas-image-url canvas))
        (insert "\n")
        (xiiif-ui--insert-heading "Image service")
        (if (not service)
            (insert "No IIIF Image API service detected on this canvas.\n")
          (xiiif-ui--insert-field "Base"    (xiiif-image-service-id service))
          (xiiif-ui--insert-field "Type"    (xiiif-image-service-type service))
          (xiiif-ui--insert-field "Profile" (xiiif-image-service-profile service))
          (xiiif-ui--insert-field "info"    (xiiif-image-info-url service))
          (insert "\n")
          (xiiif-ui--insert-heading "Default derivative")
          (xiiif-ui--insert-field "URL" (xiiif-image-url canvas)))
        (when (and xiiif-ui-show-thumbnails (display-graphic-p))
          (insert "\n")
          (xiiif-ui--insert-heading "Thumbnail")
          (setq thumb-marker (point-marker)))
        (goto-char (point-min)))
      (run-hook-with-args 'xiiif-after-render-canvas-hook canvas))
    (pop-to-buffer-same-window buf)
    (when thumb-marker
      (xiiif-ui--insert-thumbnail-async canvas buf thumb-marker))))

(defvar-local xiiif-ui--canvas nil
  "The `xiiif-canvas' backing the current canvas detail buffer.")


;;; ---------- image download interactive helper ----------

(defun xiiif-ui-download-canvas-image (canvas)
  "Interactively download an image derived from CANVAS.
Prompts for size and destination; other parameters take defaults.
The actual transfer runs asynchronously so Emacs stays responsive."
  (let* ((service (xiiif-canvas-image-service canvas))
         (_       (unless service
                    (user-error "Canvas has no image service")))
         (size    (read-string
                   (format "Size (default %s): " xiiif-image-default-size)
                   nil nil xiiif-image-default-size))
         (fmt     (read-string
                   (format "Format (default %s): " xiiif-image-default-format)
                   nil nil xiiif-image-default-format))
         (default (expand-file-name
                   (xiiif-image-suggested-filename service fmt)
                   xiiif-image-download-directory))
         (destination (read-file-name "Save image to: "
                                      (file-name-directory default)
                                      default nil
                                      (file-name-nondirectory default))))
    (message "xiiif: downloading...")
    (xiiif-image-download-async
     canvas destination
     (lambda (path) (message "xiiif: saved %s" path))
     :size size :format fmt)))


;;; ---------- collection browser ----------

(declare-function xiiif-open-manifest "xiiif" (url))

(defvar xiiif-collection-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'xiiif-ui--open-collection-item-at-point)
    (define-key map (kbd "o")   #'xiiif-ui--open-collection-item-at-point)
    (define-key map (kbd "y")   #'xiiif-ui--copy-collection-item-url-at-point)
    (define-key map (kbd "i")   #'xiiif-ui--insert-collection-item-org-link-at-point)
    (define-key map (kbd "g")   #'xiiif-refresh)
    (define-key map (kbd "J")   #'xiiif-show-raw-json)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `xiiif-collection-mode'.")

(define-derived-mode xiiif-collection-mode tabulated-list-mode "XIIIF-Collection"
  "Major mode for browsing the children of a IIIF Collection."
  (setq tabulated-list-format
        [("#"     4  nil :right-align t)
         ("Type"  12 t)
         ("Label" 60 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key nil)
  (tabulated-list-init-header))

(defvar-local xiiif-ui--collection nil
  "The `xiiif-collection' backing the current collection buffer.")

(defun xiiif-ui--collection-row (index item)
  "Build a tabulated-list row from INDEX and ITEM."
  (list item
        (vector (number-to-string index)
                (or (xiiif-collection-item-type item) "?")
                (xiiif-collection-item-title item))))

(defun xiiif-ui-render-collection (collection)
  "Render the Collection browser for COLLECTION and display it."
  (let ((buf (get-buffer-create xiiif-ui--collection-buffer))
        (children (xiiif-collection-children collection)))
    (with-current-buffer buf
      (xiiif-collection-mode)
      (setq-local xiiif-ui--collection collection)
      (setq tabulated-list-entries
            (cl-loop for item in children
                     for i from 1
                     collect (xiiif-ui--collection-row i item)))
      (tabulated-list-print t))
    (pop-to-buffer-same-window buf)
    (message "%s  -  %d item%s   [RET] open  [y] copy  [i] org  [g] refresh  [q] quit"
             (xiiif-collection-title collection)
             (length children)
             (if (= 1 (length children)) "" "s"))))

(defun xiiif-ui--collection-item-at-point ()
  "Return the `xiiif-collection-item' at point in a collection buffer, or nil."
  (and (derived-mode-p 'xiiif-collection-mode)
       (tabulated-list-get-id)))

(defun xiiif-ui--open-collection-item-at-point ()
  "Open the collection item at point (manifest or sub-collection)."
  (interactive)
  (let ((item (xiiif-ui--collection-item-at-point)))
    (unless item (user-error "No collection item on this line"))
    (xiiif-open-manifest (xiiif-collection-item-id item))))

(defun xiiif-ui--copy-collection-item-url-at-point ()
  "Copy the URL of the collection item at point to the kill ring."
  (interactive)
  (let ((item (xiiif-ui--collection-item-at-point)))
    (unless item (user-error "No collection item on this line"))
    (let ((url (xiiif-collection-item-id item)))
      (unless url (user-error "Item has no URL"))
      (kill-new url)
      (message "Copied %s" url))))

(defun xiiif-ui--insert-collection-item-org-link-at-point ()
  "Copy an Org link for the collection item at point to the kill-ring."
  (interactive)
  (let ((item (xiiif-ui--collection-item-at-point)))
    (unless item (user-error "No collection item on this line"))
    (let* ((target (xiiif-collection-item-id item))
           (label  (xiiif-collection-item-title item))
           (link   (format "[[%s][%s]]" target label)))
      (kill-new link)
      (message "Copied to kill ring: %s" link))))


;;; ---------- structures / ranges ----------

(declare-function xiiif-open-canvas "xiiif" (&optional canvas))

(defvar xiiif-structures-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'xiiif-ui--follow-structure-at-point)
    (define-key map (kbd "o")   #'xiiif-ui--follow-structure-at-point)
    (define-key map (kbd "n")   #'xiiif-ui--next-structure-line)
    (define-key map (kbd "p")   #'xiiif-ui--prev-structure-line)
    (define-key map (kbd "TAB") #'xiiif-ui--next-structure-line)
    (define-key map (kbd "<backtab>") #'xiiif-ui--prev-structure-line)
    (define-key map (kbd "g")   #'xiiif-refresh)
    (define-key map (kbd "J")   #'xiiif-show-raw-json)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `xiiif-structures-mode'.")

(define-derived-mode xiiif-structures-mode special-mode "XIIIF-Structures"
  "Major mode for browsing the structural hierarchy of a IIIF manifest."
  (buffer-disable-undo)
  (setq-local truncate-lines t))

(defvar-local xiiif-ui--structures-manifest nil
  "The `xiiif-manifest' backing the current structures buffer.")

(defface xiiif-structure-canvas
  '((t :inherit font-lock-string-face))
  "Face for canvas lines in the structures buffer.")

(defun xiiif-ui--insert-structure-canvas (indent canvas-id manifest)
  "Insert one canvas line at INDENT referencing CANVAS-ID from MANIFEST."
  (let* ((canvas (xiiif-manifest-find-canvas manifest canvas-id))
         (label (if canvas
                    (xiiif-canvas-title canvas)
                  (or canvas-id "(unknown canvas)")))
         (begin (point)))
    (insert (make-string indent ?\s)
            (propertize (format "- %s" label)
                        'face 'xiiif-structure-canvas) "\n")
    (add-text-properties begin (1- (point))
                         (list 'xiiif-structure-kind 'canvas
                               'xiiif-structure-id canvas-id))))

(defun xiiif-ui--insert-structure-range (indent range manifest)
  "Insert RANGE as a header line at INDENT, then recurse into its children."
  (let ((begin (point)))
    (insert (make-string indent ?\s)
            (propertize (format "* %s" (xiiif-range-title range))
                        'face 'xiiif-heading) "\n")
    (add-text-properties begin (1- (point))
                         (list 'xiiif-structure-kind 'range
                               'xiiif-structure-range range)))
  (dolist (cid (xiiif-range-canvas-ids range))
    (xiiif-ui--insert-structure-canvas (+ indent 2) cid manifest))
  (dolist (sub (xiiif-range-sub-ranges range))
    (xiiif-ui--insert-structure-range (+ indent 2) sub manifest)))

(defun xiiif-ui-render-structures (manifest)
  "Render MANIFEST's structures into the dedicated buffer and display it."
  (let ((buf (get-buffer-create xiiif-ui--structures-buffer))
        (structures (xiiif-manifest-structures manifest)))
    (unless structures
      (user-error "Manifest has no structures / ranges"))
    (with-current-buffer buf
      (xiiif-structures-mode)
      (setq-local xiiif-ui--structures-manifest manifest)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (xiiif-ui--insert-hints
         '(("RET" . "open")   ("n/p" . "next/prev")
           ("J" . "raw JSON") ("g" . "refresh")
           ("q" . "quit")))
        (xiiif-ui--insert-heading
         (format "%s  -  Structures (%d)"
                 (xiiif-manifest-title manifest)
                 (length structures)))
        (dolist (r structures)
          (xiiif-ui--insert-structure-range 0 r manifest))
        (goto-char (point-min))))
    (pop-to-buffer-same-window buf)))

(defun xiiif-ui--structure-kind-at-point ()
  "Return (KIND . VALUE) for the structure line at point, or nil."
  (let ((kind (get-text-property (point) 'xiiif-structure-kind)))
    (pcase kind
      ('canvas (cons 'canvas (get-text-property (point) 'xiiif-structure-id)))
      ('range  (cons 'range  (get-text-property (point) 'xiiif-structure-range))))))

(defun xiiif-ui--follow-structure-at-point ()
  "Open the canvas or the first canvas of the range at point."
  (interactive)
  (let ((entry (xiiif-ui--structure-kind-at-point))
        (manifest xiiif-ui--structures-manifest))
    (unless entry
      (user-error "No structure entry on this line"))
    (let ((canvas-id
           (pcase (car entry)
             ('canvas (cdr entry))
             ('range  (xiiif-range-first-canvas-id (cdr entry))))))
      (unless canvas-id
        (user-error "Nothing to open from this entry"))
      (let ((canvas (xiiif-manifest-find-canvas manifest canvas-id)))
        (unless canvas
          (user-error "Canvas %s is not listed in the current manifest"
                      canvas-id))
        (xiiif-open-canvas canvas)))))

(defun xiiif-ui--next-structure-line (&optional count)
  "Move forward COUNT structure entries."
  (interactive "p")
  (dotimes (_ (or count 1))
    (let (found)
      (save-excursion
        (forward-line 1)
        (while (and (not (eobp))
                    (not (get-text-property (point) 'xiiif-structure-kind)))
          (forward-line 1))
        (when (get-text-property (point) 'xiiif-structure-kind)
          (setq found (point))))
      (when found (goto-char found)))))

(defun xiiif-ui--prev-structure-line (&optional count)
  "Move backward COUNT structure entries."
  (interactive "p")
  (dotimes (_ (or count 1))
    (let (found)
      (save-excursion
        (forward-line -1)
        (while (and (not (bobp))
                    (not (get-text-property (point) 'xiiif-structure-kind)))
          (forward-line -1))
        (when (get-text-property (point) 'xiiif-structure-kind)
          (setq found (point))))
      (when found (goto-char found)))))


;;; ---------- image info.json ----------

(defvar xiiif-info-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'xiiif-ui--info-refresh)
    (define-key map (kbd "y") #'xiiif-ui--info-copy-url)
    (define-key map (kbd "J") #'xiiif-ui--info-show-raw)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `xiiif-info-mode'.")

(define-derived-mode xiiif-info-mode special-mode "XIIIF-Info"
  "Major mode for the IIIF Image API info.json display buffer."
  (buffer-disable-undo)
  (setq-local truncate-lines t))

(defvar-local xiiif-ui--info nil
  "The `xiiif-image-info' backing the current info buffer.")

(defun xiiif-ui-render-info (info)
  "Render INFO in the dedicated info buffer and display it."
  (let ((buf (get-buffer-create xiiif-ui--info-buffer)))
    (with-current-buffer buf
      (xiiif-info-mode)
      (setq-local xiiif-ui--info info)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (xiiif-ui--insert-hints
         '(("y" . "copy URL") ("J" . "raw JSON")
           ("g" . "refresh")  ("q" . "quit")))
        (xiiif-ui--insert-heading
         (or (xiiif-image-info-id info) "Image service"))
        (xiiif-ui--insert-field "ID"        (xiiif-image-info-id info))
        (xiiif-ui--insert-field "Type"      (xiiif-image-info-type info))
        (xiiif-ui--insert-field "Protocol"  (xiiif-image-info-protocol info))
        (xiiif-ui--insert-field "Compliance"
                                (xiiif-image-info-compliance-level info))
        (xiiif-ui--insert-field "Width"     (xiiif-image-info-width info))
        (xiiif-ui--insert-field "Height"    (xiiif-image-info-height info))
        (let ((sizes (xiiif-image-info-size-strings info)))
          (when sizes
            (insert "\n")
            (xiiif-ui--insert-heading
             (format "Advertised sizes (%d)" (length sizes)))
            (dolist (s sizes) (insert "  " s "\n"))))
        (let ((tiles (xiiif-image-info-tile-strings info)))
          (when tiles
            (insert "\n")
            (xiiif-ui--insert-heading
             (format "Tile schemes (%d)" (length tiles)))
            (dolist (t* tiles) (insert "  " t* "\n"))))
        (let ((formats (xiiif-image-info-formats info))
              (qualities (xiiif-image-info-qualities info))
              (feats (xiiif-image-info-extra-features info))
              (rights (xiiif-image-info-rights info)))
          (when (or formats qualities feats rights)
            (insert "\n")
            (xiiif-ui--insert-heading "Capabilities")
            (when formats
              (xiiif-ui--insert-field
               "Formats" (mapconcat #'identity formats ", ")))
            (when qualities
              (xiiif-ui--insert-field
               "Qualities" (mapconcat #'identity qualities ", ")))
            (when feats
              (xiiif-ui--insert-field
               "Features" (mapconcat #'identity feats ", ")))
            (xiiif-ui--insert-field "Rights" rights)))
        (goto-char (point-min))))
    (pop-to-buffer-same-window buf)))

(declare-function xiiif-show-info-json "xiiif")
(declare-function xiiif-show-annotations "xiiif")
(declare-function xiiif-show-ocr "xiiif")

(defun xiiif-ui--info-refresh ()
  "Re-fetch the current info.json."
  (interactive)
  (unless xiiif-ui--info
    (user-error "No info.json loaded"))
  (xiiif-show-info-json (xiiif-image-info-id xiiif-ui--info)))

(defun xiiif-ui--info-copy-url ()
  "Copy the info.json URL for the current buffer to the kill-ring."
  (interactive)
  (unless xiiif-ui--info
    (user-error "No info.json loaded"))
  (let ((url (concat (string-trim-right
                      (xiiif-image-info-id xiiif-ui--info) "/")
                     "/info.json")))
    (kill-new url)
    (message "Copied %s" url)))

(defun xiiif-ui--info-show-raw ()
  "Show the raw JSON of the current info buffer."
  (interactive)
  (unless xiiif-ui--info
    (user-error "No info.json loaded"))
  (xiiif-ui-show-json (xiiif-image-info-raw xiiif-ui--info)
                      (or (xiiif-image-info-id xiiif-ui--info)
                          "info.json")))


;;; ---------- annotations ----------

(defvar xiiif-annotations-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'xiiif-refresh)
    (define-key map (kbd "J") #'xiiif-show-raw-json)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `xiiif-annotations-mode'.")

(define-derived-mode xiiif-annotations-mode special-mode "XIIIF-Annotations"
  "Major mode for the IIIF annotations buffer."
  (buffer-disable-undo)
  (setq-local truncate-lines nil))

(defvar-local xiiif-ui--annotations-canvas nil
  "The `xiiif-canvas' whose annotations the current buffer shows.")

(defvar-local xiiif-ui--annotations nil
  "List of `xiiif-annotation' rendered in the current buffer.")

(defun xiiif-ui--insert-annotation (a)
  "Insert one `xiiif-annotation' A into the current buffer."
  (xiiif-ui--insert-field "Motivation" (xiiif-annotation-motivation a))
  (xiiif-ui--insert-field "Target"     (xiiif-annotation-target a))
  (xiiif-ui--insert-field "Type"       (xiiif-annotation-body-type a))
  (xiiif-ui--insert-field "Language"   (xiiif-annotation-body-lang a))
  (when-let ((val (xiiif-annotation-body-value a)))
    (insert "\n")
    (insert val)
    (unless (string-suffix-p "\n" val) (insert "\n")))
  (insert (make-string 40 ?-) "\n"))

(defun xiiif-ui-render-annotations (canvas annotations)
  "Render ANNOTATIONS (list of `xiiif-annotation') for CANVAS.
ANNOTATIONS may be empty; the buffer still opens with a diagnostic."
  (let ((buf (get-buffer-create xiiif-ui--annotations-buffer)))
    (with-current-buffer buf
      (xiiif-annotations-mode)
      (setq-local xiiif-ui--annotations-canvas canvas)
      (setq-local xiiif-ui--annotations annotations)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (xiiif-ui--insert-hints
         '(("J" . "raw JSON") ("g" . "refresh") ("q" . "quit")))
        (xiiif-ui--insert-heading
         (format "%s  -  Annotations (%d)"
                 (xiiif-canvas-title canvas)
                 (length annotations)))
        (if (null annotations)
            (insert "No annotations attached to this canvas.\n")
          (dolist (a annotations)
            (insert "\n")
            (xiiif-ui--insert-annotation a)))
        (goto-char (point-min))))
    (pop-to-buffer-same-window buf)))


;;; ---------- OCR sidecar ----------

(defvar xiiif-ocr-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "y") #'xiiif-ui--ocr-copy-url)
    (define-key map (kbd "g") #'xiiif-ui--ocr-refresh)
    (define-key map (kbd "J") #'xiiif-ui--ocr-show-raw)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `xiiif-ocr-mode'.")

(define-derived-mode xiiif-ocr-mode special-mode "XIIIF-OCR"
  "Major mode for the IIIF OCR/ALTO/hOCR sidecar buffer."
  (buffer-disable-undo)
  (setq-local truncate-lines nil))

(defvar-local xiiif-ui--ocr-canvas nil
  "The `xiiif-canvas' whose OCR the current buffer shows.")

(defvar-local xiiif-ui--ocr-ref nil
  "The OCR ref plist (augmented with :text/:body) rendered here.")

(defun xiiif-ui-render-ocr (canvas ref)
  "Render extracted OCR text for REF of CANVAS into the sidecar buffer.
REF must have been enriched by `xiiif-ocr-fetch-async' with `:text'."
  (let ((buf (get-buffer-create xiiif-ui--ocr-buffer)))
    (with-current-buffer buf
      (xiiif-ocr-mode)
      (setq-local xiiif-ui--ocr-canvas canvas)
      (setq-local xiiif-ui--ocr-ref ref)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (xiiif-ui--insert-hints
         '(("y" . "copy URL") ("J" . "raw body")
           ("g" . "refresh")  ("q" . "quit")))
        (xiiif-ui--insert-heading
         (format "%s  -  OCR (%s)"
                 (xiiif-canvas-title canvas)
                 (or (plist-get ref :format) "?")))
        (xiiif-ui--insert-field "Source" (plist-get ref :url))
        (xiiif-ui--insert-field "Label"  (plist-get ref :label))
        (insert "\n")
        (let ((text (or (plist-get ref :text) "")))
          (if (string-empty-p text)
              (insert "(no text extracted)\n")
            (insert text)
            (unless (string-suffix-p "\n" text) (insert "\n"))))
        (goto-char (point-min))))
    (pop-to-buffer-same-window buf)))

(defun xiiif-ui--ocr-copy-url ()
  "Copy the source URL of the current OCR sidecar to the kill ring."
  (interactive)
  (unless xiiif-ui--ocr-ref (user-error "No OCR loaded"))
  (let ((url (plist-get xiiif-ui--ocr-ref :url)))
    (kill-new url)
    (message "Copied %s" url)))

(defun xiiif-ui--ocr-show-raw ()
  "Show the raw body of the current OCR sidecar in a separate buffer."
  (interactive)
  (unless xiiif-ui--ocr-ref (user-error "No OCR loaded"))
  (let ((body (or (plist-get xiiif-ui--ocr-ref :body) ""))
        (url  (plist-get xiiif-ui--ocr-ref :url))
        (buf  (get-buffer-create "*XIIIF OCR raw*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert body)
        (goto-char (point-min))
        (view-mode 1)))
    (pop-to-buffer buf)
    (message "Raw body of %s" url)))

(defun xiiif-ui--ocr-refresh ()
  "Re-fetch and re-render the OCR in the current sidecar buffer."
  (interactive)
  (unless (and xiiif-ui--ocr-canvas xiiif-ui--ocr-ref)
    (user-error "No OCR context to refresh"))
  (xiiif-show-ocr xiiif-ui--ocr-canvas xiiif-ui--ocr-ref))


;;; ---------- raw JSON ----------

(defun xiiif-ui-show-json (obj title)
  "Show parsed JSON OBJ in a buffer named after TITLE."
  (let ((buf (get-buffer-create
              (format "*XIIIF JSON: %s*" title))))
    (with-current-buffer buf
      (let ((inhibit-read-only t)
            (json-encoding-pretty-print t))
        (erase-buffer)
        (insert (json-encode obj))
        (goto-char (point-min))
        (cond ((fboundp 'json-mode) (json-mode))
              ((fboundp 'js-mode)   (js-mode)))
        (view-mode 1)))
    (pop-to-buffer buf)))

(provide 'xiiif-ui)
;;; xiiif-ui.el ends here
