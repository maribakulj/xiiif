;;; xiiif-region-test.el --- Tests for canvas region parsing -*- lexical-binding: t; -*-

;;; Commentary:

;; Covers `xiiif-region' parsing from Media Fragments strings and
;; from structured v2/v3 selectors, plus the display/Image-API
;; serialisers.

;;; Code:

(require 'ert)
(require 'xiiif-region)

;;; ---- fragment parsing ----

(ert-deftest xiiif-region/fragment-pixel ()
  (let ((r (xiiif-region-from-fragment
            "https://x/canvas/1#xywh=100,200,300,400")))
    (should (xiiif-region-p r))
    (should (= 100 (xiiif-region-x r)))
    (should (= 200 (xiiif-region-y r)))
    (should (= 300 (xiiif-region-w r)))
    (should (= 400 (xiiif-region-h r)))
    (should (eq 'pixel (xiiif-region-unit r)))))

(ert-deftest xiiif-region/fragment-percent ()
  (let ((r (xiiif-region-from-fragment
            "https://x/canvas/1#xywh=percent:10,20,30,40")))
    (should (xiiif-region-p r))
    (should (= 10 (xiiif-region-x r)))
    (should (eq 'percent (xiiif-region-unit r)))))

(ert-deftest xiiif-region/fragment-bare ()
  (let ((r (xiiif-region-from-fragment "xywh=1,2,3,4")))
    (should (xiiif-region-p r))
    (should (= 1 (xiiif-region-x r)))))

(ert-deftest xiiif-region/fragment-with-other-params ()
  "An xywh fragment beside other Media Fragments params still parses."
  (let ((r (xiiif-region-from-fragment
            "https://x/c/1#xywh=5,6,7,8&t=10")))
    (should (xiiif-region-p r))
    (should (= 5 (xiiif-region-x r)))
    (should (= 8 (xiiif-region-h r)))))

(ert-deftest xiiif-region/fragment-decimal-percent ()
  (let ((r (xiiif-region-from-fragment "xywh=percent:2.5,0,50,50")))
    (should (xiiif-region-p r))
    (should (= 2.5 (xiiif-region-x r)))))

(ert-deftest xiiif-region/fragment-none ()
  (should-not (xiiif-region-from-fragment "https://x/canvas/1"))
  (should-not (xiiif-region-from-fragment nil))
  (should-not (xiiif-region-from-fragment "xywh=1,2,3"))
  (should-not (xiiif-region-from-fragment "xywh=a,b,c,d")))


;;; ---- structured selectors ----

(ert-deftest xiiif-region/target-string ()
  (let ((r (xiiif-region-from-target
            "https://x/canvas/1#xywh=1,2,3,4")))
    (should (xiiif-region-p r))
    (should (= 1 (xiiif-region-x r)))))

(ert-deftest xiiif-region/target-specific-resource-v3 ()
  (let ((r (xiiif-region-from-target
            '((type . "SpecificResource")
              (source . "https://x/canvas/1")
              (selector . ((type . "FragmentSelector")
                           (value . "xywh=100,150,400,300")))))))
    (should (xiiif-region-p r))
    (should (= 100 (xiiif-region-x r)))
    (should (= 300 (xiiif-region-h r)))))

(ert-deftest xiiif-region/target-specific-resource-v2 ()
  (let ((r (xiiif-region-from-target
            '((@type . "oa:SpecificResource")
              (full . "https://x/canvas/1")
              (selector . ((@type . "oa:FragmentSelector")
                           (value . "xywh=50,60,70,80")))))))
    (should (xiiif-region-p r))
    (should (= 50 (xiiif-region-x r)))
    (should (= 80 (xiiif-region-h r)))))

(ert-deftest xiiif-region/target-selector-array ()
  "A selector array yields the first usable FragmentSelector."
  (let ((r (xiiif-region-from-target
            '((selector . [((type . "PointSelector"))
                           ((type . "FragmentSelector")
                            (value . "xywh=9,9,9,9"))])))))
    (should (xiiif-region-p r))
    (should (= 9 (xiiif-region-x r)))))

(ert-deftest xiiif-region/target-choice-default ()
  (let ((r (xiiif-region-from-target
            '((selector . ((type . "Choice")
                           (default . ((type . "FragmentSelector")
                                       (value . "xywh=3,3,3,3")))))))))
    (should (xiiif-region-p r))
    (should (= 3 (xiiif-region-x r)))))

(ert-deftest xiiif-region/target-source-carries-fragment ()
  "A SpecificResource whose source string carries the fragment."
  (let ((r (xiiif-region-from-target
            '((type . "SpecificResource")
              (source . "https://x/canvas/1#xywh=7,7,7,7")))))
    (should (xiiif-region-p r))
    (should (= 7 (xiiif-region-x r)))))

(ert-deftest xiiif-region/target-array ()
  (let ((r (xiiif-region-from-target
            ["https://x/canvas/1#xywh=2,2,2,2"])))
    (should (xiiif-region-p r))
    (should (= 2 (xiiif-region-x r)))))

(ert-deftest xiiif-region/target-none ()
  (should-not (xiiif-region-from-target "https://x/canvas/1"))
  (should-not (xiiif-region-from-target
               '((type . "SpecificResource")
                 (source . "https://x/canvas/1"))))
  (should-not (xiiif-region-from-target nil)))


;;; ---- serialisers ----

(ert-deftest xiiif-region/to-string ()
  (should (equal "1,2,3,4"
                 (xiiif-region-to-string
                  (make-xiiif-region :x 1 :y 2 :w 3 :h 4))))
  (should (equal "10,20,30,40%"
                 (xiiif-region-to-string
                  (make-xiiif-region :x 10 :y 20 :w 30 :h 40
                                     :unit 'percent))))
  (should-not (xiiif-region-to-string nil)))

(ert-deftest xiiif-region/to-image-api ()
  (should (equal "1,2,3,4"
                 (xiiif-region-to-image-api
                  (make-xiiif-region :x 1 :y 2 :w 3 :h 4))))
  (should (equal "pct:10,20,30,40"
                 (xiiif-region-to-image-api
                  (make-xiiif-region :x 10 :y 20 :w 30 :h 40
                                     :unit 'percent))))
  (should-not (xiiif-region-to-image-api nil)))

(provide 'xiiif-region-test)
;;; xiiif-region-test.el ends here
