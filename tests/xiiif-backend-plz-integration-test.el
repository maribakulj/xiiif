;;; xiiif-backend-plz-integration-test.el --- plz backend against a live loopback server -*- lexical-binding: t; -*-

;;; Commentary:

;; End-to-end exercise of the plz transport backend: real plz, real
;; curl, and a throwaway HTTP server on the loopback interface run
;; from this very Emacs.  Every test is skipped when plz or curl is
;; not available (e.g. in CI), so the suite adds no dependency; on a
;; machine with plz installed it validates what the mocked tests in
;; xiiif-backend-test.el can only approximate.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-api)
(require 'xiiif-http-cache)

(defvar plz-curl-program)
(defvar plz-curl-default-args)

(defun xiiif-plz-int--available-p ()
  "Return non-nil when real plz and curl are usable."
  (and (require 'plz nil t)
       (executable-find plz-curl-program)))

(defvar xiiif-plz-int--responses nil
  "Alist of (PATH . RAW-RESPONSE) served by the loopback server.")

(defvar xiiif-plz-int--requests nil
  "Raw request heads received by the loopback server, newest first.")

(defun xiiif-plz-int--response (status headers body)
  "Build a raw HTTP/1.1 response with STATUS, HEADERS alist and BODY."
  (format "HTTP/1.1 %s\r\n%sContent-Length: %d\r\nConnection: close\r\n\r\n%s"
          status
          (mapconcat (lambda (h) (format "%s: %s\r\n" (car h) (cdr h)))
                     headers "")
          (string-bytes body)
          body))

(defun xiiif-plz-int--filter (proc chunk)
  "Accumulate CHUNK for connection PROC; answer once headers are in."
  (let ((head (concat (or (process-get proc :head) "") chunk)))
    (process-put proc :head head)
    (when (string-match-p "\r\n\r\n" head)
      (push head xiiif-plz-int--requests)
      (let ((path (and (string-match "\\`[A-Z]+ \\([^ ]+\\)" head)
                       (match-string 1 head))))
        ;; /hang records the request but never answers - used by the
        ;; cancellation test to keep a request in flight.
        (unless (equal path "/hang")
          (process-send-string
           proc
           (or (cdr (assoc path xiiif-plz-int--responses))
               (xiiif-plz-int--response "404 Not Found" nil "")))
          (process-send-eof proc))))))

(defmacro xiiif-plz-int--with-server (responses &rest body)
  "Serve RESPONSES on a loopback HTTP server while running BODY.
Anaphoric: BODY sees `base', the http://127.0.0.1:PORT prefix.
Forces the plz backend and routes curl around any proxy."
  (declare (indent 1) (debug (form body)))
  `(let* ((xiiif-plz-int--responses ,responses)
          (xiiif-plz-int--requests nil)
          (server (make-network-process
                   :name "xiiif-plz-int-server"
                   :server t
                   :host "127.0.0.1"
                   :service t
                   :family 'ipv4
                   :noquery t
                   :filter #'xiiif-plz-int--filter))
          (base (format "http://127.0.0.1:%s"
                        (process-contact server :service)))
          (plz-curl-default-args
           (append plz-curl-default-args '("--noproxy" "*")))
          ;; The server is on 127.0.0.1, which the URL policy refuses by
          ;; default. Reaching a loopback host is exactly what this suite is
          ;; for, so it says so rather than being exempted quietly.
          (xiiif-url-allow-private-hosts t)
          (xiiif-api-backend 'plz))
     (ignore base)
     (unwind-protect
         (progn ,@body)
       (delete-process server))))

(defun xiiif-plz-int--wait (pred &optional timeout)
  "Pump process output until PRED returns non-nil or TIMEOUT elapses."
  (let ((deadline (+ (float-time) (or timeout 8.0))))
    (while (and (not (funcall pred))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall pred)))


(ert-deftest xiiif-plz-integration/json-and-conditional-cache ()
  "Async JSON fetch, validator caching, then a 304 served from cache."
  (skip-unless (xiiif-plz-int--available-p))
  (let* ((tmpdir (make-temp-file "xiiif-plz-cache" t))
         (xiiif-http-cache-enabled t)
         (xiiif-http-cache-directory tmpdir)
         (got1 nil) (got2 nil) (failed nil))
    (unwind-protect
        (xiiif-plz-int--with-server
            (list (cons "/m.json"
                        (xiiif-plz-int--response
                         "200 OK"
                         '(("Content-Type" . "application/json")
                           ("ETag" . "\"tag1\""))
                         "{\"a\": 1}")))
          (xiiif-api-fetch-json-async
           (concat base "/m.json")
           (lambda (json) (setq got1 json))
           (lambda (err) (setq failed err)))
          (should (xiiif-plz-int--wait (lambda () (or got1 failed))))
          (should-not failed)
          (should (equal 1 (alist-get 'a got1)))
          (should (cl-some (lambda (req)
                             (string-match-p "User-Agent: xiiif\\.el" req))
                           xiiif-plz-int--requests))
          ;; Same URL again: the server now answers 304 and the body
          ;; must come from the on-disk cache, revalidated with the
          ;; stored ETag.
          (setq xiiif-plz-int--responses
                (list (cons "/m.json"
                            (xiiif-plz-int--response "304 Not Modified"
                                                     nil ""))))
          (xiiif-api-fetch-json-async
           (concat base "/m.json")
           (lambda (json) (setq got2 json))
           (lambda (err) (setq failed err)))
          (should (xiiif-plz-int--wait (lambda () (or got2 failed))))
          (should-not failed)
          (should (equal 1 (alist-get 'a got2)))
          (should (cl-some (lambda (req)
                             (string-match-p "If-None-Match: \"tag1\"" req))
                           xiiif-plz-int--requests)))
      (delete-directory tmpdir t))))


(ert-deftest xiiif-plz-integration/http-error-translated ()
  (skip-unless (xiiif-plz-int--available-p))
  (let ((captured nil) (got nil))
    (xiiif-plz-int--with-server nil
      (xiiif-api-fetch-json-async
       (concat base "/missing.json")
       (lambda (json) (setq got json))
       (lambda (err) (setq captured err)))
      (should (xiiif-plz-int--wait (lambda () (or got captured))))
      (should-not got)
      (should (eq 'xiiif-http-error (nth 0 captured)))
      (should (equal 404 (nth 2 captured))))))


(ert-deftest xiiif-plz-integration/bytes-unibyte ()
  (skip-unless (xiiif-plz-int--available-p))
  (let ((got nil) (failed nil))
    (xiiif-plz-int--with-server
        (list (cons "/img.bin"
                    (xiiif-plz-int--response
                     "200 OK"
                     '(("Content-Type" . "application/octet-stream"))
                     "raw-image-bytes")))
      (xiiif-api-fetch-bytes-async
       (concat base "/img.bin")
       (lambda (bytes) (setq got bytes))
       (lambda (err) (setq failed err)))
      (should (xiiif-plz-int--wait (lambda () (or got failed))))
      (should-not failed)
      (should (equal "raw-image-bytes" got))
      (should-not (multibyte-string-p got)))))


(ert-deftest xiiif-plz-integration/sync-json ()
  (skip-unless (xiiif-plz-int--available-p))
  (let ((xiiif-http-cache-enabled nil))
    (xiiif-plz-int--with-server
        (list (cons "/m.json"
                    (xiiif-plz-int--response
                     "200 OK"
                     '(("Content-Type" . "application/json"))
                     "{\"sync\": true}")))
      (should (eq t (alist-get
                     'sync
                     (xiiif-api-fetch-json (concat base "/m.json"))))))))


(ert-deftest xiiif-plz-integration/cancel-is-silent ()
  "Cancelling an in-flight plz request invokes neither callback."
  (skip-unless (xiiif-plz-int--available-p))
  (let ((fired nil))
    (xiiif-plz-int--with-server nil
      ;; /hang is accepted by the server but never answered, so the
      ;; request is still in flight when we cancel it.
      (let ((handle (xiiif-api-fetch-json-async
                     (concat base "/hang")
                     (lambda (_) (setq fired 'callback))
                     (lambda (_) (setq fired 'errback)))))
        (should (processp handle))
        ;; Let the request reach the server first.
        (should (xiiif-plz-int--wait
                 (lambda () xiiif-plz-int--requests)))
        (xiiif-api-cancel handle)
        ;; Give any stray events a chance to fire.
        (dotimes (_ 15) (accept-process-output nil 0.02))
        (should-not fired)))))

(provide 'xiiif-backend-plz-integration-test)
;;; xiiif-backend-plz-integration-test.el ends here
