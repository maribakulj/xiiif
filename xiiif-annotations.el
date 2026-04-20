;;; xiiif-annotations.el --- IIIF non-painting annotation fetch -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Fetch and normalize IIIF non-painting annotations declared in a
;; canvas's `annotations' array (v3) - typically commenting, tagging
;; or transcribing bodies referencing the canvas as their target.
;; Only `AnnotationPage' items are handled; a bare
;; `AnnotationCollection' reference is a later task (pagination).

;;; Code:

(require 'cl-lib)
(require 'xiiif-core)
(require 'xiiif-api)

(cl-defstruct xiiif-annotation
  "Normalized IIIF Web Annotation (W3C)."
  id motivation target body-value body-type body-lang raw)


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
  (let ((body (xiiif--get json 'body)))
    (make-xiiif-annotation
     :id         (xiiif--get json 'id)
     :motivation (xiiif--get json 'motivation)
     :target     (xiiif-annotation--target-id (xiiif--get json 'target))
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
Only AnnotationPage entries are recognised; AnnotationCollection
objects without inline items are returned as external URL refs."
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
the final list of `xiiif-annotation' structs in document order."
  (let* ((refs (xiiif-canvas-annotation-refs canvas))
         (slots (make-vector (length refs) nil))
         (pending 0)
         (finish
          (lambda ()
            (funcall callback
                     (apply #'append (append slots nil))))))
    (if (null refs)
        (funcall callback nil)
      (cl-loop
       for ref in refs
       for i from 0
       do
       (let ((inline (plist-get ref :inline))
             (url    (plist-get ref :url)))
         (cond
          (inline
           (aset slots i (xiiif-parse-annotation-page inline)))
          (url
           (cl-incf pending)
           (let ((idx i))
             (xiiif-api-fetch-json-async
              url
              (lambda (json)
                (aset slots idx (xiiif-parse-annotation-page json))
                (cl-decf pending)
                (when (zerop pending) (funcall finish)))
              (lambda (_err)
                (aset slots idx nil)
                (cl-decf pending)
                (when (zerop pending) (funcall finish))))))
          (t (aset slots i nil)))))
      (when (zerop pending) (funcall finish)))))

(provide 'xiiif-annotations)
;;; xiiif-annotations.el ends here
