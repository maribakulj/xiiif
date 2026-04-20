;;; xiiif-http-cache.el --- Conditional HTTP cache for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Tiny on-disk cache for GET responses keyed by URL.  Each entry
;; stores the body and the ETag / Last-Modified validators, so a
;; subsequent fetch can issue `If-None-Match' / `If-Modified-Since'
;; and accept a 304 Not Modified by returning the cached body.
;;
;; The cache is best-effort: any I/O failure falls back to a normal
;; fetch, and a corrupted entry is simply discarded.  `xiiif-cache-clear-http'
;; wipes the whole cache interactively.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup xiiif-http-cache nil
  "Conditional HTTP response cache for xiiif."
  :group 'xiiif
  :prefix "xiiif-http-cache-")

(defcustom xiiif-http-cache-enabled t
  "When non-nil, xiiif will persist GET responses for conditional fetches."
  :type 'boolean
  :group 'xiiif-http-cache)

(defcustom xiiif-http-cache-directory
  (expand-file-name "xiiif/http-cache/" user-emacs-directory)
  "Directory used by `xiiif-http-cache' to persist cached entries."
  :type 'directory
  :group 'xiiif-http-cache)


;;; ---------- on-disk layout ----------

(defun xiiif-http-cache--entry-file (url)
  "Return the cache file path for URL."
  (expand-file-name (concat (secure-hash 'sha1 url) ".el")
                    xiiif-http-cache-directory))

(defun xiiif-http-cache--ensure-dir ()
  "Create the cache directory if it does not exist."
  (unless (file-directory-p xiiif-http-cache-directory)
    (make-directory xiiif-http-cache-directory t)))

(defun xiiif-http-cache-lookup (url)
  "Return the cached entry for URL or nil.
An entry is a plist with keys `:url', `:etag', `:last-modified',
`:body' (unibyte string) and `:stored' (float time)."
  (when xiiif-http-cache-enabled
    (let ((file (xiiif-http-cache--entry-file url)))
      (when (file-readable-p file)
        (condition-case _err
            (with-temp-buffer
              (insert-file-contents file)
              (goto-char (point-min))
              (let ((entry (read (current-buffer))))
                (and (xiiif-http-cache--valid-entry-p entry url)
                     entry)))
          (error nil))))))

(defun xiiif-http-cache--valid-entry-p (entry url)
  "Return non-nil when ENTRY is the expected plist shape for URL."
  (and (listp entry)
       (equal url (plist-get entry :url))
       (stringp (plist-get entry :body))
       (or (null (plist-get entry :etag))
           (stringp (plist-get entry :etag)))
       (or (null (plist-get entry :last-modified))
           (stringp (plist-get entry :last-modified)))))

(defun xiiif-http-cache-store (url body &optional etag last-modified)
  "Persist BODY for URL with ETAG / LAST-MODIFIED validators.
Returns the entry alist.  I/O failures are swallowed."
  (when xiiif-http-cache-enabled
    (condition-case err
        (progn
          (xiiif-http-cache--ensure-dir)
          (let ((entry (list :url url
                             :etag etag
                             :last-modified last-modified
                             :body body
                             :stored (float-time)))
                (file (xiiif-http-cache--entry-file url))
                (coding-system-for-write 'binary))
            (with-temp-file file
              (set-buffer-multibyte nil)
              (prin1 entry (current-buffer)))
            entry))
      (error
       (message "xiiif-http-cache: could not store %s: %s"
                url (error-message-string err))
       nil))))

(defun xiiif-http-cache-invalidate (url)
  "Remove the cached entry for URL, if any."
  (let ((file (xiiif-http-cache--entry-file url)))
    (when (file-exists-p file)
      (ignore-errors (delete-file file)))))

;;;###autoload
(defun xiiif-cache-clear-http ()
  "Remove every entry from the xiiif HTTP cache on disk."
  (interactive)
  (when (file-directory-p xiiif-http-cache-directory)
    (dolist (f (directory-files xiiif-http-cache-directory t
                                "\\.el\\'"))
      (ignore-errors (delete-file f))))
  (message "xiiif: HTTP cache cleared"))


;;; ---------- conditional-request helpers ----------

(defun xiiif-http-cache-conditional-headers (url)
  "Return request headers seeding a conditional GET for URL, or nil."
  (when-let ((entry (xiiif-http-cache-lookup url)))
    (let (headers)
      (when-let ((etag (plist-get entry :etag)))
        (push (cons "If-None-Match" etag) headers))
      (when-let ((lm (plist-get entry :last-modified)))
        (push (cons "If-Modified-Since" lm) headers))
      headers)))

(provide 'xiiif-http-cache)
;;; xiiif-http-cache.el ends here
