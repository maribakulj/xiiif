;;; xiiif-cite.el --- Citation export for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Generate citation records from a `xiiif-manifest'.  Two output
;; formats are supported:
;;
;;   - BibTeX (@misc) for LaTeX-centric workflows,
;;   - CSL-JSON for any reference manager that speaks it (Zotero,
;;     Pandoc, citeproc-style tooling).
;;
;; The generator pulls title from the manifest label and looks for
;; common labels in the manifest metadata array (Author / Creator,
;; Date / Created, Publisher / Provider, Rights / License) using
;; case-insensitive matching.  Nothing is fetched from the network;
;; only the already-parsed manifest is used.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'xiiif-core)


;;; ---------- metadata extraction ----------

(defconst xiiif-citation--author-labels
  '("Author" "Creator" "Authors" "Creators" "By")
  "Labels whose value should be treated as the citation author.")

(defconst xiiif-citation--date-labels
  '("Date" "Created" "Issued" "Year" "Publication Date" "Date of Creation")
  "Labels whose value should be treated as the citation date.")

(defconst xiiif-citation--publisher-labels
  '("Publisher" "Provider" "Repository" "Holding Institution")
  "Labels whose value should be treated as the citation publisher.")

(defconst xiiif-citation--rights-labels
  '("Rights" "License" "Usage" "Copyright")
  "Labels whose value should be treated as the citation rights statement.")

(defun xiiif-citation--ci-equal (a b)
  "Return non-nil if A and B are equal ignoring case.
Both must be strings."
  (and (stringp a) (stringp b)
       (eq t (compare-strings a nil nil b nil nil t))))

(defun xiiif-citation--find (pairs labels)
  "Return the first value in PAIRS whose key matches any of LABELS.
Matching is case-insensitive.  PAIRS is a list of (LABEL . VALUE)."
  (cl-loop for label in labels
           for hit = (cl-find-if
                      (lambda (p)
                        (xiiif-citation--ci-equal (car p) label))
                      pairs)
           when hit return (cdr hit)))

(defun xiiif-citation--year (date)
  "Return the first 4-digit year substring in DATE, or nil."
  (and (stringp date)
       (string-match "\\b\\([0-9]\\{4\\}\\)\\b" date)
       (match-string 1 date)))

(defun xiiif-citation-metadata (manifest)
  "Return a plain alist of citation fields extracted from MANIFEST.
Keys: `title', `author', `date', `year', `publisher', `rights', `url', `id'."
  (let* ((pairs (xiiif-metadata-pairs (xiiif-manifest-metadata manifest)))
         (date  (xiiif-citation--find pairs xiiif-citation--date-labels))
         (year  (xiiif-citation--year date)))
    `((title     . ,(xiiif-manifest-title manifest))
      (author    . ,(xiiif-citation--find pairs xiiif-citation--author-labels))
      (date      . ,date)
      (year      . ,year)
      (publisher . ,(xiiif-citation--find pairs xiiif-citation--publisher-labels))
      (rights    . ,(xiiif-citation--find pairs xiiif-citation--rights-labels))
      (url       . ,(xiiif-manifest-url manifest))
      (id        . ,(xiiif-manifest-id manifest)))))


;;; ---------- BibTeX ----------

(defun xiiif-citation--bibtex-escape (value)
  "Make VALUE safe to drop inside a BibTeX braced field."
  (replace-regexp-in-string
   "[{}]" ""
   (format "%s" value)))

(defun xiiif-citation--bibtex-key (meta)
  "Return a BibTeX citation key built from META."
  (let* ((author (alist-get 'author meta))
         (last   (and author
                      (car (last (split-string author "[[:space:],]+" t)))))
         (year   (alist-get 'year meta))
         (stem   (or last
                     (let ((title (alist-get 'title meta)))
                       (and title
                            (car (last (split-string title "[[:space:]]+" t)))))
                     "iiif")))
    (let ((clean (downcase (replace-regexp-in-string
                            "[^[:alnum:]]" "" stem))))
      (concat (if (string-empty-p clean) "iiif" clean)
              (or year "")))))

(defun xiiif-citation-bibtex (manifest)
  "Return a BibTeX @misc entry for MANIFEST as a string."
  (let* ((meta   (xiiif-citation-metadata manifest))
         (key    (xiiif-citation--bibtex-key meta))
         (fields `(("title"     . ,(alist-get 'title meta))
                   ("author"    . ,(alist-get 'author meta))
                   ("year"      . ,(alist-get 'year meta))
                   ("publisher" . ,(alist-get 'publisher meta))
                   ("url"       . ,(alist-get 'url meta))
                   ("note"      . "IIIF Manifest"))))
    (with-output-to-string
      (princ (format "@misc{%s,\n" key))
      (dolist (field fields)
        (let ((value (cdr field)))
          (when (and value (not (string-empty-p (format "%s" value))))
            (princ (format "  %s = {%s},\n"
                           (car field)
                           (xiiif-citation--bibtex-escape value))))))
      (princ "}\n"))))


;;; ---------- CSL-JSON ----------

(defun xiiif-citation--csl-object (manifest)
  "Return a CSL-JSON-shaped alist for MANIFEST.
Ready to be serialised with `json-encode'."
  (let* ((meta   (xiiif-citation-metadata manifest))
         (year   (alist-get 'year meta))
         (author (alist-get 'author meta))
         (entry  `((id . ,(or (alist-get 'id meta)
                              (alist-get 'url meta)
                              (alist-get 'title meta)))
                   (type . "manuscript")
                   (title . ,(alist-get 'title meta)))))
    (when author
      (push `(author . ,(vector `((family . ,author)))) entry))
    (when year
      (push `(issued . ((date-parts . ,(vector
                                        (vector (string-to-number year))))))
            entry))
    (dolist (k '((publisher . publisher)
                 (rights    . rights)
                 (url       . URL)))
      (when-let ((val (alist-get (car k) meta)))
        (push (cons (cdr k) val) entry)))
    (nreverse entry)))

(defun xiiif-citation-csl-json (manifest)
  "Return a pretty-printed CSL-JSON string for MANIFEST."
  (let ((json-encoding-pretty-print t))
    (json-encode (xiiif-citation--csl-object manifest))))

(provide 'xiiif-cite)
;;; xiiif-cite.el ends here
