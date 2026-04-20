;;; xiiif-upgrade-test.el --- Tests for v2->v3 normalization -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'xiiif-core)
(require 'xiiif-upgrade)


;;; ---- labels ----

(ert-deftest xiiif-upgrade--label->map/string ()
  (should (equal '((none . ["Hi"]))
                 (xiiif-upgrade--label->map "Hi"))))

(ert-deftest xiiif-upgrade--label->map/already-map ()
  (let ((m (xiiif-upgrade--label->map '((en . ["A"]) (fr . ["B"])))))
    (should (equal ["A"] (alist-get 'en m)))
    (should (equal ["B"] (alist-get 'fr m)))))

(ert-deftest xiiif-upgrade--label->map/vector-of-strings ()
  (should (equal '((none . ["one" "two"]))
                 (xiiif-upgrade--label->map ["one" "two"]))))


;;; ---- manifest upgrade ----

(defconst xiiif-upgrade-test--v2-manifest
  '((@id . "http://x/m")
    (@type . "sc:Manifest")
    (label . "Old Book")
    (metadata . [((label . "Author") (value . "Jane Doe"))])
    (sequences . [((@id . "http://x/m/seq")
                   (@type . "sc:Sequence")
                   (canvases . [((@id . "http://x/m/c1")
                                 (@type . "sc:Canvas")
                                 (label . "p1")
                                 (width . 100)
                                 (height . 200)
                                 (images . [((@id . "http://x/a1")
                                             (@type . "oa:Annotation")
                                             (motivation . "sc:painting")
                                             (resource . ((@id . "http://img/1")
                                                          (@type . "dctypes:Image")
                                                          (format . "image/jpeg")
                                                          (width . 100)
                                                          (height . 200)
                                                          (service . ((@id . "http://img")
                                                                      (@type . "ImageService2")
                                                                      (profile . "level1"))))))]))])))]))

(ert-deftest xiiif-upgrade-manifest/normalises-v2 ()
  (let ((v3 (xiiif-upgrade-manifest xiiif-upgrade-test--v2-manifest)))
    (should (equal "http://x/m" (alist-get 'id v3)))
    (should (equal "Manifest" (alist-get 'type v3)))
    (should (equal '((none . ["Old Book"]))
                   (alist-get 'label v3)))
    (let ((items (alist-get 'items v3)))
      (should (vectorp items))
      (should (= 1 (length items)))
      (let ((canvas (aref items 0)))
        (should (equal "http://x/m/c1" (alist-get 'id canvas)))
        (should (equal "Canvas" (alist-get 'type canvas)))
        (should (equal 100 (alist-get 'width canvas)))
        (let* ((ann-pages (alist-get 'items canvas))
               (page (aref ann-pages 0))
               (anno (aref (alist-get 'items page) 0))
               (body (alist-get 'body anno)))
          (should (equal "AnnotationPage" (alist-get 'type page)))
          (should (equal "painting" (alist-get 'motivation anno)))
          (should (equal "http://img/1" (alist-get 'id body)))
          (let ((svc (aref (alist-get 'service body) 0)))
            (should (equal "http://img" (alist-get 'id svc)))
            (should (equal "ImageService2"
                           (alist-get 'type svc)))))))))

(ert-deftest xiiif-upgrade-manifest/passthrough-v3 ()
  "A v3 manifest should round-trip with @context added / type normalised."
  (let* ((raw '((id . "http://x/m3")
                (type . "Manifest")
                (label . ((en . ["hi"])))
                (items . [((id . "http://x/m3/c1")
                           (type . "Canvas")
                           (label . ((en . ["p1"])))
                           (width . 10) (height . 20))])))
         (v3 (xiiif-upgrade-manifest raw)))
    (should (equal "http://iiif.io/api/presentation/3/context.json"
                   (alist-get '@context v3)))
    (should (equal "http://x/m3" (alist-get 'id v3)))
    (should (equal 1 (length (alist-get 'items v3))))))

(ert-deftest xiiif-upgrade-manifest/rejects-non-manifest ()
  (should-error (xiiif-upgrade-manifest '((foo . "bar")))
                :type 'xiiif-parse-error))


;;; ---- collection upgrade ----

(ert-deftest xiiif-upgrade-collection/merges-v2 ()
  (let ((v3 (xiiif-upgrade-collection
             '((@id . "http://x/c")
               (@type . "sc:Collection")
               (label . "My Coll")
               (collections . [((@id . "http://x/s1")
                                (@type . "sc:Collection")
                                (label . "Sub"))])
               (manifests   . [((@id . "http://x/m1")
                                (@type . "sc:Manifest")
                                (label . "M1"))
                               ((@id . "http://x/m2")
                                (@type . "sc:Manifest")
                                (label . "M2"))])))))
    (should (equal "Collection" (alist-get 'type v3)))
    (let ((items (alist-get 'items v3)))
      (should (= 3 (length items)))
      ;; Sub-collections come first.
      (should (equal "Collection" (alist-get 'type (aref items 0))))
      (should (equal "Manifest"  (alist-get 'type (aref items 1))))
      (should (equal "Manifest"  (alist-get 'type (aref items 2)))))))


(provide 'xiiif-upgrade-test)
;;; xiiif-upgrade-test.el ends here
