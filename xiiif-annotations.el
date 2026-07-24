;;; xiiif-annotations.el --- IIIF non-painting annotation fetch -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Fetch and normalize IIIF non-painting annotations declared in a
;; canvas's `annotations' array (v3) - typically commenting, tagging
;; or transcribing bodies referencing the canvas as their target.
;; Both inline and external `AnnotationPage' references are handled,
;; as is an external `AnnotationCollection', descended via `first'
;; and paginated through `next' up to `xiiif-annotations-max-pages'.

;;; Code:

(require 'cl-lib)
(require 'xiiif-core)
(require 'xiiif-region)
(require 'xiiif-api)
(require 'xiiif-fetch)

(cl-defstruct xiiif-annotation
  "Normalized IIIF Web Annotation (W3C).
REGION is the `xiiif-region' carried by the target, or nil when the
annotation targets the whole canvas."
  id motivation target region body-value body-type body-lang raw)


;;; ---------- body and target helpers ----------

(defun xiiif--annotation-body-first (body)
  "Return the first element of BODY when it is an array, else BODY."
  (cond
   ((null body) nil)
   ((vectorp body) (and (> (length body) 0) (aref body 0)))
   (t body)))

(defun xiiif-annotation--body-value (body)
  "Extract a printable string from the annotation BODY, or nil."
  (let ((b (xiiif--annotation-body-first body)))
    (cond
     ((stringp b) b)
     ((consp b) (xiiif--get b 'value))
     (t nil))))

(defun xiiif-annotation--body-type (body)
  "Return the type of BODY (e.g. \"TextualBody\") or nil."
  (let ((b (xiiif--annotation-body-first body)))
    (and (consp b) (xiiif--normalize-type (xiiif--get b 'type)))))

(defun xiiif-annotation--body-lang (body)
  "Return the language tag of BODY or nil."
  (let ((b (xiiif--annotation-body-first body)))
    (and (consp b) (xiiif--get b 'language))))

(defun xiiif-annotation--target-id (target)
  "Return the canvas URI targeted by TARGET, or nil."
  (cond
   ((stringp target) target)
   ((vectorp target)
    (and (> (length target) 0)
         (xiiif-annotation--target-id (aref target 0))))
   ((consp target) (or (xiiif--get target 'source)
                       (xiiif--get target 'id)))))


;;; ---------- parsing ----------

(defun xiiif-parse-annotation (json)
  "Parse JSON into a `xiiif-annotation' struct."
  (let ((body   (xiiif--get json 'body))
        (target (xiiif--get json 'target)))
    (make-xiiif-annotation
     :id         (xiiif--get json 'id)
     :motivation (xiiif--get json 'motivation)
     :target     (xiiif-annotation--target-id target)
     :region     (xiiif-region-from-target target)
     :body-value (xiiif-annotation--body-value body)
     :body-type  (xiiif-annotation--body-type  body)
     :body-lang  (xiiif-annotation--body-lang  body)
     :raw        json)))

(defun xiiif-parse-annotation-page (json)
  "Return a list of `xiiif-annotation' parsed from an AnnotationPage JSON."
  (mapcar #'xiiif-parse-annotation
          (xiiif--as-list (xiiif--get json 'items))))

(defun xiiif-canvas-annotation-refs (canvas)
  "Return a list of annotation-page references attached to CANVAS.
Each entry is a plist:
  (:inline PAGE-JSON :url nil)   when the page is embedded, or
  (:inline nil       :url URL)   when only a URL reference is present.
An AnnotationCollection without inline items is returned as an
external URL ref; `xiiif-annotations-fetch-ref' paginates it."
  (let ((annos (xiiif--as-list
                (xiiif--get (xiiif-canvas-raw canvas) 'annotations))))
    (mapcar (lambda (a)
              (if (xiiif--get a 'items)
                  (list :inline a :url nil)
                (list :inline nil :url (xiiif--get a 'id))))
            annos)))


;;; ---------- orchestrated fetch ----------

(defun xiiif-annotations-collect (canvas callback)
  "Resolve every annotation attached to CANVAS and call CALLBACK.
Inline AnnotationPages are parsed immediately; external references
are fetched asynchronously.  CALLBACK is invoked exactly once with
the final list of `xiiif-annotation' structs in document order.

The fetch dispatch is two-phase: inline pages are parsed and the
external references collected first, then every fetch is issued
with the pending count already at its final value.  An errback that
runs synchronously (e.g. on an invalid URL) therefore cannot drive
the count to zero while later fetches are still waiting to start."
  (let* ((refs (xiiif-canvas-annotation-refs canvas))
         (slots (make-vector (length refs) nil))
         (fetches nil))
    (cl-loop
     for ref in refs
     for i from 0
     do
     (let ((inline (plist-get ref :inline))
           (url    (plist-get ref :url)))
       (cond
        (inline (aset slots i (xiiif-parse-annotation-page inline)))
        (url    (push (cons i url) fetches)))))
    (if (null fetches)
        (funcall callback (apply #'append (append slots nil)))
      (let* ((pending (length fetches))
             (done nil)
             (finish
              (lambda ()
                (unless done
                  (setq done t)
                  (funcall callback
                           (apply #'append (append slots nil)))))))
        (dolist (spec (nreverse fetches))
          (let ((idx (car spec)))
            (xiiif-annotations-fetch-ref
             (cdr spec)
             (lambda (annos)
               (aset slots idx annos)
               (when (zerop (cl-decf pending)) (funcall finish)))
             (lambda (_err)
               (aset slots idx nil)
               (when (zerop (cl-decf pending)) (funcall finish))))))))))


;;; ---------- external reference fetch with pagination ----------

(defcustom xiiif-annotations-max-pages 20
  "Maximum number of AnnotationPage links followed via `next'.
A safety bound on paginated AnnotationCollections; nil follows
every page."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'xiiif)

(defun xiiif-annotations--page-next (json)
  "Return the `next' AnnotationPage URL of JSON, or nil."
  (let ((next (xiiif--get json 'next)))
    (cond
     ((stringp next) next)
     ((consp next) (xiiif--get next 'id)))))

(defun xiiif-annotations--collection-first (json)
  "Return the `first' page of an AnnotationCollection JSON, or nil.
The value is a page URL string, an embedded AnnotationPage object,
or nil when JSON is not an AnnotationCollection."
  (when (equal (xiiif--normalize-type (xiiif--get json 'type))
               "AnnotationCollection")
    (let ((first (xiiif--get json 'first)))
      (cond
       ((stringp first) first)
       ((consp first) first)))))

(defun xiiif-annotations-fetch-ref (url callback errback)
  "Fetch an external annotation reference URL and call CALLBACK.
Handles a plain AnnotationPage (optionally chained by `next') and an
AnnotationCollection (descended via `first', then `next'), following
at most `xiiif-annotations-max-pages' pages.  CALLBACK receives the
combined list of `xiiif-annotation' structs."
  (xiiif-fetch-json
   url
   (lambda (json)
     (xiiif-annotations--follow json callback errback nil 1))
   :errback errback))

(defun xiiif-annotations--follow (json callback errback acc page)
  "Process an AnnotationPage/Collection JSON, accumulating into ACC.
Descends an AnnotationCollection to its first page, then follows the
`next' chain up to `xiiif-annotations-max-pages'."
  (let ((first (xiiif-annotations--collection-first json)))
    (cond
     ((stringp first)
      (xiiif-fetch-json
       first
       (lambda (j) (xiiif-annotations--follow j callback errback acc page))
       :errback errback))
     (first
      (xiiif-annotations--follow first callback errback acc page))
     (t
      (let ((acc (append acc (xiiif-parse-annotation-page json)))
            (next (xiiif-annotations--page-next json)))
        (if (and next
                 (or (null xiiif-annotations-max-pages)
                     (< page xiiif-annotations-max-pages)))
            (xiiif-fetch-json
             next
             (lambda (j)
               (xiiif-annotations--follow j callback errback acc (1+ page)))
             :errback errback)
          (funcall callback acc)))))))

(provide 'xiiif-annotations)
;;; xiiif-annotations.el ends here
