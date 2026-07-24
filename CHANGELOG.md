# Changelog

All notable changes to `xiiif` are documented here.  The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## [0.4.0] — 2026-07-24

Turns "a set of async requests" into a loading system, adds a
step-by-step region viewer, and introduces the canonical anchor that
lets Emacs, an external agent and web viewers look at the same spot.

### Added

- `xiiif-view.el`: a step-by-step region viewer (`*XIIIF View*`,
  `xiiif-view-mode`).  Shows one region of a canvas at a zoom level;
  keyboard pan (arrows / `hjkl`, half a screen, `C-u` for a fine
  step), zoom (`+`/`-`/`0`), reload (`g`), quit (`q`).  Each
  navigation cancels the previous view's fetches, shows a cached
  image or a rescaled proxy immediately, then fetches the sharp
  image and prefetches neighbours.  HiDPI-aware (`frame-scale-factor`
  when available); a per-buffer LRU flushes evicted images; off a
  graphic display it shows the Image API URL.  `xiiif-view-canvas`
  (bound to `v` in the canvas detail and browser) opens it;
  `y` copies the exact view URL, `M` hands the canvas+region off to
  Mirador, `a` starts an anchored note.
- `xiiif-anchor.el`: a canonical, serialisable, versioned anchor
  (`:manifest :canvas :region :label`) plus IIIF Content State 1.0
  import/export.  `xiiif-content-state-url` encodes an anchor as an
  `?iiif-content=` token; `xiiif-content-state-parse` reads a URL,
  token or raw JSON back.  `xiiif-open-content-state` navigates to a
  pasted Content State.
- `xiiif-region.el`: an `(x y w h)` region with a pixel/percent unit,
  parsed from Media Fragments hashes and v2/v3 structured selectors.
  Annotations and search hits now carry the region; the annotations
  buffer shows a Region field and the search list a Region column,
  and `RET` on either opens the viewer there when it has a region.
- `xiiif-annot.el`: anchored notes.  `xiiif-annot-create` builds the
  context anchor, prompts for a title and body, and delegates to
  `xiiif-annot-backend-function`.  The default Org backend appends an
  entry whose PROPERTIES drawer records the anchor; `xiiif-annot-visit`
  reopens exactly that location.
- `xiiif-batch.el`: a prompt-free scripting surface for
  `emacsclient --eval` — `xiiif-batch-open`, `xiiif-batch-goto`,
  `xiiif-batch-current-view`, `xiiif-batch-annotate`.
- `xiiif-fetch.el`: a request scheduler between the UI and the
  transport — concurrency cap, per-host politeness interval
  (`:min-interval` server profiles), `Retry-After`-aware 429/503
  retries, in-flight deduplication, interactive-over-prefetch
  priorities, and grouped cancellation.
- `xiiif-image-cache.el`: an on-disk byte cache for Image API
  responses (LRU, 200 MiB default), consumed by `xiiif-fetch-bytes`
  `:cache` — revisiting a region costs no network.
- Optional `plz` (curl) HTTP backend, selected by
  `xiiif-api-backend` (`auto`/`url`/`plz`): robust TLS and redirects,
  HTTP/2, downloads streamed to disk.  Strictly optional, detected at
  runtime; the built-in `url` library remains the default fallback.
- `xiiif-image-closest-size`: pick an advertised size, keeping
  requests valid on level-0 servers.
- `xiiif-ocr-alto-boxes`: parse ALTO `<String>` word boxes into
  `(STRING . REGION)` pairs.
- New commands `xiiif-view-canvas`, `xiiif-open-content-state`,
  `xiiif-annot-create`, `xiiif-annot-visit`, and the batch entry
  points; new keys `v` (view) and `n` (note) in the canvas detail.

### Changed

- JSON is parsed with the native `json-parse-string` when available
  (~10× faster on large manifests), falling back to
  `json-read-from-string`.
- Interactive fetches now route through `xiiif-fetch`, gaining the
  scheduler's politeness, deduplication and priorities without any
  visible behaviour change.
- The HTTP cache evicts oldest entries beyond
  `xiiif-http-cache-max-entries` / `-max-bytes`.
- Response bodies over `xiiif-api-max-body-size` (default 50 MiB) are
  rejected before decoding.
- 429/503 responses expose the parsed `Retry-After` in the error data.
- The Search API and external `AnnotationCollection`s follow `next`,
  bounded by `xiiif-search-max-pages` / `xiiif-annotations-max-pages`.
- Canvas thumbnails use an advertised size when info is available,
  so they no longer 404 on level-0 servers.
- `xiiif-open-in-mirador` takes an optional anchor and, from a canvas,
  hands off the precise canvas+region instead of the bare manifest.
- `xiiif-org-metadata-block` also records the region and a Content
  State token.
- `xiiif-preferred-languages` defaults from the locale (the user's
  language first, then English), instead of English-only.

### Fixed

- `xiiif-annotations-collect` invokes its callback exactly once, even
  when an errback runs synchronously (invalid URL).
- Stale canvas thumbnails are dropped on re-render (no image at
  `point-min`).
- `g` in the annotations buffer re-collects the annotations instead
  of showing the manifest overview.
- Canvas browser marks survive a refresh, re-applied by id.
- The `xiiif-upgrade.el` Homepage header no longer doubles the owner
  segment; `ROADMAP.md` no longer claims to reflect 0.1.0.
- `make compile-strict` is clean on a fresh checkout (Emacs 29).

## [0.3.0] — 2026-04 (unreleased)

Extends 0.2 with the "later / uncertain" items from `ROADMAP.md`.

### Added

- `xiiif-http-cache.el`: on-disk cache keyed by URL, storing body
  plus `ETag` / `Last-Modified` validators.  Conditional
  `If-None-Match` / `If-Modified-Since` are attached automatically
  to every xiiif GET; a 304 response is served from the cache.
  Interactive `xiiif-cache-clear-http` wipes the cache.
- `xiiif-upgrade.el`: `xiiif-upgrade-manifest` and
  `xiiif-upgrade-collection` return a canonical v3-shaped alist
  (language-map labels, unified `items`, v2 images wrapped into
  AnnotationPages, `sc:`-prefix stripped).  Use it before handing
  data to v3-only consumers.
- `xiiif-search.el`: minimal client for IIIF Search API 1.0.
  `xiiif-search` queries the service advertised by the current
  manifest and lists hits in `*XIIIF Search*`; RET jumps to the
  targeted canvas.
- `xiiif-open-in-mirador`: open the current manifest in an external
  Mirador viewer via `browse-url`; base URL customisable through
  `xiiif-mirador-base-url`.

### Fixed

- Response parser now recognises a 304 Not Modified as a cache
  revalidation rather than an error, eliminating needless re-parses
  on repeated opens.

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
