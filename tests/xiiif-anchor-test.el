;;; xiiif-anchor-test.el --- Tests for anchors and Content State -*- lexical-binding: t; -*-

;;; Commentary:

;; Anchor construction/accessors, Content State export/import
;; round-trips, base64url handling, and the v2/v3 target shapes a
;; pasted Content State can carry.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'xiiif-region)
(require 'xiiif-anchor)

;;; ---- construction and accessors ----

(ert-deftest xiiif-anchor/create-full ()
  (let ((a (xiiif-anchor-create
            :manifest "https://x/manifest"
            :canvas "https://x/canvas/1"
            :region (make-xiiif-region :x 10 :y 20 :w 30 :h 40)
            :label "Folio 1")))
    (should (xiiif-anchor-p a))
    (should (equal "https://x/manifest" (xiiif-anchor-manifest a)))
    (should (equal "https://x/canvas/1" (xiiif-anchor-canvas a)))
    (should (equal "Folio 1" (xiiif-anchor-label a)))
    (let ((r (xiiif-anchor-region a)))
      (should (= 10 (xiiif-region-x r)))
      (should (= 40 (xiiif-region-h r)))
      (should (eq 'pixel (xiiif-region-unit r))))))

(ert-deftest xiiif-anchor/create-from-region-list ()
  (let ((a (xiiif-anchor-create :manifest "m" :canvas "c"
                                :region '(1 2 3 4))))
    (let ((r (xiiif-anchor-region a)))
      (should (= 1 (xiiif-region-x r)))
      (should (= 4 (xiiif-region-h r))))))

(ert-deftest xiiif-anchor/create-percent-region ()
  (let ((a (xiiif-anchor-create
            :manifest "m" :canvas "c"
            :region (make-xiiif-region :x 1 :y 2 :w 3 :h 4
                                       :unit 'percent))))
    (should (eq 'percent (xiiif-region-unit (xiiif-anchor-region a))))))

(ert-deftest xiiif-anchor/create-minimal ()
  (let ((a (xiiif-anchor-create :manifest "https://x/manifest")))
    (should (equal "https://x/manifest" (xiiif-anchor-manifest a)))
    (should-not (xiiif-anchor-canvas a))
    (should-not (xiiif-anchor-region a))
    (should-not (xiiif-anchor-label a))))

(ert-deftest xiiif-anchor/is-versioned ()
  (should (plist-get (xiiif-anchor-create :manifest "m")
                     :xiiif-anchor-version)))

(ert-deftest xiiif-anchor/serialisable-round-trip ()
  "An anchor survives prin1/read as plain data."
  (let* ((a (xiiif-anchor-create
             :manifest "m" :canvas "c" :region '(1 2 3 4) :label "L"))
         (b (read (prin1-to-string a))))
    (should (equal a b))))


;;; ---- base64url ----

(ert-deftest xiiif-anchor/base64url-round-trip ()
  (dolist (s '("" "hello" "{\"a\":1}" "accentué—dash"
               "https://x/c?a=b&c=d"))
    (should (equal s (xiiif-anchor--base64url-decode
                      (xiiif-anchor--base64url-encode s))))))

(ert-deftest xiiif-anchor/base64url-has-no-padding ()
  (should-not (string-match-p "=" (xiiif-anchor--base64url-encode "abcde"))))

(ert-deftest xiiif-anchor/base64url-url-safe-alphabet ()
  ;; A payload that base64 would render with + and /.
  (let ((enc (xiiif-anchor--base64url-encode
              (string 251 255 254 253 252))))
    (should-not (string-match-p "[+/=]" enc))))


;;; ---- Content State export ----

(ert-deftest xiiif-anchor/content-state-json-canvas-region ()
  (let* ((a (xiiif-anchor-create
             :manifest "https://x/manifest"
             :canvas "https://x/canvas/1"
             :region '(100 150 400 300)))
         (json (let ((json-object-type 'alist)
                     (json-array-type 'vector)
                     (json-key-type 'symbol))
                 (json-read-from-string (xiiif-content-state-json a)))))
    (should (equal "Annotation" (alist-get 'type json)))
    (should (equal ["contentState"] (alist-get 'motivation json)))
    (let ((target (alist-get 'target json)))
      (should (equal "https://x/canvas/1#xywh=100,150,400,300"
                     (alist-get 'id target)))
      (should (equal "Canvas" (alist-get 'type target)))
      (should (equal "https://x/manifest"
                     (alist-get 'id (aref (alist-get 'partOf target) 0)))))))

(ert-deftest xiiif-anchor/content-state-json-manifest-only ()
  (let* ((a (xiiif-anchor-create :manifest "https://x/manifest"))
         (json (let ((json-object-type 'alist)
                     (json-array-type 'vector)
                     (json-key-type 'symbol))
                 (json-read-from-string (xiiif-content-state-json a))))
         (target (alist-get 'target json)))
    (should (equal "https://x/manifest" (alist-get 'id target)))
    (should (equal "Manifest" (alist-get 'type target)))))

(ert-deftest xiiif-anchor/content-state-url ()
  (let* ((a (xiiif-anchor-create :manifest "m" :canvas "c"
                                 :region '(1 2 3 4)))
         (url (xiiif-content-state-url a "https://viewer.example/embed/")))
    (should (string-prefix-p "https://viewer.example/embed/?iiif-content="
                             url))))

(ert-deftest xiiif-anchor/content-state-url-preserves-query ()
  (let* ((a (xiiif-anchor-create :manifest "m"))
         (url (xiiif-content-state-url a "https://v.example/?theme=dark")))
    (should (string-match-p "\\?theme=dark&iiif-content=" url))))


;;; ---- Content State import + round-trip ----

(ert-deftest xiiif-anchor/round-trip-canvas-region ()
  (let* ((a (xiiif-anchor-create
             :manifest "https://x/manifest"
             :canvas "https://x/canvas/1"
             :region '(100 150 400 300)))
         (b (xiiif-content-state-parse (xiiif-content-state-encode a))))
    (should (equal "https://x/manifest" (xiiif-anchor-manifest b)))
    (should (equal "https://x/canvas/1" (xiiif-anchor-canvas b)))
    (let ((r (xiiif-anchor-region b)))
      (should (= 100 (xiiif-region-x r)))
      (should (= 300 (xiiif-region-h r))))))

(ert-deftest xiiif-anchor/round-trip-percent-region ()
  (let* ((a (xiiif-anchor-create
             :manifest "m" :canvas "c"
             :region (make-xiiif-region :x 5 :y 6 :w 7 :h 8
                                        :unit 'percent)))
         (b (xiiif-content-state-parse (xiiif-content-state-encode a))))
    (should (eq 'percent (xiiif-region-unit (xiiif-anchor-region b))))
    (should (= 5 (xiiif-region-x (xiiif-anchor-region b))))))

(ert-deftest xiiif-anchor/round-trip-manifest-only ()
  (let* ((a (xiiif-anchor-create :manifest "https://x/manifest"))
         (b (xiiif-content-state-parse (xiiif-content-state-encode a))))
    (should (equal "https://x/manifest" (xiiif-anchor-manifest b)))
    (should-not (xiiif-anchor-canvas b))
    (should-not (xiiif-anchor-region b))))

(ert-deftest xiiif-anchor/parse-from-full-url ()
  (let* ((a (xiiif-anchor-create :manifest "m" :canvas "c"
                                 :region '(1 2 3 4)))
         (url (xiiif-content-state-url a "https://viewer/embed/"))
         (b (xiiif-content-state-parse url)))
    (should (equal "c" (xiiif-anchor-canvas b)))
    (should (= 1 (xiiif-region-x (xiiif-anchor-region b))))))

(ert-deftest xiiif-anchor/parse-raw-json ()
  "A raw Content State JSON string parses directly."
  (let* ((json (concat
                "{\"@context\":\"http://iiif.io/api/presentation/3/context.json\","
                "\"type\":\"Annotation\",\"motivation\":[\"contentState\"],"
                "\"target\":{\"id\":\"https://x/canvas/1#xywh=1,2,3,4\","
                "\"type\":\"Canvas\","
                "\"partOf\":[{\"id\":\"https://x/manifest\",\"type\":\"Manifest\"}]}}"))
         (a (xiiif-content-state-parse json)))
    (should (equal "https://x/manifest" (xiiif-anchor-manifest a)))
    (should (equal "https://x/canvas/1" (xiiif-anchor-canvas a)))
    (should (= 3 (xiiif-region-w (xiiif-anchor-region a))))))

(ert-deftest xiiif-anchor/parse-string-target ()
  "A Content State whose target is a bare canvas string."
  (let* ((json (concat
                "{\"type\":\"Annotation\",\"motivation\":[\"contentState\"],"
                "\"target\":\"https://x/canvas/9#xywh=5,5,5,5\"}"))
         (a (xiiif-content-state-parse json)))
    (should (equal "https://x/canvas/9" (xiiif-anchor-canvas a)))
    (should (= 5 (xiiif-region-x (xiiif-anchor-region a))))))

(ert-deftest xiiif-anchor/parse-invalid-signals ()
  (should-error (xiiif-content-state-parse "!!!not base64 %%%")
                :type 'xiiif-parse-error)
  (should-error (xiiif-content-state-parse
                 (xiiif-anchor--base64url-encode "not json"))
                :type 'xiiif-parse-error))

(provide 'xiiif-anchor-test)
;;; xiiif-anchor-test.el ends here
