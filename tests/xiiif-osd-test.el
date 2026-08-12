;;; xiiif-osd-test.el --- Tests for the OpenSeadragon handoff -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This handoff writes a page rather than opening a URL, which puts an
;; HTML/JS boundary inside xiiif that no other module has.  The tests
;; that matter most are therefore the escaping ones: a IIIF service
;; whose URL contains `</script>' or a quote must not be able to write
;; markup into the page it is named in.
;;
;; The rest checks what §8 asks of the pair - OpenSeadragon for one
;; image, Mirador for a work - and that the choice between them is
;; made on capability rather than on hope.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'xiiif-osd)
(require 'xiiif)

;;; ---------- escaping: the untrusted URL is the attack surface ----------

(defun xiiif-osd-test--occurrences (needle haystack)
  "Return how many times NEEDLE occurs in HAYSTACK."
  (let ((n 0) (start 0))
    (while (setq start (cl-search needle haystack :start2 start))
      (setq n (1+ n) start (+ start (length needle))))
    n))

(ert-deftest xiiif-osd/a-url-cannot-close-the-script-element ()
  "The page carries exactly the two script elements it writes itself.

An HTML parser reads a script element before JavaScript does, so a
`</script>' inside a string literal still ends it - and a
`<!--<script' earlier switches the tokenizer to a state where the
next `</script>' does not.  Counting both halves is what makes the
second door visible; counting only `</script>' would have passed
while `<script' was still getting through."
  (let* ((hostile
          "https://evil/<!--<script></script><script>alert(1)</script>/i.json")
         (page (xiiif-osd-page hostile)))
    (should (= 2 (xiiif-osd-test--occurrences "</script>" page)))
    (should (= 2 (xiiif-osd-test--occurrences "<script" page)))
    (should (= 0 (xiiif-osd-test--occurrences "<!--" page)))
    ;; The URL is escaped, not dropped: it is still in there.
    (should (string-match-p "evil" page))))

