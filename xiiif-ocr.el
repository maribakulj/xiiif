;;; xiiif-ocr.el --- OCR / ALTO / hOCR sidecars for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Many GLAM manifests expose OCR as ALTO XML, hOCR HTML or plain
;; text through a canvas `seeAlso' reference.  This module detects
;; those references, fetches the one the user picks, and extracts
;; readable text for a sidecar buffer.  Extraction is best-effort
;; and regex-based; the full structure of ALTO/hOCR is out of scope.

;;; Code:

(require 'cl-lib)
(require 'url)
(require 'xiiif-core)
(require 'xiiif-api)

(defcustom xiiif-ocr-extract-text t
  "When non-nil, strip ALTO/hOCR markup to plain text on display."
  :type 'boolean :group 'xiiif)


;;; ---------- seeAlso extraction ----------

(defconst xiiif-ocr--formats
  '(("application/alto+xml" . alto)
    ("application/xml+alto" . alto)
    ("application/alto"     . alto)
    ("text/xml"             . alto)
    ("text/vnd.hocr+html"   . hocr)
    ("text/hocr"            . hocr)
    ("text/plain"           . text))
  "Mapping from common seeAlso MIME types to internal format keys.")

(defun xiiif-ocr--format-from-profile (profile)
  "Return a format key when PROFILE matches a known ALTO/hOCR schema."
  (cond
   ((null profile) nil)
   ((stringp profile)
    (cond
     ((string-match-p "alto" profile) 'alto)
     ((string-match-p "hocr" profile) 'hocr)
     (t nil)))
   ((vectorp profile)
    (cl-some #'xiiif-ocr--format-from-profile (append profile nil)))))

(defun xiiif-ocr--classify (entry)
  "Return a format key for seeAlso ENTRY, or nil."
  (let ((format (xiiif--get entry 'format))
        (profile (xiiif--get entry 'profile)))
    (or (cdr (assoc (and format (downcase format)) xiiif-ocr--formats))
        (xiiif-ocr--format-from-profile profile))))

(defun xiiif-canvas-ocr-refs (canvas)
  "Return a list of OCR refs discovered on CANVAS.
Each ref is a plist (:url URL :format FORMAT :label LABEL :raw JSON)
where FORMAT is one of `alto', `hocr', `text' or nil for unknown.
Only `seeAlso' entries with a recognisable format or profile are
surfaced."
  (cl-loop for entry in (xiiif--as-list
                         (xiiif--get (xiiif-canvas-raw canvas) 'seeAlso))
           for format = (xiiif-ocr--classify entry)
           for url = (xiiif--get entry 'id)
           when (and url format)
           collect (list :url url
                         :format format
                         :label (xiiif-label-string
                                 (xiiif--get entry 'label))
                         :raw entry)))


;;; ---------- fetching ----------

(defun xiiif-ocr-fetch-sync (url)
  "Fetch URL synchronously and return the body as a decoded string.
Signals the usual `xiiif-' errors on failure."
  (unless (xiiif-api--valid-url-p url)
    (signal 'xiiif-network-error (list url "invalid URL")))
  (let* ((url-request-extra-headers
          '(("Accept" . "application/xml, text/html, text/plain, */*")))
         (buffer (condition-case err
                     (url-retrieve-synchronously url t t xiiif-api-timeout)
                   (error
                    (signal 'xiiif-network-error
                            (list url (error-message-string err)))))))
    (unwind-protect
        (progn
          (unless (buffer-live-p buffer)
            (signal 'xiiif-network-error (list url "no response")))
          (with-current-buffer buffer
            (let ((code (xiiif-api--status-code)))
              (when (and code (or (< code 200) (>= code 400)))
                (signal 'xiiif-http-error (list url code))))
            (xiiif-api--skip-headers)
            (decode-coding-region (point) (point-max) 'utf-8 t)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))


;;; ---------- extraction ----------

(defun xiiif-ocr--extract-alto (xml)
  "Return the concatenated text from every ALTO <String CONTENT=..>.
Line breaks are inserted at every </TextLine> closing tag so the
output keeps the source's logical line structure."
  (with-temp-buffer
    (insert xml)
    (goto-char (point-min))
    (let ((out (list "")))
      (while (re-search-forward
              "\\(?:<String[^>]*\\bCONTENT=\"\\([^\"]*\\)\"\\)\\|\\(?:</TextLine>\\)"
              nil t)
        (push (if (match-string 1)
                  (concat (match-string 1) " ")
                "\n")
              out))
      (string-trim
       (replace-regexp-in-string
        " +\n" "\n"
        (apply #'concat (nreverse out)))))))

(defun xiiif-ocr--extract-hocr (html)
  "Return a plain-text rendering of HTML (hOCR is HTML-with-classes)."
  (let ((clean (replace-regexp-in-string
                "<[^>]+>" " "
                (replace-regexp-in-string "<!--.*?-->" "" html))))
    (string-trim
     (replace-regexp-in-string "[ \t]*\n[ \t]*" "\n"
                               (replace-regexp-in-string
                                "[ \t]+" " " clean)))))

(defun xiiif-ocr-extract-text (body format)
  "Extract readable text from BODY according to FORMAT.
FORMAT is `alto', `hocr' or anything else (returned verbatim)."
  (pcase format
    ('alto (xiiif-ocr--extract-alto body))
    ('hocr (xiiif-ocr--extract-hocr body))
    (_ body)))


;;; ---------- async fetch + extract ----------

(defun xiiif-ocr-fetch-async (ref callback &optional errback)
  "Fetch an OCR REF asynchronously and call CALLBACK with extracted text.

REF is one of the plists returned by `xiiif-canvas-ocr-refs';
CALLBACK receives the plist augmented with `:text' (the decoded,
extracted string) and `:body' (the raw fetched body).  On failure,
ERRBACK receives (ERROR-SYMBOL URL &rest DATA) using the same shape
as the rest of `xiiif-api'."
  (let ((url (plist-get ref :url))
        (format (plist-get ref :format)))
    (xiiif-api-fetch-bytes-async
     url
     (lambda (bytes)
       (let* ((body (if (multibyte-string-p bytes)
                        bytes
                      (decode-coding-string bytes 'utf-8 t)))
              (text (if xiiif-ocr-extract-text
                        (xiiif-ocr-extract-text body format)
                      body)))
         (funcall callback
                  (append ref (list :body body :text text)))))
     errback)))

(provide 'xiiif-ocr)
;;; xiiif-ocr.el ends here
