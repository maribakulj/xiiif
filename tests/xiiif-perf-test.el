;;; xiiif-perf-test.el --- Performance regression tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Guards against the O(N*M) behaviour that Sprint 4 addressed by
;; memoising canvas parsing and indexing `xiiif-manifest-find-canvas'.
;; The budgets are generous so the test remains green on slow CI
;; runners; the important property is that the cached path is orders
;; of magnitude faster than re-parsing every time.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-core)
(require 'xiiif-ui)

(defun xiiif-perf-test--synthetic-manifest (n)
  "Return an `xiiif-manifest' with N fake canvases."
  (let (items)
    (dotimes (i n)
      (push `((id . ,(format "http://x/c/%d" i))
              (type . "Canvas")
              (label . ,(format "canvas-%d" i))
              (width . 100) (height . 100))
            items))
    (make-xiiif-manifest
     :url "http://x/m"
     :id  "http://x/m"
     :type "Manifest"
     :label "perf"
     :items (nreverse items)
     :raw   '((id . "http://x/m")
              (type . "Manifest")
              (label . "perf")))))


;;; ---- memoisation ----

(ert-deftest xiiif-manifest-canvases/memoises ()
  (let* ((m (xiiif-perf-test--synthetic-manifest 50))
         (first  (xiiif-manifest-canvases m))
         (second (xiiif-manifest-canvases m)))
    (should (eq first second))
    (should (= 50 (length first)))))

(ert-deftest xiiif-manifest-canvas-count/avoids-parse ()
  "Count must succeed without populating the canvas cache."
  (let ((m (xiiif-perf-test--synthetic-manifest 10)))
    (should (= 10 (xiiif-manifest-canvas-count m)))
    (should (null (xiiif-manifest-canvas-cache m)))))

(ert-deftest xiiif-manifest-invalidate-cache/drops-both ()
  (let ((m (xiiif-perf-test--synthetic-manifest 5)))
    (xiiif-manifest-canvases m)
    (xiiif-manifest-find-canvas m "http://x/c/0")
    (should (xiiif-manifest-canvas-cache m))
    (should (xiiif-manifest-canvas-index m))
    (xiiif-manifest-invalidate-cache m)
    (should-not (xiiif-manifest-canvas-cache m))
    (should-not (xiiif-manifest-canvas-index m))))


;;; ---- index correctness ----

(ert-deftest xiiif-manifest-find-canvas/hits-known-id ()
  (let ((m (xiiif-perf-test--synthetic-manifest 20)))
    (let ((hit (xiiif-manifest-find-canvas m "http://x/c/7")))
      (should (xiiif-canvas-p hit))
      (should (equal "http://x/c/7" (xiiif-canvas-id hit))))))

(ert-deftest xiiif-manifest-find-canvas/misses-gracefully ()
  (let ((m (xiiif-perf-test--synthetic-manifest 5)))
    (should (null (xiiif-manifest-find-canvas m "http://x/c/nope")))))

(ert-deftest xiiif-manifest-find-canvas/is-fast-under-repetition ()
  "Looking up every canvas by id should be dominated by hashing, not parsing."
  (let* ((m (xiiif-perf-test--synthetic-manifest 400))
         (ids (mapcar (lambda (c) (xiiif-canvas-id c))
                      (xiiif-manifest-canvases m)))
         (start (float-time)))
    ;; 400 canvases * 400 lookups.
    (dolist (id ids)
      (dolist (_ids ids)
        (xiiif-manifest-find-canvas m id)))
    (let ((elapsed (- (float-time) start)))
      ;; Pre-Sprint 4 this was O(N^2) *with* a parse per lookup and
      ;; blew past several seconds; memoisation + index must stay
      ;; comfortably under one second even on a slow CI runner.
      (should (< elapsed 1.0)))))


(provide 'xiiif-perf-test)
;;; xiiif-perf-test.el ends here
