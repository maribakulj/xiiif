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
(require 'xiiif-errors)

(defcustom xiiif-preferred-languages '("en" "none" "und")
  "Preferred language tags when resolving IIIF language maps.
The first tag for which a value is present wins."
  :type '(repeat string)
  :group 'xiiif)

(cl-defstruct xiiif-manifest
  "Normalized IIIF manifest.
CANVAS-CACHE and CANVAS-INDEX are populated lazily on first access
so repeated calls to `xiiif-manifest-canvases' or
`xiiif-manifest-find-canvas' do not re-parse the underlying JSON."
  url id type label summary metadata thumbnail items raw
  canvas-cache canvas-index)

(cl-defstruct xiiif-canvas
  "Normalized IIIF canvas."
  id type label width height thumbnail image-url image-service raw)

(cl-defstruct xiiif-image-service
  "Normalized IIIF Image API service descriptor."
  id type profile)

(cl-defstruct xiiif-collection
  "Normalized IIIF collection."
  url id type label summary items raw)

(cl-defstruct xiiif-collection-item
  "A lazy reference to a child Manifest or Collection inside a collection."
  id type label)

(cl-defstruct xiiif-range
  "Normalized IIIF Range (v2 and v3 structures entry).
CANVAS-IDS is a list of canvas URIs directly targeted by the range.
SUB-RANGES is a list of child `xiiif-range' objects, already linked
for v2 (ids resolved against the manifest's `structures' table) or
inlined for v3."
  id type label canvas-ids sub-ranges raw)


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

(defun xiiif--normalize-type (type)
  "Strip the `sc:' prefix from TYPE, returning a clean string or nil."
  (cond
   ((null type) nil)
   ((and (stringp type) (string-prefix-p "sc:" type))
    (substring type 3))
   ((stringp type) type)
   (t (format "%s" type))))


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
     :type      (or (xiiif--normalize-type (xiiif--get json 'type)) "Canvas")
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
   :type     (or (xiiif--normalize-type (xiiif--get json 'type)) "Manifest")
   :label    (xiiif--get json 'label)
   :summary  (or (xiiif--get json 'summary)
                 (xiiif--get json 'description))
   :metadata (xiiif--get json 'metadata)
   :thumbnail (xiiif--get json 'thumbnail)
   :items    (xiiif--manifest-items json)
   :raw      json))

(defun xiiif-manifest-canvases (manifest)
  "Return a list of `xiiif-canvas' parsed from MANIFEST.
Memoised: the first call parses every canvas once; subsequent calls
reuse the cached list.  Call `xiiif-manifest-invalidate-cache' after
mutating the underlying items to force a re-parse."
  (or (xiiif-manifest-canvas-cache manifest)
      (let ((parsed (mapcar #'xiiif-parse-canvas
                            (xiiif--as-list
                             (xiiif-manifest-items manifest)))))
        (setf (xiiif-manifest-canvas-cache manifest) parsed)
        parsed)))

(defun xiiif-manifest-canvas-count (manifest)
  "Return the number of canvases declared by MANIFEST.
Prefers the raw item count to avoid parsing every canvas when the
overview only needs a length.  Falls back to the cached canvas list."
  (or (and (xiiif-manifest-canvas-cache manifest)
           (length (xiiif-manifest-canvas-cache manifest)))
      (length (xiiif--as-list (xiiif-manifest-items manifest)))))

(defun xiiif-manifest-invalidate-cache (manifest)
  "Drop memoised canvas data from MANIFEST."
  (setf (xiiif-manifest-canvas-cache manifest) nil
        (xiiif-manifest-canvas-index manifest) nil))

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

(defun xiiif-canvas-filesystem-slug (canvas)
  "Return a filesystem-safe slug derived from CANVAS.
Uses the canvas label when available, falling back to the id's last
path segment.  Non-alphanumeric characters are folded to `_', runs of
underscores collapsed, and the result trimmed to a reasonable length.
Always returns a non-empty string (\"canvas\" as last resort)."
  (let* ((label (and canvas (xiiif-label-string (xiiif-canvas-label canvas))))
         (id    (and canvas (xiiif-canvas-id canvas)))
         (source
          (cond
           ((and label (not (string-empty-p label))) label)
           ((and id (not (string-empty-p id)))
            (car (last (split-string id "/" t))))
           (t "canvas")))
         (slug (replace-regexp-in-string "[^[:alnum:]._-]+" "_" source))
         (slug (replace-regexp-in-string "_+" "_" slug))
         (slug (replace-regexp-in-string "\\`_+\\|_+\\'" "" slug)))
    (if (string-empty-p slug)
        "canvas"
      (if (> (length slug) 64) (substring slug 0 64) slug))))

(defun xiiif--thumbnail-field-url (thumbnail)
  "Return a URL string from a IIIF `thumbnail' field THUMBNAIL or nil.
Accepts v2 (string or single object with id/@id) and v3 (array of
Image objects) shapes."
  (cond
   ((null thumbnail) nil)
   ((stringp thumbnail) thumbnail)
   ((vectorp thumbnail)
    (and (> (length thumbnail) 0)
         (xiiif--thumbnail-field-url (aref thumbnail 0))))
   ((consp thumbnail) (xiiif--get thumbnail 'id))))

(defun xiiif-canvas-thumbnail-url (canvas &optional size)
  "Return a URL string for a small preview of CANVAS, or nil.

Preference order:
1. an explicit `thumbnail' value declared by the canvas,
2. a synthesized IIIF Image API derivative of the canvas image
   service at SIZE (defaults to \"!200,200\")."
  (or (xiiif--thumbnail-field-url (xiiif-canvas-thumbnail canvas))
      (let* ((service (xiiif-canvas-image-service canvas))
             (base (and service (xiiif-image-service-id service))))
        (when base
          (format "%s/full/%s/0/default.jpg"
                  (string-trim-right base "/")
                  (or size "!200,200"))))))



;;; ---------- collections ----------

(defun xiiif-collection-p-json (json)
  "Return non-nil if JSON looks like a IIIF Collection."
  (and (consp json)
       (let ((type (xiiif--get json 'type)))
         (or (equal type "Collection")
             (equal type "sc:Collection")))))

(defun xiiif--collection-raw-items (json)
  "Return the raw list of children for collection JSON, handling v2 and v3."
  (or (xiiif--as-list (xiiif--get json 'items))
      ;; v2: collections + manifests, in that order.
      (append (xiiif--as-list (xiiif--get json 'collections))
              (xiiif--as-list (xiiif--get json 'manifests)))))

(defun xiiif-parse-collection-item (json)
  "Parse JSON into a `xiiif-collection-item' or return nil."
  (when (consp json)
    (let ((id (xiiif--get json 'id)))
      (when id
        (make-xiiif-collection-item
         :id    id
         :type  (or (xiiif--normalize-type (xiiif--get json 'type))
                    "Manifest")
         :label (xiiif--get json 'label))))))

(defun xiiif-parse-collection (json &optional url)
  "Parse JSON into a `xiiif-collection' associated with URL.
Signals `xiiif-parse-error' if JSON does not look like a collection."
  (unless (xiiif-collection-p-json json)
    (signal 'xiiif-parse-error
            (list (or url "collection") "not a IIIF collection")))
  (make-xiiif-collection
   :url     url
   :id      (xiiif--get json 'id)
   :type    (or (xiiif--normalize-type (xiiif--get json 'type)) "Collection")
   :label   (xiiif--get json 'label)
   :summary (or (xiiif--get json 'summary)
                (xiiif--get json 'description))
   :items   (xiiif--collection-raw-items json)
   :raw     json))

(defun xiiif-collection-children (collection)
  "Return a list of `xiiif-collection-item' parsed from COLLECTION."
  (delq nil
        (mapcar #'xiiif-parse-collection-item
                (xiiif-collection-items collection))))

(defun xiiif-collection-title (collection)
  "Return a short display title for COLLECTION."
  (let ((label (xiiif-label-string (xiiif-collection-label collection))))
    (if (string-empty-p label)
        (or (xiiif-collection-id collection) "(untitled collection)")
      label)))

(defun xiiif-collection-item-title (item &optional index)
  "Return a short display title for ITEM, prefixed by INDEX when non-nil."
  (let* ((lbl (xiiif-label-string (xiiif-collection-item-label item)))
         (lbl (if (string-empty-p lbl)
                  (or (xiiif-collection-item-id item)
                      "(untitled item)")
                lbl)))
    (if index (format "%d. %s" index lbl) lbl)))


;;; ---------- structures / ranges ----------

(defun xiiif--range-item-kind (item)
  "Return `canvas', `range', or nil for a v3 range ITEM entry.

v3 items can be bare strings (taken as canvases), SpecificResource
objects with a `source' canvas, or inline Range/Canvas objects."
  (cond
   ((stringp item) 'canvas)
   ((consp item)
    (let ((type (xiiif--normalize-type (xiiif--get item 'type))))
      (cond
       ((equal type "Range") 'range)
       ((or (equal type "Canvas") (equal type "SpecificResource"))
        'canvas)
       ;; Best-effort fallback: nested items means Range.
       ((xiiif--get item 'items) 'range)
       (t 'canvas))))))

(defun xiiif--range-item-id (item)
  "Return the canvas URI targeted by a v3 range ITEM, or nil."
  (cond
   ((stringp item) item)
   ((consp item)
    (or (xiiif--get item 'source)
        (xiiif--get item 'id)))))

(defun xiiif-parse-range-v3 (json)
  "Parse a v3 Range JSON into a `xiiif-range'."
  (let (canvases sub-ranges)
    (dolist (item (xiiif--as-list (xiiif--get json 'items)))
      (pcase (xiiif--range-item-kind item)
        ('canvas
         (when-let ((id (xiiif--range-item-id item)))
           (push id canvases)))
        ('range
         (push (xiiif-parse-range-v3 item) sub-ranges))))
    (make-xiiif-range
     :id         (xiiif--get json 'id)
     :type       (or (xiiif--normalize-type (xiiif--get json 'type)) "Range")
     :label      (xiiif--get json 'label)
     :canvas-ids (nreverse canvases)
     :sub-ranges (nreverse sub-ranges)
     :raw        json)))

(defun xiiif-parse-range-v2 (json by-id &optional visited)
  "Parse a v2 Range JSON into a `xiiif-range'.

BY-ID is a hash table of Range id -> raw JSON, used to resolve the
`ranges' references that v2 uses to nest ranges.  VISITED guards
against cyclic references in malformed manifests; returns nil when a
cycle is detected."
  (let* ((id (xiiif--get json 'id))
         (visited (or visited (make-hash-table :test 'equal))))
    (unless (and id (gethash id visited))
      (when id (puthash id t visited))
      (make-xiiif-range
       :id         id
       :type       (or (xiiif--normalize-type (xiiif--get json 'type)) "Range")
       :label      (xiiif--get json 'label)
       :canvas-ids (xiiif--as-list (xiiif--get json 'canvases))
       :sub-ranges
       (delq nil
             (mapcar (lambda (child-id)
                       (when-let ((raw (gethash child-id by-id)))
                         (xiiif-parse-range-v2 raw by-id visited)))
                     (xiiif--as-list (xiiif--get json 'ranges))))
       :raw        json))))

(defun xiiif-manifest-structures (manifest)
  "Return a list of top-level `xiiif-range' trees for MANIFEST, or nil.

Detects v2 vs v3 shape automatically: when the first raw range
carries an `items' array it is parsed recursively in place (v3);
otherwise the v2 `ranges' references are resolved against a sibling
lookup table and only non-child ranges are surfaced as top level."
  (let* ((raw (xiiif--get (xiiif-manifest-raw manifest) 'structures))
         (ranges (xiiif--as-list raw)))
    (when ranges
      (if (xiiif--get (car ranges) 'items)
          (mapcar #'xiiif-parse-range-v3 ranges)
        (let ((by-id (make-hash-table :test 'equal))
              (is-child (make-hash-table :test 'equal)))
          (dolist (r ranges)
            (when-let ((id (xiiif--get r 'id)))
              (puthash id r by-id)))
          (dolist (r ranges)
            (dolist (child-id (xiiif--as-list (xiiif--get r 'ranges)))
              (puthash child-id t is-child)))
          (delq nil
                (mapcar (lambda (r)
                          (unless (gethash (xiiif--get r 'id) is-child)
                            (xiiif-parse-range-v2 r by-id)))
                        ranges)))))))

(defun xiiif-range-title (range &optional index)
  "Return a short display title for RANGE, prefixed by INDEX when non-nil."
  (let* ((lbl (xiiif-label-string (xiiif-range-label range)))
         (lbl (if (string-empty-p lbl)
                  (or (xiiif-range-id range) "(untitled range)")
                lbl)))
    (if index (format "%d. %s" index lbl) lbl)))

(defun xiiif-range-first-canvas-id (range)
  "Return the first canvas URI reachable from RANGE, or nil.
Walks direct canvas ids first, then recurses into sub-ranges in order."
  (or (car (xiiif-range-canvas-ids range))
      (cl-some #'xiiif-range-first-canvas-id
               (xiiif-range-sub-ranges range))))

(defun xiiif-manifest-find-canvas (manifest canvas-id)
  "Return the `xiiif-canvas' in MANIFEST whose id is CANVAS-ID, or nil.
Builds a hash-table index on first use so repeated lookups (notably
from the structures navigator) stay O(1)."
  (when canvas-id
    (let ((index (xiiif-manifest-canvas-index manifest)))
      (unless index
        (setq index (make-hash-table :test 'equal))
        (dolist (c (xiiif-manifest-canvases manifest))
          (when (xiiif-canvas-id c)
            (puthash (xiiif-canvas-id c) c index)))
        (setf (xiiif-manifest-canvas-index manifest) index))
      (gethash canvas-id index))))


;;; ---------- resource detection ----------

(defun xiiif-resource-kind (json)
  "Return `manifest', `collection', or nil for JSON.
Used by the dispatcher in `xiiif-open-manifest'."
  (cond
   ((xiiif-collection-p-json json) 'collection)
   ((xiiif-manifest-p-json json)   'manifest)))

(provide 'xiiif-core)
;;; xiiif-core.el ends here
