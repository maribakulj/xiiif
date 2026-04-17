;;; xiiif-image-test.el --- Tests for xiiif-image -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the IIIF Image API URL builder.

;;; Code:

(require 'ert)
(require 'xiiif-core)
(require 'xiiif-image)

(defun xiiif-image-test--service (&optional id)
  (make-xiiif-image-service
   :id (or id "https://example.org/iiif/image/book1-p1")
   :type "ImageService3"
   :profile "level1"))

(ert-deftest xiiif-image-url/defaults ()
  (should (equal
           "https://example.org/iiif/image/book1-p1/full/max/0/default.jpg"
           (xiiif-image-url (xiiif-image-test--service)))))

(ert-deftest xiiif-image-url/overrides ()
  (should (equal
           "https://example.org/iiif/image/book1-p1/0,0,100,100/!256,256/90/gray.png"
           (xiiif-image-url (xiiif-image-test--service)
                            :region "0,0,100,100"
                            :size "!256,256"
                            :rotation "90"
                            :quality "gray"
                            :format "png"))))

(ert-deftest xiiif-image-url/trailing-slash ()
  (should (equal
           "https://example.org/iiif/image/x/full/max/0/default.jpg"
           (xiiif-image-url "https://example.org/iiif/image/x/"))))

(ert-deftest xiiif-image-url/nil-service ()
  (should (null (xiiif-image-url nil))))

(ert-deftest xiiif-image-url/from-canvas ()
  (let ((canvas (make-xiiif-canvas
                 :id "http://x/c1"
                 :image-service (xiiif-image-test--service "http://x/i"))))
    (should (equal "http://x/i/full/max/0/default.jpg"
                   (xiiif-image-url canvas)))))

(ert-deftest xiiif-image-info-url/appends-info-json ()
  (should (equal "https://example.org/iiif/image/book1-p1/info.json"
                 (xiiif-image-info-url (xiiif-image-test--service)))))

(ert-deftest xiiif-image-suggested-filename/uses-slug ()
  (should (equal "book1-p1.jpg"
                 (xiiif-image-suggested-filename
                  (xiiif-image-test--service)))))

(ert-deftest xiiif-image-suggested-filename/custom-format ()
  (should (equal "book1-p1.png"
                 (xiiif-image-suggested-filename
                  (xiiif-image-test--service) "png"))))



;;; ---- info.json ----

(defconst xiiif-image-test--info-fixture
  (expand-file-name
   "../examples/sample-info.json"
   (file-name-directory (or load-file-name buffer-file-name))))

(defun xiiif-image-test--load-info ()
  "Return the sample info.json parsed into an alist."
  (let ((json-object-type 'alist)
        (json-array-type  'vector)
        (json-key-type    'symbol)
        (json-null        nil))
    (json-read-file xiiif-image-test--info-fixture)))

(ert-deftest xiiif-image-parse-info/basic-fields ()
  (let ((info (xiiif-image-parse-info (xiiif-image-test--load-info)
                                      "https://example.org/iiif/image/book1-p1")))
    (should (xiiif-image-info-p info))
    (should (equal "https://example.org/iiif/image/book1-p1"
                   (xiiif-image-info-id info)))
    (should (equal "ImageService3" (xiiif-image-info-type info)))
    (should (equal 6000 (xiiif-image-info-width info)))
    (should (equal 4000 (xiiif-image-info-height info)))))

(ert-deftest xiiif-image-info-compliance-level/v3-bare ()
  (let ((info (xiiif-image-parse-info (xiiif-image-test--load-info))))
    (should (equal "level1" (xiiif-image-info-compliance-level info)))))

(ert-deftest xiiif-image-info-compliance-level/v2-uri ()
  (let ((info (xiiif-image-parse-info
               '((profile . "http://iiif.io/api/image/2/level2.json")))))
    (should (equal "level2" (xiiif-image-info-compliance-level info)))))

(ert-deftest xiiif-image-info-compliance-level/v2-mixed-array ()
  (let ((info (xiiif-image-parse-info
               '((profile . ["http://iiif.io/api/image/2/level1.json"
                             ((formats . ["jpg" "png"]))])))))
    (should (equal "level1" (xiiif-image-info-compliance-level info)))))

(ert-deftest xiiif-image-info-size-strings ()
  (let ((info (xiiif-image-parse-info (xiiif-image-test--load-info))))
    (should (equal '("150x100" "600x400" "1500x1000" "3000x2000")
                   (xiiif-image-info-size-strings info)))))

(ert-deftest xiiif-image-info-tile-strings ()
  (let ((info (xiiif-image-parse-info (xiiif-image-test--load-info))))
    (should (= 1 (length (xiiif-image-info-tile-strings info))))
    (should (string-match "512x512" (car (xiiif-image-info-tile-strings info))))
    (should (string-match "scaleFactors=1,2,4,8,16"
                          (car (xiiif-image-info-tile-strings info))))))

(ert-deftest xiiif-image-parse-info/rejects-non-object ()
  (should-error (xiiif-image-parse-info "nope")
                :type 'xiiif-parse-error))

(ert-deftest xiiif-image-parse-info/derives-id-from-url ()
  "When the document omits id, the fetch URL (minus /info.json) is used."
  (let ((info (xiiif-image-parse-info
               '((protocol . "http://iiif.io/api/image")
                 (profile . "level1"))
               "https://example.org/iiif/image/svc/info.json")))
    (should (equal "https://example.org/iiif/image/svc"
                   (xiiif-image-info-id info)))))

(provide 'xiiif-image-test)
;;; xiiif-image-test.el ends here
