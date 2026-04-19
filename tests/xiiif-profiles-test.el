;;; xiiif-profiles-test.el --- Tests for per-server profiles -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests that profile matching, header injection and image
;; overrides work without touching the network.

;;; Code:

(require 'ert)
(require 'xiiif-core)
(require 'xiiif-profiles)
(require 'xiiif-api)
(require 'xiiif-image)


;;; ---- regex matching ----

(ert-deftest xiiif-profile-for-url/matches-first ()
  (let ((xiiif-server-profiles
         '(("\\`https://a\\." :label "A" :headers (("X-A" . "1")))
           ("\\`https://b\\." :label "B" :headers (("X-B" . "2"))))))
    (should (equal "A"
                   (plist-get (xiiif-profile-for-url "https://a.example/foo")
                              :label)))
    (should (equal "B"
                   (plist-get (xiiif-profile-for-url "https://b.example/foo")
                              :label)))
    (should (null (xiiif-profile-for-url "https://c.example/foo")))))

(ert-deftest xiiif-profile-for-url/nil-on-non-string ()
  (should (null (xiiif-profile-for-url nil)))
  (should (null (xiiif-profile-for-url 42))))


;;; ---- header injection ----

(ert-deftest xiiif-api--request-headers/adds-profile-headers ()
  (let ((xiiif-server-profiles
         '(("\\`https://auth\\.example"
            :headers (("Authorization" . "Bearer abc"))))))
    (let ((hs (xiiif-api--request-headers "https://auth.example/m")))
      (should (equal "Bearer abc" (cdr (assoc "Authorization" hs))))
      (should (assoc "Accept" hs)))))

(ert-deftest xiiif-api--request-headers/no-match-is-clean ()
  (let ((xiiif-server-profiles
         '(("\\`https://auth\\.example"
            :headers (("Authorization" . "Bearer abc"))))))
    (let ((hs (xiiif-api--request-headers "https://other.example/m")))
      (should-not (assoc "Authorization" hs))
      (should (assoc "Accept" hs)))))


;;; ---- image defaults override ----

(ert-deftest xiiif-image-url/profile-overrides-globals ()
  (let* ((service (make-xiiif-image-service
                   :id "https://high-res.example/iiif/1"))
         (xiiif-server-profiles
          '(("\\`https://high-res\\.example"
             :image (:size "!1024,1024" :format "png")))))
    (should (equal "https://high-res.example/iiif/1/full/!1024,1024/0/default.png"
                   (xiiif-image-url service)))))

(ert-deftest xiiif-image-url/explicit-wins-over-profile ()
  (let* ((service (make-xiiif-image-service
                   :id "https://high-res.example/iiif/1"))
         (xiiif-server-profiles
          '(("\\`https://high-res\\.example"
             :image (:size "!1024,1024" :format "png")))))
    (should (equal "https://high-res.example/iiif/1/full/!256,256/0/default.jpg"
                   (xiiif-image-url service :size "!256,256" :format "jpg")))))

(ert-deftest xiiif-image-url/no-profile-keeps-globals ()
  (let* ((service (make-xiiif-image-service
                   :id "https://plain.example/iiif/1"))
         (xiiif-server-profiles nil))
    (should (equal "https://plain.example/iiif/1/full/max/0/default.jpg"
                   (xiiif-image-url service)))))

(provide 'xiiif-profiles-test)
;;; xiiif-profiles-test.el ends here
