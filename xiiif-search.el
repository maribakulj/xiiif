;;; xiiif-search.el --- IIIF Search API 1.0 client for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Minimal client for the IIIF Search API 1.0
;; <https://iiif.io/api/search/1.0/>.  A manifest that exposes a
;; search service declares it under the `service' (or `@id') field;
;; we detect that descriptor, let the user issue a query, and render
;; the hits in a `tabulated-list-mode' buffer.  RET on a hit jumps
;; to the targeted canvas.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'xiiif-core)
(require 'xiiif-api)
(require 'xiiif-fetch)
(require 'xiiif-cache)

(defconst xiiif-search--buffer "*XIIIF Search*")

(defconst xiiif-search--profile-regexp
  "iiif\\.io/api/search/1"
  "Regexp identifying a IIIF Search API 1.0 service profile.")


;;; ---------- service discovery ----------

(defun xiiif-search--service-p (svc)
  "Return non-nil when SVC looks like a IIIF Search API 1.0 service."
  (let ((profile (xiiif--get svc 'profile)))
    (cond
     ((stringp profile)
      (string-match-p xiiif-search--profile-regexp profile))
     ((vectorp profile)
      (cl-some (lambda (p)
                 (and (stringp p)
                      (string-match-p xiiif-search--profile-regexp p)))
               (append profile nil))))))

(defun xiiif-manifest-search-service (manifest)
  "Return the IIIF Search 1.0 service id for MANIFEST, or nil."
  (let ((services (xiiif--as-list
                   (xiiif--get (xiiif-manifest-raw manifest) 'service))))
    (cl-some (lambda (svc)
               (and (xiiif-search--service-p svc)
                    (xiiif--get svc 'id)))
             services)))


;;; ---------- query + hit parsing ----------

(cl-defstruct xiiif-search-hit
  "A single Search API result." canvas-id chars before after raw)

(defun xiiif-search--hit-chars (annotation)
  "Return the matched text inside ANNOTATION's resource, or nil."
  (let ((resource (xiiif--get annotation 'resource)))
    (cond
     ((stringp resource) resource)
     ((consp resource) (xiiif--get resource 'chars)))))

(defun xiiif-search--hit-target (annotation)
  "Return the canvas id targeted by ANNOTATION, stripping selectors."
  (let ((on (or (xiiif--get annotation 'on)
                (xiiif--get annotation 'target))))
    (cond
     ((stringp on)
      (car (split-string on "#" t)))
     ((consp on)
      (or (xiiif--get on 'source)
          (xiiif--get on 'full)
          (xiiif--get on 'id))))))

(defun xiiif-search--context-for (annotation-id hits-context)
  "Return (:before :after) plist for ANNOTATION-ID from HITS-CONTEXT.
HITS-CONTEXT is the raw `hits' array the Search API returns
alongside the `resources'; each entry carries `annotations',
`before', `after' strings."
  (cl-loop for hit in (xiiif--as-list hits-context)
           for annos = (xiiif--as-list (xiiif--get hit 'annotations))
           when (cl-find annotation-id annos :test #'equal)
           return (list :before (xiiif--get hit 'before)
                        :after  (xiiif--get hit 'after))))

(defun xiiif-search--parse (json)
  "Parse a Search API response JSON into a list of `xiiif-search-hit'."
  (let ((resources (xiiif--as-list (xiiif--get json 'resources)))
        (context   (xiiif--get json 'hits)))
    (mapcar
     (lambda (anno)
       (let* ((id (xiiif--get anno 'id))
              (ctx (xiiif-search--context-for id context)))
         (make-xiiif-search-hit
          :canvas-id (xiiif-search--hit-target anno)
          :chars     (xiiif-search--hit-chars anno)
          :before    (plist-get ctx :before)
          :after     (plist-get ctx :after)
          :raw       anno)))
     resources)))


;;; ---------- fetching ----------

(defun xiiif-search--url (service-id query)
  "Return the Search API URL for SERVICE-ID and QUERY."
  (concat (string-trim-right service-id "/?")
          "?q=" (url-hexify-string query)))

(defun xiiif-search-async (service-id query callback &optional errback)
  "Issue a Search API query against SERVICE-ID with QUERY.
On success, CALLBACK receives the list of `xiiif-search-hit' structs.
On failure, ERRBACK (defaulting to the standard xiiif reporter)
receives (ERROR-SYMBOL URL &rest DATA)."
  (let ((url (xiiif-search--url service-id query)))
    (xiiif-fetch-json
     url
     (lambda (json)
       (funcall callback (xiiif-search--parse json)))
     :errback errback)))


;;; ---------- UI ----------

(defvar xiiif-search-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'xiiif-search--open-at-point)
    (define-key map (kbd "o")   #'xiiif-search--open-at-point)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `xiiif-search-mode'.")

(define-derived-mode xiiif-search-mode tabulated-list-mode "XIIIF-Search"
  "Major mode for IIIF Search 1.0 result buffers."
  (setq tabulated-list-format
        [("Canvas" 40 t)
         ("Match"  80 nil)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key nil)
  (tabulated-list-init-header))

(defvar-local xiiif-search--manifest nil)
(defvar-local xiiif-search--query nil)

(defun xiiif-search--canvas-short (id manifest)
  "Return a short human label for canvas ID inside MANIFEST."
  (let ((c (and id (xiiif-manifest-find-canvas manifest id))))
    (if c
        (xiiif-canvas-title c)
      (or (and id (car (last (split-string id "/" t))))
          "(unknown)"))))

(defun xiiif-search--row (hit manifest)
  "Build a tabulated-list entry for HIT within MANIFEST."
  (let* ((label (xiiif-search--canvas-short
                 (xiiif-search-hit-canvas-id hit) manifest))
         (match (mapconcat
                 #'identity
                 (delq nil
                       (list (xiiif-search-hit-before hit)
                             (and (xiiif-search-hit-chars hit)
                                  (propertize
                                   (xiiif-search-hit-chars hit)
                                   'face 'bold))
                             (xiiif-search-hit-after hit)))
                 "")))
    (list hit (vector label (or match "")))))

(defun xiiif-search--render (manifest query hits)
  "Render HITS from a QUERY run against MANIFEST into the search buffer."
  (let ((buf (get-buffer-create xiiif-search--buffer)))
    (with-current-buffer buf
      (xiiif-search-mode)
      (setq-local xiiif-search--manifest manifest)
      (setq-local xiiif-search--query query)
      (setq tabulated-list-entries
            (mapcar (lambda (h) (xiiif-search--row h manifest)) hits))
      (tabulated-list-print t))
    (pop-to-buffer-same-window buf)
    (message "xiiif: %d hit%s for %S"
             (length hits) (if (= 1 (length hits)) "" "s") query)))

(declare-function xiiif-open-canvas "xiiif" (&optional canvas))

(defun xiiif-search--open-at-point ()
  "Jump to the canvas targeted by the search hit at point."
  (interactive)
  (let* ((hit (tabulated-list-get-id))
         (manifest xiiif-search--manifest))
    (unless hit (user-error "No search hit on this line"))
    (let ((canvas (and manifest
                       (xiiif-manifest-find-canvas
                        manifest (xiiif-search-hit-canvas-id hit)))))
      (unless canvas
        (user-error "Canvas %s not resolvable in the current manifest"
                    (xiiif-search-hit-canvas-id hit)))
      (xiiif-open-canvas canvas))))


;;; ---------- entry point ----------

;;;###autoload
(defun xiiif-search (query)
  "Search the current manifest's IIIF Search 1.0 service for QUERY.
Signals `user-error' when the manifest does not advertise one."
  (interactive
   (list (read-string "IIIF search query: ")))
  (let* ((manifest (or xiiif-current-manifest
                       (user-error
                        "No IIIF manifest loaded; run `xiiif-open-manifest' first")))
         (service (or (xiiif-manifest-search-service manifest)
                      (user-error
                       "Current manifest does not declare a IIIF Search service"))))
    (when (string-blank-p query)
      (user-error "Empty query"))
    (message "xiiif: searching %s for %S..." service query)
    (xiiif-search-async
     service query
     (lambda (hits)
       (xiiif-search--render manifest query hits)))))

(provide 'xiiif-search)
;;; xiiif-search.el ends here
