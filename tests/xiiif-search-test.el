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


(provide 'xiiif-search-test)
;;; xiiif-search-test.el ends here
