;;; xiiif-url-test.el --- Tests for the xiiif URL policy -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; What the policy must refuse, and — just as important — what it must
;; keep letting through.  A policy that blocks ordinary IIIF hosts gets
;; disabled wholesale by the first user it inconveniences, which is
;; worse than no policy at all.

;;; Code:

(require 'ert)
(require 'xiiif-url)

;; `defvar' without a value marks a symbol special only inside the file that
;; declares it. `xiiif-api' does so for plz's variables; the test file must do
;; the same, or its `let' binds lexically and the code under test never sees it.
(defvar plz-curl-default-args)

;;; ---------- what stays allowed ----------

(ert-deftest xiiif-url/ordinary-hosts-pass ()
  (dolist (url '("https://iiif.bodleian.ox.ac.uk/iiif/manifest/x.json"
                 "https://gallica.bnf.fr/iiif/ark:/12148/btv1b/manifest.json"
                 "http://example.org/iiif/m"
                 "https://example.org:8443/iiif/m"))
    (should (xiiif-url-allowed-p url))))

(ert-deftest xiiif-url/file-urls-pass ()
  ;; Local fixtures and downloaded snapshots. No host to judge.
  (should (xiiif-url-allowed-p "file:///tmp/manifest.json"))
  (should (xiiif-url-allowed-p "file:///home/u/iiif/m.json")))

;;; ---------- schemes ----------

(ert-deftest xiiif-url/unlisted-schemes-are-refused ()
  (dolist (url '("ftp://example.org/m.json"
                 "gopher://example.org/m"
                 "javascript://example.org/"
                 "data:application/json,{}"))
    (should-not (xiiif-url-allowed-p url)))
  (should (eq 'scheme (car (xiiif-url-refusal "ftp://example.org/m.json")))))

(ert-deftest xiiif-url/scheme-list-is-honoured ()
  (let ((xiiif-url-allowed-schemes '("https")))
    (should (xiiif-url-allowed-p "https://example.org/m"))
    (should-not (xiiif-url-allowed-p "http://example.org/m"))))

(ert-deftest xiiif-url/malformed-input-is-refused-not-thrown ()
  (dolist (url (list "" "not a url" "https://" "//example.org/m" nil 42))
    (should-not (xiiif-url-allowed-p url))))

;;; ---------- the address that matters ----------

(ert-deftest xiiif-url/cloud-metadata-is-never-reachable ()
  ;; On every major cloud this answers with instance credentials.
  ;; No setting lifts the refusal — that is the point of the tier.
  (dolist (url '("http://169.254.169.254/latest/meta-data/"
                 "http://169.254.169.254/computeMetadata/v1/"
                 "http://metadata.google.internal/computeMetadata/v1/"
                 "http://[fe80::1]/meta"))
    (should-not (xiiif-url-allowed-p url))
    (let ((xiiif-url-allow-private-hosts t))
      (should-not (xiiif-url-allowed-p url))
      (should (eq 'link-local (car (xiiif-url-refusal url)))))))

;;; ---------- private hosts, refused by default ----------

(ert-deftest xiiif-url/private-hosts-are-refused-by-default ()
  (dolist (url '("http://127.0.0.1:8182/iiif/m"
                 "http://localhost:8182/iiif/m"
                 "http://10.0.0.5/iiif/m"
                 "http://172.16.3.4/iiif/m"
                 "http://172.31.255.1/iiif/m"
                 "http://192.168.1.10/iiif/m"
                 "http://[::1]:8182/iiif/m"
                 "http://cantaloupe.local/iiif/m"
                 "http://box.internal/iiif/m"))
    (should-not (xiiif-url-allowed-p url))
    (should (eq 'private (car (xiiif-url-refusal url))))))

(ert-deftest xiiif-url/private-hosts-open-with-the-setting ()
  ;; Running a local Cantaloupe is ordinary practice; the user says so once.
  (let ((xiiif-url-allow-private-hosts t))
    (dolist (url '("http://127.0.0.1:8182/iiif/m"
                   "http://localhost:8182/iiif/m"
                   "http://192.168.1.10/iiif/m"
                   "http://[::1]:8182/iiif/m"))
      (should (xiiif-url-allowed-p url)))))

(ert-deftest xiiif-url/public-ranges-adjacent-to-private-ones-pass ()
  ;; 172.16/12 stops at 172.31; 172.32 is public. Off-by-one here would
  ;; silently block real hosts.
  (dolist (url '("http://172.15.0.1/m" "http://172.32.0.1/m"
                 "http://11.0.0.1/m" "http://192.169.1.1/m"
                 "http://169.253.0.1/m" "http://169.255.0.1/m"))
    (should (xiiif-url-allowed-p url))))

;;; ---------- how the refusal reaches the caller ----------

(ert-deftest xiiif-url/check-signals-with-a-usable-message ()
  (let ((err (should-error (xiiif-url-check "http://169.254.169.254/latest/")
                           :type 'xiiif-url-refused)))
    (should (string-match-p "link-local\\|metadata" (nth 2 err))))
  (let ((err (should-error (xiiif-url-check "http://127.0.0.1/iiif/m")
                           :type 'xiiif-url-refused)))
    ;; The message must name the setting, or the user cannot act on it.
    (should (string-match-p "xiiif-url-allow-private-hosts" (nth 2 err)))))

(ert-deftest xiiif-url/refusal-is-a-network-error-subtype ()
  ;; Existing handlers catch `xiiif-network-error'; they must keep working.
  (should (memq 'xiiif-network-error (get 'xiiif-url-refused 'error-conditions))))

(ert-deftest xiiif-url/check-returns-the-url-when-allowed ()
  (should (equal "https://example.org/m" (xiiif-url-check "https://example.org/m"))))

;;; ---------- the api layer enforces it ----------

(ert-deftest xiiif-url/api-predicate-follows-the-policy ()
  (require 'xiiif-api)
  (should (xiiif-api--valid-url-p "https://example.org/iiif/m"))
  (should-not (xiiif-api--valid-url-p "http://169.254.169.254/latest/"))
  (should-not (xiiif-api--valid-url-p "http://127.0.0.1/iiif/m"))
  (let ((xiiif-url-allow-private-hosts t))
    (should (xiiif-api--valid-url-p "http://127.0.0.1/iiif/m"))))

(ert-deftest xiiif-url/redirect-bound-reaches-curl-arguments ()
  (require 'xiiif-api)
  (let ((xiiif-url-max-redirections 2)
        (plz-curl-default-args '("--silent" "--max-redirs" "99")))
    (let ((args (xiiif-api--curl-redirect-args)))
      (should (member "--silent" args))
      ;; The old value must be gone, not merely followed by a new one.
      (should-not (member "99" args))
      (should (equal '("--max-redirs" "2") (last args 2))))))

(provide 'xiiif-url-test)
;;; xiiif-url-test.el ends here
