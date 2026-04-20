;;; xiiif-sources.el --- Named IIIF endpoint registry -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A tiny registry of known IIIF endpoints so users can fetch a
;; manifest by institution + local identifier instead of typing a
;; full URL.  Ships with a handful of well-known GLAM sources and
;; is trivially extensible from init files or `customize'.

;;; Code:

(require 'cl-lib)
(require 'url-util)

(defgroup xiiif-sources nil
  "Registry of named IIIF endpoints."
  :group 'xiiif
  :prefix "xiiif-sources-")

(defcustom xiiif-sources
  '((gallica
     :label "Gallica (BnF)"
     :prompt "Gallica ARK (e.g. ark:/12148/btv1b...): "
     :manifest-url "https://gallica.bnf.fr/iiif/%s/manifest.json"
     :notes "French National Library. IDs are ARK handles.")
    (wellcome
     :label "Wellcome Collection"
     :prompt "Wellcome ID (e.g. b19974760): "
     :manifest-url "https://iiif.wellcomecollection.org/presentation/%s"
     :notes "IIIF Presentation 3; IDs are Wellcome bibliographic IDs.")
    (ia
     :label "Internet Archive"
     :prompt "Archive.org item ID: "
     :manifest-url "https://iiif.archivelab.org/iiif/%s/manifest.json"
     :notes "Archive.org IIIF shim, served by archivelab.org."))
  "Registry of known IIIF endpoints.

Each entry is a cons (NAME . PLIST).  Supported plist keys:

  :label        Display string shown in `xiiif-open-source'.
  :prompt       Prompt string for the identifier (optional).
  :manifest-url A `format' string with a single %s placeholder for the id.
                URL-encoding of the id itself is opt-in via
                `:encode-id'.
  :encode-id    When non-nil, pass the id through `url-hexify-string'
                before substitution.  Off by default so ARK-style
                ids with literal slashes keep working.
  :manifest-url-fn A function of the id returning a URL, used when
                set; takes precedence over `:manifest-url'.
  :notes        Free text shown next to the label (optional)."
  :type '(alist :key-type symbol :value-type plist)
  :group 'xiiif-sources)


;;; ---------- lookup and URL building ----------

(defun xiiif-source-names ()
  "Return the list of source names (symbols) currently registered."
  (mapcar #'car xiiif-sources))

(defun xiiif-source-get (name)
  "Return the plist for the source NAME, or nil."
  (cdr (assq name xiiif-sources)))

(defun xiiif-source-label (source)
  "Return the display label for SOURCE (a plist)."
  (or (plist-get source :label) "(unnamed)"))

(defun xiiif-source--prepare-id (source id)
  "Return the substitution value for ID according to SOURCE.
Passes ID through `url-hexify-string' when SOURCE declares
`:encode-id'; otherwise returns ID as-is."
  (if (plist-get source :encode-id)
      (url-hexify-string id)
    id))

(defun xiiif-source-build-manifest-url (source id)
  "Return the manifest URL for ID using SOURCE.
Prefers `:manifest-url-fn' over `:manifest-url' when both are set.
When `:encode-id' is non-nil, ID is URL-hexified before
substitution; otherwise it is inserted verbatim so that ARK-style
identifiers with literal slashes keep working.
Signals `user-error' when SOURCE defines neither builder."
  (let ((fn  (plist-get source :manifest-url-fn))
        (fmt (plist-get source :manifest-url)))
    (cond
     (fn  (funcall fn id))
     (fmt (format fmt (xiiif-source--prepare-id source id)))
     (t (user-error
         "Source %s defines no :manifest-url or :manifest-url-fn"
         (xiiif-source-label source))))))


;;; ---------- interactive picker ----------

(defun xiiif-sources--completion-table ()
  "Return an alist of (DISPLAY-STRING . NAME) for completion."
  (mapcar (lambda (entry)
            (let ((plist (cdr entry)))
              (cons (format "%-22s  %s"
                            (xiiif-source-label plist)
                            (or (plist-get plist :notes) ""))
                    (car entry))))
          xiiif-sources))

(defun xiiif-sources-read (&optional prompt)
  "Prompt for a source name via `completing-read'.
Returns the source plist."
  (let* ((table (xiiif-sources--completion-table))
         (pick (completing-read (or prompt "IIIF source: ")
                                (mapcar #'car table)
                                nil t))
         (name (cdr (assoc pick table))))
    (xiiif-source-get name)))

(provide 'xiiif-sources)
;;; xiiif-sources.el ends here
