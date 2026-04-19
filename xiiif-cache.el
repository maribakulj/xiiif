;;; xiiif-cache.el --- In-memory state and recent resources for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Minimal session state: the manifest or collection the user is
;; currently looking at, the canvas they last opened, and a short
;; history of recently opened resource URLs (manifests *and*
;; collections).  Persistence is intentionally trivial and writes a
;; tiny Lisp file so the recent list survives restarts.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'xiiif-core)

(defcustom xiiif-history-file
  (expand-file-name "xiiif-history.el" user-emacs-directory)
  "File used to persist the list of recently opened IIIF resources."
  :type 'file
  :group 'xiiif)

(defcustom xiiif-history-size 25
  "Maximum number of recent IIIF resource URLs to remember."
  :type 'integer
  :group 'xiiif)

(defvar xiiif-current-manifest nil
  "The most recently opened `xiiif-manifest', or nil.")

(defvar xiiif-current-canvas nil
  "The most recently opened `xiiif-canvas', or nil.")

(defvar xiiif-current-collection nil
  "The most recently opened `xiiif-collection', or nil.")

(defvar xiiif-recent-manifests nil
  "List of recently opened resource URLs, most recent first.
The name is kept for backwards compatibility with `xiiif-history-file';
both manifest and collection URLs are stored in this list.")

(defun xiiif-cache-add-recent (url)
  "Push URL onto `xiiif-recent-manifests' and persist."
  (when (and url (stringp url))
    (setq xiiif-recent-manifests
          (cons url (delete url xiiif-recent-manifests)))
    (when (> (length xiiif-recent-manifests) xiiif-history-size)
      (setq xiiif-recent-manifests
            (seq-take xiiif-recent-manifests xiiif-history-size)))
    (xiiif-cache-save)))

(defun xiiif-cache-set-manifest (manifest)
  "Record MANIFEST as the current manifest and update recents."
  (setq xiiif-current-manifest manifest)
  (when manifest
    (xiiif-cache-add-recent (xiiif-manifest-url manifest)))
  manifest)

(defun xiiif-cache-set-canvas (canvas)
  "Record CANVAS as the current canvas."
  (setq xiiif-current-canvas canvas))

(defun xiiif-cache-set-collection (collection)
  "Record COLLECTION as the current collection and update recents."
  (setq xiiif-current-collection collection)
  (when collection
    (xiiif-cache-add-recent (xiiif-collection-url collection)))
  collection)

(defun xiiif-cache-clear ()
  "Reset in-memory xiiif state (does not touch the history file)."
  (interactive)
  (setq xiiif-current-manifest nil
        xiiif-current-canvas nil
        xiiif-current-collection nil))

(defun xiiif-cache-save ()
  "Write the recent resources list to `xiiif-history-file'."
  (condition-case err
      (with-temp-file xiiif-history-file
        (insert ";;; xiiif recent resources -*- lexical-binding: t; -*-\n")
        (prin1 `(setq xiiif-recent-manifests ',xiiif-recent-manifests)
               (current-buffer))
        (insert "\n"))
    (error
     (message "xiiif: could not save history: %s"
              (error-message-string err)))))

(defun xiiif-cache-load ()
  "Load recent resources from `xiiif-history-file', if present."
  (when (file-readable-p xiiif-history-file)
    (condition-case err
        (load xiiif-history-file t t)
      (error
       (message "xiiif: could not load history: %s"
                (error-message-string err))))))

(provide 'xiiif-cache)
;;; xiiif-cache.el ends here
