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
;;
;; Also exposes a small wrapper around the Image API `info.json'
;; document: fetch it (sync or async), and parse it into a
;; `xiiif-image-info' struct that surfaces the advertised sizes,
;; tiles and compliance level for callers that want to adapt to
;; server capabilities.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'xiiif-core)
(require 'xiiif-api)
(require 'xiiif-fetch)
(require 'xiiif-profiles)

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
by the `xiiif-image-default-*' customization variables.  When a server
profile in `xiiif-server-profiles' matches the service base URL, its
`:image' plist provides defaults that sit between the explicit
arguments and the global defaults.

Returns nil when SERVICE has no derivable base URL."
  (when-let ((base (xiiif-image-service-base service)))
    (let ((profile (xiiif-profile-image-defaults base)))
      (format "%s/%s/%s/%s/%s.%s"
              base
              (or region   (plist-get profile :region)
                  xiiif-image-default-region)
              (or size     (plist-get profile :size)
                  xiiif-image-default-size)
              (or rotation (plist-get profile :rotation)
                  xiiif-image-default-rotation)
              (or quality  (plist-get profile :quality)
                  xiiif-image-default-quality)
              (or format   (plist-get profile :format)
                  xiiif-image-default-format)))))

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
  "Download a derivative from SERVICE to DESTINATION synchronously.

PARAMS are forwarded to `xiiif-image-url' as keyword arguments.
Creates the destination directory if it does not exist.  Returns
the absolute path of the downloaded file.

Blocks Emacs; interactive commands should prefer
`xiiif-image-download-async'."
  (let ((url (apply #'xiiif-image-url service params)))
    (unless url
      (signal 'xiiif-error (list "no image service")))
    (let ((dir (file-name-directory (expand-file-name destination))))
      (when (and dir (not (file-directory-p dir)))
        (make-directory dir t)))
    (xiiif-api-download-file url (expand-file-name destination))))

(cl-defun xiiif-image-download-async (service destination callback
                                              &key errback
                                              region size rotation
                                              quality format)
  "Download a derivative from SERVICE to DESTINATION asynchronously.

CALLBACK receives the absolute path on success.  ERRBACK (or the
default xiiif reporter) receives (ERROR-SYMBOL URL &rest DATA) on
failure.  Keyword arguments override the Image API defaults in the
same way as `xiiif-image-url'."
  (let ((url (xiiif-image-url service
                              :region region :size size
                              :rotation rotation :quality quality
                              :format format)))
    (if (not url)
        (funcall (or errback #'xiiif-api--default-errback)
                 (list 'xiiif-error nil "no image service"))
      (xiiif-fetch-file
       url
       (expand-file-name destination)
       callback
       :errback errback))))



;;; ---------- info.json ----------

(cl-defstruct xiiif-image-info
  "Normalized IIIF Image API `info.json' descriptor."
  id type protocol profile width height sizes tiles
  preferred-formats formats qualities extra-features rights raw)

(defun xiiif-image-parse-info (json &optional url)
  "Parse a JSON `info.json' alist into a `xiiif-image-info'.

URL is the URL the document was fetched from.  When the document
omits its own id, a best-effort service base is derived from URL by
stripping a trailing `/info.json' segment."
  (unless (consp json)
    (signal 'xiiif-parse-error (list (or url "info.json") "not an object")))
  (make-xiiif-image-info
   :id                (or (xiiif--get json 'id)
                          (and url
                               (replace-regexp-in-string
                                "/info\\.json\\'" "" url)))
   :type              (xiiif--normalize-type (xiiif--get json 'type))
   :protocol          (xiiif--get json 'protocol)
   :profile           (xiiif--get json 'profile)
   :width             (xiiif--get json 'width)
   :height            (xiiif--get json 'height)
   :sizes             (xiiif--as-list (xiiif--get json 'sizes))
   :tiles             (xiiif--as-list (xiiif--get json 'tiles))
   :preferred-formats (xiiif--as-list (xiiif--get json 'preferredFormats))
   :formats           (xiiif--as-list (xiiif--get json 'formats))
   :qualities         (xiiif--as-list (xiiif--get json 'qualities))
   :extra-features    (xiiif--as-list (xiiif--get json 'extraFeatures))
   :rights            (xiiif--get json 'rights)
   :raw               json))

(defun xiiif-image-info-compliance-level (info)
  "Return a short compliance level string for INFO, or nil.

For IIIF Image API 3 this is the bare `profile' (e.g. \"level1\").
For API 2 the profile is a URI or a mixed array of URIs and
extension objects; the URI is truncated to its `levelN' suffix."
  (cl-labels ((pick (val)
                (cond
                 ((null val) nil)
                 ((stringp val)
                  (cond
                   ((string-match "level\\([0-2]\\)" val) (match-string 0 val))
                   ((member val '("level0" "level1" "level2")) val)
                   (t val)))
                 ((vectorp val) (pick (and (> (length val) 0) (aref val 0))))
                 ((listp val)   (pick (car val))))))
    (pick (xiiif-image-info-profile info))))

(defun xiiif-image-info-size-strings (info)
  "Return a list of \"WxH\" strings for the advertised sizes of INFO."
  (cl-loop for s in (xiiif-image-info-sizes info)
           for w = (xiiif--get s 'width)
           for h = (xiiif--get s 'height)
           when (and w h) collect (format "%sx%s" w h)))

(defun xiiif-image-info-tile-strings (info)
  "Return a list of short descriptions of the advertised tile schemes of INFO."
  (cl-loop for tile in (xiiif-image-info-tiles info)
           for w = (xiiif--get tile 'width)
           for h = (or (xiiif--get tile 'height) w)
           for sf = (xiiif--get tile 'scaleFactors)
           collect (format "%sx%s  scaleFactors=%s"
                           (or w "?") (or h "?")
                           (if sf
                               (mapconcat #'number-to-string
                                          (xiiif--as-list sf) ",")
                             "-"))))

(defun xiiif-image-fetch-info (service)
  "Fetch and parse the `info.json' for SERVICE synchronously.
SERVICE is a `xiiif-image-service', a `xiiif-canvas', or a base URL.
Returns a `xiiif-image-info' or signals an `xiiif-' error."
  (let ((url (xiiif-image-info-url service)))
    (unless url (signal 'xiiif-error (list "no info.json URL")))
    (xiiif-image-parse-info (xiiif-api-fetch-json url) url)))

(defun xiiif-image-fetch-info-async (service callback &optional errback)
  "Fetch the `info.json' for SERVICE asynchronously.
On success, CALLBACK is called with a `xiiif-image-info'.  On
failure, ERRBACK is called with (ERROR-SYMBOL URL &rest DATA);
defaults to the same reporter used by `xiiif-api-fetch-json-async'."
  (let ((url (xiiif-image-info-url service)))
    (if (not url)
        (funcall (or errback #'xiiif-api--default-errback)
                 (list 'xiiif-error nil "no info.json URL"))
      (xiiif-fetch-json
       url
       (lambda (json)
         (funcall callback (xiiif-image-parse-info json url)))
       :errback errback))))

(provide 'xiiif-image)
;;; xiiif-image.el ends here
