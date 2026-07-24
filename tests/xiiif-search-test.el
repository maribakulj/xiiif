;;; xiiif-search-test.el --- Tests for IIIF Search 1.0 client -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'xiiif-core)
(require 'xiiif-search)


;;; ---- discovery ----

(ert-deftest xiiif-manifest-search-service/detects-string-profile ()
  (let ((m (make-xiiif-manifest
            :url "http://x/m" :id "http://x/m" :type "Manifest"
            :raw '((id . "http://x/m") (type . "Manifest")
                   (service . [((id . "http://x/search")
                                (type . "SearchService1")
                                (profile . "http://iiif.io/api/search/1/search"))])))))
    (should (equal "http://x/search"
                   (xiiif-manifest-search-service m)))))

(ert-deftest xiiif-manifest-search-service/detects-vector-profile ()
  (let ((m (make-xiiif-manifest
            :url "http://x/m" :id "http://x/m" :type "Manifest"
            :raw '((id . "http://x/m") (type . "Manifest")
                   (service . [((id . "http://x/search")
                                (profile . ["something-else"
                                            "http://iiif.io/api/search/1/search"]))])))))
    (should (equal "http://x/search"
                   (xiiif-manifest-search-service m)))))

(ert-deftest xiiif-manifest-search-service/nil-when-absent ()
  (let ((m (make-xiiif-manifest
            :url "http://x/m" :id "http://x/m" :type "Manifest"
            :raw '((id . "http://x/m") (type . "Manifest")))))
    (should (null (xiiif-manifest-search-service m)))))


;;; ---- URL building ----

(ert-deftest xiiif-search--url/hexifies-query ()
  (should (equal "http://x/search?q=hello%20world"
                 (xiiif-search--url "http://x/search" "hello world")))
  (should (equal "http://x/search?q=foo%3Fbar"
                 (xiiif-search--url "http://x/search" "foo?bar"))))

(ert-deftest xiiif-search--url/strips-trailing-slash ()
  (should (equal "http://x/search?q=x"
                 (xiiif-search--url "http://x/search/" "x"))))


;;; ---- parsing ----

(defconst xiiif-search-test--response
  '((@context . "http://iiif.io/api/search/1/context.json")
    (@id . "http://x/search?q=foo")
    (type . "sc:AnnotationList")
    (resources . [((id . "http://x/anno/1")
                   (type . "oa:Annotation")
                   (motivation . "sc:painting")
                   (resource . ((type . "cnt:ContentAsText")
                                (chars . "foo")))
                   (on . "http://x/canvas/1#xywh=10,20,30,40"))
                  ((id . "http://x/anno/2")
                   (resource . "bare-string-hit")
                   (on . ((type . "SpecificResource")
                          (source . "http://x/canvas/2"))))])
    (hits . [((type . "search:Hit")
              (annotations . ["http://x/anno/1"])
              (before . "before ")
              (after . " after"))])))

(ert-deftest xiiif-search--parse/resolves-contexts ()
  (let ((hits (xiiif-search--parse xiiif-search-test--response)))
    (should (= 2 (length hits)))
    (let ((first (car hits)))
      (should (equal "http://x/canvas/1"
                     (xiiif-search-hit-canvas-id first)))
      (should (equal "foo" (xiiif-search-hit-chars first)))
      (should (equal "before " (xiiif-search-hit-before first)))
      (should (equal " after"  (xiiif-search-hit-after first))))
    (let ((second (cadr hits)))
      (should (equal "http://x/canvas/2"
                     (xiiif-search-hit-canvas-id second)))
      (should (equal "bare-string-hit"
                     (xiiif-search-hit-chars second))))))

(ert-deftest xiiif-search--parse/carries-region-from-string-on ()
  (let* ((hits (xiiif-search--parse xiiif-search-test--response))
         (region (xiiif-search-hit-region (car hits))))
    (should (xiiif-region-p region))
    (should (= 10 (xiiif-region-x region)))
    (should (= 40 (xiiif-region-h region)))
    ;; The regionless second hit has none.
    (should-not (xiiif-search-hit-region (cadr hits)))))


;;; ---- v2 fixture with structured selectors ----

(defconst xiiif-search-test--v2-fixture
  (expand-file-name
   "../examples/sample-search-v2.json"
   (file-name-directory (or load-file-name buffer-file-name))))

(defun xiiif-search-test--read-json (path)
  (let ((json-object-type 'alist)
        (json-array-type  'vector)
        (json-key-type    'symbol)
        (json-false       :json-false)
        (json-null        nil))
    (require 'json)
    (json-read-file path)))

(ert-deftest xiiif-search--parse/v2-fixture-regions ()
  "The v2 Search fixture yields regions from a string `on' and from
a structured `on'/`full' + `selector'."
  (let ((hits (xiiif-search--parse
               (xiiif-search-test--read-json
                xiiif-search-test--v2-fixture))))
    (should (= 2 (length hits)))
    (let ((h1 (car hits)))
      (should (equal "https://example.org/iiif/book1/canvas/1"
                     (xiiif-search-hit-canvas-id h1)))
      (should (equal "lettrine" (xiiif-search-hit-chars h1)))
      (let ((r (xiiif-search-hit-region h1)))
        (should (= 200 (xiiif-region-x r)))
        (should (= 90 (xiiif-region-h r)))))
    (let ((h2 (cadr hits)))
      (should (equal "https://example.org/iiif/book1/canvas/2"
                     (xiiif-search-hit-canvas-id h2)))
      (let ((r (xiiif-search-hit-region h2)))
        (should (= 50 (xiiif-region-x r)))
        (should (= 80 (xiiif-region-h r)))))))


;;; ---- pagination ----

(ert-deftest xiiif-search--next-url/shapes ()
  (should (equal "http://x/p2"
                 (xiiif-search--next-url '((next . "http://x/p2")))))
  (should (equal "http://x/p2"
                 (xiiif-search--next-url '((next . ((id . "http://x/p2")))))))
  (should-not (xiiif-search--next-url '((resources . [])))))

(defvar xiiif-search-test--pages nil
  "Alist of URL -> response JSON string for the paging stub.")

(defmacro xiiif-search-test--with-pages (pages &rest body)
  "Bind PAGES and stub `xiiif-fetch-json' to serve them synchronously."
  (declare (indent 1) (debug (form body)))
  `(let ((xiiif-search-test--pages ,pages))
     (cl-letf (((symbol-function 'xiiif-fetch-json)
                (lambda (url callback &rest _)
                  (let ((json (cdr (assoc url xiiif-search-test--pages))))
                    (funcall callback
                             (let ((json-object-type 'alist)
                                   (json-array-type 'vector)
                                   (json-key-type 'symbol)
                                   (json-false :json-false)
                                   (json-null nil))
                               (json-read-from-string json)))))))
       ,@body)))

(ert-deftest xiiif-search-async/follows-next-and-accumulates ()
  (require 'json)
  (let ((hits nil))
    (xiiif-search-test--with-pages
        '(("http://x/search?q=foo"
           . "{\"resources\":[{\"@id\":\"http://x/a1\",\"resource\":{\"chars\":\"one\"},\"on\":\"http://x/c1\"}],\"next\":\"http://x/search?q=foo&page=2\"}")
          ("http://x/search?q=foo&page=2"
           . "{\"resources\":[{\"@id\":\"http://x/a2\",\"resource\":{\"chars\":\"two\"},\"on\":\"http://x/c2\"}]}"))
      (cl-letf (((symbol-function 'xiiif-search--url)
                 (lambda (&rest _) "http://x/search?q=foo")))
        (xiiif-search-async "http://x/search" "foo"
                            (lambda (hs) (setq hits hs)))))
    (should (= 2 (length hits)))
    (should (equal '("one" "two")
                   (mapcar #'xiiif-search-hit-chars hits)))))

(ert-deftest xiiif-search-async/honours-max-pages ()
  (require 'json)
  (let ((hits nil)
        (xiiif-search-max-pages 1))
    (xiiif-search-test--with-pages
        '(("http://x/search?q=foo"
           . "{\"resources\":[{\"@id\":\"http://x/a1\",\"resource\":{\"chars\":\"one\"},\"on\":\"http://x/c1\"}],\"next\":\"http://x/search?q=foo&page=2\"}")
          ("http://x/search?q=foo&page=2"
           . "{\"resources\":[{\"@id\":\"http://x/a2\",\"resource\":{\"chars\":\"two\"},\"on\":\"http://x/c2\"}]}"))
      (cl-letf (((symbol-function 'xiiif-search--url)
                 (lambda (&rest _) "http://x/search?q=foo")))
        (xiiif-search-async "http://x/search" "foo"
                            (lambda (hs) (setq hits hs)))))
    ;; Stopped after the first page.
    (should (= 1 (length hits)))
    (should (equal '("one") (mapcar #'xiiif-search-hit-chars hits)))))

(ert-deftest xiiif-search-async/single-page-no-next ()
  (require 'json)
  (let ((hits :unset))
    (xiiif-search-test--with-pages
        '(("http://x/search?q=foo"
           . "{\"resources\":[{\"@id\":\"http://x/a1\",\"resource\":{\"chars\":\"one\"},\"on\":\"http://x/c1\"}]}"))
      (cl-letf (((symbol-function 'xiiif-search--url)
                 (lambda (&rest _) "http://x/search?q=foo")))
        (xiiif-search-async "http://x/search" "foo"
                            (lambda (hs) (setq hits hs)))))
    (should (= 1 (length hits)))))


(provide 'xiiif-search-test)
;;; xiiif-search-test.el ends here
