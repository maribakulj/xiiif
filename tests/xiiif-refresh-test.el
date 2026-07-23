;;; xiiif-refresh-test.el --- Tests for xiiif-refresh per major-mode -*- lexical-binding: t; -*-

;;; Commentary:

;; Feeds a stubbed `url-retrieve' with alternating manifest bodies
;; and verifies that `xiiif-refresh' dispatches to the correct
;; renderer based on the calling major mode, and that the in-flight
;; handle cancellation does not raise.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'xiiif-core)
(require 'xiiif-api)
(require 'xiiif-ui)
(require 'xiiif-cache)
(require 'xiiif)

(defvar xiiif-refresh-test--fixtures nil)

(defun xiiif-refresh-test--stub (url callback &optional _cbargs _silent _inhibit-cookies)
  (let* ((body (or (cdr (assoc url xiiif-refresh-test--fixtures))
                   (error "no fixture for %s" url)))
         (buf (generate-new-buffer " *xiiif-refresh-stub*")))
    (with-current-buffer buf
      (set-buffer-multibyte nil)
      (insert "HTTP/1.1 200 OK\r\nContent-Type: application/ld+json\r\n\r\n")
      (insert body)
      (run-at-time 0 nil
                   (lambda ()
                     (with-current-buffer buf
                       (funcall callback nil)))))
    buf))

(defmacro xiiif-refresh-test--with (fixtures &rest body)
  (declare (indent 1) (debug (form body)))
  `(let ((xiiif-refresh-test--fixtures ,fixtures)
         (xiiif-api-backend 'url))
     (cl-letf (((symbol-function 'url-retrieve)
                #'xiiif-refresh-test--stub))
       ,@body)))

(defun xiiif-refresh-test--wait-for (pred)
  (let ((deadline (+ (float-time) 2.0)))
    (while (and (not (funcall pred))
                (< (float-time) deadline))
      (accept-process-output nil 0.02))
    (funcall pred)))

(defconst xiiif-refresh-test--manifest-body
  (concat
   "{\"@context\":\"http://iiif.io/api/presentation/3/context.json\","
   "\"id\":\"http://x/m\",\"type\":\"Manifest\","
   "\"label\":{\"en\":[\"Refreshed M\"]},"
   "\"items\":[{\"id\":\"http://x/c1\",\"type\":\"Canvas\","
   "\"label\":{\"en\":[\"Folio\"]},\"width\":10,\"height\":20}]}"))

(defconst xiiif-refresh-test--collection-body
  (concat
   "{\"@context\":\"http://iiif.io/api/presentation/3/context.json\","
   "\"id\":\"http://x/col\",\"type\":\"Collection\","
   "\"label\":{\"en\":[\"Refreshed C\"]},"
   "\"items\":[{\"id\":\"http://x/sub\",\"type\":\"Manifest\","
   "\"label\":{\"en\":[\"Child\"]}}]}"))


(ert-deftest xiiif-refresh/manifest-mode-updates-overview ()
  (xiiif-refresh-test--with
      `(("http://x/m" . ,xiiif-refresh-test--manifest-body))
    (let ((xiiif-current-manifest
           (make-xiiif-manifest :url "http://x/m" :id "http://x/m"
                                :type "Manifest" :label "old"
                                :items nil :raw nil)))
      (xiiif-ui-render-manifest xiiif-current-manifest)
      (with-current-buffer xiiif-ui--manifest-buffer
        (xiiif-refresh))
      (should (xiiif-refresh-test--wait-for
               (lambda ()
                 (with-current-buffer xiiif-ui--manifest-buffer
                   (save-excursion
                     (goto-char (point-min))
                     (search-forward "Refreshed M" nil t))))))
      (kill-buffer xiiif-ui--manifest-buffer))))


(ert-deftest xiiif-refresh/collection-mode-updates-browser ()
  (xiiif-refresh-test--with
      `(("http://x/col" . ,xiiif-refresh-test--collection-body))
    (let ((xiiif-current-collection
           (make-xiiif-collection :url "http://x/col" :id "http://x/col"
                                  :type "Collection" :label "old"
                                  :items nil :raw nil)))
      (xiiif-ui-render-collection xiiif-current-collection)
      (with-current-buffer xiiif-ui--collection-buffer
        (xiiif-refresh))
      (should (xiiif-refresh-test--wait-for
               (lambda ()
                 (with-current-buffer xiiif-ui--collection-buffer
                   (= 1 (length tabulated-list-entries))))))
      (kill-buffer xiiif-ui--collection-buffer))))


(ert-deftest xiiif-refresh/no-context-signals ()
  (let ((xiiif-current-manifest nil)
        (xiiif-current-collection nil))
    (with-temp-buffer
      (should-error (xiiif-refresh) :type 'user-error))))


(provide 'xiiif-refresh-test)
;;; xiiif-refresh-test.el ends here
