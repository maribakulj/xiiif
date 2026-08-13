;;; xiiif-redirect-test.el --- Tests for per-hop redirect inspection -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; W10.4 validated the URL a fetch starts from and bounded how many
;; redirections it would follow.  Both transports still followed the
;; chain themselves, so xiiif never saw where it went: a public URL
;; redirecting to `169.254.169.254' was reached, and the count told us
;; nothing about that.
;;
;; The tests here are about the hop that turns.  A chain is not
;; trustworthy because it started on a trustworthy host, and the
;; expensive half of that sentence is that the check has to happen
;; *before* the next request goes out - detecting it afterwards means
;; the request already reached the metadata service.  Several tests
;; therefore assert on what was *not* requested.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-api)
(require 'xiiif-url)
(require 'xiiif-http-cache)

;;; ---------- resolving a Location ----------

(ert-deftest xiiif-redirect/absolute-location-is-taken-as-is ()
  (should (equal "https://b.example/m.json"
                 (xiiif-api--redirect-target "https://b.example/m.json"
                                             "https://a.example/x"))))

(ert-deftest xiiif-redirect/relative-locations-resolve-against-the-current-url ()
  ;; RFC 7231 allows a relative Location, and a policy that only looks
  ;; at the header text would see no host at all and pass it.
  (should (equal "https://a.example/iiif/m.json"
                 (xiiif-api--redirect-target "/iiif/m.json"
                                             "https://a.example/x/y")))
  (should (equal "https://a.example/x/m.json"
                 (xiiif-api--redirect-target "m.json"
                                             "https://a.example/x/y"))))

(ert-deftest xiiif-redirect/a-blank-location-is-not-a-target ()
  (dolist (loc '(nil "" "   "))
    (should-not (xiiif-api--redirect-target loc "https://a.example/x"))))

;;; ---------- the hop that turns ----------

(ert-deftest xiiif-redirect/a-hop-onto-a-refused-host-is-refused ()
  "The whole point: the chain starts allowed and ends where it must not."
  (should-error (xiiif-api--checked-hop "http://169.254.169.254/latest/meta"
                                        "https://a.example/x" 1)
                :type 'xiiif-url-refused)
  (should-error (xiiif-api--checked-hop "http://127.0.0.1/iiif/m"
                                        "https://a.example/x" 1)
                :type 'xiiif-url-refused)
  (should-error (xiiif-api--checked-hop "ftp://a.example/m"
                                        "https://a.example/x" 1)
                :type 'xiiif-url-refused))

(ert-deftest xiiif-redirect/a-relative-hop-onto-a-refused-host-is-refused ()
  "Resolution happens before the check, not instead of it."
  (should-error (xiiif-api--checked-hop "/latest/meta"
                                        "http://169.254.169.254/x" 1)
                :type 'xiiif-url-refused))

(ert-deftest xiiif-redirect/an-allowed-hop-returns-its-absolute-target ()
  (should (equal "https://b.example/m.json"
                 (xiiif-api--checked-hop "https://b.example/m.json"
                                         "https://a.example/x" 1)))
  (should (equal "https://a.example/m.json"
                 (xiiif-api--checked-hop "/m.json" "https://a.example/x" 3))))

(ert-deftest xiiif-redirect/the-chain-is-still-bounded ()
  (let ((xiiif-url-max-redirections 3))
    (should (xiiif-api--checked-hop "https://b.example/m" "https://a.example/x" 3))
    (should-error (xiiif-api--checked-hop "https://b.example/m"
                                          "https://a.example/x" 4)
                  :type 'xiiif-network-error)))

(ert-deftest xiiif-redirect/a-redirect-without-a-location-is-an-error ()
  (should-error (xiiif-api--checked-hop nil "https://a.example/x" 1)
                :type 'xiiif-network-error))

;;; ---------- the url backend, driven hop by hop ----------

(defun xiiif-redirect-test--buffer (status &optional location body)
  "Return a fake `url' response buffer with STATUS and LOCATION."
  (let ((buf (generate-new-buffer " *xiiif-redirect-test*")))
    (with-current-buffer buf
      (insert (format "HTTP/1.1 %d Something\r\n" status))
      (when location (insert (format "Location: %s\r\n" location)))
      (insert "Content-Type: application/json\r\n\r\n")
      (insert (or body "")))
    buf))

