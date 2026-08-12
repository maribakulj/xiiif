;;; xiiif-url.el --- URL policy for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Which URLs xiiif is willing to fetch, per SPEC_V1.md §13: allowed
;; schemes, internal hosts refused, redirections bounded.
;;
;; The reason a viewer needs this at all: a manifest is remote data,
;; and it names further URLs - image services, OCR sources, annotation
;; targets, `seeAlso' links.  Following them blindly turns the user's
;; Emacs into a request forwarder for whoever wrote the manifest, which
;; is the shape of an SSRF.  The address that matters most is
;; 169.254.169.254: on every major cloud it answers with instance
;; credentials, and nothing there has ever been a IIIF endpoint.
;;
;; Two tiers, deliberately:
;;
;;   - Link-local and cloud-metadata addresses are refused always.  No
;;     setting lifts it, because no legitimate IIIF service lives there.
;;   - Loopback and private ranges are refused by default and can be
;;     allowed with `xiiif-url-allow-private-hosts'.  Running a local
;;     Cantaloupe or IIPImage is ordinary practice, so this one is a
;;     policy choice rather than a rule - but it is a choice the user
;;     makes explicitly, not a door left open.
;;
;; What this does NOT do yet: re-check each hop of a redirect chain.
;; Both transports follow redirects internally, so xiiif bounds how many
;; hops are allowed but does not see their targets.  A public URL that
;; redirects to a private one is therefore still reachable.  Closing it
;; means following redirects by hand in `xiiif-api'; the bounded count
;; is what limits the damage until then.

;;; Code:

(require 'cl-lib)
(require 'url-parse)
(require 'xiiif-errors)

(defgroup xiiif-url nil
  "Which URLs xiiif is willing to fetch."
  :group 'xiiif
  :prefix "xiiif-url-")

(defcustom xiiif-url-allowed-schemes '("https" "http" "file")
  "URL schemes xiiif will fetch.
`file' is kept for local fixtures and downloaded snapshots.  Removing
`http' is a reasonable hardening step when every source is TLS."
  :type '(repeat string)
  :group 'xiiif-url)

(defcustom xiiif-url-allow-private-hosts nil
  "When non-nil, allow loopback and private-range hosts.
Set this to t to browse a IIIF server running on your own machine or
LAN.  It does not lift the refusal of link-local and cloud-metadata
addresses, which is unconditional."
  :type 'boolean
  :group 'xiiif-url)

(defcustom xiiif-url-max-redirections 5
  "How many redirects a single request may follow.
Bounds redirect loops and chains that walk a request somewhere it was
not pointed.  The hops themselves are not inspected - see the
Commentary."
  :type 'integer
  :group 'xiiif-url)

;;; ---------- host classification ----------

(defconst xiiif-url--metadata-hosts
  '("metadata.google.internal" "metadata" "instance-data")
  "Hostnames that answer with cloud instance credentials.")

(defun xiiif-url--octets (host)
  "Return HOST as a list of four integers, or nil if it is not IPv4."
  (when (string-match
         "\\`\\([0-9]\\{1,3\\}\\)\\.\\([0-9]\\{1,3\\}\\)\\.\\([0-9]\\{1,3\\}\\)\\.\\([0-9]\\{1,3\\}\\)\\'"
         host)
    (let ((parts (mapcar (lambda (n) (string-to-number (match-string n host)))
                         '(1 2 3 4))))
      (and (cl-every (lambda (o) (<= 0 o 255)) parts) parts))))

(defun xiiif-url--ipv6 (host)
  "Return the inside of a bracketed IPv6 HOST, downcased, or nil."
  (when (string-match "\\`\\[\\(.*\\)\\]\\'" host)
    (downcase (match-string 1 host))))

(defun xiiif-url-link-local-p (host)
  "Return non-nil if HOST is link-local or a cloud metadata endpoint.
These are refused whatever `xiiif-url-allow-private-hosts' says."
  (let ((host (downcase (or host "")))
        (octets (xiiif-url--octets (or host ""))))
    (or (member host xiiif-url--metadata-hosts)
        (and octets (= (nth 0 octets) 169) (= (nth 1 octets) 254))
        (let ((v6 (xiiif-url--ipv6 host)))
          (and v6 (string-match-p "\\`fe[89ab]" v6))))))

(defun xiiif-url-private-p (host)
  "Return non-nil if HOST is loopback, private-range, or site-local."
  (let* ((host (downcase (or host "")))
         (octets (xiiif-url--octets host))
         (v6 (xiiif-url--ipv6 host)))
    (or (member host '("localhost" "" "0.0.0.0"))
        (string-suffix-p ".localhost" host)
        (string-suffix-p ".local" host)
        (string-suffix-p ".internal" host)
        (and octets
             (let ((a (nth 0 octets)) (b (nth 1 octets)))
               (or (= a 127)                      ; loopback
                   (= a 10)                       ; private
                   (= a 0)                        ; unspecified
                   (and (= a 172) (<= 16 b 31))   ; private
                   (and (= a 192) (= b 168)))))   ; private
        (and v6 (or (string= v6 "::1")
                    (string-match-p "\\`f[cd]" v6))))))

;;; ---------- policy ----------

(defun xiiif-url-host (url)
  "Return the host of URL, downcased, or nil when it has none."
  (let ((parsed (ignore-errors (url-generic-parse-url url))))
    (when parsed
      (let ((host (url-host parsed)))
        (and (stringp host) (downcase host))))))

(defun xiiif-url-refusal (url)
  "Return why xiiif refuses URL, or nil when the policy allows it.
The value is a cons (REASON . DETAIL) where REASON is one of
`malformed', `scheme', `link-local' or `private'."
  (cond
   ((not (stringp url)) (cons 'malformed "not a string"))
   ((not (string-match-p "\\`[a-zA-Z][a-zA-Z0-9+.-]*://[^[:space:]]+\\'" url))
    (cons 'malformed url))
   (t
    (let* ((parsed (ignore-errors (url-generic-parse-url url)))
           (scheme (and parsed (url-type parsed)))
           (host   (xiiif-url-host url)))
      (cond
       ((not scheme) (cons 'malformed url))
       ((not (member (downcase scheme) xiiif-url-allowed-schemes))
        (cons 'scheme scheme))
       ;; file:// has no host to judge; the scheme check already ruled.
       ((string= (downcase scheme) "file") nil)
       ((xiiif-url-link-local-p host) (cons 'link-local (or host "")))
       ((and (not xiiif-url-allow-private-hosts) (xiiif-url-private-p host))
        (cons 'private (or host "")))
       (t nil))))))

(defun xiiif-url-allowed-p (url)
  "Return non-nil if the policy allows fetching URL."
  (null (xiiif-url-refusal url)))

(defun xiiif-url-refusal-message (refusal)
  "Return a human-readable sentence for REFUSAL.
REFUSAL is a value returned by `xiiif-url-refusal'."
  (pcase refusal
    (`(malformed . ,what) (format "not a usable URL: %s" what))
    (`(scheme . ,scheme)
     (format "scheme %s is not in xiiif-url-allowed-schemes" scheme))
    (`(link-local . ,host)
     (format "%s is a link-local or cloud-metadata address; xiiif never fetches those"
             host))
    (`(private . ,host)
     (format "%s is a private or loopback host; set xiiif-url-allow-private-hosts to allow it"
             host))
    (_ "refused by URL policy")))

(defun xiiif-url-check (url)
  "Return URL, or signal `xiiif-url-refused' when the policy refuses it."
  (let ((refusal (xiiif-url-refusal url)))
    (when refusal
      (signal 'xiiif-url-refused
              (list url (xiiif-url-refusal-message refusal) (car refusal))))
    url))

(provide 'xiiif-url)
;;; xiiif-url.el ends here
