;;; xiiif-osd.el --- OpenSeadragon handoff for xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The second external viewer of Spec §8, and not the symmetric twin
;; of the Mirador handoff it looks like.
;;
;; Mirador is a hosted application that speaks IIIF Content State, so
;; handing it a location is a URL: `?iiif-content=<token>' and
;; `browse-url'.  OpenSeadragon is a JavaScript library.  There is no
;; canonical instance to send anyone to, it has no notion of a
;; Manifest or a Canvas, and what it consumes is an Image API
;; `info.json'.  A URL handoff is therefore not available, and
;; pretending otherwise would produce a command that never works.
;;
;; So this module writes a small self-contained page to a temporary
;; file and opens that.  Two consequences worth naming:
;;
;;  - It views one canvas, never a manifest.  That is what
;;    OpenSeadragon is good at - deep zoom on a single image - and
;;    Mirador remains the handoff for a whole work.
;;  - The page loads the library from `xiiif-osd-library-url'.  It is
;;    a CDN by default and a customization point precisely so an
;;    air-gapped or privacy-minded user can point it at a local copy.
;;
;; A region survives the handoff, so `O' from the region viewer opens
;; OpenSeadragon framed on exactly what was on screen.  The arithmetic
;; happens in the browser, where the image dimensions are already
;; known, rather than costing an info.json fetch here.
;;
;; Everything interpolated into the page is escaped for a JavaScript
;; string *inside* an HTML script element, which is not the same as
;; escaping for JSON: an HTML parser reads the element before
;; JavaScript does, so `</script>' ends it from within a string
;; literal, and `<!--<script' earlier switches the tokenizer to a
;; state where the next `</script>' no longer does.  Rather than
;; enumerate those cases, no `<' survives literally at all.
;;
;; The info.json URL passes the URL policy before any of that: Spec
;; §13 asks that an external viewer open validated URLs, and it is
;; validated here even though the fetch happens in another process.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'xml)
(require 'xiiif-core)
(require 'xiiif-url)
(require 'xiiif-region)
(require 'xiiif-image)

(defcustom xiiif-osd-library-url
  "https://cdn.jsdelivr.net/npm/openseadragon@4/build/openseadragon/openseadragon.min.js"
  "URL of the OpenSeadragon library loaded by the generated page.
Point it at a local file (a `file://' URL or an absolute path) to
open canvases without reaching a CDN."
  :type 'string
  :group 'xiiif)

(defcustom xiiif-osd-page-title "xiiif — OpenSeadragon"
  "Title of the generated OpenSeadragon page."
  :type 'string
  :group 'xiiif)

(defun xiiif-osd--js-string (value)
  "Return VALUE as a JavaScript string literal safe inside a script element.

`json-encode-string' handles quoting and control characters.  What
it does not handle is that an HTML parser reads a script element
before JavaScript does: `</script>' ends the element from inside a
string literal, and `<!--<script' switches the tokenizer to a state
where a later `</script>' no longer ends it.  Escaping only `</'
would leave that second door open, so no `<' survives literally at
all - `\\u003C' is what JavaScript reads it as, and it is ordinary
JSON, so the escaped form still round-trips."
  (replace-regexp-in-string
   "<" "\\u003C" (json-encode-string (or value "")) t t))

(defun xiiif-osd--focus-script (region)
  "Return the JavaScript framing REGION on open, or the empty string.
REGION is a `xiiif-region' or nil.  Percent regions are resolved
against the image's own content size, which the browser knows and
Emacs would have to fetch."
  (if (not (xiiif-region-p region))
      ""
    (let ((percent (eq (xiiif-region-unit region) 'percent)))
      (format "
  viewer.addHandler('open', function () {
    var item = viewer.world.getItemAt(0);
    if (!item) { return; }
    var s = item.getContentSize();
    var f = %s;
    var r = item.imageToViewportRectangle(
      f ? s.x * %s / 100 : %s, f ? s.y * %s / 100 : %s,
      f ? s.x * %s / 100 : %s, f ? s.y * %s / 100 : %s);
    viewer.viewport.fitBounds(r, true);
  });"
              (if percent "true" "false")
              (xiiif-region-x region) (xiiif-region-x region)
              (xiiif-region-y region) (xiiif-region-y region)
              (xiiif-region-w region) (xiiif-region-w region)
              (xiiif-region-h region) (xiiif-region-h region)))))

(defun xiiif-osd-page (info-url &optional region label)
  "Return the HTML of a page viewing INFO-URL with OpenSeadragon.
REGION, a `xiiif-region', frames the initial view.  LABEL is shown
above the viewer so the page says what it is showing."
  (format "<!DOCTYPE html>
<html lang=\"en\">
<head>
<meta charset=\"utf-8\">
<title>%s</title>
<style>
 html, body { margin: 0; height: 100%%; background: #111; color: #ddd;
              font: 13px/1.5 system-ui, sans-serif; }
 header { padding: .5em .8em; }
 #xiiif-osd { width: 100%%; height: calc(100%% - 3em); }
</style>
</head>
<body>
<header id=\"xiiif-label\"></header>
<div id=\"xiiif-osd\"></div>
<script src=\"%s\"></script>
<script>
  document.getElementById('xiiif-label').textContent = %s;
  var viewer = OpenSeadragon({
    id: 'xiiif-osd',
    prefixUrl: '',
    showNavigator: true,
    tileSources: [%s]
  });%s
</script>
</body>
</html>
"
          (xml-escape-string xiiif-osd-page-title)
          (xml-escape-string xiiif-osd-library-url)
          (xiiif-osd--js-string (or label ""))
          (xiiif-osd--js-string info-url)
          (xiiif-osd--focus-script region)))

(defun xiiif-osd-write-page (info-url &optional region label)
  "Write the OpenSeadragon page for INFO-URL and return its file name.
REGION and LABEL are passed to `xiiif-osd-page'.  The file is a
temporary one, created with the restrictive permissions
`make-temp-file' gives, and holds no credentials - only the public
URL of an image service."
  (let ((file (make-temp-file "xiiif-osd-" nil ".html")))
    (with-temp-file file
      (insert (xiiif-osd-page info-url region label)))
    file))

(defun xiiif-osd-open (service &optional region label)
  "Open SERVICE in OpenSeadragon, framed on REGION, titled LABEL.
SERVICE is anything `xiiif-image-service-base' understands.  Signals
`user-error' when SERVICE has no derivable info.json, and
`xiiif-url-refused' when the policy rejects that URL."
  (let ((info-url (xiiif-image-info-url service)))
    (unless info-url
      (user-error "No Image API service to hand to OpenSeadragon"))
    ;; Spec §13: an external viewer opens validated URLs, and this one
    ;; is validated here even though the browser does the fetching.
    (xiiif-url-check info-url)
    (browse-url-of-file (xiiif-osd-write-page info-url region label))
    info-url))

(provide 'xiiif-osd)
;;; xiiif-osd.el ends here