(ert-deftest xiiif-osd/escaping-loses-nothing-and-adds-nothing ()
  "Every escaped value reads back as itself.
`\\/' is valid JSON, so the escaped form is still JSON - and a
round-trip catches a character silently added (an over-eager
backslash) as surely as one dropped, which regexp-sniffing does not."
  (dolist (value '("https://x/iiif/img/info.json"
                   "https://evil/</script>/info.json"
                   "https://x/\"+alert(1)+\"/info.json"
                   "https://x/a\\b/info.json"
                   "https://x/é/info.json"
                   ""))
    (should (equal value
                   (json-read-from-string (xiiif-osd--js-string value))))))

(ert-deftest xiiif-osd/the-label-is-escaped-too ()
  (let ((page (xiiif-osd-page "https://x/info.json" nil
                              "</script><img src=x onerror=alert(1)>")))
    (should-not (string-match-p "</script><img" page))))

(ert-deftest xiiif-osd/the-page-title-and-library-are-html-escaped ()
  (let* ((xiiif-osd-library-url "https://x/osd.js\"></script><b>")
         (page (xiiif-osd-page "https://x/info.json")))
    (should-not (string-match-p "\"></script><b>" page))
    (should (string-match-p "&quot;" page))))

;;; ---------- what the page says ----------

(ert-deftest xiiif-osd/page-names-the-tile-source-and-the-library ()
  (let ((page (xiiif-osd-page "https://x/iiif/img/info.json" nil "Folio 1")))
    (should (string-match-p "https://x/iiif/img/info.json" page))
    (should (string-match-p (regexp-quote xiiif-osd-library-url) page))
    (should (string-match-p "Folio 1" page))
    (should (string-match-p "OpenSeadragon(" page))))

(ert-deftest xiiif-osd/no-region-means-no-focus-script ()
  (should-not (string-match-p "fitBounds" (xiiif-osd-page "https://x/info.json"))))

(ert-deftest xiiif-osd/a-pixel-region-is-handed-over-in-pixels ()
  (let ((page (xiiif-osd-page "https://x/info.json"
                              (xiiif-region-from-string "100,200,300,400"))))
    (should (string-match-p "fitBounds" page))
    (should (string-match-p "imageToViewportRectangle" page))
    ;; The pixel branch, and the four numbers as given.
    (should (string-match-p "var f = false" page))
    (dolist (n '("100" "200" "300" "400"))
      (should (string-match-p n page)))))

(ert-deftest xiiif-osd/a-percent-region-is-resolved-in-the-browser ()
  "Percent needs the image size, which the browser already has."
  (let ((page (xiiif-osd-page "https://x/info.json"
                              (xiiif-region-from-string "10,20,30,40%"))))
    (should (string-match-p "var f = true" page))
    (should (string-match-p "getContentSize" page))))

;;; ---------- the URL policy applies before the browser sees it ----------

(ert-deftest xiiif-osd/a-refused-service-never-reaches-a-file ()
  (cl-letf (((symbol-function 'browse-url-of-file)
             (lambda (_) (error "must not open anything")))
            ((symbol-function 'xiiif-osd-write-page)
             (lambda (&rest _) (error "must not write anything"))))
    (should-error (xiiif-osd-open "http://169.254.169.254/iiif/img")
                  :type 'xiiif-url-refused)
    (should-error (xiiif-osd-open "ftp://example.org/iiif/img")
                  :type 'xiiif-url-refused)))

(ert-deftest xiiif-osd/no-service-is-a-user-error ()
  (should-error (xiiif-osd-open nil) :type 'user-error))

(ert-deftest xiiif-osd/writes-a-readable-page-and-opens-it ()
  (let ((opened nil))
    (cl-letf (((symbol-function 'browse-url-of-file)
               (lambda (file) (setq opened file))))
      (xiiif-osd-open "https://example.org/iiif/img"))
    (should opened)
    (unwind-protect
        (let ((text (with-temp-buffer
                      (insert-file-contents opened)
                      (buffer-string))))
          (should (string-match-p "<!DOCTYPE html>" text))
          (should (string-match-p "https://example.org/iiif/img/info.json" text)))
      (delete-file opened))))

;;; ---------- the pair, and the choice between them ----------

(defun xiiif-osd-test--canvas (&optional service)
  (make-xiiif-canvas
   :id "https://x/canvas/1" :label "Folio 1"
   :image-service (and service (make-xiiif-image-service :id service))))

(ert-deftest xiiif-osd/a-canvas-without-a-service-says-what-to-use-instead ()
  (let ((err (should-error
              (xiiif-open-in-openseadragon (xiiif-osd-test--canvas))
              :type 'user-error)))
    (should (string-match-p "mirador" (cadr err)))))

(ert-deftest xiiif-osd/auto-picks-openseadragon-for-a-zoomable-canvas ()
  (let ((xiiif-default-external-viewer 'auto)
        (xiiif-current-canvas (xiiif-osd-test--canvas "https://x/iiif/img"))
        (xiiif-current-manifest
         (make-xiiif-manifest :url "https://x/manifest" :id "https://x/manifest"
                              :type "Manifest" :label "Test"))
        (chosen nil))
    (cl-letf (((symbol-function 'xiiif-osd-open)
               (lambda (&rest _) (setq chosen 'openseadragon)))
              ((symbol-function 'browse-url)
               (lambda (_) (setq chosen 'mirador))))
      (with-temp-buffer (xiiif-open-external-viewer)))
    (should (eq 'openseadragon chosen))))

(ert-deftest xiiif-osd/auto-falls-back-to-mirador-without-a-service ()
  (let ((xiiif-default-external-viewer 'auto)
        (xiiif-current-canvas (xiiif-osd-test--canvas))
        (xiiif-current-manifest
         (make-xiiif-manifest :url "https://x/manifest" :id "https://x/manifest"
                              :type "Manifest" :label "Test"))
        (chosen nil))
    (cl-letf (((symbol-function 'xiiif-osd-open)
               (lambda (&rest _) (setq chosen 'openseadragon)))
              ((symbol-function 'browse-url)
               (lambda (_) (setq chosen 'mirador))))
      (with-temp-buffer (xiiif-open-external-viewer)))
    (should (eq 'mirador chosen))))

(ert-deftest xiiif-osd/an-explicit-anchor-goes-to-mirador-under-auto ()
  "An anchor is a manifest+canvas+region location, which is Mirador's."
  (let ((xiiif-default-external-viewer 'auto)
        (xiiif-current-canvas (xiiif-osd-test--canvas "https://x/iiif/img"))
        (xiiif-current-manifest
         (make-xiiif-manifest :url "https://x/manifest" :id "https://x/manifest"
                              :type "Manifest" :label "Test"))
        (chosen nil))
    (cl-letf (((symbol-function 'xiiif-osd-open)
               (lambda (&rest _) (setq chosen 'openseadragon)))
              ((symbol-function 'browse-url)
               (lambda (_) (setq chosen 'mirador))))
      (xiiif-open-external-viewer
       nil (xiiif-anchor-create :manifest "https://x/manifest"
                                :canvas "https://x/canvas/1")))
    (should (eq 'mirador chosen))))

(ert-deftest xiiif-osd/an-unresolvable-anchor-is-refused-not-guessed ()
  (let ((xiiif-current-manifest
         (make-xiiif-manifest :url "https://x/manifest" :id "https://x/manifest"
                              :type "Manifest" :label "Test" :items nil)))
    (cl-letf (((symbol-function 'xiiif-osd-open)
               (lambda (&rest _) (error "must not open anything"))))
      (should-error
       (xiiif-open-external-viewer
        'openseadragon
        (xiiif-anchor-create :manifest "https://x/manifest"
                             :canvas "https://x/canvas/absent"))
       :type 'user-error))))

(ert-deftest xiiif-osd/the-viewer-binds-o-and-keeps-m ()
  (should (eq 'xiiif-view-open-in-openseadragon
              (lookup-key xiiif-view-mode-map (kbd "O"))))
  (should (eq 'xiiif-view-open-in-mirador
              (lookup-key xiiif-view-mode-map (kbd "M")))))

(provide 'xiiif-osd-test)
;;; xiiif-osd-test.el ends here
