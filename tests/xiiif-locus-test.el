;;; xiiif-locus-test.el --- Tests for Locus artifact references -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The exit test of §19, in two halves.
;;
;; The first: the five facets are five, distinct, and in the spec's
;; order on screen.  A viewer that folded two of them together would
;; still look correct in a screenshot.
;;
;; The second, and the one that matters: a remote resource modified
;; after the run must never make the historical proof look changed.
;; That is not tested by reading one sentence - it is tested by holding
;; the proof fixed, moving the source, and asserting the integrity
;; facet is *byte-for-byte the same*.  Any leak at all fails it.
;;
;; The refusals are a second, independent implementation of the same
;; contract locusolus enforces in Rust.  They are tested here against
;; documents, not against that code, because the value of two
;; implementations is exactly that neither one is consulted.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-locus)

(defconst xiiif-locus-test--root
  ;; Captured at load time: `load-file-name' is nil by the time a test
  ;; body runs, and a test that silently resolved to the wrong tree
  ;; would pass by looking at nothing.
  (when load-file-name
    (file-name-directory (directory-file-name
                          (file-name-directory load-file-name))))
  "The repository root, or nil when the suite was not loaded from a file.")

(defun xiiif-locus-test--hash (char)
  (format "sha256:%s" (make-string 64 char)))

(defun xiiif-locus-test--doc (&rest overrides)
  "A well-formed reference document, with OVERRIDES applied at top level.

`copy-tree', because a backquoted branch with no unquote in it is a
shared constant: one test overriding the locator would rewrite the
fixture for every test that ran after it, and which ones those are
depends on the alphabet."
  (let ((doc (copy-tree
              `((artifact_id . "art-0001")
                (media_type . "image/jpeg")
                (expected . ((snapshot_hash . ,(xiiif-locus-test--hash ?a))
                             (live_hash_at_run . ,(xiiif-locus-test--hash ?b))
                             (captured_at . "2026-08-01T10:00:00Z")))
                (locator
                 . ((manifest_url . "https://example.org/iiif/manifest")))))))
    (while overrides
      (let* ((key (pop overrides))
             (value (pop overrides)))
        (setf (alist-get key doc) value)))
    doc))

(defun xiiif-locus-test--ref (&rest overrides)
  (xiiif-locus-parse (apply #'xiiif-locus-test--doc overrides)))

(defun xiiif-locus-test--reason (form-thunk)
  "The reason symbol carried by the `xiiif-locus-invalid' FORM-THUNK signals."
  (condition-case err (progn (funcall form-thunk) nil)
    (xiiif-locus-invalid (nth 1 err))))


;;; ---------- reading the document ----------

(ert-deftest xiiif-locus/a-well-formed-document-reads ()
  (let ((ref (xiiif-locus-test--ref)))
    (should (equal (xiiif-locus-ref-id ref) "art-0001"))
    (should (equal (xiiif-locus-ref-media-type ref) "image/jpeg"))
    (should (equal (xiiif-locus-ref-snapshot-hash ref)
                   (xiiif-locus-test--hash ?a)))
    (should (equal (xiiif-locus-ref-live-hash-at-run ref)
                   (xiiif-locus-test--hash ?b)))
    (should (eq (xiiif-locus-ref-locator-kind ref) 'manifest_url))
    (should (equal (xiiif-locus-ref-locator-value ref)
                   "https://example.org/iiif/manifest"))))

(ert-deftest xiiif-locus/the-document-reads-from-json-text ()
  "The reference arrives as bytes, not as an alist someone built here."
  (let ((ref (xiiif-locus-parse
              (json-encode (xiiif-locus-test--doc)) "test")))
    (should (equal (xiiif-locus-ref-id ref) "art-0001"))
    (should (eq (xiiif-locus-ref-locator-kind ref) 'manifest_url))))

(ert-deftest xiiif-locus/the-fixture-is-fresh-for-every-test ()
  "Guards the bug that made this suite pass or fail by alphabet: a test
that overrode the locator used to rewrite the shared fixture for every
test that ran after it."
  (xiiif-locus-test--doc 'locator '((local_snapshot . "/tmp/x")))
  (should (equal '((manifest_url . "https://example.org/iiif/manifest"))
                 (alist-get 'locator (xiiif-locus-test--doc)))))

(ert-deftest xiiif-locus/two-locators-are-refused ()
  "§19 names five and allows one.  Two would leave xiiif to pick, so the
same citation would not always open the same thing."
  (let ((reason (xiiif-locus-test--reason
                 (lambda ()
                   (xiiif-locus-test--ref
                    'locator '((manifest_url . "https://example.org/m")
                               (canvas_id . "https://example.org/c/1")))))))
    (should (eq 'locator-count reason))))

(ert-deftest xiiif-locus/no-locator-is-refused ()
  "A producer that emits its five locator fields and leaves them all null
sends a document that names no resource at all."
  (let ((reason (xiiif-locus-test--reason
                 (lambda ()
                   (xiiif-locus-test--ref
                    'locator '((manifest_url . nil) (canvas_id . nil)))))))
    (should (eq 'locator-count reason))))

(ert-deftest xiiif-locus/an-unnamed-locator-is-refused-not-ignored ()
  "Skipping a key xiiif does not know would open a different resource in
silence - the exact failure the one-locator rule exists to prevent."
  (let ((reason (xiiif-locus-test--reason
                 (lambda ()
                   (xiiif-locus-test--ref
                    'locator '((manifest_url . "https://example.org/m")
                               (iiif_v4_pointer . "https://example.org/x")))))))
    (should (eq 'unknown-locator reason))))

(ert-deftest xiiif-locus/an-empty-locator-is-refused ()
  (let ((reason (xiiif-locus-test--reason
                 (lambda ()
                   (xiiif-locus-test--ref 'locator '((canvas_id . "   ")))))))
    (should (eq 'empty-field reason))))

(ert-deftest xiiif-locus/every-refusal-reason-is-reachable ()
  "A reason no document can produce is a promise the parser does not keep."
  (let ((cases
         `((not-an-object . ,(lambda () (xiiif-locus-parse '(1 2 3))))
           (missing-field
            . ,(lambda () (xiiif-locus-parse
                           (assq-delete-all 'expected
                                            (xiiif-locus-test--doc)))))
           (malformed-field
            . ,(lambda () (xiiif-locus-test--ref 'artifact_id 42)))
           (empty-field
            . ,(lambda () (xiiif-locus-test--ref 'artifact_id "  ")))
           (malformed-media-type
            . ,(lambda () (xiiif-locus-test--ref 'media_type "image")))
           (malformed-hash
            . ,(lambda () (xiiif-locus-test--ref
                           'expected '((snapshot_hash . "deadbeef")))))
           (locator-count
            . ,(lambda () (xiiif-locus-test--ref
                           'locator '((manifest_url . nil)))))
           (unknown-locator
            . ,(lambda () (xiiif-locus-test--ref 'locator '((nope . "x"))))))))
    (dolist (case cases)
      (ert-info ((format "reason %s" (car case)))
        (let ((reason (xiiif-locus-test--reason (cdr case))))
          (should (eq (car case) reason)))))))

(ert-deftest xiiif-locus/the-five-locators-are-the-five-of-19 ()
  (should (equal xiiif-locus-locators
                 '(manifest_url canvas_id content_state
                                annotation_target local_snapshot)))
  (dolist (kind xiiif-locus-locators)
    (ert-info ((symbol-name kind))
      (should (eq kind (xiiif-locus-ref-locator-kind
                        (xiiif-locus-test--ref
                         'locator (list (cons kind "https://example.org/x")))))))))


;;; ---------- the two verdicts ----------

(ert-deftest xiiif-locus/the-snapshot-is-what-proves ()
  (let ((ref (xiiif-locus-test--ref)))
    (should (eq 'holds (xiiif-locus-proof-standing
                        ref (xiiif-locus-test--hash ?a))))
    (should (eq 'broken (xiiif-locus-proof-standing
                         ref (xiiif-locus-test--hash ?z))))))

(ert-deftest xiiif-locus/nothing-replayed-is-not-a-broken-proof ()
  "An absence of evidence is not evidence.  `unverified' is not a milder
`broken': nobody looked."
  (should (eq 'unverified
              (xiiif-locus-proof-standing (xiiif-locus-test--ref) nil))))

(ert-deftest xiiif-locus/drift-has-four-answers-and-two-of-them-are-absences ()
  (let ((ref (xiiif-locus-test--ref)))
    (should (eq 'unchanged (xiiif-locus-live-drift
                            ref (xiiif-locus-test--hash ?b))))
    (should (eq 'moved (xiiif-locus-live-drift
                        ref (xiiif-locus-test--hash ?z))))
    (should (eq 'unchecked (xiiif-locus-live-drift ref nil))))
  ;; The run noted no live hash, so change can never be told - a
  ;; different absence from "nobody has looked yet", and one no
  ;; keystroke fixes.
  (should (eq 'unrecorded
              (xiiif-locus-live-drift
               (xiiif-locus-test--ref
                'expected `((snapshot_hash . ,(xiiif-locus-test--hash ?a))))
               (xiiif-locus-test--hash ?z)))))


;;; ---------- §19: the source moves, the proof does not ----------

(defun xiiif-locus-test--facet (key ref &optional observation)
  (cl-find key (xiiif-locus-facets ref observation)
           :key (lambda (facet) (plist-get facet :key))))

(ert-deftest xiiif-locus/integrity-is-a-function-of-the-proof-alone ()
  "The heart of §19.  Hold the replay fixed, move the source, and the
integrity facet must not change by one character.  Asserting on a
sentence would pass a facet that leaked the drift into a second line."
  (let ((ref (xiiif-locus-test--ref)))
    (dolist (replayed (list (xiiif-locus-test--hash ?a)
                            (xiiif-locus-test--hash ?z)
                            nil))
      (let ((facets (mapcar (lambda (live)
                              (xiiif-locus-test--facet
                               'integrity ref
                               (list :replayed-hash replayed :live-hash live)))
                            (list (xiiif-locus-test--hash ?b)
                                  (xiiif-locus-test--hash ?z)
                                  nil))))
        (ert-info ((format "replayed %s" replayed))
          (should (equal (nth 0 facets) (nth 1 facets)))
          (should (equal (nth 0 facets) (nth 2 facets))))))))

(ert-deftest xiiif-locus/divergences-never-speak-of-the-proof ()
  "And the other way round: replaying, or failing to, must not alter what
the screen says about the source."
  (let ((ref (xiiif-locus-test--ref)))
    (dolist (live (list (xiiif-locus-test--hash ?b)
                        (xiiif-locus-test--hash ?z)
                        nil))
      (let ((facets (mapcar (lambda (replayed)
                              (xiiif-locus-test--facet
                               'divergences ref
                               (list :replayed-hash replayed :live-hash live)))
                            (list (xiiif-locus-test--hash ?a)
                                  (xiiif-locus-test--hash ?z)
                                  nil))))
        (ert-info ((format "live %s" live))
          (should (equal (nth 0 facets) (nth 1 facets)))
          (should (equal (nth 0 facets) (nth 2 facets))))))))

(ert-deftest xiiif-locus/identity-is-what-does-not-move ()
  "§19 asks for the canonical Locus identity separately because it is the
one thing a redesigned website cannot touch."
  (let* ((ref (xiiif-locus-test--ref))
         (reference (xiiif-locus-test--facet 'identity ref)))
    (dolist (observation (list nil
                               (list :live-hash (xiiif-locus-test--hash ?z))
                               (list :replayed-hash (xiiif-locus-test--hash ?z))
                               (list :metadata-divergences
                                     '(("Label" "Folio 1" "f. 1")))))
      (should (equal reference
                     (xiiif-locus-test--facet 'identity ref observation))))))

(ert-deftest xiiif-locus/a-moved-source-with-a-standing-proof-says-both ()
  (let* ((ref (xiiif-locus-test--ref))
         (observation (list :replayed-hash (xiiif-locus-test--hash ?a)
                           :live-hash (xiiif-locus-test--hash ?z))))
    (should (eq 'holds (xiiif-locus-proof-standing
                        ref (plist-get observation :replayed-hash))))
    (should (eq 'moved (xiiif-locus-live-drift
                        ref (plist-get observation :live-hash))))
    (should (equal "holds"
                   (alist-get "Snapshot"
                              (plist-get (xiiif-locus-test--facet
                                          'integrity ref observation)
                                         :lines)
                              nil nil #'equal)))
    (should (equal "moved"
                   (alist-get "Content"
                              (plist-get (xiiif-locus-test--facet
                                          'divergences ref observation)
                                         :lines)
                              nil nil #'equal)))))


;;; ---------- five facets, on screen ----------

(defun xiiif-locus-test--render (ref &optional observation)
  "Render REF and return the buffer text, cleaning up after itself."
  (unwind-protect
      (save-window-excursion
        (xiiif-locus-render ref observation)
        (with-current-buffer xiiif-locus-buffer
          (substring-no-properties (buffer-string))))
    (when (get-buffer xiiif-locus-buffer)
      (kill-buffer xiiif-locus-buffer))))

(ert-deftest xiiif-locus/the-screen-shows-five-headings-in-order ()
  (let* ((text (xiiif-locus-test--render (xiiif-locus-test--ref)))
         (labels (mapcar #'cdr xiiif-locus-facet-labels))
         (positions (mapcar (lambda (label) (string-search label text)) labels)))
    (should (= 5 (length labels)))
    (dolist (position positions) (should position))
    (should (equal positions (sort (copy-sequence positions) #'<)))
    ;; Each heading exactly once: a facet rendered twice is a facet the
    ;; reader has to reconcile with itself.
    (dolist (label labels)
      (ert-info (label)
        (should (= 1 (cl-count label (split-string text "\n")
                               :test (lambda (needle line)
                                       (string-prefix-p needle line)))))))))

(ert-deftest xiiif-locus/the-integrity-section-never-carries-the-drift ()
  "Rendered, not just computed: the section the reader's eye lands on when
asking whether the result still holds must contain no word about the
source having moved."
  (let* ((ref (xiiif-locus-test--ref))
         (sections
          (lambda (live)
            (let* ((text (xiiif-locus-test--render
                          ref (list :replayed-hash (xiiif-locus-test--hash ?a)
                                    :live-hash live)))
                   (start (string-search
                           (alist-get 'integrity xiiif-locus-facet-labels)
                           text))
                   (end (string-search
                         (alist-get 'divergences xiiif-locus-facet-labels)
                         text)))
              (should (and start end (< start end)))
              (substring text start end)))))
    (let ((unchanged (funcall sections (xiiif-locus-test--hash ?b)))
          (moved (funcall sections (xiiif-locus-test--hash ?z))))
      (should (equal unchanged moved))
      (should-not (string-match-p "moved\\|changed" moved))
      (should (string-match-p "holds" moved)))))

(ert-deftest xiiif-locus/a-facet-line-is-never-silently-dropped ()
  "`xiiif-ui--insert-field' skips empty values, which is right for a
manifest and wrong here: a missing integrity line reads as a clean bill
of health."
  (let ((text (xiiif-locus-test--render
               (xiiif-locus-test--ref
                'expected `((snapshot_hash . ,(xiiif-locus-test--hash ?a)))))))
    (should (string-match-p "^Live at run: *not recorded" text))
    (should (string-match-p "^Captured: *not recorded" text))
    (should (string-match-p "^Hash now: *not checked" text))))


;;; ---------- reaching the resource ----------

(ert-deftest xiiif-locus/an-annotation-target-keeps-its-region-out-of-the-url ()
  (let ((target (xiiif-locus-locator-target
                 (xiiif-locus-test--ref
                  'locator '((annotation_target
                              . "https://example.org/c/1#xywh=10,20,30,40"))))))
    (should (eq 'resource (plist-get target :action)))
    (should (equal "https://example.org/c/1" (plist-get target :target)))
    (should (equal "10,20,30,40" (plist-get target :region)))))

(ert-deftest xiiif-locus/only-a-local-snapshot-reads-without-network ()
  "The one locator that keeps a proof consultable when the source is not."
  (should-not (xiiif-locus-locator-needs-network-p
               (xiiif-locus-test--ref
                'locator '((local_snapshot . "/var/locus/snap.json")))))
  (dolist (kind '(manifest_url canvas_id content_state annotation_target))
    (ert-info ((symbol-name kind))
      (should (xiiif-locus-locator-needs-network-p
               (xiiif-locus-test--ref
                'locator (list (cons kind "https://example.org/x"))))))))

(ert-deftest xiiif-locus/the-url-policy-refuses-before-any-fetch ()
  "A reference is remote data.  Its locator goes through the same policy as
a URL a user typed, and the refusal happens before the transport is
reached - poisoned here so a leak is a failure, not a slow test."
  (let* ((reached nil)
         (ref (xiiif-locus-test--ref
               'locator '((manifest_url . "http://169.254.169.254/latest/meta-data/")))))
    (should (eq 'refused (car (xiiif-locus-reachability ref))))
    (cl-letf (((symbol-function 'xiiif-open-manifest)
               (lambda (&rest _) (setq reached t))))
      (should-error (xiiif-locus-open-resource ref) :type 'xiiif-url-refused))
    (should-not reached)))

(ert-deftest xiiif-locus/reachability-tells-offline-from-allowed ()
  (should (eq 'offline (car (xiiif-locus-reachability
                             (xiiif-locus-test--ref
                              'locator '((local_snapshot . "/var/locus/x")))))))
  (should (eq 'allowed (car (xiiif-locus-reachability
                             (xiiif-locus-test--ref))))))


;;; ---------- what xiiif can check itself ----------

(defmacro xiiif-locus-test--with-snapshot (var content &rest body)
  "Bind VAR to a temporary file holding CONTENT and run BODY."
  (declare (indent 2))
  `(let ((,var (make-temp-file "xiiif-locus-test")))
     (unwind-protect
         (progn (with-temp-file ,var (insert ,content)) ,@body)
       (delete-file ,var))))

(ert-deftest xiiif-locus/a-local-snapshot-is-replayed-from-disk ()
  (xiiif-locus-test--with-snapshot path "hello"
    (let* ((digest (xiiif-locus-hash-string 'sha256 "hello"))
           (ref (xiiif-locus-test--ref
                 'expected `((snapshot_hash . ,digest))
                 'locator `((local_snapshot . ,path)))))
      (should (eq 'holds (plist-get (xiiif-locus-verify-snapshot ref)
                                    :standing))))))

(ert-deftest xiiif-locus/a-damaged-snapshot-breaks-the-proof ()
  (xiiif-locus-test--with-snapshot path "hello"
    (let ((ref (xiiif-locus-test--ref
                'expected `((snapshot_hash . ,(xiiif-locus-hash-string
                                               'sha256 "goodbye")))
                'locator `((local_snapshot . ,path)))))
      (should (eq 'broken (plist-get (xiiif-locus-verify-snapshot ref)
                                     :standing))))))

(ert-deftest xiiif-locus/what-emacs-cannot-hash-is-unverified-not-broken ()
  "Reporting a mismatch xiiif caused itself would put a correct run in
doubt.  blake3 is a hash Locus may write and Emacs cannot compute."
  (xiiif-locus-test--with-snapshot path "hello"
    (let* ((ref (xiiif-locus-test--ref
                 'expected `((snapshot_hash . ,(format "blake3:%s"
                                                       (make-string 64 ?a))))
                 'locator `((local_snapshot . ,path))))
           (result (xiiif-locus-verify-snapshot ref)))
      (should (eq 'unverified (plist-get result :standing)))
      (should (eq 'unsupported-algorithm (plist-get result :reason))))))

(ert-deftest xiiif-locus/a-remote-reference-is-unverified-not-broken ()
  (let ((result (xiiif-locus-verify-snapshot (xiiif-locus-test--ref))))
    (should (eq 'unverified (plist-get result :standing)))
    (should (eq 'remote (plist-get result :reason)))))

(ert-deftest xiiif-locus/a-missing-snapshot-is-unverified-not-broken ()
  (let ((result (xiiif-locus-verify-snapshot
                 (xiiif-locus-test--ref
                  'locator '((local_snapshot . "/nonexistent/xiiif/snap"))))))
    (should (eq 'unverified (plist-get result :standing)))
    (should (eq 'unreadable (plist-get result :reason)))))

(ert-deftest xiiif-locus/checking-live-leaves-the-integrity-facet-alone ()
  "The command that talks to the network, exercised end to end through a
stubbed transport: what it may change is the live and divergence facets,
and nothing else."
  (let* ((ref (xiiif-locus-test--ref))
         (before nil))
    (unwind-protect
        (save-window-excursion
          (xiiif-locus-render ref (list :replayed-hash
                                        (xiiif-locus-test--hash ?a)))
          (with-current-buffer xiiif-locus-buffer
            (setq before (xiiif-locus-test--facet
                          'integrity ref xiiif-locus--observation))
            (cl-letf (((symbol-function 'xiiif-fetch-bytes)
                       (lambda (_url callback &rest _)
                         (funcall callback "quite different bytes"))))
              (xiiif-locus-check-live))
            (should (equal (xiiif-locus-hash-string
                            'sha256 "quite different bytes")
                           (plist-get xiiif-locus--observation :live-hash)))
            (should (eq 'moved (xiiif-locus-live-drift
                                ref (plist-get xiiif-locus--observation
                                               :live-hash))))
            (should (equal before (xiiif-locus-test--facet
                                   'integrity ref xiiif-locus--observation)))))
      (when (get-buffer xiiif-locus-buffer)
        (kill-buffer xiiif-locus-buffer)))))


;;; ---------- metadata divergences ----------

(ert-deftest xiiif-locus/metadata-divergences-include-what-disappeared ()
  "Metadata that vanished from the source is exactly the kind that keeps
being cited, so an absent field is a divergence, not a match."
  (let ((divergences (xiiif-locus-metadata-divergences
                      '(("Label" . "Folio 1") ("Rights" . "CC-BY")
                        ("Date" . "1521"))
                      '(("Label" . "f. 1") ("Date" . "1521")))))
    (should (equal (sort (mapcar #'car divergences) #'string<)
                   '("Label" "Rights")))
    (should (equal (assoc "Rights" divergences) '("Rights" "CC-BY" nil)))))


;;; ---------- the boundary ----------

(ert-deftest xiiif-locus/xiiif-imports-no-locus-code ()
  "xiiif reads the reference as data.  Invariant 10 and the repository's
hard rule: the integration is optional and goes through the Locus Emacs
client, never through Locus code linked in here."
  (should-not (cl-find-if (lambda (feature)
                            (string-prefix-p "locus" (symbol-name feature)))
                          features)))

(ert-deftest xiiif-locus/no-source-file-requires-a-locus-feature ()
  "The `features' check above only sees what a load actually pulled in; a
`require' hidden in a function body would slip past it."
  (skip-unless xiiif-locus-test--root)
  (let ((sources (directory-files xiiif-locus-test--root t "\\`xiiif.*\\.el\\'")))
    (should (> (length sources) 20))
    (dolist (source sources)
      (ert-info ((file-name-nondirectory source))
        (with-temp-buffer
          (insert-file-contents source)
          (goto-char (point-min))
          (should-not (re-search-forward
                       "(\\(?:require\\|load\\)[[:space:]]+'locus" nil t)))))))

(provide 'xiiif-locus-test)
;;; xiiif-locus-test.el ends here
