;;; xiiif-view.el --- Region viewer model and geometry -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The data model of the step-by-step region viewer (Spec B): what a
;; view shows, and how that maps to an Image API request.  Rendering
;; and key navigation live elsewhere; this file is pure, testable
;; geometry.
;;
;; A `xiiif-view-state' names a rectangle of a canvas in CANONICAL
;; full-resolution canvas pixels (never screen pixels), plus a zoom
;; LEVEL - an index into a scale table derived from the image
;; `info.json' (its `sizes'/`tiles'/compliance) or a default table -
;; and a ROTATION.  Being plain data, a state serialises to an alist
;; that the agent (Spec D) and anchors (Spec C) read and write.
;;
;; `xiiif-view-image-request' turns a state into the Image API
;; `region'/`size' segments and the display `:scale', honouring:
;;  - level-0 servers: the region is never cropped and the size is
;;    snapped to an advertised one (M6), so no URL 404s;
;;  - HiDPI: physical pixels are requested and shown at 1/factor;
;;  - a prefetch MARGIN that grows the region, clamped to the canvas.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'xiiif-core)
(require 'xiiif-region)
(require 'xiiif-image)

(cl-defstruct xiiif-view-state
  "A view onto a canvas region.
X, Y, W and H are the region in full-resolution canvas pixels.
LEVEL indexes the zoom scale table (see `xiiif-view-scales').
ROTATION is degrees.  MANIFEST-URL and CANVAS-ID locate the source."
  manifest-url canvas-id x y w h (level 0) (rotation 0))

(defconst xiiif-view-default-scales '(0.0625 0.125 0.25 0.5 1.0)
  "Fallback zoom scales (1/16 .. 1) when info.json advertises none.
Each is a resolution fraction: displayed detail per canvas pixel.")


;;; ---------- serialisation ----------

(defun xiiif-view-state-to-alist (state)
  "Return STATE as a serialisable alist."
  `((manifest-url . ,(xiiif-view-state-manifest-url state))
    (canvas-id    . ,(xiiif-view-state-canvas-id state))
    (x            . ,(xiiif-view-state-x state))
    (y            . ,(xiiif-view-state-y state))
    (w            . ,(xiiif-view-state-w state))
    (h            . ,(xiiif-view-state-h state))
    (level        . ,(xiiif-view-state-level state))
    (rotation     . ,(xiiif-view-state-rotation state))))

(defun xiiif-view-state-from-alist (alist)
  "Return a `xiiif-view-state' built from ALIST."
  (make-xiiif-view-state
   :manifest-url (alist-get 'manifest-url alist)
   :canvas-id    (alist-get 'canvas-id alist)
   :x            (alist-get 'x alist)
   :y            (alist-get 'y alist)
   :w            (alist-get 'w alist)
   :h            (alist-get 'h alist)
   :level        (or (alist-get 'level alist) 0)
   :rotation     (or (alist-get 'rotation alist) 0)))


;;; ---------- zoom scale table ----------

(defun xiiif-view-scales (info)
  "Return the ascending zoom scale table for INFO, a `xiiif-image-info'.
Derived from the advertised `sizes' (each width over the full
width), else from tile `scaleFactors' (1/factor), else
`xiiif-view-default-scales'.  Always ends at 1.0 (full resolution)
and contains no duplicates."
  (let* ((full-w (and info (xiiif-image-info-width info)))
         (raw
          (cond
           ((and info full-w (xiiif-image-info-sizes info))
            (cl-loop for s in (xiiif-image-info-sizes info)
                     for w = (xiiif--get s 'width)
                     when (and w (> w 0))
                     collect (/ (float w) full-w)))
           ((and info (xiiif-image-info-tiles info))
            (cl-loop for tile in (xiiif-image-info-tiles info)
                     append (cl-loop for sf in (xiiif--as-list
                                                (xiiif--get tile 'scaleFactors))
                                     when (and (numberp sf) (> sf 0))
                                     collect (/ 1.0 sf))))
           (t (copy-sequence xiiif-view-default-scales))))
         (scales (delete-dups (sort (cons 1.0 (mapcar (lambda (s) (min s 1.0))
                                                      raw))
                                    #'<))))
    scales))

(defun xiiif-view-scale-at (info level)
  "Return the scale fraction for zoom LEVEL under INFO.
LEVEL is clamped to the bounds of the scale table."
  (let* ((scales (xiiif-view-scales info))
         (n (length scales))
         (idx (max 0 (min level (1- n)))))
    (nth idx scales)))

(defun xiiif-view-max-level (info)
  "Return the highest valid zoom level index for INFO."
  (1- (length (xiiif-view-scales info))))


;;; ---------- geometry ----------

(defun xiiif-view--clamp-region (x y w h full-w full-h)
  "Clamp region X Y W H to stay within FULL-W by FULL-H.
FULL-W/FULL-H may be nil, in which case that axis is left as-is."
  (let* ((x (max 0 x))
         (y (max 0 y))
         (w (if full-w (min w (- full-w x)) w))
         (h (if full-h (min h (- full-h y)) h)))
    (list (round x) (round y) (round (max 1 w)) (round (max 1 h)))))

(defun xiiif-view--expand-region (x y w h margin full-w full-h)
  "Grow region X Y W H by MARGIN fraction each side, clamped to full.
MARGIN 0 is a no-op; MARGIN 1.0 adds a full W (H) on each side."
  (let ((dx (* margin w))
        (dy (* margin h)))
    (xiiif-view--clamp-region (- x dx) (- y dy)
                              (+ w (* 2 dx)) (+ h (* 2 dy))
                              full-w full-h)))

(cl-defun xiiif-view-image-request (state &key info (hidpi 1.0) (margin 0.0))
  "Return the Image API request plist for STATE.

Keys in the result:
  :region   Image API region segment (\"x,y,w,h\" or \"full\").
  :size     Image API size segment.
  :rotation rotation segment.
  :scale    display scale for `create-image' (1/HIDPI).
  :width    :height  requested output pixels.

INFO (a `xiiif-image-info' or nil) supplies the canvas dimensions,
the zoom scale table and the compliance level.  HIDPI multiplies the
requested pixels (physical pixels shown at 1/HIDPI logical size).
MARGIN grows the requested region for prefetching.

On a level-0 server the region is forced to `full' and the size is
snapped to the advertised set, so no request escapes what the server
serves."
  (let* ((full-w (and info (xiiif-image-info-width info)))
         (full-h (and info (xiiif-image-info-height info)))
         (region (xiiif-view--expand-region
                  (xiiif-view-state-x state) (xiiif-view-state-y state)
                  (xiiif-view-state-w state) (xiiif-view-state-h state)
                  margin full-w full-h))
         (rx (nth 0 region)) (ry (nth 1 region))
         (rw (nth 2 region)) (rh (nth 3 region))
         (scale (xiiif-view-scale-at info (xiiif-view-state-level state)))
         (rotation (or (xiiif-view-state-rotation state) 0)))
    (if (and info (xiiif-image-info-level0-p info))
        ;; Level 0: whole image only, size from the advertised set.
        (let* ((target (round (* (or full-w rw) scale hidpi)))
               (best (xiiif-image-closest-size info (max 1 target))))
          (list :region "full"
                :size (if best (plist-get best :segment) "max")
                :rotation (number-to-string rotation)
                :scale (/ 1.0 hidpi)
                :width (and best (plist-get best :width))
                :height (and best (plist-get best :height))))
      ;; Level >= 1: crop the region, request it at LEVEL x HIDPI,
      ;; capped at native (no upscaling past canvas resolution).
      (let* ((out-w (max 1 (min (round (* rw scale hidpi)) rw)))
             (out-h (max 1 (min (round (* rh scale hidpi)) rh))))
        (list :region (format "%d,%d,%d,%d" rx ry rw rh)
              :size (format "%d,%d" out-w out-h)
              :rotation (number-to-string rotation)
              :scale (/ 1.0 hidpi)
              :width out-w :height out-h)))))

(cl-defun xiiif-view-image-url (state service &key info hidpi margin format quality)
  "Return the Image API URL for STATE against SERVICE.
INFO, HIDPI and MARGIN are passed to `xiiif-view-image-request';
FORMAT and QUALITY override the Image API defaults."
  (let ((req (xiiif-view-image-request
              state :info info
              :hidpi (or hidpi 1.0) :margin (or margin 0.0))))
    (xiiif-image-url service
                     :region (plist-get req :region)
                     :size (plist-get req :size)
                     :rotation (plist-get req :rotation)
                     :quality quality
                     :format format)))


;;; ---------- anchor bridge ----------

(defun xiiif-view-state-region (state)
  "Return STATE's region as a `xiiif-region' (pixel unit)."
  (make-xiiif-region :x (xiiif-view-state-x state)
                     :y (xiiif-view-state-y state)
                     :w (xiiif-view-state-w state)
                     :h (xiiif-view-state-h state)
                     :unit 'pixel))

(provide 'xiiif-view)
;;; xiiif-view.el ends here
