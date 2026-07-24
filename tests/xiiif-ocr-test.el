;;; xiiif-ocr-test.el --- Tests for xiiif-ocr -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused tests on the OCR classifier and the text extractors.  The
;; sync fetcher hits the network and is not exercised here.

;;; Code:

(require 'ert)
(require 'xiiif-core)
(require 'xiiif-ocr)


;;; ---- classification ----

(ert-deftest xiiif-ocr--classify/mime-alto ()
  (should (eq 'alto
              (xiiif-ocr--classify
               '((id . "http://x/ocr.xml")
                 (format . "application/alto+xml"))))))

(ert-deftest xiiif-ocr--classify/mime-hocr ()
  (should (eq 'hocr
              (xiiif-ocr--classify
               '((id . "http://x/ocr.html")
                 (format . "text/vnd.hocr+html"))))))

(ert-deftest xiiif-ocr--classify/profile-alto ()
  (should (eq 'alto
              (xiiif-ocr--classify
               '((id . "http://x/ocr")
                 (profile . "http://www.loc.gov/standards/alto/v3"))))))

(ert-deftest xiiif-ocr--classify/unknown-format ()
  (should (null (xiiif-ocr--classify
                 '((id . "http://x/ocr")
                   (format . "application/pdf"))))))


;;; ---- canvas ref extraction ----

(ert-deftest xiiif-canvas-ocr-refs/filters-and-classifies ()
  (let* ((raw '((id . "http://x/c1")
                (type . "Canvas")
                (seeAlso . [((id . "http://x/ocr.xml")
                             (type . "Dataset")
                             (format . "application/alto+xml")
                             (label . ((en . ["ALTO OCR"]))))
                            ((id . "http://x/ocr.html")
                             (format . "text/vnd.hocr+html"))
                            ((id . "http://x/metadata.ttl")
                             (format . "text/turtle"))])))
         (canvas (make-xiiif-canvas :id "http://x/c1" :raw raw))
         (refs (xiiif-canvas-ocr-refs canvas)))
    (should (= 2 (length refs)))
    (should (eq 'alto (plist-get (car refs) :format)))
    (should (equal "ALTO OCR" (plist-get (car refs) :label)))
    (should (eq 'hocr (plist-get (cadr refs) :format)))))


;;; ---- text extractors ----

(ert-deftest xiiif-ocr--extract-alto/basic ()
  (let ((xml "<alto><TextLine><String CONTENT=\"hello\"/><String CONTENT=\"world\"/></TextLine><TextLine><String CONTENT=\"second\"/><String CONTENT=\"line\"/></TextLine></alto>"))
    (should (equal "hello world\nsecond line"
                   (xiiif-ocr--extract-alto xml)))))

(ert-deftest xiiif-ocr--extract-alto/ignores-other-attrs ()
  (let ((xml "<String WC=\"0.9\" CONTENT=\"quoted\"/>"))
    (should (equal "quoted"
                   (xiiif-ocr--extract-alto xml)))))

(ert-deftest xiiif-ocr--extract-hocr/strips-tags ()
  (let ((html "<div class='ocr_page'><span class='ocrx_word'>hello</span>\n<span class='ocrx_word'>world</span></div>"))
    (should (string-match-p "hello" (xiiif-ocr--extract-hocr html)))
    (should (string-match-p "world" (xiiif-ocr--extract-hocr html)))
    (should-not (string-match-p "<" (xiiif-ocr--extract-hocr html)))))

(ert-deftest xiiif-ocr-extract-text/passthrough-for-plain ()
  (should (equal "raw text"
                 (xiiif-ocr-extract-text "raw text" 'text))))


;;; ---- ALTO word boxes ----

(ert-deftest xiiif-ocr-alto-boxes/parses-string-boxes ()
  (let* ((xml (concat
               "<TextLine>"
               "<String CONTENT=\"hello\" HPOS=\"100\" VPOS=\"200\""
               " WIDTH=\"80\" HEIGHT=\"30\"/>"
               "<String CONTENT=\"world\" HPOS=\"190\" VPOS=\"200\""
               " WIDTH=\"90\" HEIGHT=\"30\"/>"
               "</TextLine>"))
         (boxes (xiiif-ocr-alto-boxes xml)))
    (should (= 2 (length boxes)))
    (should (equal "hello" (car (nth 0 boxes))))
    (let ((r (cdr (nth 0 boxes))))
      (should (xiiif-region-p r))
      (should (= 100 (xiiif-region-x r)))
      (should (= 200 (xiiif-region-y r)))
      (should (= 80 (xiiif-region-w r)))
      (should (= 30 (xiiif-region-h r))))
    (should (equal "world" (car (nth 1 boxes))))
    (should (= 190 (xiiif-region-x (cdr (nth 1 boxes)))))))

(ert-deftest xiiif-ocr-alto-boxes/skips-incomplete-strings ()
  "A <String> missing a coordinate attribute is skipped."
  (let ((xml (concat
              "<String CONTENT=\"ok\" HPOS=\"1\" VPOS=\"2\" WIDTH=\"3\" HEIGHT=\"4\"/>"
              "<String CONTENT=\"nocoords\"/>")))
    (should (= 1 (length (xiiif-ocr-alto-boxes xml))))))

(ert-deftest xiiif-ocr-alto-boxes/handles-decimal-coords ()
  (let ((xml "<String CONTENT=\"x\" HPOS=\"10.6\" VPOS=\"20\" WIDTH=\"5\" HEIGHT=\"5\"/>"))
    (should (= 11 (xiiif-region-x (cdr (car (xiiif-ocr-alto-boxes xml))))))))

(ert-deftest xiiif-ocr-alto-boxes/empty-without-strings ()
  (should-not (xiiif-ocr-alto-boxes "<alto></alto>")))

(provide 'xiiif-ocr-test)
;;; xiiif-ocr-test.el ends here
