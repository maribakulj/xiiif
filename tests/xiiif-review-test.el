;;; xiiif-review-test.el --- Tests for the §20 human review -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; §20 asks two things of the viewer that pull against each other.
;;
;; The reviewer must be able to say something real - four verdicts and a
;; free comment, recorded as a finding a dossier can hold.  And xiiif must
;; not, by recording it, decide anything: "cette revue n'est pas une
;; validation scientifique complète."
;;
;; The tests below take the second half seriously in the only way that
;; survives a rewrite: there is no fifth verdict, an invented one is
;; refused rather than passed through as free text, and the recorded
;; document carries no field that a reader could take for a validation.
;;
;; The display half has one rule worth a strict test - the interpretive
;; report is opened, never injected into the source.  The obvious
;; implementation appends it to the canvas buffer, and from then on nobody
;; can tell the document from the reading of it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-review)

(defconst xiiif-review-test--report
  "L'agent lit dans la marge une main du XVIIe et propose « Rousseau ».")

(defconst xiiif-review-test--source "https://example.org/iiif/canvas/34")

(defun xiiif-review-test--kill-buffers ()
  (dolist (name (list xiiif-review-buffer
                      xiiif-review-source-buffer
                      xiiif-review-report-buffer
                      xiiif-locus-buffer))
    (when (get-buffer name) (kill-buffer name))))

