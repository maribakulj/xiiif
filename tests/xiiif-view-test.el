;;; xiiif-view-test.el --- Tests for the region viewer model -*- lexical-binding: t; -*-

;;; Commentary:

;; Pure geometry: view-state serialisation, zoom scales derived from
;; info.json fixtures, region clamping/expansion, HiDPI, and the
;; level-0-safe request path.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'xiiif-core)
(require 'xiiif-image)
(require 'xiiif-view)

(defconst xiiif-view-test--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defun xiiif-view-test--info (name)
  "Load the info.json fixture NAME into a `xiiif-image-info'."
  (let* ((path (expand-file-name (concat "../examples/" name)
                                 xiiif-view-test--dir))
         (json (let ((json-object-type 'alist)
                     (json-array-type 'vector)
                     (json-key-type 'symbol)
                     (json-false :json-false)
                     (json-null nil))
                 (json-read-file path))))
    (xiiif-image-parse-info json (concat "https://x/svc/" name))))


;;; ---- serialisation ----

(ert-deftest xiiif-view/state-alist-round-trip ()
  (let* ((s (make-xiiif-view-state
             :manifest-url "https://x/m" :canvas-id "https://x/c/1"
             :x 100 :y 200 :w 300 :h 400 :level 2 :rotation 90))
         (s2 (xiiif-view-state-from-alist (xiiif-view-state-to-alist s))))
    (should (equal (xiiif-view-state-x s) (xiiif-view-state-x s2)))
    (should (equal (xiiif-view-state-level s) (xiiif-view-state-level s2)))
    (should (equal (xiiif-view-state-rotation s) (xiiif-view-state-rotation s2)))
    (should (equal (xiiif-view-state-canvas-id s)
                   (xiiif-view-state-canvas-id s2)))))

(ert-deftest xiiif-view/state-region ()
  (let ((r (xiiif-view-state-region
            (make-xiiif-view-state :x 10 :y 20 :w 30 :h 40))))
    (should (= 10 (xiiif-region-x r)))
    (should (= 40 (xiiif-region-h r)))
    (should (eq 'pixel (xiiif-region-unit r)))))


;;; ---- zoom scales ----

(ert-deftest xiiif-view/scales-from-sizes ()
  "The level-1 fixture (6000 wide, sizes 150/600/1500/3000) yields
ascending fractions ending at full resolution."
  (let ((scales (xiiif-view-scales (xiiif-view-test--info "sample-info.json"))))
    (should (equal scales (sort (copy-sequence scales) #'<)))
    (should (= 1.0 (car (last scales))))
    ;; 150/6000 = 0.025, 3000/6000 = 0.5, plus the appended 1.0.
    (should (member 0.5 scales))
    (should (cl-some (lambda (s) (< (abs (- s 0.025)) 1e-6)) scales))))

(ert-deftest xiiif-view/scales-default-without-info ()
  (should (equal (xiiif-view-scales nil)
                 (delete-dups (sort (cons 1.0 (copy-sequence
                                               xiiif-view-default-scales))
                                    #'<)))))

(ert-deftest xiiif-view/scale-at-clamps-level ()
  (let ((info (xiiif-view-test--info "sample-info.json")))
    (should (= 1.0 (xiiif-view-scale-at info 999)))
    (should (= (car (xiiif-view-scales info))
               (xiiif-view-scale-at info -5)))))


;;; ---- closest size (M6) ----

(ert-deftest xiiif-image/closest-size-picks-covering ()
  (let ((info (xiiif-view-test--info "sample-info-level0.json")))
    ;; sizes: 250, 500, 1000, 2000.  Target 400 -> smallest >= 400 = 500.
    (let ((best (xiiif-image-closest-size info 400)))
      (should (= 500 (plist-get best :width)))
      (should (= 375 (plist-get best :height)))
      (should (equal "500,375" (plist-get best :segment))))))

(ert-deftest xiiif-image/closest-size-falls-back-to-largest ()
  (let ((info (xiiif-view-test--info "sample-info-level0.json")))
    ;; Target beyond every advertised width -> the largest (2000).
    (should (= 2000 (plist-get (xiiif-image-closest-size info 9999) :width)))))

(ert-deftest xiiif-image/closest-size-derives-from-tiles ()
  "The level-1 fixture has no small `sizes' gap; verify tile-derived
candidates when only tiles are present."
  (let ((info (make-xiiif-image-info
               :width 8192 :height 8192
               :tiles '(((width . 512) (scaleFactors . [1 2 4 8]))))))
    (let ((best (xiiif-image-closest-size info 1000)))
      ;; Candidates: 8192, 4096, 2048, 1024.  Smallest >= 1000 = 1024.
      (should (= 1024 (plist-get best :width))))))

(ert-deftest xiiif-image/closest-size-nil-without-sizes ()
  (should-not (xiiif-image-closest-size
               (make-xiiif-image-info :width 100 :height 100) 50)))

(ert-deftest xiiif-image/level0-predicate ()
  (should (xiiif-image-info-level0-p
           (xiiif-view-test--info "sample-info-level0.json")))
  (should-not (xiiif-image-info-level0-p
               (xiiif-view-test--info "sample-info.json"))))


;;; ---- geometry: region clamp ----

(ert-deftest xiiif-view/request-clamps-region-to-canvas ()
  (let* ((info (xiiif-view-test--info "sample-info.json")) ; 6000x4000
         (state (make-xiiif-view-state :x 5800 :y 3900 :w 1000 :h 1000
                                       :level 99))
         (req (xiiif-view-image-request state :info info)))
    ;; x+w must not exceed 6000, y+h not exceed 4000.
    (should (string-match "\\`\\([0-9]+\\),\\([0-9]+\\),\\([0-9]+\\),\\([0-9]+\\)\\'"
                          (plist-get req :region)))
    (let ((x (string-to-number (match-string 1 (plist-get req :region))))
          (w (string-to-number (match-string 3 (plist-get req :region))))
          (y (string-to-number (match-string 2 (plist-get req :region))))
          (h (string-to-number (match-string 4 (plist-get req :region)))))
      (should (<= (+ x w) 6000))
      (should (<= (+ y h) 4000)))))

(ert-deftest xiiif-view/request-expands-by-margin ()
  (let* ((info (xiiif-view-test--info "sample-info.json"))
         (state (make-xiiif-view-state :x 1000 :y 1000 :w 200 :h 200
                                       :level 99))
         (plain (xiiif-view-image-request state :info info :margin 0.0))
         (grown (xiiif-view-image-request state :info info :margin 1.0)))
    ;; margin 1.0 adds 200px each side: region becomes 600,600 at 800,800.
    (should (equal "1000,1000,200,200" (plist-get plain :region)))
    (should (equal "800,800,600,600" (plist-get grown :region)))))


;;; ---- geometry: level >= 1 output size + HiDPI ----

(ert-deftest xiiif-view/request-output-native-cap ()
  "At full level with HiDPI 1, output equals the region (native)."
  (let* ((info (xiiif-view-test--info "sample-info.json"))
         (max-level (xiiif-view-max-level info))
         (state (make-xiiif-view-state :x 0 :y 0 :w 400 :h 300
                                       :level max-level))
         (req (xiiif-view-image-request state :info info :hidpi 1.0)))
    (should (equal "400,300" (plist-get req :size)))
    (should (= 1.0 (plist-get req :scale)))))

(ert-deftest xiiif-view/request-hidpi-doubles-pixels ()
  "At a fractional level, HiDPI 2 doubles physical pixels while the
display scale halves - the Retina path."
  (let* ((info (xiiif-view-test--info "sample-info.json"))
         ;; Find a level whose scale is 0.25 (1500/6000).
         (scales (xiiif-view-scales info))
         (level (cl-position 0.25 scales :test (lambda (a b) (< (abs (- a b)) 1e-6))))
         (state (make-xiiif-view-state :x 0 :y 0 :w 400 :h 400 :level level)))
    (should level)
    (let ((one (xiiif-view-image-request state :info info :hidpi 1.0))
          (two (xiiif-view-image-request state :info info :hidpi 2.0)))
      ;; level scale 0.25: 400*0.25 = 100 physical at hidpi 1.
      (should (= 100 (plist-get one :width)))
      (should (= 1.0 (plist-get one :scale)))
      ;; hidpi 2: 400*0.25*2 = 200 physical, scale 0.5.
      (should (= 200 (plist-get two :width)))
      (should (= 0.5 (plist-get two :scale))))))


;;; ---- geometry: level-0 safety (M6) ----

(ert-deftest xiiif-view/request-level0-uses-full-and-advertised ()
  "On a level-0 server the region is `full' and the size is one of
the advertised sizes - never a synthesized dimension."
  (let* ((info (xiiif-view-test--info "sample-info-level0.json"))
         (state (make-xiiif-view-state :x 500 :y 500 :w 300 :h 300
                                       :level 1))
         (req (xiiif-view-image-request state :info info :hidpi 1.0)))
    (should (equal "full" (plist-get req :region)))
    ;; The chosen size must be one of 250/500/1000/2000.
    (should (member (plist-get req :width) '(250 500 1000 2000)))
    (should (string-match-p "\\`[0-9]+,[0-9]+\\'" (plist-get req :size)))))

(ert-deftest xiiif-view/request-level0-scales-with-level ()
  "A higher level targets a larger advertised size."
  (let* ((info (xiiif-view-test--info "sample-info-level0.json"))
         (low  (make-xiiif-view-state :x 0 :y 0 :w 4000 :h 3000 :level 0))
         (high (make-xiiif-view-state :x 0 :y 0 :w 4000 :h 3000
                                      :level (xiiif-view-max-level info))))
    (let ((lo (xiiif-view-image-request low :info info))
          (hi (xiiif-view-image-request high :info info)))
      (should (<= (plist-get lo :width) (plist-get hi :width))))))


;;; ---- URL assembly ----

(ert-deftest xiiif-view/image-url-assembles-segments ()
  (let* ((info (xiiif-view-test--info "sample-info.json"))
         (service (make-xiiif-image-service :id "https://img/svc"))
         (state (make-xiiif-view-state :x 10 :y 20 :w 100 :h 100
                                       :level (xiiif-view-max-level info)
                                       :rotation 0))
         (url (xiiif-view-image-url state service :info info)))
    (should (string-prefix-p "https://img/svc/10,20,100,100/" url))
    (should (string-suffix-p "/0/default.jpg" url))))


;;; ---- thumbnail rewire (M6) ----

(ert-deftest xiiif-view/thumbnail-url-level0-safe ()
  "With info, the thumbnail size comes from the advertised set."
  (let* ((info (xiiif-view-test--info "sample-info-level0.json"))
         (canvas (make-xiiif-canvas
                  :id "https://x/c/1"
                  :image-service (make-xiiif-image-service
                                  :id "https://img/svc"))))
    (let ((url (xiiif-canvas-thumbnail-url canvas "!200,200" info)))
      ;; 200 -> smallest advertised >= 200 = 250x188.
      (should (equal "https://img/svc/full/250,188/0/default.jpg" url)))))

(ert-deftest xiiif-view/thumbnail-url-without-info-keeps-default ()
  (let ((canvas (make-xiiif-canvas
                 :id "https://x/c/1"
                 :image-service (make-xiiif-image-service
                                 :id "https://img/svc"))))
    (should (equal "https://img/svc/full/!200,200/0/default.jpg"
                   (xiiif-canvas-thumbnail-url canvas)))))

(provide 'xiiif-view-test)
;;; xiiif-view-test.el ends here
