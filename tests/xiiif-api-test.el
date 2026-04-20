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
