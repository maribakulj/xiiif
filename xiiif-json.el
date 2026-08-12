;;; xiiif-json.el --- JSON decoding with bounded nesting for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; One decoder for every JSON that enters xiiif from outside: HTTP
;; responses and pasted Content State alike.  It exists for the bound
;; the fetch layer could not give:
;; `xiiif-api-max-body-size' caps how many bytes arrive, and nothing
;; capped how deeply they nest.
;;
;; The risk is not the parser.  Both readers already refuse absurd
;; nesting - the native one by its own depth guard, the Elisp one by
;; `max-lisp-eval-depth' - and both failures arrive as
;; `xiiif-parse-error'.  The risk is what a document that parses
;; *successfully* at two thousand levels does to the recursive walkers
;; downstream: the v2/v3 upgrade, the selector reader, the renderers.
;; Each would fail far from the fetch, with an error naming none of
;; this.  So the limit is on what enters the model, not on what the
;; parser will tolerate, and it is ours to choose rather than
;; whichever bound the running Emacs happens to compile in.
;;
;; `xiiif-json-depth-ok-p' walks with an explicit stack.  A recursive
;; depth check on hostile input would exhaust the very stack it is
;; meant to protect - the check would become the vulnerability.

;;; Code:

(require 'json)
(require 'xiiif-errors)

(defcustom xiiif-json-max-depth 100
  "Maximum container nesting accepted in JSON decoded by xiiif.

Depth counts objects and arrays: {\"a\": 1} is 1, {\"a\": {\"b\": 1}}
is 2.  Real IIIF stays an order of magnitude below the default - a
Collection of Manifests of Canvases of AnnotationPages is under ten,
and deeply hierarchical Ranges rarely pass twenty.  A document past
this limit fails with `xiiif-json-too-deep' rather than reaching the
recursive walkers.  Set to nil to disable the guard."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'xiiif)

(defun xiiif-json-depth-ok-p (value &optional limit)
  "Return non-nil when VALUE nests no deeper than LIMIT containers.
LIMIT defaults to `xiiif-json-max-depth', and a nil limit - however
it arrives - means no bound.  VALUE is decoded JSON in xiiif's
shapes: alists for objects, vectors for arrays.  Walks iteratively
and stops at the first breach."
  (let ((limit (or limit xiiif-json-max-depth)))
    (or (null limit)
        (let ((stack (list (cons value 1)))
              (ok t))
          (while (and ok stack)
            (let* ((entry (pop stack))
                   (node (car entry))
                   (depth (cdr entry)))
              ;; Only containers count towards depth; a scalar child is
              ;; pushed, found uninteresting here, and dropped.
              (cond
               ((vectorp node)
                (if (> depth limit)
                    (setq ok nil)
                  (dotimes (i (length node))
                    (push (cons (aref node i) (1+ depth)) stack))))
               ((consp node)
                (if (> depth limit)
                    (setq ok nil)
                  (dolist (cell node)
                    (push (cons (cdr cell) (1+ depth)) stack)))))))
          ok))))

(defun xiiif-json--decode (text)
  "Decode TEXT as JSON into xiiif's shapes.
Uses the native `json-parse-string' when the running Emacs provides
it (much faster on large manifests), configured to produce what the
pure-Elisp reader produces: alists with symbol keys, vectors,
`:json-false' for false and nil for null."
  (if (fboundp 'json-parse-string)
      (json-parse-string text
                         :object-type 'alist
                         :array-type 'array
                         :null-object nil
                         :false-object :json-false)
    (let ((json-object-type 'alist)
          (json-array-type  'vector)
          (json-key-type    'symbol)
          (json-false       :json-false)
          (json-null        nil))
      (json-read-from-string text))))

(defun xiiif-json-parse (text &optional context)
  "Decode TEXT as JSON, or signal an error carrying CONTEXT.

CONTEXT identifies the source in the error - a URL for a fetch, the
original string for a pasted token.  Signals `xiiif-parse-error' on
malformed input and `xiiif-json-too-deep' - itself a
`xiiif-parse-error', so existing handlers keep working - when the
document nests past `xiiif-json-max-depth'."
  (let ((value (condition-case err
                   (xiiif-json--decode text)
                 (error
                  (signal 'xiiif-parse-error
                          (list context (error-message-string err)))))))
    (unless (xiiif-json-depth-ok-p value)
      (signal 'xiiif-json-too-deep (list context xiiif-json-max-depth)))
    value))

(provide 'xiiif-json)
;;; xiiif-json.el ends here