(defmacro xiiif-review-test--with-review (&rest body)
  "Open a review, run BODY, and clean up the buffers afterwards."
  (declare (indent 0))
  `(unwind-protect
       (save-window-excursion
         (xiiif-review-open "dossier-0007" "01HQ8Z3M4N5P6Q7R8S9T0V1W2X"
                            :source xiiif-review-test--source
                            :region "10,20,30,40"
                            :report xiiif-review-test--report)
         ,@body)
     (xiiif-review-test--kill-buffers)))

(defun xiiif-review-test--text (name)
  (with-current-buffer (get-buffer name)
    (substring-no-properties (buffer-string))))


;;; ---------- the four verdicts, and no fifth ----------

(ert-deftest xiiif-review/the-four-verdicts-are-the-four-of-20 ()
  (should (equal xiiif-review-verdicts
                 '(accept needs-correction wrong-target source-changed))))

(ert-deftest xiiif-review/an-invented-verdict-is-refused ()
  "Not passed along as free text.  `validated' is precisely the word §20
withholds from this review, and a verdict that reached a dossier under a
name nobody defined would be counted there all the same."
  (let ((reason (condition-case err
                    (progn (xiiif-review-record "d-1" "rev-1" :verdict 'validated
                                                :reviewer "human:x")
                           nil)
                  (xiiif-locus-invalid (nth 1 err)))))
    (should (eq 'unknown-verdict reason))))

(ert-deftest xiiif-review/every-verdict-records-under-its-own-name ()
  (dolist (verdict xiiif-review-verdicts)
    (ert-info ((symbol-name verdict))
      (let ((finding (xiiif-review-record "d-1" "rev-1" :verdict verdict
                                          :reviewer "human:x")))
        (should (equal (alist-get 'verdict finding) (symbol-name verdict)))))))

(ert-deftest xiiif-review/nothing-recorded-claims-a-validation ()
  "The document is exactly the seven fields the contract names.  An extra
one - a status, a score, an `accepted' flag - is how a viewer ends up
deciding something §20 says it does not decide."
  (dolist (verdict (cons nil xiiif-review-verdicts))
    (let* ((finding (xiiif-review-record "d-1" "rev-1" :verdict verdict
                                         :comment "quelque chose"
                                         :evidence '("rev-2")
                                         :reviewer "human:x"))
           (keys (mapcar #'car finding)))
      (ert-info ((format "verdict %s" verdict))
        (should (cl-subsetp keys '(dossier_id target reviewer verdict comment
                                              evidence recorded_at)))
        (should-not (cl-intersection
                     keys '(status validated accepted supports score)))))))


;;; ---------- what §20 refuses ----------

(ert-deftest xiiif-review/a-review-that-says-nothing-is-refused ()
  (let ((reason (condition-case err
                    (progn (xiiif-review-record "d-1" "rev-1" :reviewer "human:x")
                           nil)
                  (xiiif-locus-invalid (nth 1 err)))))
    (should (eq 'says-nothing reason)))
  ;; A blank comment says nothing either: accepting whitespace would turn
  ;; the guard into a field-presence check, which is not what it is for.
  (let ((reason (condition-case err
                    (progn (xiiif-review-record "d-1" "rev-1" :comment "   "
                                                :reviewer "human:x")
                           nil)
                  (xiiif-locus-invalid (nth 1 err)))))
    (should (eq 'says-nothing reason))))

(ert-deftest xiiif-review/a-finding-without-dossier-target-or-reviewer-is-refused ()
  (dolist (case '((("" "rev-1" "human:x")) (("d-1" "  " "human:x"))))
    (let* ((args (car case))
           (reason (condition-case err
                       (progn (apply #'xiiif-review-record
                                     (list (nth 0 args) (nth 1 args)
                                           :verdict 'accept
                                           :reviewer (nth 2 args)))
                              nil)
                     (xiiif-locus-invalid (nth 1 err)))))
      (ert-info ((format "%S" args))
        (should (eq 'empty-field reason)))))
  ;; An anonymous verdict cannot be weighed, and §17.4 weighs reviewers.
  (let* ((xiiif-review-reviewer nil)
         (user-mail-address "")
         (reason (condition-case err
                     (progn (xiiif-review-record "d-1" "rev-1" :verdict 'accept)
                            nil)
                   (xiiif-locus-invalid (nth 1 err)))))
    (should (eq 'empty-field reason))))

(ert-deftest xiiif-review/a-free-comment-alone-is-a-review ()
  "§20 lists it fifth, next to the four verdicts."
  (let ((finding (xiiif-review-record "d-1" "rev-1" :comment "la marge coupe la réclame"
                                      :reviewer "human:x")))
    (should-not (alist-get 'verdict finding))
    (should (equal (alist-get 'comment finding) "la marge coupe la réclame"))))

(ert-deftest xiiif-review/a-comment-survives-a-favourable-verdict ()
  "Invariant 12: what was said does not disappear because the verdict is kind."
  (let ((finding (xiiif-review-record "d-1" "rev-1" :verdict 'accept
                                      :comment "lisible, contraste faible"
                                      :reviewer "human:x")))
    (should (equal (alist-get 'verdict finding) "accept"))
    (should (equal (alist-get 'comment finding) "lisible, contraste faible"))))

(ert-deftest xiiif-review/evidence-travels-as-a-json-array ()
  (let* ((finding (xiiif-review-record "d-1" "rev-1" :verdict 'wrong-target
                                       :evidence '("rev-2" "rev-3")
                                       :reviewer "human:x"))
         (json (xiiif-review-to-json finding)))
    (should (string-match-p "\"evidence\":\\[\"rev-2\",\"rev-3\"\\]" json))))


;;; ---------- §20 on screen ----------

(ert-deftest xiiif-review/the-report-is-opened-never-injected ()
  "The rule of §20 that an implementation gets wrong by being helpful: the
agent's reading appended to the source buffer, after which nobody can tell
the document from the commentary on it."
  (xiiif-review-test--with-review
    (xiiif-review-show-report)
    (let ((source (xiiif-review-test--text xiiif-review-source-buffer))
          (report (xiiif-review-test--text xiiif-review-report-buffer)))
      (should (string-match-p (regexp-quote xiiif-review-test--report) report))
      (should-not (string-match-p (regexp-quote xiiif-review-test--report) source))
      ;; And the other way: the report buffer is not a copy of the source
      ;; with a paragraph added.
      (should-not (string-match-p (regexp-quote xiiif-review-test--source)
                                  report)))))

(ert-deftest xiiif-review/the-source-and-the-panel-are-two-buffers ()
  "§20 asks that the original and the production be juxtaposed. Two
buffers, both live, neither carrying the other's text."
  (xiiif-review-test--with-review
    (should (buffer-live-p (get-buffer xiiif-review-source-buffer)))
    (should (buffer-live-p (get-buffer xiiif-review-buffer)))
    (should-not (eq (get-buffer xiiif-review-source-buffer)
                    (get-buffer xiiif-review-buffer)))
    (should (string-match-p "Original"
                            (xiiif-review-test--text xiiif-review-source-buffer)))
    (should-not (string-match-p "Original"
                                (xiiif-review-test--text xiiif-review-buffer)))))

(ert-deftest xiiif-review/the-claimed-region-is-reachable-without-an-image ()
  "§23: a rendered image must never be the only way to reach a region.
Off a graphic display it would otherwise be unreachable - and that is
where review happens often enough for it to matter."
  (xiiif-review-test--with-review
    (let ((text (xiiif-review-test--text xiiif-review-source-buffer)))
      ;; Two lines, and both are owed. The bare coordinates are what gets
      ;; pasted into `xiiif-select-region'; the URI is what gets cited. A
      ;; test that only looked for the digits would pass while the line a
      ;; reader actually copies had quietly gone.
      (should (string-match-p "^Region: *10,20,30,40$" text))
      (should (string-match-p
               (concat "^Region URI: *"
                       (regexp-quote
                        (concat xiiif-review-test--source "#xywh=10,20,30,40"))
                       "$")
               text)))))

(ert-deftest xiiif-review/a-review-without-a-report-says-so ()
  "Rather than opening an empty buffer that reads like a report nobody wrote."
  (unwind-protect
      (save-window-excursion
        (xiiif-review-open "dossier-0007" "rev-1" :source xiiif-review-test--source)
        (should-error (xiiif-review-show-report) :type 'user-error)
        (should-not (get-buffer xiiif-review-report-buffer)))
    (xiiif-review-test--kill-buffers)))

(ert-deftest xiiif-review/the-panel-says-what-it-does-not-decide ()
  "The sentence is on screen because the reviewer is the one who needs it:
pressing `a' feels like approving something."
  (xiiif-review-test--with-review
    (let ((text (xiiif-review-test--text xiiif-review-buffer)))
      (should (string-match-p "[Nn]ot a validation" text)))))


;;; ---------- the port ----------

(ert-deftest xiiif-review/without-a-locus-client-the-finding-is-copied ()
  "xiiif still works with nothing connected: the finding lands on the kill
ring as JSON, and the message says so rather than implying it was filed."
  (cl-letf (((symbol-function 'locus-review-submit) nil))
    (fmakunbound 'locus-review-submit)
    (let* ((kill-ring nil)
           (finding (xiiif-review-record "d-1" "rev-1" :verdict 'accept
                                         :reviewer "human:x"))
           (outcome (xiiif-review-submit-default finding)))
      (should (eq outcome 'copied))
      (should (string-match-p "\"verdict\":\"accept\"" (car kill-ring))))))

(ert-deftest xiiif-review/a-loaded-locus-client-takes-the-finding ()
  (let (received)
    (cl-letf (((symbol-function 'locus-review-submit)
               (lambda (finding) (setq received finding))))
      (let* ((finding (xiiif-review-record "d-1" "rev-1" :verdict 'source-changed
                                           :reviewer "human:x"))
             (outcome (xiiif-review-submit-default finding)))
        (should (eq outcome 'sent))
        (should (equal (alist-get 'verdict received) "source-changed"))))))

(ert-deftest xiiif-review/recording-goes-through-the-port-and-nowhere-else ()
  "Poisoned rather than stubbed: a command that reached the network itself
would fail here instead of quietly working on the author's machine."
  (let (sent)
    (xiiif-review-test--with-review
      (cl-letf (((symbol-function 'url-retrieve)
                 (lambda (&rest _) (error "xiiif must not dial anything")))
                ((symbol-function 'open-network-stream)
                 (lambda (&rest _) (error "xiiif must not dial anything")))
                (xiiif-review-submit-function (lambda (finding)
                                                (setq sent finding)
                                                'sent)))
        (with-current-buffer xiiif-review-buffer
          (xiiif-review-accept))))
    (should (equal (alist-get 'verdict sent) "accept"))
    (should (equal (alist-get 'dossier_id sent) "dossier-0007"))
    (should (equal (alist-get 'target sent) "01HQ8Z3M4N5P6Q7R8S9T0V1W2X"))))

(ert-deftest xiiif-review/a-verdict-can-be-recorded-from-the-source-buffer ()
  "The reviewer is looking at the original when they decide; making them
switch windows first is how a verdict ends up attached to whatever buffer
happened to be current."
  (let (sent)
    (xiiif-review-test--with-review
      (cl-letf ((xiiif-review-submit-function (lambda (finding)
                                                (setq sent finding) 'sent)))
        (with-current-buffer xiiif-review-source-buffer
          (xiiif-review-wrong-target))))
    (should (equal (alist-get 'verdict sent) "wrong-target"))
    (should (equal (alist-get 'dossier_id sent) "dossier-0007"))))

(provide 'xiiif-review-test)
;;; xiiif-review-test.el ends here