(defmacro xiiif-redirect-test--with-url-backend (script &rest body)
  "Run BODY with `url-retrieve-synchronously' driven by SCRIPT.
SCRIPT is an alist of (URL . (STATUS LOCATION BODY)).  Binds
`requested' to the URLs asked for, oldest first - what a test asserts
on when the point is that a request never went out."
  (declare (indent 1) (debug (form body)))
  `(let ((requested nil)
         (xiiif-api-backend 'url)
         (xiiif-http-cache-enabled nil))
     (cl-letf (((symbol-function 'xiiif-api--plz-available-p) (lambda () nil))
               ((symbol-function 'url-retrieve-synchronously)
                (lambda (u &rest _)
                  (setq requested (append requested (list u)))
                  (let ((spec (cdr (assoc u ,script))))
                    (unless spec (error "unscripted URL: %s" u))
                    (apply #'xiiif-redirect-test--buffer spec)))))
       ,@body)))

(ert-deftest xiiif-redirect/url-backend-follows-an-allowed-chain ()
  (xiiif-redirect-test--with-url-backend
      '(("https://a.example/m"  . (302 "https://b.example/m"))
        ("https://b.example/m"  . (200 nil "{\"ok\": true}")))
    (should (eq t (alist-get 'ok (xiiif-api-fetch-json "https://a.example/m"))))
    (should (equal '("https://a.example/m" "https://b.example/m") requested))))

(ert-deftest xiiif-redirect/url-backend-refuses-the-turning-hop-before-requesting-it ()
  "The refused URL must never appear in `requested'."
  (xiiif-redirect-test--with-url-backend
      '(("https://a.example/m" . (302 "http://169.254.169.254/latest/meta")))
    (should-error (xiiif-api-fetch-json "https://a.example/m")
                  :type 'xiiif-url-refused)
    (should (equal '("https://a.example/m") requested))))

(ert-deftest xiiif-redirect/url-backend-stops-at-the-bound ()
  (let ((xiiif-url-max-redirections 2))
    (xiiif-redirect-test--with-url-backend
        '(("https://a.example/1" . (302 "https://a.example/2"))
          ("https://a.example/2" . (302 "https://a.example/3"))
          ("https://a.example/3" . (302 "https://a.example/4"))
          ("https://a.example/4" . (200 nil "{}")))
      (should-error (xiiif-api-fetch-json "https://a.example/1")
                    :type 'xiiif-network-error)
      ;; Three requests: the original and two allowed hops.
      (should (= 3 (length requested))))))

(ert-deftest xiiif-redirect/url-backend-carries-a-relative-hop ()
  (xiiif-redirect-test--with-url-backend
      '(("https://a.example/x/m" . (302 "../iiif/m.json"))
        ("https://a.example/iiif/m.json" . (200 nil "{\"ok\": true}")))
    (should (eq t (alist-get 'ok (xiiif-api-fetch-json "https://a.example/x/m"))))))

;;; ---------- asynchronous, same rule ----------

(defmacro xiiif-redirect-test--with-url-async (script &rest body)
  "Like `xiiif-redirect-test--with-url-backend', for `url-retrieve'."
  (declare (indent 1) (debug (form body)))
  `(let ((requested nil)
         (xiiif-api-backend 'url)
         (xiiif-http-cache-enabled nil))
     (cl-letf (((symbol-function 'xiiif-api--plz-available-p) (lambda () nil))
               ((symbol-function 'url-retrieve)
                (lambda (u cb &rest _)
                  (setq requested (append requested (list u)))
                  (let* ((spec (cdr (assoc u ,script)))
                         (buf (progn
                                (unless spec (error "unscripted URL: %s" u))
                                (apply #'xiiif-redirect-test--buffer spec))))
                    (with-current-buffer buf (funcall cb nil))
                    buf))))
       ,@body)))

(ert-deftest xiiif-redirect/async-follows-an-allowed-chain ()
  (let (got failed)
    (xiiif-redirect-test--with-url-async
        '(("https://a.example/m" . (302 "https://b.example/m"))
          ("https://b.example/m" . (200 nil "{\"ok\": true}")))
      (xiiif-api-fetch-json-async "https://a.example/m"
                                  (lambda (j) (setq got j))
                                  (lambda (e) (setq failed e)))
      (should-not failed)
      (should (eq t (alist-get 'ok got)))
      (should (equal '("https://a.example/m" "https://b.example/m") requested)))))

(ert-deftest xiiif-redirect/async-refuses-the-turning-hop-before-requesting-it ()
  (let (got failed)
    (xiiif-redirect-test--with-url-async
        '(("https://a.example/m" . (302 "http://169.254.169.254/latest/meta")))
      (xiiif-api-fetch-json-async "https://a.example/m"
                                  (lambda (j) (setq got j))
                                  (lambda (e) (setq failed e)))
      (should-not got)
      (should (eq 'xiiif-url-refused (car failed)))
      (should (equal '("https://a.example/m") requested)))))

(ert-deftest xiiif-redirect/async-bytes-obey-the-same-rule ()
  (let (got failed)
    (xiiif-redirect-test--with-url-async
        '(("https://a.example/i.jpg" . (302 "http://127.0.0.1/i.jpg")))
      (xiiif-api-fetch-bytes-async "https://a.example/i.jpg"
                                   (lambda (b) (setq got b))
                                   (lambda (e) (setq failed e)))
      (should-not got)
      (should (eq 'xiiif-url-refused (car failed)))
      (should (equal '("https://a.example/i.jpg") requested)))))

;;; ---------- downloads are not a side door ----------
;;
;; `url-copy-file' and curl's --location followed chains for the
;; download paths too.  Turning that off without replacing it would
;; have broken every redirected download while the JSON tests stayed
;; green, so the same driver runs here and is tested here.

(ert-deftest xiiif-redirect/download-follows-an-allowed-chain ()
  (let ((dest (make-temp-file "xiiif-redirect-dl")))
    (unwind-protect
        (xiiif-redirect-test--with-url-backend
            '(("https://a.example/i.jpg" . (302 "https://b.example/i.jpg"))
              ("https://b.example/i.jpg" . (200 nil "IMAGEBYTES")))
          (should (equal dest (xiiif-api-download-file
                               "https://a.example/i.jpg" dest)))
          (should (equal "IMAGEBYTES"
                         (with-temp-buffer
                           (insert-file-contents dest)
                           (buffer-string))))
          (should (equal '("https://a.example/i.jpg" "https://b.example/i.jpg")
                         requested)))
      (delete-file dest))))

(ert-deftest xiiif-redirect/download-refuses-the-turning-hop ()
  (let ((dest (make-temp-file "xiiif-redirect-dl")))
    (unwind-protect
        (xiiif-redirect-test--with-url-backend
            '(("https://a.example/i.jpg" . (302 "http://169.254.169.254/i")))
          (should-error (xiiif-api-download-file "https://a.example/i.jpg" dest)
                        :type 'xiiif-url-refused)
          (should (equal '("https://a.example/i.jpg") requested)))
      (delete-file dest))))

;;; ---------- cancellation survives the chain ----------

(ert-deftest xiiif-redirect/the-handle-callers-get-is-the-durable-one ()
  "Following the chain ourselves changes the transport handle under
the caller, so what they receive must be the cell, not hop 0's buffer."
  (xiiif-redirect-test--with-url-async
      '(("https://a.example/m" . (200 nil "{}")))
    (should (xiiif-api-chain-p
             (xiiif-api-fetch-json-async "https://a.example/m"
                                         #'ignore #'ignore)))))

(ert-deftest xiiif-redirect/cancelling-the-cell-reaches-the-hop-in-flight ()
  (let ((chain (xiiif-api--chain))
        (buf (generate-new-buffer " *xiiif-redirect-hop*")))
    (setf (xiiif-api-chain-handle chain) buf)
    (xiiif-api-cancel chain)
    (should (xiiif-api-chain-cancelled chain))
    (should-not (buffer-live-p buf))))

(ert-deftest xiiif-redirect/a-cancelled-chain-stops-between-hops ()
  "Between two hops there is no live handle to kill, only the flag.
Without it a cancelled chain would keep walking and deliver a result
the caller has already stopped waiting for."
  (let ((delivered nil)
        (chain (xiiif-api--chain)))
    (setf (xiiif-api-chain-cancelled chain) t)
    (xiiif-redirect-test--with-url-async
        '(("https://a.example/m" . (200 nil "{\"ok\": true}")))
      (xiiif-api--url-async-chain
       chain "https://a.example/m" "https://a.example/m" 0
       #'xiiif-api--request-headers nil
       (lambda (_) (setq delivered 'errback))
       (lambda () (setq delivered 'callback))))
    (should-not delivered)))

;;; ---------- the plz backend, same rule ----------
;;
;; Reuses the fake-plz harness so these run without plz or curl.  With
;; --location gone from the curl arguments, a 3xx arrives as a plz
;; error carrying the response instead of being followed inside curl.

(require 'xiiif-backend-test)

(defun xiiif-redirect-test--plz-redirect (location)
  "Return a plz error standing for a 302 to LOCATION."
  (xiiif-backend-test--err
   :response (xiiif-backend-test--resp
              :status 302 :headers `((location . ,location)))))

(ert-deftest xiiif-redirect/plz-sync-follows-an-allowed-chain ()
  (let ((requested nil) (got nil))
    (xiiif-backend-test--with-fake-plz
        (lambda (_method u &rest _kw)
          (setq requested (append requested (list u)))
          (if (equal u "https://a.example/m")
              (signal 'plz-http-error
                      (list "redirect"
                            (xiiif-redirect-test--plz-redirect
                             "https://b.example/m")))
            (xiiif-backend-test--resp
             :status 200
             :headers '((content-type . "application/json"))
             :body "{\"ok\": true}")))
      (setq got (xiiif-api-fetch-json "https://a.example/m")))
    (should (eq t (alist-get 'ok got)))
    (should (equal '("https://a.example/m" "https://b.example/m") requested))))

(ert-deftest xiiif-redirect/plz-sync-refuses-the-turning-hop ()
  (let ((requested nil))
    (xiiif-backend-test--with-fake-plz
        (lambda (_method u &rest _kw)
          (setq requested (append requested (list u)))
          (signal 'plz-http-error
                  (list "redirect"
                        (xiiif-redirect-test--plz-redirect
                         "http://169.254.169.254/latest/meta"))))
      (should-error (xiiif-api-fetch-json "https://a.example/m")
                    :type 'xiiif-url-refused))
    (should (equal '("https://a.example/m") requested))))

(ert-deftest xiiif-redirect/plz-async-refuses-the-turning-hop ()
  (let ((requested nil) (got nil) (failed nil))
    (xiiif-backend-test--with-fake-plz
        (lambda (_method u &rest kw)
          (setq requested (append requested (list u)))
          (funcall (plist-get kw :else)
                   (xiiif-redirect-test--plz-redirect "http://127.0.0.1/m"))
          'fake-process)
      (xiiif-api-fetch-json-async "https://a.example/m"
                                  (lambda (j) (setq got j))
                                  (lambda (e) (setq failed e))))
    (should-not got)
    (should (eq 'xiiif-url-refused (car failed)))
    (should (equal '("https://a.example/m") requested))))

(ert-deftest xiiif-redirect/plz-async-follows-an-allowed-chain ()
  (let ((requested nil) (got nil) (failed nil))
    (xiiif-backend-test--with-fake-plz
        (lambda (_method u &rest kw)
          (setq requested (append requested (list u)))
          (if (equal u "https://a.example/m")
              (funcall (plist-get kw :else)
                       (xiiif-redirect-test--plz-redirect "https://b.example/m"))
            (funcall (plist-get kw :then)
                     (xiiif-backend-test--resp
                      :status 200
                      :headers '((content-type . "application/json"))
                      :body "{\"ok\": true}")))
          'fake-process)
      (xiiif-api-fetch-json-async "https://a.example/m"
                                  (lambda (j) (setq got j))
                                  (lambda (e) (setq failed e))))
    (should-not failed)
    (should (eq t (alist-get 'ok got)))
    (should (equal '("https://a.example/m" "https://b.example/m") requested))))

(ert-deftest xiiif-redirect/plz-still-tells-a-304-from-a-redirect ()
  "The conditional cache and the redirect path share the else branch."
  (let ((got nil))
    (xiiif-backend-test--with-fake-plz
        (lambda (_method _u &rest kw)
          (funcall (plist-get kw :else)
                   (xiiif-backend-test--err
                    :response (xiiif-backend-test--resp :status 304)))
          'fake-process)
      (cl-letf (((symbol-function 'xiiif-api--cached-json-or-error)
                 (lambda (_) '((cached . t)))))
        (xiiif-api-fetch-json-async "https://a.example/m"
                                    (lambda (j) (setq got j))
                                    #'ignore)))
    (should (eq t (alist-get 'cached got)))))

(provide 'xiiif-redirect-test)
;;; xiiif-redirect-test.el ends here
