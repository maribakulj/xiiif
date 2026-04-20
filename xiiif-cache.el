;;; xiiif-cache.el --- In-memory state and recent resources for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Minimal session state: the manifest or collection the user is
;; currently looking at, the canvas they last opened, and a short
;; history of recently opened resource URLs (manifests *and*
;; collections).
;;
;; Persistence reads the history file with `read' rather than `load'
;; so a tampered file cannot execute arbitrary code, and writes are
;; debounced through an idle timer so rapid navigation does not
;; thrash the disk.  A `kill-emacs-hook' flushes any pending write
;; before Emacs exits.
;;
;; `xiiif-cache-select' is the single entry point for mutating the
;; \"current\" pointers.  It keeps manifest / canvas / collection
;; state mutually consistent - loading a collection clears the
;; stale current canvas, and vice versa.

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

(defcustom xiiif-history-save-debounce 2.0
  "Seconds of idle time to wait before persisting the recent list.
A debounced save is cancelled and rescheduled whenever the list
changes; set to 0 for immediate writes (pre-debounce behaviour)."
  :type 'number
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

(defvar xiiif-cache--save-timer nil
  "Pending idle-timer that will flush `xiiif-recent-manifests' to disk.")


;;; ---------- unified selector ----------

(cl-defun xiiif-cache-select (&key manifest canvas collection)
  "Set the current xiiif context atomically.
Pass one of :MANIFEST, :CANVAS, :COLLECTION.  Selecting a manifest
clears the current collection (and, unless a canvas is passed in
the same call, the current canvas).  Selecting a collection clears
both current manifest and current canvas.  Selecting a canvas alone
replaces only the canvas pointer.  Adds the resource URL to the
recent list when applicable."
  (cond
   (manifest
    (setq xiiif-current-manifest  manifest
          xiiif-current-collection nil
          xiiif-current-canvas     canvas)
    (xiiif-cache-add-recent (xiiif-manifest-url manifest)))
   (collection
    (setq xiiif-current-collection collection
          xiiif-current-manifest   nil
          xiiif-current-canvas     nil)
    (xiiif-cache-add-recent (xiiif-collection-url collection)))
   (t
    (setq xiiif-current-canvas canvas))))

(defun xiiif-cache-set-manifest (manifest)
  "Record MANIFEST as the current manifest (clears current canvas).
Preserved as the public mutation point; delegates to `xiiif-cache-select'."
  (xiiif-cache-select :manifest manifest)
  manifest)

(defun xiiif-cache-set-canvas (canvas)
  "Record CANVAS as the current canvas."
  (xiiif-cache-select :canvas canvas))

(defun xiiif-cache-set-collection (collection)
  "Record COLLECTION as the current collection; clears manifest/canvas."
  (xiiif-cache-select :collection collection)
  collection)

(defun xiiif-cache-clear ()
  "Reset in-memory xiiif state (does not touch the history file)."
  (interactive)
  (setq xiiif-current-manifest nil
        xiiif-current-canvas nil
        xiiif-current-collection nil))


;;; ---------- recent list ----------

(defun xiiif-cache-add-recent (url)
  "Push URL onto `xiiif-recent-manifests' and schedule a debounced save."
  (when (and url (stringp url))
    (setq xiiif-recent-manifests
          (cons url (delete url xiiif-recent-manifests)))
    (when (> (length xiiif-recent-manifests) xiiif-history-size)
      (setq xiiif-recent-manifests
            (seq-take xiiif-recent-manifests xiiif-history-size)))
    (xiiif-cache--schedule-save)))


;;; ---------- persistence ----------

(defun xiiif-cache--schedule-save ()
  "Arrange for `xiiif-cache-save' to run once Emacs has been idle."
  (cond
   ((<= xiiif-history-save-debounce 0)
    (xiiif-cache-save))
   (t
    (when (timerp xiiif-cache--save-timer)
      (cancel-timer xiiif-cache--save-timer))
    (setq xiiif-cache--save-timer
          (run-with-idle-timer xiiif-history-save-debounce nil
                               #'xiiif-cache--flush)))))

(defun xiiif-cache--flush ()
  "Clear the pending timer then persist the recent list."
  (setq xiiif-cache--save-timer nil)
  (xiiif-cache-save))

(defun xiiif-cache-save ()
  "Write the recent resources list to `xiiif-history-file' now.
Creates the parent directory when missing so a fresh install does
not error on its first write."
  (condition-case err
      (progn
        (let ((dir (file-name-directory
                    (expand-file-name xiiif-history-file))))
          (when (and dir (not (file-directory-p dir)))
            (make-directory dir t)))
        (with-temp-file xiiif-history-file
          (insert ";;; xiiif recent resources -*- lexical-binding: t; -*-\n")
          (insert ";;; Generated by xiiif-cache-save; do not edit by hand.\n")
          (prin1 `(setq xiiif-recent-manifests ',xiiif-recent-manifests)
                 (current-buffer))
          (insert "\n")))
    (error
     (message "xiiif: could not save history: %s"
              (error-message-string err)))))

(defun xiiif-cache--valid-history-form-p (form)
  "Return non-nil when FORM is the whitelisted `setq' shape we accept."
  (and (consp form)
       (eq (car form) 'setq)
       (eq (nth 1 form) 'xiiif-recent-manifests)
       (consp (nth 2 form))
       (eq (car (nth 2 form)) 'quote)
       (let ((payload (nth 1 (nth 2 form))))
         (and (listp payload)
              (cl-every #'stringp payload)))))

(defun xiiif-cache-load ()
  "Load recent resources from `xiiif-history-file' safely.
Rejects anything that is not the `(setq xiiif-recent-manifests
\\='(\"url\" ...))' shape produced by `xiiif-cache-save' - a corrupted
or tampered file can therefore not execute arbitrary code."
  (when (file-readable-p xiiif-history-file)
    (condition-case err
        (let* ((content (with-temp-buffer
                          (insert-file-contents xiiif-history-file)
                          (buffer-string)))
               (form nil))
          (with-temp-buffer
            (insert content)
            (goto-char (point-min))
            ;; Skip over the leading comments / whitespace.
            (while (forward-comment 1))
            (setq form (condition-case _ (read (current-buffer))
                         (end-of-file nil))))
          (if (xiiif-cache--valid-history-form-p form)
              (setq xiiif-recent-manifests
                    (seq-take (nth 1 (nth 2 form))
                              xiiif-history-size))
            (message "xiiif: ignoring malformed history file %s"
                     xiiif-history-file)))
      (error
       (message "xiiif: could not load history: %s"
                (error-message-string err))))))


;;; ---------- kill-emacs flush ----------

(defun xiiif-cache--on-kill-emacs ()
  "Flush any pending history save before Emacs exits."
  (when (timerp xiiif-cache--save-timer)
    (cancel-timer xiiif-cache--save-timer)
    (setq xiiif-cache--save-timer nil)
    (xiiif-cache-save)))

(add-hook 'kill-emacs-hook #'xiiif-cache--on-kill-emacs)

(provide 'xiiif-cache)
;;; xiiif-cache.el ends here
