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

(provide 'xiiif-image-test)
;;; xiiif-image-test.el ends here
