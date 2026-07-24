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
(require 'image)
(require 'xiiif-core)
(require 'xiiif-region)
(require 'xiiif-image)
(require 'xiiif-fetch)
(require 'xiiif-anchor)

;; Defined in xiiif.el; referenced lazily for the Mirador handoff.
(defvar xiiif-mirador-base-url)

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


;;; ---------- navigation math (pure) ----------

(defun xiiif-view--with-region (state region)
  "Return a copy of STATE whose x/y/w/h are set from REGION (a list)."
  (let ((s (copy-xiiif-view-state state)))
    (setf (xiiif-view-state-x s) (nth 0 region)
          (xiiif-view-state-y s) (nth 1 region)
          (xiiif-view-state-w s) (nth 2 region)
          (xiiif-view-state-h s) (nth 3 region))
    s))

(defun xiiif-view-fit-region (state info win-w win-h)
  "Return STATE resized so its region fills WIN-W by WIN-H logical px.
The region width is WIN-W / scale canvas pixels (scale from the
zoom level); the centre is preserved and the result clamped to the
canvas.  WIN-W/WIN-H are display-area pixels."
  (let* ((scale (xiiif-view-scale-at info (xiiif-view-state-level state)))
         (cx (+ (xiiif-view-state-x state)
                (/ (xiiif-view-state-w state) 2.0)))
         (cy (+ (xiiif-view-state-y state)
                (/ (xiiif-view-state-h state) 2.0)))
         (rw (max 1 (round (/ win-w scale))))
         (rh (max 1 (round (/ win-h scale))))
         (full-w (and info (xiiif-image-info-width info)))
         (full-h (and info (xiiif-image-info-height info))))
    (xiiif-view--with-region
     state
     (xiiif-view--clamp-region (- cx (/ rw 2.0)) (- cy (/ rh 2.0))
                               rw rh full-w full-h))))

(defun xiiif-view-pan (state info dx-frac dy-frac)
  "Return STATE panned by DX-FRAC x W and DY-FRAC x H, clamped.
Positive DX-FRAC moves the view right, DY-FRAC down."
  (let* ((dx (round (* dx-frac (xiiif-view-state-w state))))
         (dy (round (* dy-frac (xiiif-view-state-h state))))
         (full-w (and info (xiiif-image-info-width info)))
         (full-h (and info (xiiif-image-info-height info))))
    (xiiif-view--with-region
     state
     (xiiif-view--clamp-region (+ (xiiif-view-state-x state) dx)
                               (+ (xiiif-view-state-y state) dy)
                               (xiiif-view-state-w state)
                               (xiiif-view-state-h state)
                               full-w full-h))))

(defun xiiif-view-zoom (state info delta win-w win-h)
  "Return STATE with zoom level changed by DELTA, refit to the window.
DELTA is clamped so the level stays within the scale table."
  (let* ((maxl (xiiif-view-max-level info))
         (new-level (max 0 (min (+ (xiiif-view-state-level state) delta) maxl)))
         (s (copy-xiiif-view-state state)))
    (setf (xiiif-view-state-level s) new-level)
    (xiiif-view-fit-region s info win-w win-h)))

(defun xiiif-view-neighbors (state info)
  "Return the four pan-neighbour states of STATE (for prefetch)."
  (delq nil
        (list (xiiif-view-pan state info -1.0 0)
              (xiiif-view-pan state info  1.0 0)
              (xiiif-view-pan state info 0 -1.0)
              (xiiif-view-pan state info 0  1.0))))


;;; ---------- interactive viewer ----------

(defcustom xiiif-view-cache-size 8
  "Number of decoded region images kept in the per-buffer LRU.
Emacs's own image cache evicts only by age, not size; this bounds
the viewer's memory and flushes evicted images."
  :type 'integer
  :group 'xiiif)

(defcustom xiiif-view-prefetch t
  "When non-nil, the viewer prefetches neighbouring regions at low priority."
  :type 'boolean
  :group 'xiiif)

(defcustom xiiif-view-idle-delay 0.15
  "Seconds of idle time before the sharp image request is issued.
Coalesces rapid pan/zoom so only the settled view is fetched."
  :type 'number
  :group 'xiiif)

;; image-size is a C primitive only present in a graphical build; the
;; sole caller wraps it in `ignore-errors' for the text-mode case.
(declare-function image-size "image" (spec &optional pixels frame))

(defconst xiiif-view--buffer "*XIIIF View*")

(defvar-local xiiif-view--state nil "The `xiiif-view-state' shown here.")
(defvar-local xiiif-view--service nil "Image service backing the view.")
(defvar-local xiiif-view--info nil "The `xiiif-image-info', or nil.")
(defvar-local xiiif-view--image nil "The image object currently displayed.")
(defvar-local xiiif-view--generation 0 "Bumped on each navigation.")
(defvar-local xiiif-view--group nil "Current fetch group symbol.")
(defvar-local xiiif-view--lru nil "List of (URL . IMAGE), most-recent first.")
(defvar-local xiiif-view--idle-timer nil "Pending coalesced-fetch timer.")

(defun xiiif-view--hidpi ()
  "Return the display scale factor, or 1.0 when it cannot be detected."
  (if (fboundp 'frame-scale-factor)
      (condition-case nil (float (frame-scale-factor)) (error 1.0))
    1.0))

(defun xiiif-view--window-pixels ()
  "Return (WIDTH . HEIGHT) of the view window body in pixels."
  (let ((win (get-buffer-window xiiif-view--buffer)))
    (if win
        (cons (window-body-width win t) (window-body-height win t))
      (cons 800 600))))


;;; ---- per-buffer image LRU ----

(defun xiiif-view--lru-get (url)
  "Return the cached image for URL, promoting it to most-recent."
  (when-let ((cell (assoc url xiiif-view--lru)))
    (setq xiiif-view--lru (cons cell (delq cell xiiif-view--lru)))
    (cdr cell)))

(defun xiiif-view--lru-put (url image)
  "Cache IMAGE under URL, evicting and flushing the oldest over the cap."
  (setq xiiif-view--lru
        (cons (cons url image)
              (cl-remove url xiiif-view--lru :key #'car :test #'equal)))
  (when (> (length xiiif-view--lru) xiiif-view-cache-size)
    (dolist (cell (nthcdr xiiif-view-cache-size xiiif-view--lru))
      (when (and (fboundp 'image-flush) (cdr cell))
        (ignore-errors (image-flush (cdr cell)))))
    (setq xiiif-view--lru (cl-subseq xiiif-view--lru 0 xiiif-view-cache-size)))
  image)

(defun xiiif-view--make-image (bytes scale)
  "Return an image object from BYTES displayed at SCALE, or nil on failure.
Isolated so tests can substitute a stub for the graphics layer."
  (condition-case nil
      (create-image bytes nil t :scale scale)
    (error nil)))


;;; ---- request + display ----

(defun xiiif-view--url (state)
  "Return the Image API URL for STATE in the current buffer."
  (xiiif-view-image-url state xiiif-view--service
                        :info xiiif-view--info
                        :hidpi (xiiif-view--hidpi)
                        :margin 0.0))

(defun xiiif-view--display-image (image)
  "Replace the view buffer's content with IMAGE, centred."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (when image
      (let* ((win (get-buffer-window (current-buffer)))
             (iw (car (ignore-errors (image-size image t))))
             (pad (and win iw
                       (max 0 (/ (- (window-body-width win t) iw) 2)))))
        (when (and pad (> pad 0))
          (insert (propertize " " 'display `(space :width (,pad))))))
      (insert-image image))
    (insert "\n")
    (setq xiiif-view--image image)))

(defun xiiif-view--display-status (text)
  "Show TEXT as the view buffer content (used off graphic displays)."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize text 'face 'font-lock-comment-face) "\n")))

(defun xiiif-view--fetch-sharp (state generation)
  "Fetch the sharp image for STATE and display it when still current.
GENERATION guards against a response that a later navigation
superseded."
  (let ((url (xiiif-view--url state))
        (buffer (current-buffer))
        (scale (/ 1.0 (xiiif-view--hidpi))))
    (xiiif-fetch-bytes
     url
     (lambda (bytes)
       (when (and (buffer-live-p buffer)
                  (= generation (buffer-local-value
                                 'xiiif-view--generation buffer)))
         (with-current-buffer buffer
           (when-let ((image (xiiif-view--make-image bytes scale)))
             (xiiif-view--lru-put url image)
             (xiiif-view--display-image image)))))
     :group xiiif-view--group
     :cache t)))

(defun xiiif-view--prefetch (state)
  "Queue low-priority fetches of STATE's neighbouring regions."
  (when xiiif-view-prefetch
    (dolist (neighbor (xiiif-view-neighbors state xiiif-view--info))
      (xiiif-fetch-bytes
       (xiiif-view--url neighbor)
       #'ignore
       :group xiiif-view--group
       :priority 'prefetch
       :cache t))))

(defun xiiif-view--render (&optional proxy-scale)
  "Render the current state: cached image now, or a proxy then a fetch.
PROXY-SCALE, when non-nil, redisplays the image in hand at that
scale as an immediate low-fidelity stand-in while the sharp version
is fetched."
  (if (not (display-graphic-p))
      (xiiif-view--display-status
       (format "Region viewer needs a graphic display.\nImage URL: %s\nUse `xiiif-view-copy-url' (y) to copy it."
               (xiiif-view--url xiiif-view--state)))
    (let* ((url (xiiif-view--url xiiif-view--state))
           (cached (xiiif-view--lru-get url)))
      (cond
       (cached (xiiif-view--display-image cached))
       ((and proxy-scale xiiif-view--image)
        (xiiif-view--display-image
         (xiiif-view--rescale xiiif-view--image proxy-scale)))
       (t nil))
      (unless cached
        (xiiif-view--schedule-fetch)))))

(defun xiiif-view--rescale (image scale)
  "Return IMAGE with its display scale multiplied by SCALE (a proxy)."
  (let ((copy (copy-sequence image)))
    (setf (image-property copy :scale)
          (* (or (image-property image :scale) 1.0) scale))
    copy))

(defun xiiif-view--schedule-fetch ()
  "Debounce the sharp fetch and neighbour prefetch for the current view."
  (when (timerp xiiif-view--idle-timer)
    (cancel-timer xiiif-view--idle-timer))
  (let ((buffer (current-buffer))
        (state xiiif-view--state)
        (generation xiiif-view--generation))
    (setq xiiif-view--idle-timer
          (run-with-idle-timer
           xiiif-view-idle-delay nil
           (lambda ()
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when (= generation xiiif-view--generation)
                   (xiiif-view--fetch-sharp state generation)
                   (xiiif-view--prefetch state)))))))))

(defun xiiif-view--navigate (new-state &optional proxy-scale)
  "Move the viewer to NEW-STATE, cancelling the previous view's fetches.
PROXY-SCALE is forwarded to `xiiif-view--render' for an immediate
rescaled stand-in during zoom."
  (when xiiif-view--group
    (xiiif-fetch-cancel-group xiiif-view--group))
  (setq xiiif-view--state new-state)
  (cl-incf xiiif-view--generation)
  (setq xiiif-view--group (make-symbol
                           (format "xiiif-view-%d" xiiif-view--generation)))
  (xiiif-view--render proxy-scale))


;;; ---- commands ----

(defvar xiiif-view-mode-map
  (let ((map (make-sparse-keymap)))
    (dolist (k '("<left>" "h")) (define-key map (kbd k) #'xiiif-view-pan-left))
    (dolist (k '("<right>" "l")) (define-key map (kbd k) #'xiiif-view-pan-right))
    (dolist (k '("<up>" "k")) (define-key map (kbd k) #'xiiif-view-pan-up))
    (dolist (k '("<down>" "j")) (define-key map (kbd k) #'xiiif-view-pan-down))
    (dolist (k '("+" "=")) (define-key map (kbd k) #'xiiif-view-zoom-in))
    (define-key map (kbd "-") #'xiiif-view-zoom-out)
    (define-key map (kbd "0") #'xiiif-view-zoom-reset)
    (define-key map (kbd "y") #'xiiif-view-copy-url)
    (define-key map (kbd "M") #'xiiif-view-open-in-mirador)
    (define-key map (kbd "a") #'xiiif-view-annotate)
    (define-key map (kbd "g") #'xiiif-view-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `xiiif-view-mode'.")

(define-derived-mode xiiif-view-mode special-mode "XIIIF-View"
  "Major mode for the step-by-step IIIF region viewer."
  (buffer-disable-undo)
  (setq-local cursor-type nil)
  (setq-local truncate-lines t))

(defun xiiif-view--pan-step (fine)
  "Return the pan fraction: half a screen, or a fine step with FINE."
  (if fine 0.1 0.5))

(defun xiiif-view-pan-left (&optional fine)
  "Pan the view left by half a screen (FINE: a small step)."
  (interactive "P")
  (xiiif-view--navigate
   (xiiif-view-pan xiiif-view--state xiiif-view--info
                   (- (xiiif-view--pan-step fine)) 0)))

(defun xiiif-view-pan-right (&optional fine)
  "Pan the view right by half a screen (FINE: a small step)."
  (interactive "P")
  (xiiif-view--navigate
   (xiiif-view-pan xiiif-view--state xiiif-view--info
                   (xiiif-view--pan-step fine) 0)))

(defun xiiif-view-pan-up (&optional fine)
  "Pan the view up by half a screen (FINE: a small step)."
  (interactive "P")
  (xiiif-view--navigate
   (xiiif-view-pan xiiif-view--state xiiif-view--info
                   0 (- (xiiif-view--pan-step fine)))))

(defun xiiif-view-pan-down (&optional fine)
  "Pan the view down by half a screen (FINE: a small step)."
  (interactive "P")
  (xiiif-view--navigate
   (xiiif-view-pan xiiif-view--state xiiif-view--info
                   0 (xiiif-view--pan-step fine))))

(defun xiiif-view-zoom-in ()
  "Zoom in one level, refitting to the window."
  (interactive)
  (let ((win (xiiif-view--window-pixels)))
    (xiiif-view--navigate
     (xiiif-view-zoom xiiif-view--state xiiif-view--info 1
                      (car win) (cdr win))
     2.0)))

(defun xiiif-view-zoom-out ()
  "Zoom out one level, refitting to the window."
  (interactive)
  (let ((win (xiiif-view--window-pixels)))
    (xiiif-view--navigate
     (xiiif-view-zoom xiiif-view--state xiiif-view--info -1
                      (car win) (cdr win))
     0.5)))

(defun xiiif-view-zoom-reset ()
  "Reset the zoom to fit the whole canvas."
  (interactive)
  (let* ((win (xiiif-view--window-pixels))
         (s (copy-xiiif-view-state xiiif-view--state)))
    (setf (xiiif-view-state-level s) 0
          (xiiif-view-state-x s) 0
          (xiiif-view-state-y s) 0)
    (xiiif-view--navigate (xiiif-view-fit-region s xiiif-view--info
                                                 (car win) (cdr win)))))

(defun xiiif-view-refresh ()
  "Re-fetch the current view, bypassing the per-buffer image cache."
  (interactive)
  (setq xiiif-view--lru nil)
  (xiiif-view--navigate xiiif-view--state))


;;; ---- anchor + output commands ----

(defun xiiif-view-state-to-anchor (state)
  "Return the canonical anchor for the current view STATE."
  (xiiif-anchor-create
   :manifest (xiiif-view-state-manifest-url state)
   :canvas   (xiiif-view-state-canvas-id state)
   :region   (xiiif-view-state-region state)))

(defun xiiif-view-copy-url ()
  "Copy the Image API URL of the exact current view to the kill ring."
  (interactive)
  (let ((url (xiiif-view--url xiiif-view--state)))
    (kill-new url)
    (message "Copied %s" url)))

(defun xiiif-view-open-in-mirador ()
  "Open the current view's canvas+region in an external Mirador viewer."
  (interactive)
  (let ((url (xiiif-content-state-url
              (xiiif-view-state-to-anchor xiiif-view--state))))
    (browse-url url)
    (message "xiiif: opening region in Mirador")))

(defvar xiiif-view-annotate-function nil
  "Function called by `xiiif-view-annotate' with the current anchor.
Wired by the anchored-note layer (Spec C3); nil means unconfigured.")

(defun xiiif-view-annotate ()
  "Create an anchored note for the current view via the note backend."
  (interactive)
  (if (functionp xiiif-view-annotate-function)
      (funcall xiiif-view-annotate-function
               (xiiif-view-state-to-anchor xiiif-view--state))
    (user-error "Anchored notes are not configured yet")))


;;; ---- entry ----

(defun xiiif-view-region (state &optional service info)
  "Display STATE in the `*XIIIF View*' buffer and select it.
SERVICE is the `xiiif-image-service' (defaults to nothing, in which
case the view can still show its URL); INFO is a `xiiif-image-info'
supplying dimensions, zoom scales and compliance."
  (let ((buf (get-buffer-create xiiif-view--buffer)))
    (with-current-buffer buf
      (xiiif-view-mode)
      (setq xiiif-view--service service
            xiiif-view--info info
            xiiif-view--lru nil
            xiiif-view--image nil
            xiiif-view--group nil
            xiiif-view--generation 0))
    (pop-to-buffer-same-window buf)
    (with-current-buffer buf
      (xiiif-view--navigate state))
    buf))

(defun xiiif-view--region-pixels (region info)
  "Return REGION as a pixel (X Y W H) list, converting percent via INFO."
  (if (and (eq (xiiif-region-unit region) 'percent)
           info (xiiif-image-info-width info) (xiiif-image-info-height info))
      (let ((fw (xiiif-image-info-width info))
            (fh (xiiif-image-info-height info)))
        (list (round (* (/ (xiiif-region-x region) 100.0) fw))
              (round (* (/ (xiiif-region-y region) 100.0) fh))
              (round (* (/ (xiiif-region-w region) 100.0) fw))
              (round (* (/ (xiiif-region-h region) 100.0) fh))))
    (list (xiiif-region-x region) (xiiif-region-y region)
          (xiiif-region-w region) (xiiif-region-h region))))

(defun xiiif-view--level-for-region (info win-w win-h region-w region-h)
  "Return the highest zoom level whose fitted region still covers REGION."
  (let* ((scales (xiiif-view-scales info))
         (limit (min (/ (float win-w) (max 1 region-w))
                     (/ (float win-h) (max 1 region-h))))
         (best 0))
    (dotimes (i (length scales))
      (when (<= (nth i scales) limit) (setq best i)))
    best))

(defun xiiif-view--initial-state (manifest-url canvas-id info region win-w win-h)
  "Build the fitted initial view-state.
REGION (a `xiiif-region' or nil) focuses the view; nil starts from
the whole canvas.  WIN-W/WIN-H are the display area in pixels."
  (if region
      (let* ((px (xiiif-view--region-pixels region info))
             (rw (max 1 (nth 2 px)))
             (rh (max 1 (nth 3 px)))
             (level (xiiif-view--level-for-region info win-w win-h rw rh)))
        (xiiif-view-fit-region
         (make-xiiif-view-state :manifest-url manifest-url :canvas-id canvas-id
                                :x (nth 0 px) :y (nth 1 px) :w rw :h rh
                                :level level)
         info win-w win-h))
    (let ((full-w (or (and info (xiiif-image-info-width info)) win-w))
          (full-h (or (and info (xiiif-image-info-height info)) win-h)))
      (xiiif-view-fit-region
       (make-xiiif-view-state :manifest-url manifest-url :canvas-id canvas-id
                              :x 0 :y 0 :w full-w :h full-h :level 0)
       info win-w win-h))))

(defun xiiif-view-open (manifest-url canvas-id service info &optional region)
  "Create the region viewer for CANVAS-ID and select it.
SERVICE is its `xiiif-image-service', INFO the parsed info.json.
REGION, when non-nil, focuses the initial view."
  (let ((buf (get-buffer-create xiiif-view--buffer)))
    (with-current-buffer buf
      (xiiif-view-mode)
      (setq xiiif-view--service service
            xiiif-view--info info
            xiiif-view--lru nil
            xiiif-view--image nil
            xiiif-view--group nil
            xiiif-view--generation 0))
    (pop-to-buffer-same-window buf)
    (with-current-buffer buf
      (let ((win (xiiif-view--window-pixels)))
        (xiiif-view--navigate
         (xiiif-view--initial-state manifest-url canvas-id info region
                                    (car win) (cdr win)))))
    buf))

(defun xiiif-view-load-canvas (manifest-url canvas-id service &optional region)
  "Fetch SERVICE's info.json, then open the viewer (focused on REGION).
Asynchronous; used by the interactive entry points."
  (message "xiiif: loading view...")
  (xiiif-image-fetch-info-async
   service
   (lambda (info)
     (xiiif-view-open manifest-url canvas-id service info region))
   (lambda (err)
     (message "xiiif: %s" (xiiif-api-error-hint err)))))

(provide 'xiiif-view)
;;; xiiif-view.el ends here
