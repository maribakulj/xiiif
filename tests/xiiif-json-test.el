;;; xiiif-json-test.el --- Tests for bounded JSON decoding -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The depth guard has to hold two ends at once.  It must refuse a
;; document that would blow the recursive walkers downstream, and it
;; must let every real IIIF document through - a limit that rejects
;; ordinary manifests gets set to nil by the first person it annoys,
;; which is worse than no limit at all.  Both ends are tested here,
;; the second against the repository's own example fixtures.
;;
;; The load-bearing test is `check-does-not-recurse': a recursive
;; depth check on hostile input would exhaust the very stack it is
;; meant to protect, so the check would become the vulnerability.

;;; Code:

(require 'ert)
(require 'json)
(require 'xiiif-json)
(require 'xiiif-api)
(require 'xiiif-anchor)

(defconst xiiif-json-test--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defun xiiif-json-test--nest (depth)
  "Return an alist nested DEPTH containers deep, built iteratively."
  (let ((value 1))
    (dotimes (_ depth) (setq value (list (cons 'a value))))
    value))

(defun xiiif-json-test--nest-text (depth)
  "Return JSON text nesting DEPTH objects."
  (concat (mapconcat (lambda (_) "{\"a\":")
                     (number-sequence 1 depth) "")
          "1"
          (mapconcat (lambda (_) "}") (number-sequence 1 depth) "")))

;;; ---------- what depth means ----------

(ert-deftest xiiif-json/depth-counts-containers-not-values ()
  (should (xiiif-json-depth-ok-p 1 1))
  (should (xiiif-json-depth-ok-p "scalar" 1))
  (should (xiiif-json-depth-ok-p nil 1))
  ;; {"a": 1} is one container deep, and fits in a limit of one.
  (should (xiiif-json-depth-ok-p '((a . 1)) 1))
  (should (xiiif-json-depth-ok-p [1 2 3] 1))
  ;; {"a": {"b": 1}} is two.
  (should-not (xiiif-json-depth-ok-p '((a . ((b . 1)))) 1))
  (should (xiiif-json-depth-ok-p '((a . ((b . 1)))) 2)))

(ert-deftest xiiif-json/depth-sees-through-arrays-and-objects-alike ()
  (should-not (xiiif-json-depth-ok-p (vector (vector (vector 1))) 2))
  (should (xiiif-json-depth-ok-p (vector (vector (vector 1))) 3))
  ;; Mixed nesting counts every level, whichever kind it is.
  (should-not (xiiif-json-depth-ok-p `((a . ,(vector '((b . 1))))) 2)))

(ert-deftest xiiif-json/deepest-branch-decides ()
  ;; A shallow sibling must not mask a deep one.
  (let ((value `((shallow . 1) (deep . ,(xiiif-json-test--nest 20)))))
    (should-not (xiiif-json-depth-ok-p value 10))
    (should (xiiif-json-depth-ok-p value 30))))

(ert-deftest xiiif-json/a-nil-limit-is-no-limit ()
  (let* ((xiiif-json-max-depth nil)
         (ok (and (xiiif-json-depth-ok-p (xiiif-json-test--nest 3000)) t)))
    (should ok)))

;;; ---------- the check must not recurse ----------

(ert-deftest xiiif-json/check-does-not-recurse ()
  "Depth-checking 5000 levels neither overflows nor errors.
A recursive implementation would signal `excessive-lisp-nesting' (or
exhaust `max-lisp-eval-depth') long before reaching the answer - on
exactly the input the guard exists to handle."
  ;; The verdicts are computed first so a failure report prints two
  ;; booleans rather than five thousand nested conses.
  (let* ((deep (xiiif-json-test--nest 5000))
         (permitted (and (xiiif-json-depth-ok-p deep 10000) t))
         (refused (and (xiiif-json-depth-ok-p deep 100) t)))
    (should permitted)
    (should-not refused)))

;;; ---------- real documents pass ----------

(ert-deftest xiiif-json/the-example-fixtures-are-well-inside-the-default ()
  "Every shipped example decodes at the default limit, with room.
A limit that rejects ordinary IIIF gets disabled by the first user it
blocks, so the margin is part of the guard."
  (dolist (name '("sample-manifest.json" "sample-collection.json"
                  "sample-annotation-page.json" "sample-search-v2.json"
                  "sample-info.json" "sample-info-level0.json"))
    (let* ((file (expand-file-name (concat "../examples/" name)
                                   xiiif-json-test--dir))
           (text (with-temp-buffer
                   (insert-file-contents file)
                   (buffer-string)))
           (value (xiiif-json-parse text file)))
      (should value)
      ;; Room to spare: a quarter of the default still admits them.
      (should (xiiif-json-depth-ok-p value (/ xiiif-json-max-depth 4))))))

;;; ---------- the decoder enforces it ----------

(ert-deftest xiiif-json/parse-refuses-a-document-past-the-limit ()
  (let ((xiiif-json-max-depth 10))
    (should-error (xiiif-json-parse (xiiif-json-test--nest-text 50) "u")
                  :type 'xiiif-json-too-deep)
    (should (xiiif-json-parse (xiiif-json-test--nest-text 5) "u"))))

(ert-deftest xiiif-json/too-deep-is-a-parse-error ()
  "Existing handlers keep working: the new error inherits the old one."
  (let ((xiiif-json-max-depth 3)
        (caught nil))
    (condition-case err
        (xiiif-json-parse (xiiif-json-test--nest-text 20) "https://x/m")
      (xiiif-parse-error (setq caught err)))
    (should (eq 'xiiif-json-too-deep (car caught)))
    (should (equal "https://x/m" (nth 1 caught)))
    (should (equal 3 (nth 2 caught)))))

(ert-deftest xiiif-json/malformed-input-is-still-a-plain-parse-error ()
  (let ((err (should-error (xiiif-json-parse "{not json" "https://x/m")
                           :type 'xiiif-parse-error)))
    (should-not (eq 'xiiif-json-too-deep (car err)))))

(ert-deftest xiiif-json/parse-produces-the-documented-shapes ()
  (let ((parsed (xiiif-json-parse "{\"a\":[1,2],\"b\":null,\"c\":false}" "u")))
    (should (equal [1 2] (alist-get 'a parsed)))
    (should (eq nil (alist-get 'b parsed)))
    (should (eq :json-false (alist-get 'c parsed)))))

;;; ---------- both entry points are covered ----------

(ert-deftest xiiif-json/http-responses-are-bounded ()
  (let ((xiiif-json-max-depth 5))
    (should-error (xiiif-api--parse-json (xiiif-json-test--nest-text 40)
                                         "https://x/manifest")
                  :type 'xiiif-json-too-deep)))

(ert-deftest xiiif-json/pasted-content-state-is-bounded ()
  "A pasted token is as untrusted as a fetched manifest."
  (let ((xiiif-json-max-depth 5))
    (should-error (xiiif-content-state-parse (xiiif-json-test--nest-text 40))
                  :type 'xiiif-json-too-deep)))

(provide 'xiiif-json-test)
;;; xiiif-json-test.el ends here
