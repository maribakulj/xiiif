;;; xiiif-core.el --- Parsing and data model for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Defines the normalized data model used by the rest of the package
;; and a tolerant parser that accepts both IIIF Presentation API v2
;; and v3 shapes (the common ones, at least).  The goal is not full
;; spec compliance: it is to pick out the fields real users look at
;; first - ids, labels, canvases, and their image services - without
;; crashing on imperfect real-world manifests.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defcustom xiiif-preferred-languages '("en" "none" "und")
  "Preferred language tags when resolving IIIF language maps.
The first tag for which a value is present wins."
  :type '(repeat string)
  :group 'xiiif)

(cl-defstruct xiiif-manifest
  "Normalized IIIF manifest."
  url id type label summary metadata thumbnail items raw)

(cl-defstruct xiiif-canvas
  "Normalized IIIF canvas."
  id type label width height thumbnail image-url image-service raw)

(cl-defstruct xiiif-image-service
  "Normalized IIIF Image API service descriptor."
  id type profile)


;;; ---------- generic JSON helpers ----------

(defun xiiif--get (obj key)
  "Return the value for KEY in alist OBJ.
KEY is a symbol; both bare (`id') and JSON-LD style (`@id') forms are tried."
  (when (consp obj)
    (or (alist-get key obj)
        (alist-get (intern (concat "@" (symbol-name key))) obj))))

(defun xiiif--as-list (val)
  "Normalize VAL into a list.
Vectors become lists; a single JSON object is wrapped into a one-element list;
nil becomes nil."
  (cond
   ((null val) nil)
   ((vectorp val) (append val nil))
   ((and (consp val) (consp (car val)) (symbolp (caar val)))
    (list val))
   ((listp val) val)
   (t (list val))))


;;; ---------- label / language map handling ----------

(defun xiiif--language-map-p (val)
  "Return non-nil if VAL looks like a IIIF v3 language map alist."
  (and (consp val)
       (consp (car val))
       (symbolp (caar val))
       ;; A language map value is always an array of strings.
       (let ((v (cdar val)))
         (or (vectorp v) (stringp v)))))

(defun xiiif-label-string (label)
  "Return a human-readable string for LABEL.
LABEL may be nil, a plain string (IIIF v2), a vector of strings, or
a IIIF v3 language map alist like ((en . [\"Title\"]))."
  (cond
   ((null label) "")
   ((stringp label) label)
   ((vectorp label)
    (mapconcat #'xiiif-label-string (append label nil) " "))
   ((xiiif--language-map-p label)
    (let* ((entry (cl-some (lambda (tag)
                             (assq (intern tag) label))
                           xiiif-preferred-languages)))
      (xiiif-label-string (cdr (or entry (car label))))))
   ((consp label)
    (xiiif-label-string (car label)))
   (t (format "%s" label))))

(defun xiiif-metadata-pairs (metadata)
  "Convert METADATA (a IIIF metadata array) into a list of (LABEL . VALUE) strings."
  (mapcar (lambda (entry)
            (cons (xiiif-label-string (xiiif--get entry 'label))
                  (xiiif-label-string (xiiif--get entry 'value))))
          (xiiif--as-list metadata)))


;;; ---------- image service ----------

(defun xiiif-parse-image-service (obj)
  "Parse a single image-service OBJ into a `xiiif-image-service' or nil."
  (when (consp obj)
    (let ((id (xiiif--get obj 'id))
          (type (or (xiiif--get obj 'type)
                    (xiiif--get obj 'profile))))
      (when id
        (make-xiiif-image-service
         :id (string-trim-right id "/")
         :type type
         :profile (xiiif--get obj 'profile))))))

(defun xiiif--collect-services (obj)
  "Return the first usable `xiiif-image-service' found on OBJ or nil."
  (cl-loop for s in (xiiif--as-list (xiiif--get obj 'service))
           for parsed = (xiiif-parse-image-service s)
           when parsed return parsed))


;;; ---------- canvases ----------

(defun xiiif--canvas-image-body (canvas)
  "Return the painting image body for CANVAS, or nil.

Supports IIIF v3 (items -> AnnotationPage -> items -> Annotation -> body)
and IIIF v2 (images -> Annotation -> resource)."
  (or
   ;; v3 path
   (let* ((anno-pages (xiiif--as-list (xiiif--get canvas 'items)))
          (page (car anno-pages))
          (annos (xiiif--as-list (xiiif--get page 'items)))
          (painting (cl-find-if
                     (lambda (a)
                       (let ((m (xiiif--get a 'motivation)))
                         (or (null m) (equal m "painting"))))
                     annos)))
     (xiiif--get painting 'body))
   ;; v2 path
   (let* ((images (xiiif--as-list (xiiif--get canvas 'images)))
          (first (car images)))
     (xiiif--get first 'resource))))

(defun xiiif-parse-canvas (json)
  "Parse JSON into a `xiiif-canvas'."
  (let* ((body (xiiif--canvas-image-body json))
         (service (or (xiiif--collect-services body)
                      (xiiif--collect-services json))))
    (make-xiiif-canvas
     :id        (xiiif--get json 'id)
     :type      (or (xiiif--get json 'type) "Canvas")
     :label     (xiiif--get json 'label)
     :width     (xiiif--get json 'width)
     :height    (xiiif--get json 'height)
     :thumbnail (xiiif--get json 'thumbnail)
     :image-url (and body (xiiif--get body 'id))
     :image-service service
     :raw json)))


;;; ---------- manifests ----------

(defun xiiif--manifest-items (json)
  "Return the raw canvas list from manifest JSON, handling v2 and v3."
  (or (xiiif--get json 'items)
      ;; v2: sequences[0].canvases
      (let* ((seqs (xiiif--as-list (xiiif--get json 'sequences)))
             (first (car seqs)))
        (xiiif--get first 'canvases))))

(defun xiiif-manifest-p-json (json)
  "Return non-nil if JSON looks like a IIIF manifest."
  (and (consp json)
       (let ((type (xiiif--get json 'type)))
         (or (equal type "Manifest")
             (equal type "sc:Manifest")
             ;; v2 sometimes omits @type on the root; fall back to structure.
             (and (null type)
                  (or (xiiif--get json 'items)
                      (xiiif--get json 'sequences)))))))

(defun xiiif-parse-manifest (json &optional url)
  "Parse JSON into a `xiiif-manifest' associated with URL.
Signals `xiiif-parse-error' if JSON does not look like a manifest."
  (unless (xiiif-manifest-p-json json)
    (signal 'xiiif-parse-error
            (list (or url "manifest") "not a IIIF manifest")))
  (make-xiiif-manifest
   :url      url
   :id       (xiiif--get json 'id)
   :type     (or (xiiif--get json 'type) "Manifest")
   :label    (xiiif--get json 'label)
   :summary  (or (xiiif--get json 'summary)
                 (xiiif--get json 'description))
   :metadata (xiiif--get json 'metadata)
   :thumbnail (xiiif--get json 'thumbnail)
   :items    (xiiif--manifest-items json)
   :raw      json))

(defun xiiif-manifest-canvases (manifest)
  "Return a list of `xiiif-canvas' parsed from MANIFEST."
  (mapcar #'xiiif-parse-canvas
          (xiiif--as-list (xiiif-manifest-items manifest))))

(defun xiiif-manifest-title (manifest)
  "Return a short display title for MANIFEST."
  (let ((label (xiiif-label-string (xiiif-manifest-label manifest))))
    (if (string-empty-p label)
        (or (xiiif-manifest-id manifest) "(untitled manifest)")
      label)))

(defun xiiif-canvas-title (canvas &optional index)
  "Return a short display title for CANVAS, prefixed by INDEX when non-nil."
  (let* ((lbl (xiiif-label-string (xiiif-canvas-label canvas)))
         (lbl (if (string-empty-p lbl)
                  (or (xiiif-canvas-id canvas) "(untitled canvas)")
                lbl)))
    (if index
        (format "%d. %s" index lbl)
      lbl)))

(provide 'xiiif-core)
;;; xiiif-core.el ends here
