;;; xiiif-errors.el --- Error symbols used by xiiif -*- lexical-binding: t; -*-

;; Copyright (C) 2026 The xiiif authors

;; Author: The xiiif authors
;; Homepage: https://github.com/maribakulj/xiiif
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Separating the `define-error' calls from `xiiif-api' lets lower
;; layers like `xiiif-core' signal them without pulling in the HTTP
;; stack - useful when a caller feeds already-decoded JSON to the
;; parser directly, and useful for the test suite, which exercises
;; parser errors without touching `url.el'.

;;; Code:

(define-error 'xiiif-error         "xiiif error")
(define-error 'xiiif-network-error "xiiif network error"    'xiiif-error)
(define-error 'xiiif-http-error    "xiiif HTTP error"       'xiiif-error)
(define-error 'xiiif-parse-error   "xiiif JSON parse error" 'xiiif-error)

(provide 'xiiif-errors)
;;; xiiif-errors.el ends here
