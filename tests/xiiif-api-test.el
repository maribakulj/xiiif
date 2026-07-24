;;; xiiif-api-test.el --- Tests for xiiif-api -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the HTTP/JSON transport layer.  Most tests focus on
;; `xiiif-api--response-json', the internal helper that every fetch -
;; synchronous or asynchronous - runs over the raw response buffer.
;; Exercising it with hand-crafted buffers avoids needing a real HTTP
;; server in CI while still covering the failure modes the async code
;; relies on.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'xiiif-api)

(defun xiiif-api-test--with-response (raw thunk)
  "Run THUNK in a temp buffer whose contents are RAW bytes."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert raw)
    (funcall thunk)))

(ert-deftest xiiif-api--valid-url-p/obvious ()
  (should (xiiif-api--valid-url-p "https://example.org/iiif/m"))
  (should (xiiif-api--valid-url-p "http://x/m"))
  (should (xiiif-api--valid-url-p "file:///tmp/m.json"))
  (should-not (xiiif-api--valid-url-p "ftp://x/m"))
  (should-not (xiiif-api--valid-url-p "example.org/iiif/m"))
  (should-not (xiiif-api--valid-url-p "   "))
  (should-not (xiiif-api--valid-url-p nil)))

(ert-deftest xiiif-api--response-json/parses-body ()
  (xiiif-api-test--with-response
   "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"a\": 1}"
   (lambda ()
     (let ((result (xiiif-api--response-json "http://x")))
       (should (equal 1 (alist-get 'a result)))))))

(ert-deftest xiiif-api--response-json/http-error ()
  (xiiif-api-test--with-response
   "HTTP/1.1 404 Not Found\r\n\r\n{}"
   (lambda ()
     (let ((err (should-error (xiiif-api--response-json "http://x")
                              :type 'xiiif-http-error)))
       (should (equal 404 (nth 2 err)))))))

(ert-deftest xiiif-api--response-json/parse-error ()
  (xiiif-api-test--with-response
   "HTTP/1.1 200 OK\r\n\r\nnot json"
   (lambda ()
     (should-error (xiiif-api--response-json "http://x")
                   :type 'xiiif-parse-error))))

(ert-deftest xiiif-api--response-json/lf-only-separator ()
  "Some upstreams use LF-only header separators; we must still parse them."
  (xiiif-api-test--with-response
   "HTTP/1.1 200 OK\n\n{\"ok\": true}"
   (lambda ()
     (let ((result (xiiif-api--response-json "http://x")))
       (should (eq t (alist-get 'ok result)))))))

;;; ---- native JSON parser ----

(defconst xiiif-api-test--examples-dir
  (expand-file-name
   "../examples"
   (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest xiiif-api--parse-json/native-matches-legacy-on-fixtures ()
  "The native `json-parse-string' configuration must produce shapes
