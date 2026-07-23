;;; xiiif-image-cache-test.el --- Tests for the image byte cache -*- lexical-binding: t; -*-

;;; Commentary:

;; On-disk byte cache round-trips, binary safety, the byte-budget
;; eviction and its LRU behaviour (reads refresh entries).

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-image-cache)

(defmacro xiiif-image-cache-test--with-temp-dir (&rest body)
  "Run BODY with a fresh temp dir bound as `xiiif-image-cache-directory'."
  (declare (indent 0) (debug t))
  `(let* ((dir (make-temp-file "xiiif-imgc-" t))
          (xiiif-image-cache-directory dir)
          (xiiif-image-cache-enabled t)
          (xiiif-image-cache-max-bytes (* 200 1024 1024)))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p dir)
         (dolist (f (directory-files dir t "^[^.]"))
           (ignore-errors (delete-file f)))
         (ignore-errors (delete-directory dir))))))

(defun xiiif-image-cache-test--backdate (url seconds-ago)
  "Set the mtime of URL's cache file SECONDS-AGO seconds in the past."
  (set-file-times (xiiif-image-cache--file url)
                  (time-subtract (current-time)
                                 (seconds-to-time seconds-ago))))


(ert-deftest xiiif-image-cache/round-trip-binary ()
  (xiiif-image-cache-test--with-temp-dir
    (let ((bytes (unibyte-string 0 1 2 255 216 137 80 78 71 0)))
      (xiiif-image-cache-put "http://img/1.jpg" bytes)
      (let ((got (xiiif-image-cache-get "http://img/1.jpg")))
        (should (equal bytes got))
        (should-not (multibyte-string-p got))))))

(ert-deftest xiiif-image-cache/miss-returns-nil ()
  (xiiif-image-cache-test--with-temp-dir
    (should-not (xiiif-image-cache-get "http://img/absent.jpg"))))

(ert-deftest xiiif-image-cache/disabled-neither-reads-nor-writes ()
  (xiiif-image-cache-test--with-temp-dir
    (xiiif-image-cache-put "http://img/1.jpg" "bytes")
    (let ((xiiif-image-cache-enabled nil))
      (xiiif-image-cache-put "http://img/2.jpg" "bytes")
      (should-not (xiiif-image-cache-get "http://img/1.jpg")))
    (should-not (xiiif-image-cache-get "http://img/2.jpg"))))

(ert-deftest xiiif-image-cache/evicts-lru-beyond-byte-budget ()
  (xiiif-image-cache-test--with-temp-dir
    (let ((xiiif-image-cache-max-bytes 250)
          (bytes (make-string 100 ?x)))
      (xiiif-image-cache-put "http://img/a" bytes)
      (xiiif-image-cache-test--backdate "http://img/a" 100)
      (xiiif-image-cache-put "http://img/b" bytes)
      (xiiif-image-cache-test--backdate "http://img/b" 50)
      ;; Reading A refreshes it: B becomes the LRU entry.
      (should (xiiif-image-cache-get "http://img/a"))
      (xiiif-image-cache-put "http://img/c" bytes)
      (should (xiiif-image-cache-get "http://img/a"))
      (should-not (xiiif-image-cache-get "http://img/b"))
      (should (xiiif-image-cache-get "http://img/c")))))

(ert-deftest xiiif-image-cache/clear-wipes-dir ()
  (xiiif-image-cache-test--with-temp-dir
    (xiiif-image-cache-put "http://img/a" "bytes")
    (xiiif-image-cache-clear)
    (should-not (xiiif-image-cache-get "http://img/a"))))

(provide 'xiiif-image-cache-test)
;;; xiiif-image-cache-test.el ends here
