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

(provide 'xiiif-profiles)
;;; xiiif-profiles.el ends here
