;;; xiiif-auth-test.el --- Tests for auth-source + source ID encoding -*- lexical-binding: t; -*-

;;; Commentary:

;; Covers Sprint 6: auth-source-backed Authorization header,
;; percent-safe id substitution, optional url-hexify of source ids,
;; and the soft Content-Type warning.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-errors)
(require 'xiiif-profiles)
(require 'xiiif-api)
(require 'xiiif-sources)


;;; ---- profile auth-source lookup ----

(defun xiiif-auth-test--stub-authsource (secret)
  "Install a stub `auth-source-search' that returns SECRET once."
  (lambda (&rest args)
    (ignore args)
    (list (list :secret secret))))

(ert-deftest xiiif-profile-auth-header/resolves-bearer ()
  (require 'auth-source)
  (cl-letf* ((xiiif-server-profiles
              '(("\\`https://secure\\.example"
                 :auth (:user "svc"))))
             ((symbol-function 'auth-source-search)
              (xiiif-auth-test--stub-authsource "token-abc")))
    (let ((header (xiiif-profile-auth-header
                   "https://secure.example/m/manifest")))
      (should (equal "Authorization" (car header)))
      (should (equal "Bearer token-abc" (cdr header))))))

(ert-deftest xiiif-profile-auth-header/custom-scheme ()
  (require 'auth-source)
  (cl-letf* ((xiiif-server-profiles
              '(("\\`https://s\\.example"
                 :auth (:scheme "Token"))))
             ((symbol-function 'auth-source-search)
              (xiiif-auth-test--stub-authsource "xyz")))
    (let ((header (xiiif-profile-auth-header
                   "https://s.example/m")))
      (should (equal "Token xyz" (cdr header))))))

(ert-deftest xiiif-profile-auth-header/nil-when-no-profile ()
  (let ((xiiif-server-profiles nil))
    (should-not (xiiif-profile-auth-header "https://other.example"))))

(ert-deftest xiiif-profile-auth-header/resolves-secret-function ()
  "auth-source returns :secret as a function when kept encrypted."
  (require 'auth-source)
  (cl-letf* ((xiiif-server-profiles
              '(("\\`https://s\\.example" :auth ())))
             ((symbol-function 'auth-source-search)
              (lambda (&rest _)
                (list (list :secret (lambda () "fn-secret"))))))
    (let ((header (xiiif-profile-auth-header "https://s.example")))
      (should (equal "Bearer fn-secret" (cdr header))))))


;;; ---- header merging ----

(ert-deftest xiiif-api--request-headers/profile-auth-appended ()
  (require 'auth-source)
  (cl-letf* ((xiiif-server-profiles
              '(("\\`https://s\\.example" :auth ())))
             ((symbol-function 'auth-source-search)
              (xiiif-auth-test--stub-authsource "token-via-auth")))
    (let ((hs (xiiif-api--request-headers "https://s.example/m")))
      (should (equal "Bearer token-via-auth"
                     (cdr (assoc "Authorization" hs)))))))

(ert-deftest xiiif-api--request-headers/explicit-header-wins ()
  (require 'auth-source)
  (cl-letf* ((xiiif-server-profiles
              '(("\\`https://s\\.example"
                 :headers (("Authorization" . "Basic hardcoded"))
                 :auth ())))
             ((symbol-function 'auth-source-search)
              (xiiif-auth-test--stub-authsource "shouldnt-be-used")))
    (let* ((hs (xiiif-api--request-headers "https://s.example/m"))
           (vals (cl-remove-if-not
                  (lambda (h) (equal "Authorization" (car h))) hs)))
      ;; Only one Authorization header, the explicit one.
      (should (= 1 (length vals)))
      (should (equal "Basic hardcoded" (cdr (car vals)))))))


;;; ---- source id handling ----

(ert-deftest xiiif-source-build-manifest-url/raw-id-passthrough ()
  "Without :encode-id, the id is dropped in verbatim."
  (let ((source '(:label "Test"
                  :manifest-url "https://x/%s/manifest")))
    (should (equal "https://x/raw:id/manifest"
                   (xiiif-source-build-manifest-url source "raw:id")))))

(ert-deftest xiiif-source-build-manifest-url/encodes-when-requested ()
  (let ((source '(:label "Test"
                  :encode-id t
                  :manifest-url "https://x/%s/manifest")))
    (should (equal "https://x/ark%3A%2F42/manifest"
                   (xiiif-source-build-manifest-url source "ark:/42")))))

(ert-deftest xiiif-source-build-manifest-url/keeps-ark-raw-by-default ()
  "Backwards compat: Gallica-style ARKs pass through unchanged."
  (let ((source (xiiif-source-get 'gallica)))
    (should (equal
             "https://gallica.bnf.fr/iiif/ark:/12148/btv1b/manifest.json"
             (xiiif-source-build-manifest-url
              source "ark:/12148/btv1b")))))


;;; ---- content-type warning ----

(ert-deftest xiiif-api--response-json/warns-on-bad-ct ()
  (let ((warned nil))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (type msg &rest _)
                 (when (eq type 'xiiif) (setq warned msg)))))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n{\"a\":1}")
        (xiiif-api--response-json "http://x")))
    (should warned)
    (should (string-match-p "text/html" warned))))

(ert-deftest xiiif-api--response-json/silent-on-json ()
  (let ((warned nil))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (type msg &rest _)
                 (when (eq type 'xiiif) (setq warned msg)))))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert "HTTP/1.1 200 OK\r\nContent-Type: application/ld+json\r\n\r\n{\"a\":1}")
        (xiiif-api--response-json "http://x")))
    (should-not warned)))


(provide 'xiiif-auth-test)
;;; xiiif-auth-test.el ends here
