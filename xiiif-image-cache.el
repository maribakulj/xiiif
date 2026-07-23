;;; xiiif-image-cache.el --- On-disk image byte cache -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Persistent byte cache for Image API responses, keyed by URL.
;; Revisiting a page or region costs zero network once its bytes are
;; on disk - the prerequisite for the region viewer.  Entries live
;; under the same parent directory as the HTTP cache; eviction is
;; least-recently-used within a total byte budget (reads refresh an
;; entry's modification time).  Consumed by `xiiif-fetch-bytes' via
;; its `:cache' keyword.

;;; Code:

(require 'xiiif-http-cache)

(defcustom xiiif-image-cache-enabled t
  "When non-nil, xiiif persists fetched image bytes on disk."
  :type 'boolean
  :group 'xiiif-http-cache)

(defcustom xiiif-image-cache-directory
  (expand-file-name "xiiif/image-cache/" user-emacs-directory)
  "Directory used to persist cached image bytes."
  :type 'directory
  :group 'xiiif-http-cache)

(defcustom xiiif-image-cache-max-bytes (* 200 1024 1024)
  "Total byte budget of the image cache, or nil for no cap.
Least-recently-used entries are deleted when a store pushes the
cache over this cap."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'xiiif-http-cache)

(defun xiiif-image-cache--file (url)
  "Return the cache file path for URL."
  (expand-file-name (concat (secure-hash 'sha1 url) ".bin")
                    xiiif-image-cache-directory))

(defun xiiif-image-cache-get (url)
  "Return the cached bytes for URL as a unibyte string, or nil.
A hit refreshes the entry's modification time, making eviction
least-recently-used rather than least-recently-stored."
  (when xiiif-image-cache-enabled
    (let ((file (xiiif-image-cache--file url)))
      (when (file-readable-p file)
        (condition-case nil
            (prog1
                (with-temp-buffer
                  (set-buffer-multibyte nil)
                  (insert-file-contents-literally file)
                  (buffer-string))
              (ignore-errors (set-file-times file)))
          (error nil))))))

(defun xiiif-image-cache-put (url bytes)
  "Persist BYTES (a unibyte string) for URL; returns BYTES.
Evicts least-recently-used entries beyond
`xiiif-image-cache-max-bytes'.  I/O failures are swallowed."
  (when (and xiiif-image-cache-enabled (stringp bytes))
    (condition-case nil
        (progn
          (unless (file-directory-p xiiif-image-cache-directory)
            (make-directory xiiif-image-cache-directory t))
          (let ((coding-system-for-write 'binary))
            (with-temp-file (xiiif-image-cache--file url)
              (set-buffer-multibyte nil)
              (insert bytes)))
          (xiiif-http-cache--evict-directory
           xiiif-image-cache-directory "\\.bin\\'"
           nil xiiif-image-cache-max-bytes))
      (error nil)))
  bytes)

;;;###autoload
(defun xiiif-image-cache-clear ()
  "Remove every entry from the xiiif image byte cache on disk."
  (interactive)
  (when (file-directory-p xiiif-image-cache-directory)
    (dolist (f (directory-files xiiif-image-cache-directory t
                                "\\.bin\\'"))
      (ignore-errors (delete-file f))))
  (message "xiiif: image cache cleared"))

(provide 'xiiif-image-cache)
;;; xiiif-image-cache.el ends here
