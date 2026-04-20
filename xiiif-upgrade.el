;;; xiiif-upgrade.el --- Normalize IIIF Presentation 2.x to 3.x shape -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `xiiif-core' already parses v2 and v3 manifests into the same
;; struct.  This module goes further: it returns a canonical v3-shaped
;; alist ready to hand off to non-xiiif consumers (Mirador, a v3-only
;; server, a CLI tool, etc.).
;;
;; The upgrade covers the parts users actually need in the field:
;;
;;   - `@id'/`@type' -> `id'/`type'
;;   - `sc:<Thing>' -> `<Thing>'
;;   - Plain-string / vector labels -> v3 language maps
;;   - Presentation metadata -> v3 `metadata' with language-wrapped values
;;   - `sequences[0].canvases' -> top-level `items'
;;   - Canvas `images[].resource' -> AnnotationPage wrapping a single
;;     `painting' annotation with the same image body + service
;;   - Collection `collections' + `manifests' -> unified `items'
;;
;; What is *not* covered: annotation lists/ranges beyond the common
;; shapes, services declared by custom extensions, and anything that
;; the upstream v2 didn't actually contain.  The return value is an
;; alist suitable for `json-encode'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'xiiif-core)


;;; ---------- generic helpers ----------

(defconst xiiif-upgrade--context
  "http://iiif.io/api/presentation/3/context.json")

(defun xiiif-upgrade--vector (x)
  "Wrap X in a one-element vector unless it already is a vector."
  (cond
   ((null x) [])
   ((vectorp x) x)
   (t (vector x))))

(defun xiiif-upgrade--label->map (label)
  "Return a IIIF v3 language-map alist for LABEL.
LABEL can be nil, a plain string, a vector of strings, or an
existing language-map alist.  Plain and vector inputs default to
the `none' language tag."
  (cond
   ((null label) nil)
   ((stringp label) `((none . ,(vector label))))
   ((vectorp label)
    `((none . ,(apply #'vector (mapcar (lambda (v)
                                         (if (stringp v) v (format "%s" v)))
                                       (append label nil))))))
   ((consp label)
    (if (and (consp (car label)) (symbolp (caar label)))
        ;; Already a language-map shape; coerce each value to a vector.
        (mapcar (lambda (pair)
                  (cons (car pair)
                        (xiiif-upgrade--vector (cdr pair))))
                label)
      ;; Single object { "@value": "x" } form.
      (let ((v (xiiif--get label 'value)))
        (if v `((none . ,(vector v))) nil))))
   (t nil)))

(defun xiiif-upgrade--type (type)
  "Strip `sc:' from TYPE and normalise to a plain string."
  (xiiif--normalize-type type))


;;; ---------- canvas upgrade ----------

(defun xiiif-upgrade--painting-annotation (canvas-id body)
  "Build a v3 AnnotationPage wrapping BODY as a painting annotation on CANVAS-ID."
  (let ((annotation
         `((id . ,(concat canvas-id "/annotation/1"))
           (type . "Annotation")
           (motivation . "painting")
           (target . ,canvas-id)
           (body . ,body))))
    `((id . ,(concat canvas-id "/page/1"))
      (type . "AnnotationPage")
      (items . ,(vector annotation)))))

(defun xiiif-upgrade--image-body (body)
  "Upgrade an image BODY (resource in v2, body in v3) to v3 shape."
  (let ((id      (or (xiiif--get body 'id) (xiiif--get body 'source)))
        (type    (or (xiiif-upgrade--type (xiiif--get body 'type))
                     "Image"))
        (format  (xiiif--get body 'format))
        (width   (xiiif--get body 'width))
        (height  (xiiif--get body 'height))
        (service (xiiif--as-list (xiiif--get body 'service))))
    (let (out)
      (when id      (push (cons 'id id) out))
      (push (cons 'type type) out)
      (when format  (push (cons 'format format) out))
      (when width   (push (cons 'width width) out))
      (when height  (push (cons 'height height) out))
      (when service
        (push (cons 'service
                    (apply #'vector
                           (mapcar #'xiiif-upgrade--service service)))
              out))
      (nreverse out))))

(defun xiiif-upgrade--service (service)
  "Upgrade a single image service SERVICE to v3 shape."
  (let ((id      (xiiif--get service 'id))
        (type    (xiiif--get service 'type))
        (profile (xiiif--get service 'profile)))
    (let (out)
      (when id (push (cons 'id id) out))
      (cond
       ((and (stringp type) (string-match-p "ImageService" type))
        (push (cons 'type type) out))
       ;; v2 carried the level as a profile URI; infer ImageService2.
       (t (push (cons 'type "ImageService2") out)))
      (when profile (push (cons 'profile profile) out))
      (nreverse out))))

(defun xiiif-upgrade--canvas (raw)
  "Upgrade a single raw canvas RAW to a v3 alist."
  (let* ((id     (xiiif--get raw 'id))
         (label  (xiiif-upgrade--label->map (xiiif--get raw 'label)))
         (width  (xiiif--get raw 'width))
         (height (xiiif--get raw 'height))
         (v3-body
          (or (let* ((page (car (xiiif--as-list (xiiif--get raw 'items))))
                     (anno (car (xiiif--as-list (xiiif--get page 'items)))))
                (xiiif--get anno 'body))
              (let ((res (xiiif--get
                          (car (xiiif--as-list (xiiif--get raw 'images)))
                          'resource)))
                (and res (xiiif-upgrade--image-body res))))))
    (let (out)
      (when id (push (cons 'id id) out))
      (push (cons 'type "Canvas") out)
      (when label  (push (cons 'label label) out))
      (when width  (push (cons 'width width) out))
      (when height (push (cons 'height height) out))
      (when (and id v3-body)
        (push (cons 'items
                    (vector
                     (xiiif-upgrade--painting-annotation id v3-body)))
              out))
      (nreverse out))))


;;; ---------- metadata + summary ----------

(defun xiiif-upgrade--metadata-pair (raw)
  "Upgrade one metadata entry RAW to v3 (label + value as language maps)."
  (let ((label (xiiif-upgrade--label->map (xiiif--get raw 'label)))
        (value (xiiif-upgrade--label->map (xiiif--get raw 'value))))
    (and label value
         `((label . ,label) (value . ,value)))))

(defun xiiif-upgrade--metadata (raw)
  "Return a vector of v3 metadata entries from RAW (a v2/v3 metadata array)."
  (apply #'vector
         (delq nil
               (mapcar #'xiiif-upgrade--metadata-pair
                       (xiiif--as-list raw)))))


;;; ---------- public: manifest ----------

;;;###autoload
(defun xiiif-upgrade-manifest (json)
  "Return a v3-shaped alist equivalent to the IIIF manifest JSON.
Tolerant of v2 sequences, v2 images, `sc:' types and plain-string
labels; passes already-v3 shapes through with light normalisation.
Does not mutate JSON."
  (unless (xiiif-manifest-p-json json)
    (signal 'xiiif-parse-error
            (list "upgrade-manifest" "not a IIIF manifest")))
  (let* ((id       (xiiif--get json 'id))
         (label    (xiiif-upgrade--label->map (xiiif--get json 'label)))
         (summary  (xiiif-upgrade--label->map
                    (or (xiiif--get json 'summary)
                        (xiiif--get json 'description))))
         (metadata (xiiif-upgrade--metadata (xiiif--get json 'metadata)))
         (raw-canvases (or (xiiif--as-list (xiiif--get json 'items))
                           (let* ((seqs (xiiif--as-list
                                         (xiiif--get json 'sequences)))
                                  (first (car seqs)))
                             (xiiif--as-list
                              (xiiif--get first 'canvases)))))
         (items    (apply #'vector
                          (mapcar #'xiiif-upgrade--canvas raw-canvases))))
    (let (out)
      (push (cons '@context xiiif-upgrade--context) out)
      (when id (push (cons 'id id) out))
      (push (cons 'type "Manifest") out)
      (when label   (push (cons 'label label) out))
      (when summary (push (cons 'summary summary) out))
      (when (> (length metadata) 0)
        (push (cons 'metadata metadata) out))
      (push (cons 'items items) out)
      (nreverse out))))

;;;###autoload
(defun xiiif-upgrade-collection (json)
  "Return a v3-shaped alist equivalent to the IIIF collection JSON.
v2 `collections' + `manifests' are merged into a single v3 `items'
array (collections first, then manifests)."
  (unless (xiiif-collection-p-json json)
    (signal 'xiiif-parse-error
            (list "upgrade-collection" "not a IIIF collection")))
  (let* ((id      (xiiif--get json 'id))
         (label   (xiiif-upgrade--label->map (xiiif--get json 'label)))
         (summary (xiiif-upgrade--label->map
                   (or (xiiif--get json 'summary)
                       (xiiif--get json 'description))))
         (raw-items
          (or (xiiif--as-list (xiiif--get json 'items))
              (append (xiiif--as-list (xiiif--get json 'collections))
                      (xiiif--as-list (xiiif--get json 'manifests)))))
         (items
          (apply #'vector
                 (mapcar
                  (lambda (raw)
                    (let ((cid   (xiiif--get raw 'id))
                          (ctype (xiiif-upgrade--type
                                  (xiiif--get raw 'type)))
                          (clbl  (xiiif-upgrade--label->map
                                  (xiiif--get raw 'label))))
                      (let (entry)
                        (when cid (push (cons 'id cid) entry))
                        (push (cons 'type (or ctype "Manifest")) entry)
                        (when clbl (push (cons 'label clbl) entry))
                        (nreverse entry))))
                  raw-items))))
    (let (out)
      (push (cons '@context xiiif-upgrade--context) out)
      (when id (push (cons 'id id) out))
      (push (cons 'type "Collection") out)
      (when label   (push (cons 'label label) out))
      (when summary (push (cons 'summary summary) out))
      (push (cons 'items items) out)
      (nreverse out))))

(provide 'xiiif-upgrade)
;;; xiiif-upgrade.el ends here
