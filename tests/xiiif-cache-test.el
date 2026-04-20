;;; xiiif-cache-test.el --- Tests for session state + persistence -*- lexical-binding: t; -*-

;;; Commentary:

;; Covers Sprint 5: the unified `xiiif-cache-select' selector, the
;; round-trip of `xiiif-cache-save'/`xiiif-cache-load' and the
;; rejection of malformed history files.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-core)
(require 'xiiif-cache)

(defmacro xiiif-cache-test--with-temp-history (&rest body)
  "Run BODY with a fresh temp file bound as `xiiif-history-file'."
  (declare (indent 0) (debug t))
  `(let* ((tmp (make-temp-file "xiiif-hist-"))
          (xiiif-history-file tmp)
          (xiiif-recent-manifests nil)
          (xiiif-history-save-debounce 0))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (delete-file tmp)))))


;;; ---- selector ----

(ert-deftest xiiif-cache-select/manifest-clears-collection-and-canvas ()
  (let ((xiiif-current-manifest nil)
        (xiiif-current-canvas
         (make-xiiif-canvas :id "http://x/c" :label "stale"))
        (xiiif-current-collection
         (make-xiiif-collection :url "http://x/col" :id "col" :label "old")))
    (xiiif-cache-test--with-temp-history
      (xiiif-cache-select
       :manifest (make-xiiif-manifest :url "http://x/m" :id "m" :label "M")))
    (should xiiif-current-manifest)
    (should-not xiiif-current-canvas)
    (should-not xiiif-current-collection)))

(ert-deftest xiiif-cache-select/collection-clears-manifest-and-canvas ()
  (let ((xiiif-current-manifest
         (make-xiiif-manifest :url "http://x/m" :id "m" :label "stale"))
        (xiiif-current-canvas
         (make-xiiif-canvas :id "http://x/c"))
        (xiiif-current-collection nil))
    (xiiif-cache-test--with-temp-history
      (xiiif-cache-select
       :collection (make-xiiif-collection :url "http://x/col"
                                          :id "col" :label "New")))
    (should xiiif-current-collection)
    (should-not xiiif-current-manifest)
    (should-not xiiif-current-canvas)))

(ert-deftest xiiif-cache-select/canvas-only-leaves-manifest ()
  (let* ((m (make-xiiif-manifest :url "http://x/m" :id "m" :label "M"))
         (c (make-xiiif-canvas :id "http://x/c"))
         (xiiif-current-manifest m)
         (xiiif-current-canvas nil))
    (xiiif-cache-select :canvas c)
    (should (eq m xiiif-current-manifest))
    (should (eq c xiiif-current-canvas))))


;;; ---- recent list: dedup + truncation ----

(ert-deftest xiiif-cache-add-recent/dedups ()
  (xiiif-cache-test--with-temp-history
    (xiiif-cache-add-recent "http://x/1")
    (xiiif-cache-add-recent "http://x/2")
    (xiiif-cache-add-recent "http://x/1")
    (should (equal '("http://x/1" "http://x/2")
                   xiiif-recent-manifests))))

(ert-deftest xiiif-cache-add-recent/truncates ()
  (let ((xiiif-history-size 3))
    (xiiif-cache-test--with-temp-history
      (xiiif-cache-add-recent "http://x/1")
      (xiiif-cache-add-recent "http://x/2")
      (xiiif-cache-add-recent "http://x/3")
      (xiiif-cache-add-recent "http://x/4")
      (should (equal '("http://x/4" "http://x/3" "http://x/2")
                     xiiif-recent-manifests)))))

(ert-deftest xiiif-cache-add-recent/ignores-non-string ()
  (xiiif-cache-test--with-temp-history
    (xiiif-cache-add-recent nil)
    (xiiif-cache-add-recent 42)
    (should (null xiiif-recent-manifests))))


;;; ---- save / load round-trip ----

(ert-deftest xiiif-cache/round-trip ()
  (xiiif-cache-test--with-temp-history
    (xiiif-cache-add-recent "http://x/a")
    (xiiif-cache-add-recent "http://x/b")
    (xiiif-cache-save)
    (setq xiiif-recent-manifests nil)
    (xiiif-cache-load)
    (should (equal '("http://x/b" "http://x/a")
                   xiiif-recent-manifests))))

(ert-deftest xiiif-cache-load/rejects-arbitrary-code ()
  "A tampered history file with a non-setq form must be ignored."
  (let* ((tmp (make-temp-file "xiiif-hist-mal-"))
         (xiiif-history-file tmp)
         (xiiif-recent-manifests '("keep-me")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "(message \"pwned\")\n"))
          (xiiif-cache-load)
          (should (equal '("keep-me") xiiif-recent-manifests)))
      (ignore-errors (delete-file tmp)))))

(ert-deftest xiiif-cache-load/rejects-wrong-var ()
  (let* ((tmp (make-temp-file "xiiif-hist-wrong-"))
         (xiiif-history-file tmp)
         (xiiif-recent-manifests '("keep-me")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "(setq some-other-var '(\"x\"))\n"))
          (xiiif-cache-load)
          (should (equal '("keep-me") xiiif-recent-manifests)))
      (ignore-errors (delete-file tmp)))))

(ert-deftest xiiif-cache-load/rejects-non-string-payload ()
  (let* ((tmp (make-temp-file "xiiif-hist-ns-"))
         (xiiif-history-file tmp)
         (xiiif-recent-manifests '("keep-me")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "(setq xiiif-recent-manifests '(\"ok\" 42))\n"))
          (xiiif-cache-load)
          (should (equal '("keep-me") xiiif-recent-manifests)))
      (ignore-errors (delete-file tmp)))))

(ert-deftest xiiif-cache-load/caps-at-history-size ()
  (let* ((tmp (make-temp-file "xiiif-hist-cap-"))
         (xiiif-history-file tmp)
         (xiiif-history-size 2)
         (xiiif-recent-manifests nil))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "(setq xiiif-recent-manifests '(\"a\" \"b\" \"c\" \"d\"))\n"))
          (xiiif-cache-load)
          (should (equal '("a" "b") xiiif-recent-manifests)))
      (ignore-errors (delete-file tmp)))))


;;; ---- cache-clear ----

(ert-deftest xiiif-cache-clear/resets-pointers ()
  (let ((xiiif-current-manifest
         (make-xiiif-manifest :url "http://x/m" :id "m" :label "M"))
        (xiiif-current-canvas (make-xiiif-canvas :id "http://x/c"))
        (xiiif-current-collection
         (make-xiiif-collection :url "http://x/col" :id "col" :label "C")))
    (xiiif-cache-clear)
    (should-not xiiif-current-manifest)
    (should-not xiiif-current-canvas)
    (should-not xiiif-current-collection)))


(provide 'xiiif-cache-test)
;;; xiiif-cache-test.el ends here