identical to the pure-Elisp reader on every bundled fixture."
  (skip-unless (fboundp 'json-parse-string))
  (let ((fixtures (directory-files
                   xiiif-api-test--examples-dir t "\\.json\\'")))
    (should fixtures)
    (dolist (file fixtures)
      (let* ((body (with-temp-buffer
                     (insert-file-contents file)
                     (buffer-string)))
             (native (xiiif-api--parse-json body file))
             (legacy (let ((json-object-type 'alist)
                           (json-array-type  'vector)
                           (json-key-type    'symbol)
                           (json-false       :json-false)
                           (json-null        nil))
                       (json-read-from-string body))))
        (should (equal native legacy))))))

(ert-deftest xiiif-api--parse-json/shapes ()
  "Objects are symbol-keyed alists, arrays vectors, false/null mapped."
  (let ((parsed (xiiif-api--parse-json
                 "{\"a\": [1, 2], \"b\": false, \"c\": null, \"d\": \"x\"}"
                 "http://x")))
    (should (equal [1 2] (alist-get 'a parsed)))
    (should (eq :json-false (alist-get 'b parsed)))
    (should (null (alist-get 'c parsed)))
    (should (equal "x" (alist-get 'd parsed)))))


;;; ---- body size guard ----

(ert-deftest xiiif-api--response-json/oversized-body-rejected ()
  (let ((xiiif-api-max-body-size 10))
    (xiiif-api-test--with-response
     "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{\"a\": 1234}"
     (lambda ()
       (let ((err (should-error (xiiif-api--response-json "http://x")
                                :type 'xiiif-body-too-large)))
         (should (equal '(xiiif-body-too-large "http://x" 11 10) err)))))))

(ert-deftest xiiif-api--response-json/body-within-limit-parses ()
  (let ((xiiif-api-max-body-size 1024))
    (xiiif-api-test--with-response
     "HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\n{\"a\": 1}"
     (lambda ()
       (should (equal 1 (alist-get
                         'a (xiiif-api--response-json "http://x"))))))))

(ert-deftest xiiif-api--response-json/size-guard-disabled ()
  (let ((xiiif-api-max-body-size nil))
    (xiiif-api-test--with-response
     "HTTP/1.1 200 OK\r\nContent-Length: 99999999\r\n\r\n{\"a\": 1}"
     (lambda ()
       (should (equal 1 (alist-get
                         'a (xiiif-api--response-json "http://x"))))))))

(ert-deftest xiiif-api-fetch-bytes-async/oversized-body-calls-errback ()
  "The bytes path enforces the size guard before extracting the body."
  (let ((xiiif-api-max-body-size 10)
        (xiiif-api-backend 'url)
        (captured nil))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url callback &optional _cbargs _silent _inhibit)
                 (let ((buf (generate-new-buffer " *xiiif-size-stub*")))
                   (with-current-buffer buf
                     (set-buffer-multibyte nil)
                     (insert "HTTP/1.1 200 OK\r\n"
                             "Content-Length: 999999\r\n\r\n"
                             "bytes")
                     (funcall callback nil))
                   buf))))
      (xiiif-api-fetch-bytes-async
       "http://x/big.jpg"
       (lambda (_bytes) (error "callback should not fire"))
       (lambda (err) (setq captured err)))
      (should (eq 'xiiif-body-too-large (nth 0 captured)))
      (should (equal "http://x/big.jpg" (nth 1 captured)))
      (should (equal '(999999 10) (nthcdr 2 captured))))))

;;; ---- Retry-After exposure ----

(ert-deftest xiiif-api--retry-after-seconds/shapes ()
  (should (equal 120 (xiiif-api--retry-after-seconds "120")))
  (should (equal 0 (xiiif-api--retry-after-seconds "0")))
  ;; An HTTP date in the past clamps to 0.
  (should (equal 0 (xiiif-api--retry-after-seconds
                    "Wed, 21 Oct 2015 07:28:00 GMT")))
  (should-not (xiiif-api--retry-after-seconds "soon"))
  (should-not (xiiif-api--retry-after-seconds nil)))

(ert-deftest xiiif-api--response-json/429-carries-retry-after ()
  (xiiif-api-test--with-response
   "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 7\r\n\r\n{}"
   (lambda ()
     (let ((err (should-error (xiiif-api--response-json "http://x")
                              :type 'xiiif-http-error)))
       (should (equal '(xiiif-http-error "http://x" 429 :retry-after 7)
                      err))))))

(ert-deftest xiiif-api--response-json/error-without-retry-after ()
  (xiiif-api-test--with-response
   "HTTP/1.1 503 Service Unavailable\r\n\r\n{}"
   (lambda ()
     (let ((err (should-error (xiiif-api--response-json "http://x")
                              :type 'xiiif-http-error)))
       (should (equal '(xiiif-http-error "http://x" 503) err))))))


(ert-deftest xiiif-api-error-hint/body-too-large ()
  (should (string-match-p
           "too large.*11 > 10 bytes"
           (xiiif-api-error-hint
            '(xiiif-body-too-large "http://x/m" 11 10)))))


(ert-deftest xiiif-api-fetch-json-async/invalid-url-calls-errback ()
  (let (captured)
    (xiiif-api-fetch-json-async
     "not-a-url"
     (lambda (_json) (error "callback should not fire"))
     (lambda (err) (setq captured err)))
    (should (eq 'xiiif-network-error (nth 0 captured)))
    (should (equal "not-a-url" (nth 1 captured)))))



;;; ---- error hints ----

(ert-deftest xiiif-api-error-hint/401 ()
  (should (string-match-p
           "requires authentication"
           (xiiif-api-error-hint '(xiiif-http-error "http://x/m" 401)))))

(ert-deftest xiiif-api-error-hint/403 ()
  (should (string-match-p
           "access denied"
           (xiiif-api-error-hint '(xiiif-http-error "http://x/m" 403)))))

(ert-deftest xiiif-api-error-hint/404 ()
  (should (string-match-p
           "not found"
           (xiiif-api-error-hint '(xiiif-http-error "http://x/m" 404)))))

(ert-deftest xiiif-api-error-hint/429 ()
  (should (string-match-p
           "rate limited"
           (xiiif-api-error-hint '(xiiif-http-error "http://x/m" 429)))))

(ert-deftest xiiif-api-error-hint/5xx ()
  (should (string-match-p
           "upstream error 503"
           (xiiif-api-error-hint '(xiiif-http-error "http://x/m" 503))))
  (should (string-match-p
           "upstream error 500"
           (xiiif-api-error-hint '(xiiif-http-error "http://x/m" 500)))))

(ert-deftest xiiif-api-error-hint/network ()
  (should (string-match-p
           "network error for http://x/m: connection refused"
           (xiiif-api-error-hint
            '(xiiif-network-error "http://x/m" "connection refused")))))

(ert-deftest xiiif-api-error-hint/parse ()
  (should (string-match-p
           "could not parse http://x/m"
           (xiiif-api-error-hint
            '(xiiif-parse-error "http://x/m" "unexpected token")))))

(ert-deftest xiiif-api-error-hint/unknown ()
  (should (string-match-p
           "some-weird-error"
           (xiiif-api-error-hint '(some-weird-error "http://x/m")))))

(ert-deftest xiiif-api--default-errback/records-last ()
  "The default errback stores the incident for `xiiif-retry-last'."
  (let ((xiiif-api-last-error nil))
    (xiiif-api--default-errback '(xiiif-http-error "http://x/m" 404))
    (should (equal '(xiiif-http-error "http://x/m" 404)
                   xiiif-api-last-error))))

(provide 'xiiif-api-test)
;;; xiiif-api-test.el ends here
