;;; xiiif-http-cache-test.el --- Tests for the conditional HTTP cache -*- lexical-binding: t; -*-

;;; Commentary:

;; Covers Sprint 9: on-disk cache round-trip, rejection of foreign
;; entries, full 200 -> 304 cycle through `xiiif-api--response-json'
;; with a stubbed response buffer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-http-cache)
(require 'xiiif-api)

(defmacro xiiif-http-cache-test--with-temp-dir (&rest body)
  "Run BODY with a fresh temp cache dir bound as `xiiif-http-cache-directory'."
  (declare (indent 0) (debug t))
  `(let* ((dir (make-temp-file "xiiif-httpc-" t))
          (xiiif-http-cache-directory dir)
          (xiiif-http-cache-enabled t))
     (unwind-protect
         (progn ,@body)
       (when (file-directory-p dir)
         (dolist (f (directory-files dir t "^[^.]"))
           (ignore-errors (delete-file f)))
         (ignore-errors (delete-directory dir))))))


;;; ---- round-trip ----

(ert-deftest xiiif-http-cache/store-and-lookup ()
  (xiiif-http-cache-test--with-temp-dir
    (xiiif-http-cache-store "http://x/m" "BODY" "etag-abc" "Wed, 01 Jan 2026")
    (let ((e (xiiif-http-cache-lookup "http://x/m")))
      (should e)
      (should (equal "BODY" (plist-get e :body)))
      (should (equal "etag-abc" (plist-get e :etag)))
      (should (equal "Wed, 01 Jan 2026" (plist-get e :last-modified))))))

(ert-deftest xiiif-http-cache/ignores-other-url ()
  "A cache file whose payload is for URL-A must not answer a lookup for URL-B."
  (xiiif-http-cache-test--with-temp-dir
    (xiiif-http-cache-store "http://x/a" "A")
    (should-not (xiiif-http-cache-lookup "http://x/b"))))

(ert-deftest xiiif-http-cache/invalidate-drops ()
  (xiiif-http-cache-test--with-temp-dir
    (xiiif-http-cache-store "http://x/a" "A" "etag" nil)
    (should (xiiif-http-cache-lookup "http://x/a"))
    (xiiif-http-cache-invalidate "http://x/a")
    (should-not (xiiif-http-cache-lookup "http://x/a"))))

(ert-deftest xiiif-http-cache/disabled-never-reads ()
  (xiiif-http-cache-test--with-temp-dir
    (xiiif-http-cache-store "http://x/a" "A" "etag" nil)
    (let ((xiiif-http-cache-enabled nil))
      (should-not (xiiif-http-cache-lookup "http://x/a")))))

(ert-deftest xiiif-cache-clear-http/wipes-dir ()
  (xiiif-http-cache-test--with-temp-dir
    (xiiif-http-cache-store "http://x/1" "A")
    (xiiif-http-cache-store "http://x/2" "B")
    (should (= 2 (length (directory-files xiiif-http-cache-directory
                                          nil "\\.el\\'"))))
    (xiiif-cache-clear-http)
    (should (= 0 (length (directory-files xiiif-http-cache-directory
                                          nil "\\.el\\'"))))))


;;; ---- conditional headers ----

(ert-deftest xiiif-http-cache-conditional-headers/emits-both ()
  (xiiif-http-cache-test--with-temp-dir
    (xiiif-http-cache-store "http://x/m" "B" "etag-x" "date-y")
    (let ((hs (xiiif-http-cache-conditional-headers "http://x/m")))
      (should (equal "etag-x" (cdr (assoc "If-None-Match" hs))))
      (should (equal "date-y" (cdr (assoc "If-Modified-Since" hs)))))))

(ert-deftest xiiif-http-cache-conditional-headers/none-without-entry ()
  (xiiif-http-cache-test--with-temp-dir
    (should-not (xiiif-http-cache-conditional-headers "http://x/m"))))


;;; ---- 200 then 304 via response parser ----

(defun xiiif-http-cache-test--parse (raw url)
  "Feed RAW into a temp buffer and call `xiiif-api--response-json' for URL."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert raw)
    (xiiif-api--response-json url)))

(ert-deftest xiiif-api--response-json/stores-on-etag ()
  (xiiif-http-cache-test--with-temp-dir
    (let ((raw (concat "HTTP/1.1 200 OK\r\n"
                       "Content-Type: application/json\r\n"
                       "ETag: \"v1\"\r\n"
                       "\r\n"
                       "{\"a\":1}")))
      (xiiif-http-cache-test--parse raw "http://x/m"))
    (let ((entry (xiiif-http-cache-lookup "http://x/m")))
      (should entry)
      (should (equal "\"v1\"" (plist-get entry :etag)))
      (should (string-match-p "\"a\":1" (plist-get entry :body))))))

(ert-deftest xiiif-api--response-json/304-returns-cached ()
  (xiiif-http-cache-test--with-temp-dir
    (xiiif-http-cache-store "http://x/m" "{\"cached\":true}" "\"v1\"" nil)
    (let* ((raw (concat "HTTP/1.1 304 Not Modified\r\n\r\n"))
           (result (xiiif-http-cache-test--parse raw "http://x/m")))
      (should (eq t (alist-get 'cached result))))))

(ert-deftest xiiif-api--response-json/304-without-cache-errors ()
  (xiiif-http-cache-test--with-temp-dir
    (let ((raw (concat "HTTP/1.1 304 Not Modified\r\n\r\n")))
      (should-error
       (xiiif-http-cache-test--parse raw "http://x/missing")
       :type 'xiiif-http-error))))


(provide 'xiiif-http-cache-test)
;;; xiiif-http-cache-test.el ends here
