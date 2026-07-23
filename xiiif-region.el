;;; xiiif-region.el --- Canvas region parsing for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A `xiiif-region' is the "which part of the canvas" carried by an
;; annotation target or a search hit: an (x y w h) rectangle plus a
;; UNIT of either `pixel' (the default, canvas full-resolution
;; pixels) or `percent' (relative to the canvas box).  The parsers
;; recover it from the two shapes real IIIF uses:
;;
;;   * a Media Fragments hash on a string target,
;;       .../canvas/1#xywh=100,200,300,400
;;       .../canvas/1#xywh=percent:10,20,30,40
;;   * a structured selector - the v3 `SpecificResource' with a
;;     `FragmentSelector', and the v2 `on'/`full' + `selector' shape
;;     search responses use.
;;
;; This is the load-bearing datum for the anchor format (Spec C): the
;; region is what lets the viewer, the notes and Mirador all look at
;; the same spot.  Keeping percent regions distinct from pixel ones
;; (rather than silently conflating them) lets a later consumer
;; convert with the canvas dimensions in hand.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'xiiif-core)

(cl-defstruct xiiif-region
  "A rectangular region of a canvas.
X, Y, W and H are numbers.  UNIT is `pixel' (canvas full-resolution
pixels, the default) or `percent' (relative to the canvas box)."
  x y w h (unit 'pixel))

(defun xiiif-region--parse-xywh (value)
  "Parse a Media Fragments xywh VALUE into a `xiiif-region', or nil.
VALUE is the part after `xywh=', e.g. \"100,200,300,400\" or
\"percent:10,20,30,40\".  Whitespace and a leading `pixel:' prefix
are tolerated."
  (when (stringp value)
    (let* ((trimmed (string-trim value))
           (unit 'pixel)
           (spec trimmed))
      (cond
       ((string-prefix-p "percent:" spec)
        (setq unit 'percent spec (substring spec (length "percent:"))))
       ((string-prefix-p "pixel:" spec)
        (setq spec (substring spec (length "pixel:")))))
      (let ((parts (split-string spec "," t "[ \t]+")))
        (when (= 4 (length parts))
          (let ((nums (mapcar #'xiiif-region--number parts)))
            (when (cl-every #'identity nums)
              (make-xiiif-region :x (nth 0 nums) :y (nth 1 nums)
                                 :w (nth 2 nums) :h (nth 3 nums)
                                 :unit unit))))))))

(defun xiiif-region--number (s)
  "Return S parsed as a number, or nil when it is not numeric.
Accepts integers and decimals (percent regions may be fractional)."
  (when (and (stringp s)
             (string-match-p "\\`-?[0-9]+\\(?:\\.[0-9]+\\)?\\'"
                             (string-trim s)))
    (string-to-number s)))

(defun xiiif-region-from-fragment (string)
  "Return the `xiiif-region' encoded in STRING's `#xywh=' fragment, or nil.
STRING may be a bare fragment (\"xywh=...\") or a URL that carries
one after `#'."
  (when (stringp string)
    (let ((frag (if (string-match "#\\(.*\\)\\'" string)
                    (match-string 1 string)
                  string)))
      (when (string-match "xywh=\\([^&]*\\)" frag)
        (xiiif-region--parse-xywh (match-string 1 frag))))))

(defun xiiif-region--from-selector (selector)
  "Return the `xiiif-region' described by a IIIF SELECTOR, or nil.
Handles a lone `FragmentSelector', an array of selectors (the first
usable one wins) and an `oa:Choice' with a `default'/`item'."
  (cond
   ((null selector) nil)
   ((vectorp selector)
    (cl-some #'xiiif-region--from-selector (append selector nil)))
   ((consp selector)
    (or (xiiif-region--from-selector (xiiif--get selector 'default))
        (xiiif-region--from-selector (xiiif--get selector 'item))
        (let ((value (xiiif--get selector 'value)))
          (and (stringp value)
               (or (xiiif-region-from-fragment value)
                   (xiiif-region--parse-xywh
                    (and (string-prefix-p "xywh=" value)
                         (substring value (length "xywh=")))))))))))

(defun xiiif-region-from-target (target)
  "Return the `xiiif-region' carried by an annotation TARGET, or nil.
Recognises a string target with a Media Fragments hash, a v3
`SpecificResource' with a `FragmentSelector', and the v2
`on'/`full' + `selector' shape.  Returns the region of the first
element of an array target."
  (cond
   ((null target) nil)
   ((stringp target) (xiiif-region-from-fragment target))
   ((vectorp target)
    (and (> (length target) 0)
         (xiiif-region-from-target (aref target 0))))
   ((consp target)
    (or (xiiif-region--from-selector (xiiif--get target 'selector))
        ;; A bare source/full/id may itself carry a fragment.
        (xiiif-region-from-fragment (xiiif--get target 'source))
        (xiiif-region-from-fragment (xiiif--get target 'full))
        (xiiif-region-from-fragment (xiiif--get target 'id))))))

(defun xiiif-region-to-string (region)
  "Return REGION as a compact display string, or nil.
Integers print without a decimal point; a percent region gains a
trailing `%'."
  (when (xiiif-region-p region)
    (let ((fmt (lambda (n) (if (integerp n)
                               (number-to-string n)
                             (format "%s" n)))))
      (format "%s,%s,%s,%s%s"
              (funcall fmt (xiiif-region-x region))
              (funcall fmt (xiiif-region-y region))
              (funcall fmt (xiiif-region-w region))
              (funcall fmt (xiiif-region-h region))
              (if (eq (xiiif-region-unit region) 'percent) "%" "")))))

(defun xiiif-region-to-fragment (region)
  "Return REGION as a Media Fragments value, or nil.
A pixel region becomes \"xywh=X,Y,W,H\"; a percent region becomes
\"xywh=percent:X,Y,W,H\".  This is the form used in a canvas
fragment identifier (Content State targets), distinct from the
Image API `pct:' segment of `xiiif-region-to-image-api'."
  (when (xiiif-region-p region)
    (format "xywh=%s%s,%s,%s,%s"
            (if (eq (xiiif-region-unit region) 'percent) "percent:" "")
            (xiiif-region-x region) (xiiif-region-y region)
            (xiiif-region-w region) (xiiif-region-h region))))

(defun xiiif-region-to-image-api (region)
  "Return REGION as an Image API `region' path segment.
A pixel region becomes \"X,Y,W,H\"; a percent region becomes
\"pct:X,Y,W,H\".  Returns nil for a nil REGION."
  (when (xiiif-region-p region)
    (let ((core (format "%s,%s,%s,%s"
                        (xiiif-region-x region) (xiiif-region-y region)
                        (xiiif-region-w region) (xiiif-region-h region))))
      (if (eq (xiiif-region-unit region) 'percent)
          (concat "pct:" core)
        core))))

(provide 'xiiif-region)
;;; xiiif-region.el ends here
