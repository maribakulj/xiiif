;;; xiiif-review.el --- Human review of agentic productions -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `SPEC_V1.md' §20.  A human looks at what an agent produced, next to the
;; source it claims to come from, and records what they think.
;;
;; # xiiif records, and validates nothing
;;
;; §20 is explicit: "cette revue n'est pas une validation scientifique
;; complète.  Elle produit un finding humain attachable à un
;; ReviewDossier."  So this file has no notion of a claim being accepted.
;; It builds a document, hands it to whoever is connected, and keeps no
;; verdict of its own - there is nothing here to ask "is this validated",
;; because xiiif is not who decides.
;;
;; The four verdicts are §20's, under §20's names.  A fifth would be a
;; word nobody defined, and `xiiif-review-record' refuses it rather than
;; passing it along as free text; that refusal is written here rather than
;; borrowed, so that Locus and xiiif agree without consulting each other.
;;
;; # The report is opened, never injected
;;
;; "Ouvrir le rapport interprétatif sans l'injecter dans le rendu de la
;; source."  The obvious implementation appends the agent's reading to the
;; canvas buffer, and from then on nobody can tell the source from the
;; commentary on it.  The report therefore lives in its own buffer, and a
;; test asserts the source buffer contains none of it.
;;
;; # Nothing is sent from here
;;
;; Recording goes through `xiiif-review-submit-function', a port.  Its
;; default hands the document to the Locus Emacs client when that client
;; is loaded, and otherwise puts it on the kill ring and says so.  xiiif
;; opens no connection to Locus and requires no Locus code: the
;; integration is optional (ADR 0007), and a viewer that dialled a control
;; plane would no longer be one.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'xiiif-errors)
(require 'xiiif-locus)
(require 'xiiif-region)
(require 'xiiif-ui)

(defconst xiiif-review-verdicts
  '(accept needs-correction wrong-target source-changed)
  "The four verdicts of §20, under their names.
A fifth would be a word nobody defined.  `xiiif-review-record' refuses
one rather than letting it through as free text, because a verdict that
reached a dossier under an unknown name would be counted there.")

(defcustom xiiif-review-reviewer nil
  "Who is reviewing, as recorded in the finding.

Left nil, `user-mail-address' is used.  A finding without a reviewer is
refused: an anonymous verdict in a dossier cannot be weighed, and §17.4
weighs reviewers."
  :type '(choice (const :tag "Use `user-mail-address'" nil) string)
  :group 'xiiif)

(defvar xiiif-review-submit-function #'xiiif-review-submit-default
  "The function that carries a finding away - a port.

It receives the finding alist and returns a symbol saying what happened:
`sent' when a connected Locus client took it, `copied' when it went to
the kill ring instead.

xiiif never opens a connection to Locus itself.  The integration is
optional, it goes through the Locus Emacs client, and a viewer that
dialled a control plane would stop being a viewer.")


;;; ---------- the finding ----------

(defun xiiif-review--refuse (reason format &rest args)
  "Signal `xiiif-locus-invalid' with REASON and a message from FORMAT and ARGS."
  (signal 'xiiif-locus-invalid (list reason (apply #'format format args))))

(defun xiiif-review-reviewer ()
  "Who is reviewing, or nil when nothing identifies them."
  (let ((who (or xiiif-review-reviewer user-mail-address)))
    (and (stringp who) (not (string-blank-p who)) who)))

