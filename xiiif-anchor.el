;;; xiiif-anchor.el --- Canonical anchors and IIIF Content State -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The anchor is the keystone of the wider system (Spec C): one
;; serialisable, versioned description of "this exact spot of this
;; source" that xiiif, the research agent (via MCP, out of tree) and
;; web viewers can all read and write.
;;
;; An anchor is a plain property list:
;;
;;   (:xiiif-anchor-version 1
;;    :manifest URL          ; the manifest URL (or id)
;;    :canvas   ID           ; the canvas id, omitted for a whole manifest
;;    :region   (X Y W H)    ; canvas pixels, omitted for a whole canvas
;;    :region-unit percent   ; present only for a percent region
;;    :label    STR)         ; optional human label
;;
;; being just data, it round-trips through `prin1'/`read' and through
;; the note backends (Spec C3) and the batch surface (Spec D).
;;
;; Export/import bridges to IIIF Content State 1.0
;; <https://iiif.io/api/content-state/1.0/>: an anchor becomes a
;; base64url-encoded contentState Annotation, and the
;; `?iiif-content=' URL that carries it to a viewer such as Mirador -
;; a precise canvas+region handoff rather than a bare manifest.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'url-util)
(require 'xiiif-errors)
(require 'xiiif-json)
(require 'xiiif-core)
(require 'xiiif-region)

(defconst xiiif-anchor-version 1
  "Schema version stamped into every anchor this xiiif writes.")

(defconst xiiif-anchor--presentation-context
  "http://iiif.io/api/presentation/3/context.json"
  "JSON-LD context used in exported Content State documents.")


;;; ---------- construction and accessors ----------

(cl-defun xiiif-anchor-create (&key manifest canvas region label)
  "Build a canonical anchor plist.
MANIFEST is the manifest URL/id, CANVAS a canvas id (nil for a
whole-manifest anchor), REGION a `xiiif-region' struct or an
\(X Y W H) list (nil for a whole canvas), LABEL an optional string."
  (let ((anchor (list :xiiif-anchor-version xiiif-anchor-version)))
    (when manifest (setq anchor (plist-put anchor :manifest manifest)))
    (when canvas   (setq anchor (plist-put anchor :canvas canvas)))
    (when region
      (let ((r (xiiif-anchor--normalize-region region)))
        (setq anchor (plist-put anchor :region (plist-get r :region)))
        (when (eq (plist-get r :unit) 'percent)
          (setq anchor (plist-put anchor :region-unit 'percent)))))
    (when label (setq anchor (plist-put anchor :label label)))
    anchor))

(defun xiiif-anchor--normalize-region (region)
  "Return (:region (X Y W H) :unit UNIT) from REGION.
REGION is a `xiiif-region' struct or a raw (X Y W H) list."
  (cond
   ((xiiif-region-p region)
    (list :region (list (xiiif-region-x region) (xiiif-region-y region)
                        (xiiif-region-w region) (xiiif-region-h region))
          :unit (xiiif-region-unit region)))
   ((and (listp region) (= 4 (length region)))
    (list :region (copy-sequence region) :unit 'pixel))
   (t (error "xiiif-anchor: invalid region %S" region))))

(defun xiiif-anchor-p (object)
  "Return non-nil when OBJECT looks like a xiiif anchor plist."
  (and (listp object)
       (plist-member object :xiiif-anchor-version)))

(defun xiiif-anchor-manifest (anchor)
  "Return the manifest URL of ANCHOR, or nil."
  (plist-get anchor :manifest))

(defun xiiif-anchor-canvas (anchor)
  "Return the canvas id of ANCHOR, or nil."
  (plist-get anchor :canvas))

(defun xiiif-anchor-label (anchor)
  "Return the label of ANCHOR, or nil."
  (plist-get anchor :label))

(defun xiiif-anchor-region (anchor)
  "Return ANCHOR's region as a `xiiif-region' struct, or nil."
  (when-let ((xywh (plist-get anchor :region)))
    (make-xiiif-region :x (nth 0 xywh) :y (nth 1 xywh)
                       :w (nth 2 xywh) :h (nth 3 xywh)
                       :unit (or (plist-get anchor :region-unit) 'pixel))))


;;; ---------- base64url ----------

(defun xiiif-anchor--base64url-encode (string)
  "Base64url-encode STRING (UTF-8, no padding)."
  (let ((bytes (encode-coding-string string 'utf-8)))
    (if (fboundp 'base64url-encode-string)
        (base64url-encode-string bytes t)
      (thread-last (base64-encode-string bytes t)
                   (replace-regexp-in-string "+" "-")
                   (replace-regexp-in-string "/" "_")
                   (replace-regexp-in-string "=+\\'" "")))))

(defun xiiif-anchor--base64url-decode (string)
  "Base64url-decode STRING into a UTF-8 string."
  (if (fboundp 'base64url-decode-string)
      (decode-coding-string (base64url-decode-string string) 'utf-8)
    (let* ((s (thread-last string
                           (replace-regexp-in-string "-" "+")
                           (replace-regexp-in-string "_" "/")))
           (pad (mod (- 4 (mod (length s) 4)) 4))
           (padded (concat s (make-string pad ?=))))
      (decode-coding-string (base64-decode-string padded) 'utf-8))))


;;; ---------- Content State export ----------

(defun xiiif-anchor--target-id (anchor)
  "Return the Content State target id string for ANCHOR.
The canvas id (or manifest, absent a canvas) carries a Media
Fragments `#xywh=' hash when ANCHOR has a region."
  (let* ((canvas (xiiif-anchor-canvas anchor))
         (base   (or canvas (xiiif-anchor-manifest anchor)))
         (region (xiiif-anchor-region anchor)))
    (if (and canvas region)
        (concat base "#" (xiiif-region-to-fragment region))
      base)))

(defun xiiif-anchor-to-content-state (anchor)
  "Return the IIIF Content State Annotation for ANCHOR as an alist.
The alist is the JSON model encoded by `xiiif-content-state-json'."
  (let* ((canvas   (xiiif-anchor-canvas anchor))
         (manifest (xiiif-anchor-manifest anchor))
         (target-id (xiiif-anchor--target-id anchor))
         (target
          (if canvas
              (append
               `(("id" . ,target-id)
                 ("type" . "Canvas"))
               (when manifest
                 `(("partOf" . [(("id" . ,manifest)
                                 ("type" . "Manifest"))]))))
            `(("id" . ,target-id)
              ("type" . "Manifest")))))
    `(("@context" . ,xiiif-anchor--presentation-context)
      ("type" . "Annotation")
      ("motivation" . ["contentState"])
      ("target" . ,target))))

(defun xiiif-content-state-json (anchor)
  "Return the Content State JSON document for ANCHOR as a string."
  (json-encode (xiiif-anchor-to-content-state anchor)))

(defun xiiif-content-state-encode (anchor)
  "Return the base64url-encoded Content State token for ANCHOR."
  (xiiif-anchor--base64url-encode (xiiif-content-state-json anchor)))

(defun xiiif-content-state-url (anchor &optional viewer-base)
  "Return a viewer URL embedding ANCHOR as an `iiif-content' token.
VIEWER-BASE defaults to `xiiif-mirador-base-url'.  Any existing
query string on VIEWER-BASE is preserved."
  (let* ((base (or viewer-base
                   (bound-and-true-p xiiif-mirador-base-url)
                   "https://projectmirador.org/embed/"))
         (sep (if (string-match-p "\\?" base) "&" "?")))
    (format "%s%siiif-content=%s"
            (string-trim-right base "?&")
            sep
            (xiiif-content-state-encode anchor))))


;;; ---------- Content State import ----------

(defun xiiif-content-state--extract-token (string)
  "Return the Content State token carried by STRING.
STRING may be a full URL with an `iiif-content' query parameter or
a bare base64url token."
  (if (string-match "[?&]iiif-content=\\([^&]+\\)" string)
      (url-unhex-string (match-string 1 string))
    (string-trim string)))

(defun xiiif-content-state--anchor-from-json (json)
  "Return an anchor plist parsed from a Content State JSON alist."
  (let* ((target (xiiif--get json 'target))
         (target (if (vectorp target)
                     (and (> (length target) 0) (aref target 0))
                   target))
         (id     (cond ((stringp target) target)
                       ((consp target) (xiiif--get target 'id))))
         (type   (and (consp target)
                      (xiiif--normalize-type (xiiif--get target 'type))))
         (region (and (stringp id) (xiiif-region-from-fragment id)))
         (base   (and (stringp id) (car (split-string id "#" t))))
         (part-of (and (consp target)
                       (xiiif--as-list (xiiif--get target 'partOf))))
         (manifest (cl-some (lambda (p) (xiiif--get p 'id)) part-of)))
    (cond
     ;; A canvas target: base is the canvas, manifest comes from partOf.
     ((or (equal type "Canvas") region part-of)
      (xiiif-anchor-create :manifest manifest :canvas base :region region))
     ;; Otherwise the target itself is the manifest.
     (t (xiiif-anchor-create :manifest base)))))

(defun xiiif-content-state-parse (string)
  "Parse STRING into an anchor plist.
STRING may be a viewer URL carrying `iiif-content=', a bare
base64url Content State token, or the raw Content State JSON.
Signals `xiiif-parse-error' when it cannot be decoded."
  (let* ((trimmed (string-trim string))
         (json-text
          (if (string-prefix-p "{" trimmed)
              trimmed
            (condition-case _
                (xiiif-anchor--base64url-decode
                 (xiiif-content-state--extract-token trimmed))
              (error
               (signal 'xiiif-parse-error
                       (list string "invalid Content State token"))))))
         ;; A pasted Content State is as untrusted as a fetched
         ;; manifest, so it goes through the same bounded decoder.
         (json (xiiif-json-parse json-text string)))
    (xiiif-content-state--anchor-from-json json)))

(provide 'xiiif-anchor)
;;; xiiif-anchor.el ends here
