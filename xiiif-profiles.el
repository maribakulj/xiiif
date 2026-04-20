;;; xiiif-profiles.el --- Per-server IIIF profiles -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Per-host customisation of IIIF requests.  Users can declare an
;; alist of (URL-REGEXP . PLIST) entries that adjust extra HTTP
;; headers (for API tokens) and override Image API defaults
;; (region / size / rotation / quality / format) for URLs matching
;; the regexp.

;;; Code:

(require 'cl-lib)

(defgroup xiiif-profiles nil
  "Per-host IIIF profiles."
  :group 'xiiif
  :prefix "xiiif-")

(defcustom xiiif-server-profiles nil
  "Alist of per-host IIIF server profiles.

Each entry is (URL-REGEXP . PLIST).  The first regexp that matches
a request URL wins.  Supported plist keys:

  :label    Display string shown by diagnostics.
  :headers  Alist of (HEADER-NAME . VALUE) added to every request
            targeting a matching URL (e.g. `(\"Authorization\" . \"Bearer …\")').
            Prefer `:auth' to keep secrets out of your init file.
  :auth     Plist describing how to obtain an Authorization header
            from `auth-source'.  Supported keys:
              :host    value passed as :host to `auth-source-search'
                       (defaults to the matched request URL's host).
              :user    optional :user filter for `auth-source-search'.
              :scheme  authentication scheme (default \"Bearer\").
            The resulting header is merged *after* any explicit
            `:headers', so user-supplied headers still win.
  :image    Plist of Image API overrides used by `xiiif-image-url'.
            Keys: :region :size :rotation :quality :format.
  :notes    Free text."
  :type '(alist :key-type regexp :value-type plist)
  :group 'xiiif-profiles)


;;; ---------- lookup ----------

(defun xiiif-profile-for-url (url)
  "Return the server profile plist matching URL, or nil."
  (when (stringp url)
    (cl-loop for (regexp . plist) in xiiif-server-profiles
             when (and regexp (string-match-p regexp url))
             return plist)))

(defun xiiif-profile-headers (url)
  "Return an alist of extra HTTP headers for URL from its server profile."
  (plist-get (xiiif-profile-for-url url) :headers))

(defun xiiif-profile-image-defaults (url)
  "Return the :image override plist for URL, or nil."
  (plist-get (xiiif-profile-for-url url) :image))

(declare-function auth-source-search "auth-source")

(defun xiiif-profile--url-host (url)
  "Return the host portion of URL, or nil."
  (and (stringp url)
       (save-match-data
         (when (string-match "\\`[a-z][a-z0-9+.-]*://\\([^/:?#]+\\)" url)
           (match-string 1 url)))))

(defun xiiif-profile-auth-header (url)
  "Return an (HEADER . VALUE) cons for URL's auth profile, or nil.
Looks up a secret via `auth-source-search' using :host and optional
:user taken from the matched profile's `:auth' plist.  The default
authentication scheme is Bearer; override with `:scheme'.

The auth lookup is triggered as soon as the matched profile declares
an `:auth' key (even with an empty plist value), so
`(:auth nil)' and `(:auth (:scheme \"Token\"))' both work."
  (let ((profile (xiiif-profile-for-url url)))
    (when (plist-member profile :auth)
      (let ((auth (plist-get profile :auth)))
        (when (require 'auth-source nil t)
          (let* ((host (or (plist-get auth :host)
                           (xiiif-profile--url-host url)))
                 (hits (and host
                            (ignore-errors
                              (auth-source-search
                               :host host
                               :user (plist-get auth :user)
                               :max  1
                               :require '(:secret)))))
                 (entry (car hits))
                 (raw (and entry (plist-get entry :secret)))
                 (secret (cond ((null raw) nil)
                               ((functionp raw) (funcall raw))
                               (t raw))))
            (when secret
              (cons "Authorization"
                    (format "%s %s"
                            (or (plist-get auth :scheme) "Bearer")
                            secret)))))))))

(provide 'xiiif-profiles)
;;; xiiif-profiles.el ends here
