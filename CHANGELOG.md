# Changelog

All notable changes to `xiiif` are documented here.  The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## [0.2.0] — 2026-04 (unreleased)

The 0.2 cycle finishes the `ROADMAP.md` 0.2 / 0.3 / 0.4 sprints and
makes previously-announced features actually usable end-to-end.

### Added

- `xiiif-show-annotations` and `xiiif-show-ocr` interactive commands,
  bound to `a` and `O` respectively in `xiiif-canvas-mode`.  Inline
  IIIF `AnnotationPage` objects and external page references are
  resolved asynchronously and merged in document order.
- `xiiif-api-download-file-async` / `xiiif-image-download-async`:
  non-blocking writers built on top of the bytes fetcher.
- Bulk download runs through a serial async queue with a live
  progress reporter (`xiiif--download-queue-run`) instead of
  `url-copy-file`.
- `xiiif-api-cancel` + the `xiiif--inflight` buffer-local handle;
  rapid `xiiif-refresh` presses no longer interleave two renders.
- `xiiif-manifest-canvas-count` avoids parsing canvases when only a
  length is needed; `xiiif-manifest-canvases` memoises its output
  and `xiiif-manifest-find-canvas` builds a hash-table index on
  first use.
- `xiiif-cache-select` is the unified selector for the current
  manifest / collection / canvas trio.
- `auth-source` integration via a new `:auth` key on
  `xiiif-server-profiles`; the old plain-text `:headers` path still
  works.
- Named-source identifiers can be URL-encoded with `:encode-id t`.
- Content-Type of each response is checked; an unexpected value
  raises a lazy `display-warning` (never an error).
- `xiiif-errors.el` defines the `xiiif-error` hierarchy that
  `xiiif-core` and `xiiif-api` both depend on.
- `CHANGELOG.md`, `Makefile` (targets: `test`, `compile`,
  `compile-strict`, `clean`) and a GitHub Actions workflow running
  the ERT suite on Emacs 27.2 / 28.2 / 29.4.

### Fixed

- `xiiif-download-marked` previously referenced the undefined
  `xiiif-canvas-filesystem-slug`, making the bulk-download path
  crash on the first invocation.
- `xiiif-open-source` now actually loads (`xiiif-sources` was not
  required from the top-level `xiiif.el`).
- `xiiif-after-render-canvas-hook` is now fired by
  `xiiif-ui-render-canvas`; the hook was documented, tested and
  never invoked.
- `a` in the canvas detail buffer no longer errors with
  `void-function xiiif-show-annotations`.
- `xiiif-ui--annotations-buffer` is defined.
- `file://` URLs pass `xiiif-api--valid-url-p`, matching the README
  workflow that opens local fixtures.
- `xiiif-cache-load` no longer calls `load` on the history file;
  tampering with it can no longer execute arbitrary code.
- `xiiif-cache-add-recent` writes are debounced through an idle
  timer; previously every manifest open triggered two disk writes.
- Session pointers (`xiiif-current-manifest`, `-canvas`,
  `-collection`) are kept mutually consistent when switching
  context.
- `xiiif-source-build-manifest-url` no longer relies on unvalidated
  `format` substitution; identifiers with spaces or special
  characters can opt into URL-hexification.

### Changed

- `xiiif.el` now requires `xiiif-errors`, `xiiif-sources`,
  `xiiif-ocr` in addition to the previous set.
- `xiiif-image-download` stays available as a scripting primitive
  but is explicitly documented as blocking; interactive code paths
  use the async variant.
- `README.md` architecture table lists every module; the keymap /
  commands / buffers tables include the annotations and OCR
  entries; per-server profiles and named sources are documented.
- `ROADMAP.md` reflects the actual ship state of 0.2/0.3/0.4
  items.

### Removed

- `xiiif-ui--json-buffer` (dead constant; `xiiif-ui-show-json`
  builds its own buffer names).

## [0.1.0] — 2026-01

Initial MVP: async fetch, Collections, `info.json`, Structures /
Ranges, inline thumbnails, citation export, Org capture.  See
`ROADMAP.md` for the original scoping.
