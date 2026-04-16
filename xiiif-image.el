;;; xiiif-image.el --- IIIF Image API helpers -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Build IIIF Image API URLs of the form
;;   {base}/{region}/{size}/{rotation}/{quality}.{format}
;; from a `xiiif-image-service' or a bare base URL, and download the
;; resulting derivative.  Defaults match the spec: full / max / 0 /
;; default / jpg.  No attempt is made to detect server compliance;
;; the builder trusts the caller.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'xiiif-core)
(require 'xiiif-api)

(defcustom xiiif-image-default-region "full"
  "Default region segment for `xiiif-image-url'."
  :type 'string :group 'xiiif)

(defcustom xiiif-image-default-size "max"
  "Default size segment for `xiiif-image-url'.
Note that the IIIF Image API 2.x uses \"full\" and 3.x uses \"max\";
\"max\" is accepted by most implementations."
  :type 'string :group 'xiiif)

(defcustom xiiif-image-default-rotation "0"
  "Default rotation segment for `xiiif-image-url'."
  :type 'string :group 'xiiif)

(defcustom xiiif-image-default-quality "default"
  "Default quality segment for `xiiif-image-url'."
  :type 'string :group 'xiiif)

(defcustom xiiif-image-default-format "jpg"
  "Default format extension for `xiiif-image-url'."
  :type 'string :group 'xiiif)

(defcustom xiiif-image-download-directory
  (expand-file-name "xiiif/" user-emacs-directory)
  "Directory where downloaded IIIF derivatives are saved by default."
  :type 'directory :group 'xiiif)

(defun xiiif-image-service-base (service)
  "Return the base URL string for SERVICE.
SERVICE may be a `xiiif-image-service', a canvas (the service on its
image body is used) or a plain string."
  (cond
   ((null service) nil)
   ((stringp service) (string-trim-right service "/"))
   ((xiiif-image-service-p service)
    (string-trim-right (xiiif-image-service-id service) "/"))
   ((xiiif-canvas-p service)
    (xiiif-image-service-base (xiiif-canvas-image-service service)))
   (t nil)))

(cl-defun xiiif-image-url (service &key region size rotation quality format)
  "Build an IIIF Image API URL from SERVICE.

SERVICE is a `xiiif-image-service', a `xiiif-canvas', or a base URL string.
REGION, SIZE, ROTATION, QUALITY and FORMAT override the defaults defined
by the `xiiif-image-default-*' customization variables.

Returns nil when SERVICE has no derivable base URL."
  (when-let ((base (xiiif-image-service-base service)))
    (format "%s/%s/%s/%s/%s.%s"
            base
            (or region   xiiif-image-default-region)
            (or size     xiiif-image-default-size)
            (or rotation xiiif-image-default-rotation)
            (or quality  xiiif-image-default-quality)
            (or format   xiiif-image-default-format))))

(defun xiiif-image-info-url (service)
  "Return the info.json URL for SERVICE, or nil."
  (when-let ((base (xiiif-image-service-base service)))
    (concat base "/info.json")))

(defun xiiif-image--slug (service)
  "Return a filesystem-safe slug from SERVICE base URL."
  (let ((base (xiiif-image-service-base service)))
    (if (not base)
        "image"
      (let* ((tail (car (last (split-string base "/" t))))
             (slug (replace-regexp-in-string "[^[:alnum:]._-]" "_" tail)))
        (if (string-empty-p slug) "image" slug)))))

(defun xiiif-image-suggested-filename (service &optional format)
  "Return a suggested local filename for SERVICE, using FORMAT as extension."
  (format "%s.%s"
          (xiiif-image--slug service)
          (or format xiiif-image-default-format)))

(defun xiiif-image-download (service destination &rest params)
  "Download a derivative from SERVICE to DESTINATION.

PARAMS are forwarded to `xiiif-image-url' as keyword arguments.
Creates the destination directory if it does not exist.  Returns
the absolute path of the downloaded file."
  (let ((url (apply #'xiiif-image-url service params)))
    (unless url
      (signal 'xiiif-error (list "no image service")))
    (let ((dir (file-name-directory (expand-file-name destination))))
      (when (and dir (not (file-directory-p dir)))
        (make-directory dir t)))
    (xiiif-api-download-file url (expand-file-name destination))))

(provide 'xiiif-image)
;;; xiiif-image.el ends here