(cl-defun xiiif-review-record (dossier target &key verdict comment evidence reviewer)
  "Build the §20 finding for TARGET in DOSSIER.

VERDICT is one of `xiiif-review-verdicts' or nil; COMMENT is the free
comment §20 also allows.  EVIDENCE is a list of revision identifiers the
reviewer leans on - without it the finding is a non-binding remark, and
that is Locus' rule, not a courtesy to humans.  REVIEWER overrides
`xiiif-review-reviewer'.

Returns an alist whose keys are the wire field names, ready for
`json-encode'.  Signals `xiiif-locus-invalid' with a reason symbol:
`empty-field', `unknown-verdict' or `says-nothing'."
  (let ((who (or reviewer (xiiif-review-reviewer)))
        (comment (and (stringp comment)
                      (let ((text (string-trim comment)))
                        (and (not (string-empty-p text)) text)))))
    (when (or (not (stringp dossier)) (string-blank-p dossier))
      (xiiif-review--refuse 'empty-field "no dossier to attach the finding to"))
    (when (or (not (stringp target)) (string-blank-p target))
      (xiiif-review--refuse 'empty-field "no target to review"))
    (unless who
      (xiiif-review--refuse
       'empty-field
       "no reviewer: set `xiiif-review-reviewer' or `user-mail-address'"))
    (when (and verdict (not (memq verdict xiiif-review-verdicts)))
      (xiiif-review--refuse
       'unknown-verdict
       "`%s' is not one of the four verdicts of §20" verdict))
    (unless (or verdict comment)
      (xiiif-review--refuse
       'says-nothing
       "neither verdict nor comment: §20 offers five ways to speak, and \
none of them is silence"))
    (append
     (list (cons 'dossier_id dossier)
           (cons 'target target)
           (cons 'reviewer who))
     (when verdict (list (cons 'verdict (symbol-name verdict))))
     (when comment (list (cons 'comment comment)))
     (when evidence (list (cons 'evidence (vconcat evidence))))
     (list (cons 'recorded_at (format-time-string "%FT%T%z"))))))

(defun xiiif-review-to-json (finding)
  "Render FINDING as the JSON document Locus reads."
  (json-encode finding))

(defun xiiif-review-submit-default (finding)
  "Hand FINDING to a connected Locus client, or to the kill ring.

`fboundp' rather than `require': xiiif imports no Locus code, and the
integration is present only when the user has loaded the Locus Emacs
client themselves."
  (if (fboundp 'locus-review-submit)
      (progn (funcall 'locus-review-submit finding) 'sent)
    (kill-new (xiiif-review-to-json finding))
    'copied))


;;; ---------- the review buffers ----------

(defconst xiiif-review-buffer "*xiiif-review*"
  "Where the reviewer records a verdict.")

(defconst xiiif-review-source-buffer "*xiiif-review-source*"
  "The original, shown next to the derived production.")

(defconst xiiif-review-report-buffer "*xiiif-review-report*"
  "The interpretive report - never mixed into the source.")

(defvar-local xiiif-review--context nil
  "What the current review buffer is about, as a plist.")

(defvar xiiif-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'xiiif-review-accept)
    (define-key map (kbd "c") #'xiiif-review-needs-correction)
    (define-key map (kbd "w") #'xiiif-review-wrong-target)
    (define-key map (kbd "s") #'xiiif-review-source-changed)
    (define-key map (kbd "m") #'xiiif-review-comment)
    (define-key map (kbd "r") #'xiiif-review-show-report)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `xiiif-review-mode'.")

(define-derived-mode xiiif-review-mode special-mode "XIIIF-Review"
  "Major mode for recording a §20 human review."
  (buffer-disable-undo)
  (setq-local truncate-lines t))

(cl-defun xiiif-review-open (dossier target &key source region report derived)
  "Open the §20 review of TARGET in DOSSIER.

SOURCE is the URI of the original resource, REGION the claimed region as
an xywh string, REPORT the interpretive report, and DERIVED a
`xiiif-locus-ref' for the production under review.

The original and the production are juxtaposed in two buffers.  The
report gets a third: §20 asks that it be opened without being injected
into the rendering of the source, and appending it to the source buffer
would leave nobody able to tell one from the other."
  (interactive (list (read-string "Dossier: ") (read-string "Target revision: ")))
  (let ((context (list :dossier dossier :target target :source source
                       :region region :report report)))
    (when source (xiiif-review--render-source source region))
    (when derived (xiiif-locus-render derived))
    (xiiif-review--render-panel context)))

(defun xiiif-review--render-source (source region)
  "Render SOURCE and its claimed REGION, and nothing else.

The region is written out as text and as a URI.  §23 asks that a rendered
image never be the only way to reach a region; off a graphic display it
would otherwise be unreachable, which is where review actually happens
often enough to matter."
  (let ((buffer (get-buffer-create xiiif-review-source-buffer)))
    (with-current-buffer buffer
      (xiiif-review-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (xiiif-ui--insert-heading "Original")
        (xiiif-review--insert-line "Source" source)
        (xiiif-review--insert-line "Region" (or region "not claimed"))
        (xiiif-review--insert-line
         "Region URI"
         (if region (format "%s#xywh=%s" source region) "not claimed"))
        (goto-char (point-min))))
    (display-buffer buffer)
    buffer))

(defun xiiif-review--render-panel (context)
  "Render the recording panel for CONTEXT and select it."
  (let ((buffer (get-buffer-create xiiif-review-buffer)))
    (with-current-buffer buffer
      (xiiif-review-mode)
      (setq-local xiiif-review--context context)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (xiiif-ui--insert-hints
         '(("a" . "accept") ("c" . "needs-correction")
           ("w" . "wrong-target") ("s" . "source-changed")
           ("m" . "comment") ("r" . "report") ("q" . "quit")))
        (xiiif-ui--insert-heading "Human review")
        (xiiif-review--insert-line "Dossier" (plist-get context :dossier))
        (xiiif-review--insert-line "Target" (plist-get context :target))
        (xiiif-review--insert-line
         "Reviewer" (or (xiiif-review-reviewer) "unidentified"))
        (insert "\n")
        (xiiif-ui--insert-heading "What this records")
        (insert "A finding attached to the dossier. Not a validation:\n"
                "§20 says this review is not a complete scientific one,\n"
                "and xiiif decides nothing about the claim itself.\n")
        (goto-char (point-min))))
    (pop-to-buffer-same-window buffer)
    buffer))

(defun xiiif-review--insert-line (label value)
  "Insert LABEL and VALUE, never skipping an empty VALUE."
  (insert (propertize (format "%-12s " (concat label ":")) 'face 'xiiif-key))
  (insert (format "%s" (or value "—")) "\n"))

(defun xiiif-review-show-report ()
  "Open the interpretive report in its own buffer.

Its own, and not the source's: mixing the two would leave the reader
unable to tell what the document says from what an agent read into it."
  (interactive)
  (let ((report (plist-get (xiiif-review--require-context) :report)))
    (unless report (user-error "This review carries no interpretive report"))
    (let ((buffer (get-buffer-create xiiif-review-report-buffer)))
      (with-current-buffer buffer
        (xiiif-review-mode)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (xiiif-ui--insert-heading "Interpretive report")
          (insert report "\n")
          (goto-char (point-min))))
      (display-buffer buffer)
      buffer)))

(defun xiiif-review--require-context ()
  "The review context of the current buffer, or a user-error."
  (or xiiif-review--context
      (with-current-buffer (or (get-buffer xiiif-review-buffer)
                               (current-buffer))
        xiiif-review--context)
      (user-error "No review here; start one with `xiiif-review-open'")))

(defun xiiif-review--send (verdict comment)
  "Record VERDICT and COMMENT for the current review and hand it off."
  (let* ((context (xiiif-review--require-context))
         (finding (xiiif-review-record
                   (plist-get context :dossier)
                   (plist-get context :target)
                   :verdict verdict
                   :comment comment))
         (outcome (funcall xiiif-review-submit-function finding)))
    (message "xiiif: %s %s"
             (or verdict "comment")
             (pcase outcome
               ('sent "recorded via the Locus client")
               ('copied "copied as JSON; no Locus client is loaded")
               (other (format "handed off (%s)" other))))
    outcome))

(defun xiiif-review-accept (&optional comment)
  "Record `accept' with an optional COMMENT: the reviewer has no objection.

Which is not the same as saying the claim holds - §20 again.

The prompt lives in the interactive spec and not in the body, so that
recording a verdict from Lisp - a batch review, a test - does not stop to
ask a question nobody is there to answer."
  (interactive (list (xiiif-review--read-comment)))
  (xiiif-review--send 'accept comment))

(defun xiiif-review-needs-correction (&optional comment)
  "Record `needs-correction' with an optional COMMENT."
  (interactive (list (xiiif-review--read-comment)))
  (xiiif-review--send 'needs-correction comment))

(defun xiiif-review-wrong-target (&optional comment)
  "Record `wrong-target' with an optional COMMENT.
This is not what the claim points at."
  (interactive (list (xiiif-review--read-comment)))
  (xiiif-review--send 'wrong-target comment))

(defun xiiif-review-source-changed (&optional comment)
  "Record `source-changed' with an optional COMMENT.

The remote resource is no longer the one that was read: a fact about the
source.  It says nothing about whether the run's proof still holds - that
is `xiiif-locus-proof-standing', and the two are kept apart here for the
same reason they are kept apart there."
  (interactive (list (xiiif-review--read-comment)))
  (xiiif-review--send 'source-changed comment))

(defun xiiif-review-comment (comment)
  "Record COMMENT with no verdict - the fifth form of §20."
  (interactive (list (xiiif-review--read-comment)))
  (when (or (null comment) (string-blank-p comment))
    (user-error "Nothing to record"))
  (xiiif-review--send nil comment))

(defun xiiif-review--read-comment ()
  "Read an optional comment from the minibuffer."
  (let ((text (read-string "Comment (optional): ")))
    (and (not (string-blank-p text)) text)))

(provide 'xiiif-review)
;;; xiiif-review.el ends here
