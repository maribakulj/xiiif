;;; xiiif-locus.el --- Locus artifact references, read as data -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `SPEC_V1.md' §19.  An artifact carrying `viewer_hint: iiif' reaches
;; xiiif as a structured reference: the Locus ID, a media type, the
;; hashes the run observed, and exactly one of five locators.
;;
;; # A document, not a dependency
;;
;; The reference is read the way a Manifest is read - as something that
;; arrived from elsewhere.  xiiif requires no Locus module, shares no
;; parser with Locus, and evaluates nothing it receives.  The refusals
;; below are therefore a second and independent implementation of the
;; same contract, which is the whole point: a shared library would
;; agree with itself no matter which side had it wrong.
;;
;; # Five facets, kept apart on purpose
;;
;; §19 asks for the artifact identity, the live remote resource, the
;; snapshot used during the run, the integrity state and the
;; divergences - each shown separately.  `xiiif-locus-facets' returns
;; them in that order and the buffer renders them under five headings.
;;
;; # Two verdicts that never merge
;;
;; "Une ressource distante modifiee apres le run ne doit jamais faire
;; croire que la preuve historique a change."  So there are two
;; questions here and no function answers both:
;;
;;   `xiiif-locus-proof-standing' - does a replayed copy still match
;;   the snapshot?  This one, and only this one, speaks about the
;;   proof.
;;
;;   `xiiif-locus-live-drift' - has the remote resource moved since the
;;   run?  This one never speaks about the proof.  A library that
;;   redesigns its site would otherwise cast doubt on correct work.
;;
;; Both of them refuse to guess.  A snapshot nobody replayed is
;; `unverified', not `broken'; a resource nobody checked is
;; `unchecked', not `unchanged'.  An absence of evidence is not
;; evidence, and the screen says which absence it is.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'xiiif-errors)
(require 'xiiif-json)
(require 'xiiif-url)
(require 'xiiif-fetch)
(require 'xiiif-ui)

(declare-function xiiif-open-manifest "xiiif" (url))
(declare-function xiiif-open-content-state "xiiif" (token))

(defconst xiiif-locus-locators
  '(manifest_url canvas_id content_state annotation_target local_snapshot)
  "The five locators of §19, in the order the spec names them.
Exactly one may be present.  Two would leave xiiif to pick, so two
openings of the same reference would not necessarily show the same
thing - and the one a citation pointed at would be whichever xiiif
happened to prefer that day.")

(defconst xiiif-locus--hash-re
  "\\`\\(sha256\\|sha512\\|blake3\\):\\([0-9a-f]+\\)\\'"
  "A content hash as Locus writes it: algorithm, colon, lowercase hex.")

(cl-defstruct (xiiif-locus-ref
               (:constructor xiiif-locus--make-ref)
               (:copier nil))
  "A Locus RemoteArtifactRef, already checked."
  id media-type snapshot-hash live-hash-at-run captured-at
  locator-kind locator-value viewer-hint)


;;; ---------- reading the document ----------

(defun xiiif-locus--refuse (reason format &rest args)
  "Signal `xiiif-locus-invalid' with REASON and a message from FORMAT and ARGS."
  (signal 'xiiif-locus-invalid (list reason (apply #'format format args))))

(defun xiiif-locus--string (alist key where)
  "Return the non-blank string at KEY in ALIST, or refuse.
WHERE names the enclosing object in the message."
  (let ((value (alist-get key alist)))
    (cond
     ((null value)
      (xiiif-locus--refuse 'missing-field "%s has no `%s'" where key))
     ((not (stringp value))
      (xiiif-locus--refuse 'malformed-field "%s.%s is not a string: %S"
                           where key value))
     ((string-blank-p value)
      (xiiif-locus--refuse 'empty-field "%s.%s is empty" where key))
     (t value))))

(defun xiiif-locus--hash (value key)
  "Return VALUE when it reads as a content hash, else refuse; KEY names it."
  (unless (and (stringp value) (string-match-p xiiif-locus--hash-re value))
    (xiiif-locus--refuse 'malformed-hash "%s is not a content hash: %S"
                         key value))
  value)

(defun xiiif-locus--locator (locator)
  "Return the single (KIND . VALUE) LOCATOR carries, or refuse.

An unrecognised key is refused rather than ignored, while an
unrecognised `viewer_hint' is kept and ignored.  The asymmetry is
deliberate: a hint xiiif does not know changes nothing, whereas a
locator xiiif does not know changes which resource you are looking
at - and skipping it would show a different one in silence."
  ;; An absent `locator' and an empty one decode to the same nil, so they
  ;; get the same refusal; a `locator' whose fields are all null still
  ;; reaches the count below, which is the message that fits it.
  (unless (and locator (consp locator) (consp (car locator)))
    (xiiif-locus--refuse 'missing-field "the reference carries no `locator'"))
  (let ((unknown (cl-remove-if (lambda (pair)
                                 (memq (car pair) xiiif-locus-locators))
                               locator)))
    (when unknown
      (xiiif-locus--refuse
       'unknown-locator "locator carries %s, which §19 does not name"
       (mapconcat (lambda (pair) (format "`%s'" (car pair))) unknown ", "))))
  (let ((present (cl-remove-if-not (lambda (kind) (alist-get kind locator))
                                   xiiif-locus-locators)))
    (unless (= 1 (length present))
      (xiiif-locus--refuse
       'locator-count
       "%d locators: §19 wants exactly one, and two would leave xiiif to pick"
       (length present)))
    (let ((kind (car present)))
      (cons kind (xiiif-locus--string locator kind "locator")))))

(defun xiiif-locus-parse (source &optional context)
  "Read a Locus RemoteArtifactRef from SOURCE, returning a `xiiif-locus-ref'.

SOURCE is either the decoded JSON object - an alist, as
`xiiif-json-parse' produces - or a string holding the document.
CONTEXT identifies the source in a parse error.

Signals `xiiif-locus-invalid' with a reason symbol as its first
datum: `not-an-object', `missing-field', `malformed-field',
`empty-field', `malformed-media-type', `malformed-hash',
`locator-count' or `unknown-locator'."
  (let ((doc (if (stringp source) (xiiif-json-parse source context) source)))
    (unless (and doc (consp doc) (consp (car doc)))
      (xiiif-locus--refuse 'not-an-object
                           "not a Locus artifact reference: %S" source))
    (let* ((id (xiiif-locus--string doc 'artifact_id "the reference"))
           (media (xiiif-locus--string doc 'media_type "the reference"))
           (expected (alist-get 'expected doc))
           (locator (xiiif-locus--locator (alist-get 'locator doc)))
           (hint (alist-get 'viewer_hint doc)))
      (unless (and media (string-match-p "\\`[^/[:space:]]+/[^/[:space:]]+\\'"
                                         media))
        (xiiif-locus--refuse 'malformed-media-type
                             "`%s' is not a media type" media))
      (unless (and expected (consp expected) (consp (car expected)))
        (xiiif-locus--refuse 'missing-field "the reference has no `expected'"))
      (xiiif-locus--make-ref
       :id id
       :media-type media
       :snapshot-hash (xiiif-locus--hash (alist-get 'snapshot_hash expected)
                                         "expected.snapshot_hash")
       :live-hash-at-run (let ((live (alist-get 'live_hash_at_run expected)))
                           (and live
                                (xiiif-locus--hash
                                 live "expected.live_hash_at_run")))
       :captured-at (let ((at (alist-get 'captured_at expected)))
                      (and (stringp at) (not (string-blank-p at)) at))
       :locator-kind (car locator)
       :locator-value (cdr locator)
       :viewer-hint (and (stringp hint) (not (string-blank-p hint)) hint)))))


;;; ---------- the two verdicts ----------

(defun xiiif-locus-proof-standing (ref &optional replayed)
  "What REF's snapshot says about a REPLAYED copy of the resource.

`holds' when the replayed content hashes to the snapshot, `broken'
when it does not, and `unverified' when nothing was replayed.  The
third is not a milder form of the second: nobody looked."
  (cond
   ((not (stringp replayed)) 'unverified)
   ;; `downcase' rather than `string-equal-ignore-case': the package
   ;; declares Emacs 27.1, and that function arrived in 29.  Hashes are
   ;; ASCII hex, so folding case here means exactly what it says.
   ((string= (downcase replayed)
             (downcase (xiiif-locus-ref-snapshot-hash ref)))
    'holds)
   (t 'broken)))

(defun xiiif-locus-live-drift (ref &optional live-now)
  "Whether REF's remote resource still hashes to LIVE-NOW as it did at the run.

`unchanged', `moved', `unrecorded' when the run noted no live hash,
and `unchecked' when nobody has looked since.  The last two are kept
apart because they call for different things: one can never be
answered, the other is one keystroke away.

This verdict says nothing about the proof.  See
`xiiif-locus-proof-standing', which is the one that does."
  (let ((at-run (xiiif-locus-ref-live-hash-at-run ref)))
    (cond
     ((null at-run) 'unrecorded)
     ((not (stringp live-now)) 'unchecked)
     ((string= (downcase at-run) (downcase live-now)) 'unchanged)
     (t 'moved))))


;;; ---------- reaching the resource ----------

(defun xiiif-locus-locator-target (ref)
  "How to open REF's locator, as a plist.

`:action' is `resource' (a Manifest, Collection or Canvas URL),
`content-state' or `local-file'; `:target' is what that action
takes; `:region' is the xywh fragment an annotation target carried,
or nil.  Pure: it decides nothing about the network and touches
nothing on disk."
  (let ((value (xiiif-locus-ref-locator-value ref)))
    (pcase (xiiif-locus-ref-locator-kind ref)
      ('content_state (list :action 'content-state :target value))
      ('local_snapshot (list :action 'local-file :target value))
      ('annotation_target
       ;; An annotation target is a Canvas URI, often with the claimed
       ;; region hanging off it.  The fragment is not part of the URL to
       ;; fetch, and it is the half worth reporting.
       (let* ((hash (string-match-p "#" value))
              (base (if hash (substring value 0 hash) value))
              (fragment (and hash (substring value (1+ hash)))))
         (list :action 'resource :target base
               :region (and fragment
                            (string-match-p "\\`xywh=" fragment)
                            (substring fragment 5)))))
      (_ (list :action 'resource :target value)))))

(defun xiiif-locus-locator-needs-network-p (ref)
  "Return non-nil when reaching REF's locator needs the network.
A local snapshot does not, which is what keeps a proof consultable
when the source is not."
  (not (eq (xiiif-locus-ref-locator-kind ref) 'local_snapshot)))

(defun xiiif-locus-reachability (ref)
  "What xiiif can say about reaching REF before trying.
A cons (STATE . DETAIL) where STATE is `offline', `allowed' or
`refused'."
  (let ((target (plist-get (xiiif-locus-locator-target ref) :target)))
    (if (not (xiiif-locus-locator-needs-network-p ref))
        (cons 'offline "local snapshot; no network needed")
      (let ((refusal (xiiif-url-refusal target)))
        (if refusal
            (cons 'refused (xiiif-url-refusal-message refusal))
          (cons 'allowed "allowed by the URL policy"))))))


;;; ---------- what xiiif can check itself ----------

(defun xiiif-locus--algorithm (hash)
  "The algorithm named by HASH, as a symbol `secure-hash' accepts, or nil.
Locus may write a blake3 hash; Emacs cannot compute one, and saying
so is better than reporting a mismatch xiiif caused itself."
  (when (and (stringp hash) (string-match xiiif-locus--hash-re hash))
    (let ((name (match-string 1 hash)))
      (and (member name '("sha256" "sha512")) (intern name)))))

(defun xiiif-locus-hash-string (algorithm string)
  "Return STRING hashed with ALGORITHM, written the way Locus writes it."
  (format "%s:%s" algorithm (secure-hash algorithm string)))

(defun xiiif-locus-verify-snapshot (ref)
  "Replay REF's snapshot from disk and return a plist (:standing S :reason R).

Only a `local_snapshot' can be replayed here: it is the one locator
whose bytes xiiif holds.  Everything else is `unverified' - not
`broken', because nothing was compared."
  (let ((algorithm (xiiif-locus--algorithm (xiiif-locus-ref-snapshot-hash ref)))
        (path (xiiif-locus-ref-locator-value ref)))
    (cond
     ((not (eq (xiiif-locus-ref-locator-kind ref) 'local_snapshot))
      (list :standing 'unverified :reason 'remote))
     ((null algorithm)
      (list :standing 'unverified :reason 'unsupported-algorithm))
     ((not (file-readable-p path))
      (list :standing 'unverified :reason 'unreadable))
     (t
      (let ((replayed (with-temp-buffer
                        (set-buffer-multibyte nil)
                        (insert-file-contents-literally path)
                        (xiiif-locus-hash-string algorithm (buffer-string)))))
        (list :standing (xiiif-locus-proof-standing ref replayed)
              :reason 'replayed
              :hash replayed))))))


;;; ---------- the five facets ----------

(defconst xiiif-locus-facet-labels
  '((identity     . "Locus artifact")
    (live         . "Remote resource, live")
    (snapshot     . "Snapshot used during the run")
    (integrity    . "Integrity of the proof")
    (divergences  . "Divergences"))
  "The five facets §19 asks xiiif to show separately, in its order.")

(defun xiiif-locus--standing-line (standing)
  "The one sentence STANDING is worth.  A function of STANDING alone."
  (pcase standing
    ('holds "the replayed content matches the snapshot")
    ('broken "the replayed content does NOT match the snapshot")
    (_ "not replayed, so nothing is claimed either way")))

(defun xiiif-locus--drift-line (drift)
  "The one sentence DRIFT is worth.  A function of DRIFT alone."
  (pcase drift
    ('unchanged "the remote resource still matches what the run saw")
    ('moved "the remote resource changed after the run")
    ('unrecorded "the run recorded no live hash, so change cannot be told")
    (_ "the remote resource has not been checked since the run")))

(defun xiiif-locus-facets (ref &optional observation)
  "The five facets of §19 for REF, in order, as a list of plists.

Each plist carries `:key', `:label' and `:lines', a list of
\(LABEL . VALUE) pairs.  OBSERVATION is a plist of what has actually
been looked at: `:replayed-hash', `:live-hash' and
`:metadata-divergences', a list of (FIELD RECORDED LIVE).

The `integrity' facet is a function of the proof standing alone, and
the `divergences' facet never mentions it.  That separation is §19
itself, not a presentation choice: a screen that merged them would
either blame the run for a library's redesign, or hide a source that
is no longer the one that was read."
  (let* ((replayed (plist-get observation :replayed-hash))
         (live (plist-get observation :live-hash))
         (metadata (plist-get observation :metadata-divergences))
         (standing (xiiif-locus-proof-standing ref replayed))
         (drift (xiiif-locus-live-drift ref live))
         (reach (xiiif-locus-reachability ref))
         (target (xiiif-locus-locator-target ref)))
    (list
     (list :key 'identity :label (alist-get 'identity xiiif-locus-facet-labels)
           :lines `(("Artifact" . ,(xiiif-locus-ref-id ref))
                    ("Media type" . ,(xiiif-locus-ref-media-type ref))
                    ("Viewer hint" . ,(or (xiiif-locus-ref-viewer-hint ref)
                                          "none; xiiif is never required"))))
     (list :key 'live :label (alist-get 'live xiiif-locus-facet-labels)
           :lines `(("Locator" . ,(symbol-name
                                   (xiiif-locus-ref-locator-kind ref)))
                    ("Target" . ,(plist-get target :target))
                    ,@(when (plist-get target :region)
                        `(("Region" . ,(plist-get target :region))))
                    ("Reachable" . ,(format "%s - %s" (car reach) (cdr reach)))
                    ("Hash now" . ,(or live "not checked"))))
     (list :key 'snapshot :label (alist-get 'snapshot xiiif-locus-facet-labels)
           :lines `(("Snapshot" . ,(xiiif-locus-ref-snapshot-hash ref))
                    ("Live at run" . ,(or (xiiif-locus-ref-live-hash-at-run ref)
                                          "not recorded"))
                    ("Captured" . ,(or (xiiif-locus-ref-captured-at ref)
                                       "not recorded"))))
     (list :key 'integrity :label (alist-get 'integrity xiiif-locus-facet-labels)
           :lines `(("Snapshot" . ,(symbol-name standing))
                    ("Means" . ,(xiiif-locus--standing-line standing))))
     (list :key 'divergences
           :label (alist-get 'divergences xiiif-locus-facet-labels)
           :lines `(("Content" . ,(symbol-name drift))
                    ("Means" . ,(xiiif-locus--drift-line drift))
                    ,@(if metadata
                          (mapcar (lambda (entry)
                                    (cons (format "%s" (nth 0 entry))
                                          (format "run: %s / live: %s"
                                                  (nth 1 entry) (nth 2 entry))))
                                  metadata)
                        '(("Metadata" . "none reported"))))))))

(defun xiiif-locus-metadata-divergences (recorded live)
  "Fields where the RECORDED and LIVE alists disagree.
Each element is (FIELD RECORDED-VALUE LIVE-VALUE).  A field absent
from one side counts as a divergence: metadata that disappeared is
exactly the kind that gets cited anyway."
  (let ((fields (cl-remove-duplicates
                 (append (mapcar #'car recorded) (mapcar #'car live))
                 :test #'equal :from-end t)))
    (cl-remove-if-not
     (lambda (entry) (not (equal (nth 1 entry) (nth 2 entry))))
     (mapcar (lambda (field)
               (list field (alist-get field recorded nil nil #'equal)
                     (alist-get field live nil nil #'equal)))
             fields))))


;;; ---------- the buffer ----------

(defvar xiiif-locus-buffer "*xiiif-locus*"
  "Name of the buffer showing a Locus artifact reference.")

(defvar-local xiiif-locus--ref nil
  "The `xiiif-locus-ref' backing the current buffer.")

(defvar-local xiiif-locus--observation nil
  "What has actually been looked at in the current buffer, as a plist.")

(defvar xiiif-locus-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'xiiif-locus-open-resource)
    (define-key map (kbd "o")   #'xiiif-locus-open-resource)
    (define-key map (kbd "v")   #'xiiif-locus-verify)
    (define-key map (kbd "l")   #'xiiif-locus-check-live)
    (define-key map (kbd "y")   #'xiiif-locus-copy-artifact-id)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `xiiif-locus-mode'.")

(define-derived-mode xiiif-locus-mode special-mode "XIIIF-Locus"
  "Major mode for a Locus artifact reference."
  (buffer-disable-undo)
  (setq-local truncate-lines t))

(defun xiiif-locus--insert-line (label value)
  "Insert LABEL and VALUE.  Unlike `xiiif-ui--insert-field', never skips.
A facet that quietly dropped a line would be a facet §19 asked for
and the screen did not show."
  (insert (propertize (format "%-13s " (concat label ":")) 'face 'xiiif-key))
  (insert (format "%s" value) "\n"))

(defun xiiif-locus-render (ref &optional observation)
  "Render REF and OBSERVATION in `xiiif-locus-buffer' and display it."
  (let ((buf (get-buffer-create xiiif-locus-buffer)))
    (with-current-buffer buf
      (xiiif-locus-mode)
      (setq-local xiiif-locus--ref ref)
      (setq-local xiiif-locus--observation observation)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (xiiif-ui--insert-hints
         '(("RET" . "open resource") ("v" . "verify snapshot")
           ("l" . "check live") ("y" . "copy ID") ("q" . "quit")))
        (dolist (facet (xiiif-locus-facets ref observation))
          (xiiif-ui--insert-heading (plist-get facet :label))
          (dolist (line (plist-get facet :lines))
            (xiiif-locus--insert-line (car line) (cdr line)))
          (insert "\n"))
        (goto-char (point-min))))
    (pop-to-buffer-same-window buf)))

(defun xiiif-locus--context-ref ()
  "The reference the current buffer is about, or a user-error."
  (or xiiif-locus--ref
      (user-error "No Locus artifact reference here")))

(defun xiiif-locus--observe (key value)
  "Record VALUE under KEY in this buffer's observation and re-render."
  (let ((ref (xiiif-locus--context-ref))
        (observation (plist-put (copy-sequence xiiif-locus--observation)
                                key value)))
    (xiiif-locus-render ref observation)))

;;;###autoload
(defun xiiif-open-locus-artifact (reference)
  "Open a Locus artifact REFERENCE and show the five facets of §19.

REFERENCE is a `xiiif-locus-ref', a decoded JSON object, or a string
holding the document - interactively, the name of a readable file or
the JSON itself.  Nothing is fetched: the reference is shown first,
and reaching the resource is a keystroke away."
  (interactive (list (read-string "Locus artifact reference (file or JSON): ")))
  (xiiif-locus-render (xiiif-locus--coerce reference)))

(defun xiiif-locus--coerce (reference)
  "Return REFERENCE as a `xiiif-locus-ref'."
  (cond
   ((xiiif-locus-ref-p reference) reference)
   ((and (stringp reference) (file-readable-p (expand-file-name reference)))
    (let ((path (expand-file-name reference)))
      (xiiif-locus-parse
       (with-temp-buffer (insert-file-contents path) (buffer-string))
       path)))
   ((stringp reference)
    (when (string-blank-p reference)
      (user-error "Nothing to open"))
    (xiiif-locus-parse reference reference))
   (t (xiiif-locus-parse reference))))

(defun xiiif-locus-open-resource (&optional ref)
  "Open the resource REF points at, applying the URL policy first.
REF defaults to the reference in the current buffer."
  (interactive)
  (let* ((ref (or ref (xiiif-locus--context-ref)))
         (target (xiiif-locus-locator-target ref))
         (where (plist-get target :target))
         (region (plist-get target :region)))
    (when region
      (message "xiiif: the reference claims region %s" region))
    (pcase (plist-get target :action)
      ('content-state (xiiif-open-content-state where))
      ('local-file
       (unless (file-readable-p where)
         (user-error "Snapshot %s is not readable" where))
       (find-file-read-only where))
      (_ (xiiif-open-manifest (xiiif-url-check where))))))

(defun xiiif-locus-verify ()
  "Replay this buffer's snapshot from disk and report what it says."
  (interactive)
  (let* ((ref (xiiif-locus--context-ref))
         (result (xiiif-locus-verify-snapshot ref)))
    (pcase (plist-get result :reason)
      ('replayed (xiiif-locus--observe :replayed-hash
                                       (plist-get result :hash)))
      ('remote (message "xiiif: %s is remote; xiiif holds no copy to replay"
                        (xiiif-locus-ref-locator-kind ref)))
      ('unsupported-algorithm
       (message "xiiif: Emacs cannot compute %s; reporting nothing rather than a mismatch xiiif caused"
                (car (split-string (xiiif-locus-ref-snapshot-hash ref) ":"))))
      (_ (message "xiiif: snapshot %s is not readable"
                  (xiiif-locus-ref-locator-value ref))))))

(defun xiiif-locus-check-live ()
  "Fetch this buffer's remote resource and record what it hashes to now.

Touches the live facet and the divergences facet, never the
integrity one: what the source is doing today has no bearing on
whether the run's snapshot still proves what it proved."
  (interactive)
  (let* ((ref (xiiif-locus--context-ref))
         (buffer (current-buffer))
         (target (xiiif-locus-locator-target ref))
         (algorithm (or (xiiif-locus--algorithm
                         (xiiif-locus-ref-live-hash-at-run ref))
                        (xiiif-locus--algorithm
                         (xiiif-locus-ref-snapshot-hash ref)))))
    (unless (xiiif-locus-locator-needs-network-p ref)
      (user-error "This reference is a local snapshot; use `v' to verify it"))
    (unless algorithm
      (user-error "Emacs cannot compute the algorithm this reference uses"))
    (let ((url (xiiif-url-check (plist-get target :target))))
      (message "xiiif: hashing %s..." url)
      (xiiif-fetch-bytes
       url
       (lambda (bytes)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (xiiif-locus--observe
              :live-hash (xiiif-locus-hash-string algorithm bytes)))))
       :errback (lambda (err)
                  (message "xiiif: could not reach %s (%s)"
                           url (error-message-string err)))))))

(defun xiiif-locus-copy-artifact-id ()
  "Copy the Locus artifact ID to the kill ring.
It is the one identity in this buffer that does not move."
  (interactive)
  (let ((id (xiiif-locus-ref-id (xiiif-locus--context-ref))))
    (kill-new id)
    (message "xiiif: %s copied" id)))

(provide 'xiiif-locus)
;;; xiiif-locus.el ends here
