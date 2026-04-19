# xiiif — an Emacs-native IIIF workbench

`xiiif` is an Emacs package for exploring [IIIF](https://iiif.io)
resources from inside Emacs. It is built for people who already live
in Emacs and work with cultural-heritage and research collections:
GLAM practitioners, librarians, curators, digital-humanities scholars,
and anyone who needs to triage manifests, walk collections, pull
derivatives, and paste clean references into notes.

`xiiif` is **not** a graphical viewer like Mirador or the Universal
Viewer. It is a text-first, structure-first, scriptable Emacs tool:

- Open any IIIF Presentation Manifest **or** Collection by URL.
- Inspect either in a readable buffer — label, summary, metadata,
  child counts.
- Browse canvases in a sortable tabulated list.
- Walk Collections (including nested sub-collections) without leaving
  Emacs.
- Drill into a canvas to see its image-service base, default
  derivative URL, and `info.json` endpoint.
- Copy or download IIIF Image API derivatives at any size, quality,
  region, rotation or format.
- Drop links and metadata blocks straight into Org.

The raw JSON is still one keystroke away when you need it — but you
are not forced to stare at it as the default experience. Network
requests are non-blocking, so Emacs stays responsive even on slow
upstream servers.

---

## Table of contents

- [Why this might be useful](#why-this-might-be-useful)
- [Status](#status)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Buffers and keymaps](#buffers-and-keymaps)
- [Collections](#collections)
- [IIIF Image API URLs](#iiif-image-api-urls)
- [Org integration](#org-integration)
- [Internal data model](#internal-data-model)
- [Architecture](#architecture)
- [Customization](#customization)
- [Error handling](#error-handling)
- [Development](#development)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

---

## Why this might be useful

Most IIIF tooling targets web viewers and end-user presentation.
Research and GLAM workflows often want the opposite: the ability to
enumerate, script, annotate, and reference IIIF resources without
leaving a text-based environment. `xiiif` is aimed at that side of
the ecosystem.

Typical use cases:

- Quickly surveying an unfamiliar manifest — is it v2 or v3? How
  many canvases? Which expose a IIIF Image API service?
- Walking an institution's top-level Collection to find a specific
  manuscript without clicking through ten HTML pages.
- Building a research note in Org that cites specific folios with
  properly formed manifest and image URLs.
- Pulling a specific thumbnail, tile, or derivative for inclusion in
  a paper, slide, or dataset.
- Scripting bulk extraction with Emacs Lisp — e.g. `mapcar`-ing over
  canvases to dump `info.json` URLs for downstream tools.

## Status

| Field           | Value                                                       |
| --------------- | ----------------------------------------------------------- |
| Version         | `0.1.0`                                                     |
| Stability       | MVP — APIs may change while the package stabilizes          |
| Emacs           | 27.1 or newer                                               |
| Built on        | `url.el`, `json.el`, `tabulated-list`, `cl-lib`             |
| External deps   | none                                                        |
| License         | GPL-3.0-or-later                                            |

## Installation

### With `use-package` and a local clone

```elisp
(use-package xiiif
  :load-path "~/src/xiiif"
  :commands (xiiif-open-manifest
             xiiif-open
             xiiif-browse-canvases
             xiiif-open-canvas
             xiiif-copy-image-url
             xiiif-download-image
             xiiif-insert-org-link
             xiiif-open-recent))
```

### Manually

```elisp
(add-to-list 'load-path "/path/to/xiiif")
(require 'xiiif)
```

No external packages are required.

### From source on GitHub

```sh
git clone https://github.com/maribakulj/xiiif.git ~/src/xiiif
```

## Quick start

```
M-x xiiif-open-manifest RET https://example.org/iiif/book1/manifest RET
```

A `*XIIIF Manifest*` buffer opens with the manifest's label, summary,
metadata pairs, and the canvas count. Press `RET` to jump to the
canvas browser, `RET` on a canvas to drill in, and `y` to copy a
ready-to-use Image API URL.

If the URL points at a Collection, you land in `*XIIIF Collection*`
instead — same `RET` to descend into the next level (manifest or
sub-collection). The same command handles both because it
auto-detects resource type.

`M-x xiiif-open-recent` re-opens any URL you have visited before
(persisted across Emacs restarts).

## Commands

All commands are autoloaded.

### Primary

| Command                     | What it does                                                     |
| --------------------------- | ---------------------------------------------------------------- |
| `xiiif-open-manifest`       | Prompt for a URL, fetch asynchronously, dispatch by type.        |
| `xiiif-open`                | Alias for `xiiif-open-manifest`.                                 |
| `xiiif-browse-canvases`     | Open the canvas browser for the current manifest.                |
| `xiiif-open-canvas`         | Open the canvas at point or the current canvas.                  |
| `xiiif-copy-image-url`      | Copy a derivative URL. `C-u` prompts for all parameters.         |
| `xiiif-download-image`      | Download a derivative for the current/contextual canvas.         |
| `xiiif-show-info-json`      | Fetch and display the Image API `info.json` for a canvas.        |
| `xiiif-insert-org-link`     | Insert a manifest, canvas, image link, or metadata block.        |

### Auxiliary

| Command                     | What it does                                                     |
| --------------------------- | ---------------------------------------------------------------- |
| `xiiif-copy-manifest-url`   | Copy the current manifest URL to the kill ring.                  |
| `xiiif-show-raw-json`       | Open the raw JSON for the current context.                       |
| `xiiif-refresh`             | Re-fetch the current resource and redisplay.                     |
| `xiiif-open-recent`         | Pick from recently opened resource URLs.                         |
| `xiiif-retry-last`          | Re-issue the most recent failed fetch.                           |
| `xiiif-cache-clear`         | Drop in-memory state (does not touch the history file).          |

## Buffers and keymaps

`xiiif` uses four buffers, each in its own derived major mode. They
share a vocabulary of keys.

| Buffer                 | Mode                       | Underlying mode        |
| ---------------------- | -------------------------- | ---------------------- |
| `*XIIIF Manifest*`     | `xiiif-manifest-mode`      | `special-mode`         |
| `*XIIIF Canvases*`     | `xiiif-canvas-list-mode`   | `tabulated-list-mode`  |
| `*XIIIF Canvas*`       | `xiiif-canvas-mode`        | `special-mode`         |
| `*XIIIF Collection*`   | `xiiif-collection-mode`    | `tabulated-list-mode`  |
| `*XIIIF Image Info*`   | `xiiif-info-mode`          | `special-mode`         |

Common bindings:

| Key   | Action                                                         |
| ----- | -------------------------------------------------------------- |
| `RET` | Open / drill in                                                |
| `o`   | Same as `RET` in list buffers                                  |
| `y`   | Copy the contextually useful URL                               |
| `d`   | Download the contextual image (canvas browser, canvas detail)  |
| `i`   | Insert an Org link (or copy to kill-ring in read-only buffers) |
| `I`   | Fetch and display the image service `info.json` (canvas detail)|
| `J`   | Show raw JSON                                                  |
| `g`   | Refresh                                                        |
| `q`   | `quit-window`                                                  |
| `c`   | Jump to canvas browser (manifest overview)                     |

`i` does the right thing depending on the buffer: when the current
buffer is writable (like an Org buffer you've switched to), the link
is inserted at point; when called from a read-only xiiif buffer, the
link is placed on the kill-ring with a notification, ready to yank.

## Collections

A IIIF Collection lists Manifests and/or sub-Collections under a
single label. `xiiif` parses both v2 (`manifests` + `collections`
arrays) and v3 (`items`) shapes, normalizes the type names (so
`sc:Collection` reads as `Collection`), and renders a tabulated
browser:

```
  #  Type        Label
  ---------------------------------------------------
  1  Manifest    A Sample Illuminated Book
  2  Manifest    A Second Manuscript
  3  Collection  Medieval Manuscripts (sub-collection)
```

`RET` on any row fetches that child and dispatches:

- a Manifest opens in `*XIIIF Manifest*`,
- a sub-Collection opens in `*XIIIF Collection*`, recursively.

Walks are **lazy** — child resources are not fetched until you press
`RET`. This makes huge institutional collections (hundreds of
manifests) painless to browse.

## IIIF Image API URLs

`xiiif-image-url` builds URLs of the form:

```
{base}/{region}/{size}/{rotation}/{quality}.{format}
```

Defaults are: `full` / `max` / `0` / `default` / `jpg`. They are
customizable per call or globally via `xiiif-image-default-*`.

In Lisp:

```elisp
(xiiif-image-url canvas
                 :region "0,0,1024,1024"
                 :size   "!512,512"
                 :rotation "0"
                 :quality "gray"
                 :format  "png")
;; => "https://example.org/iiif/image/book1-p1/0,0,1024,1024/!512,512/0/gray.png"
```

`xiiif-image-info-url` returns the `info.json` endpoint of a service.

### Inspecting `info.json`

Inside the canvas detail buffer, `I` (`xiiif-show-info-json`) fetches
the Image API `info.json` for the canvas's service and opens a
dedicated `*XIIIF Image Info*` buffer.  It surfaces the id, declared
type and protocol, the compliance level (for both v3 bare `levelN`
profiles and v2 profile URIs), declared width/height, the list of
advertised sizes, tile schemes with `scaleFactors`, supported
formats/qualities/features, and a rights statement when present.

The underlying helpers are usable directly from Lisp:

```elisp
(xiiif-image-fetch-info-async
 canvas
 (lambda (info)
   (message "compliance=%s, sizes=%s"
            (xiiif-image-info-compliance-level info)
            (xiiif-image-info-size-strings info))))
```

`xiiif-image-download` writes a derivative to disk and creates parent
directories as needed:

```elisp
(xiiif-image-download canvas "/tmp/folio-1r.jpg" :size "!1024,1024")
```

Interactively, `xiiif-download-image` prompts for size, format and
destination.

## Org integration

`xiiif-insert-org-link` interactively picks one of:

| Kind       | What it inserts                                                       |
| ---------- | --------------------------------------------------------------------- |
| `manifest` | An Org link to the manifest URL, labeled with its title.              |
| `canvas`   | An Org link to the canvas id, labeled with the canvas title.          |
| `image`    | An Org link to the default image-API derivative.                      |
| `metadata` | A small `#+begin_xiiif / #+end_xiiif` block with title, manifest URL, canvas label, canvas id, image URL, and a `:notes:` line. |

Example metadata block:

```org
#+begin_xiiif
:title: A Sample Illuminated Book
:manifest: https://example.org/iiif/book1/manifest
:canvas-label: Folio 1r
:canvas-id: https://example.org/iiif/book1/canvas/p1
:image: https://example.org/iiif/image/book1-p1/full/max/0/default.jpg
:notes:
#+end_xiiif
```

These are plain Org links and plain block elements — they do not
require any Org extensions to work.

## Internal data model

Internally, `xiiif` parses every resource into `cl-defstruct` types:

- `xiiif-manifest`        — url, id, type, label, summary, metadata,
  thumbnail, items, raw.
- `xiiif-canvas`          — id, type, label, width, height, thumbnail,
  image-url, image-service, raw.
- `xiiif-image-service`   — id (base URL), type, profile.
- `xiiif-image-info`      — parsed `info.json`: id, type, protocol,
  profile, width, height, sizes, tiles, preferred-formats, formats,
  qualities, extra-features, rights, raw.
- `xiiif-collection`      — url, id, type, label, summary, items, raw.
- `xiiif-collection-item` — id, type, label (lazy stub for a child).

The parser accepts both IIIF Presentation API 2.x
(`sequences`/`images`/`manifests`/`collections`) and 3.x (`items`)
shapes and falls back gracefully when either side is missing.
Multilingual `label` and `value` values are resolved via
`xiiif-preferred-languages` (default: `("en" "none" "und")`).
v2-style `sc:` type prefixes are stripped on the way in.

## Architecture

```
xiiif/
  xiiif.el          ; package entry, public commands, dispatch
  xiiif-api.el      ; sync + async HTTP, JSON parse, typed errors
  xiiif-core.el     ; data model, tolerant v2/v3 parser
  xiiif-cache.el    ; in-memory state + persisted recent list
  xiiif-image.el    ; IIIF Image API URL builder, download
  xiiif-ui.el       ; major modes & buffers
  xiiif-org.el      ; Org link / metadata insertion
  tests/            ; ERT tests
  examples/         ; sample manifest + collection fixtures
```

| Module          | Responsibility                                                      |
| --------------- | ------------------------------------------------------------------- |
| `xiiif`         | Autoloaded user commands; dispatches between manifest and collection. |
| `xiiif-api`     | `xiiif-api-fetch-json` (sync) and `xiiif-api-fetch-json-async`. Defines `xiiif-network-error`, `xiiif-http-error`, `xiiif-parse-error`. |
| `xiiif-core`    | `cl-defstruct` types, `xiiif-parse-manifest`, `xiiif-parse-collection`, `xiiif-resource-kind`, `xiiif-label-string`, `xiiif-metadata-pairs`. |
| `xiiif-cache`   | Current manifest / canvas / collection; recent URL ring; tiny on-disk persistence. |
| `xiiif-image`   | `xiiif-image-url`, `xiiif-image-info-url`, `xiiif-image-download`, `xiiif-image-fetch-info`, `xiiif-image-fetch-info-async`, and the `xiiif-image-info` parser. |
| `xiiif-ui`      | Five derived modes; renders all xiiif buffers. |
| `xiiif-org`     | `xiiif-org-insert-*` and the underlying link / metadata-block helpers. |

## Customization

All options live under the `xiiif` group (`M-x customize-group RET xiiif`).

### HTTP

| Option                  | Default                                                  |
| ----------------------- | -------------------------------------------------------- |
| `xiiif-api-timeout`     | `30` seconds                                             |
| `xiiif-api-user-agent`  | `xiiif.el/<version> Emacs/<version>`                     |

### Languages

| Option                       | Default                  |
| ---------------------------- | ------------------------ |
| `xiiif-preferred-languages`  | `("en" "none" "und")`    |

### Image API defaults

| Option                          | Default     |
| ------------------------------- | ----------- |
| `xiiif-image-default-region`    | `"full"`    |
| `xiiif-image-default-size`      | `"max"`     |
| `xiiif-image-default-rotation`  | `"0"`       |
| `xiiif-image-default-quality`   | `"default"` |
| `xiiif-image-default-format`    | `"jpg"`     |
| `xiiif-image-download-directory`| `~/.emacs.d/xiiif/` |

### Recents

| Option                | Default                              |
| --------------------- | ------------------------------------ |
| `xiiif-history-file`  | `~/.emacs.d/xiiif-history.el`        |
| `xiiif-history-size`  | `25`                                 |

### Extensibility hooks

Three abnormal hooks let you plug in without patching:

| Hook                                | Argument                | When it fires                                          |
| ----------------------------------- | ----------------------- | ------------------------------------------------------ |
| `xiiif-after-load-manifest-hook`    | `xiiif-manifest`        | After `xiiif-open-manifest` or `xiiif-refresh` succeeds on a Manifest. |
| `xiiif-after-load-collection-hook`  | `xiiif-collection`      | After `xiiif-open-manifest` or `xiiif-refresh` succeeds on a Collection. |
| `xiiif-after-render-canvas-hook`    | `xiiif-canvas`          | Inside the `*XIIIF Canvas*` buffer after it has been populated. |

Example — drop a quick note whenever a manifest finishes loading:

```elisp
(add-hook 'xiiif-after-load-manifest-hook
          (lambda (m)
            (message "xiiif: %s has %d canvas(es)"
                     (xiiif-manifest-title m)
                     (length (xiiif-manifest-canvases m)))))
```

## Error handling

All transport, HTTP and JSON failures are translated into a small
hierarchy of error symbols rooted at `xiiif-error`:

- `xiiif-network-error` — invalid URL, DNS failure, connection refused, timeout.
- `xiiif-http-error`    — non-2xx HTTP status (data: URL, status code).
- `xiiif-parse-error`   — invalid JSON, or JSON that is neither a
  Manifest nor a Collection.

The synchronous helper `xiiif-api-fetch-json` signals these directly,
which is convenient when scripting. The asynchronous variant
`xiiif-api-fetch-json-async` calls an errback with the same
`(SYMBOL URL &rest DATA)` shape; interactive commands report failures
via `message`.

`xiiif-api-error-hint` turns that tuple into a human-readable string
with tailored wording for the common HTTP statuses:

| Status    | Wording                                            |
| --------- | -------------------------------------------------- |
| `401`     | `requires authentication`                          |
| `403`     | `access denied`                                    |
| `404`     | `not found`                                        |
| `410`     | `resource gone`                                    |
| `429`     | `rate limited (try later)`                         |
| `5xx`     | `upstream error <code>`                            |
| other     | `HTTP <code>`                                      |

Every failure the default errback handles is stored in
`xiiif-api-last-error`, so `M-x xiiif-retry-last` re-issues the
offending request after you fix, say, a missing auth header or a
transient upstream blip.

Manifests with missing canvases, canvases with no image service,
empty metadata, monolingual or multilingual labels, and v2-vs-v3 mix
are all handled silently — no user-facing crashes.

## Development

The test suite uses ERT and requires no external package.

```sh
emacs -batch -L . -L tests \
      -l tests/xiiif-api-test.el \
      -l tests/xiiif-core-test.el \
      -l tests/xiiif-image-test.el \
      -l tests/xiiif-hooks-test.el \
      -f ert-run-tests-batch-and-exit
```

Three fixtures live under `examples/`:

- `examples/sample-manifest.json` — a tiny v3 manifest with two canvases.
- `examples/sample-collection.json` — a v3 collection with two manifest stubs and one sub-collection stub.
- `examples/sample-info.json` — a v3 Image API `info.json` with advertised sizes, tiles, formats, qualities and rights.

To try the package against real data without leaving the repo:

```
M-x xiiif-open-manifest RET file:///path/to/xiiif/examples/sample-manifest.json RET
```

(Note: the bundled fixtures use synthetic `example.org` URLs, so the
canvases will not actually return image bytes; they exist for parser
testing.)

## Roadmap

See [`ROADMAP.md`](ROADMAP.md) for the short-, medium-, and
long-term plan. Highlights of the next sprints:

- **0.2** — async fetch ✅, Collections ✅, `info.json` integration ✅,
  structures/ranges navigation, inline thumbnail preview,
  finer-grained HTTP error reporting.
- **0.3** — bulk derivative export, `org-capture` template, citation
  export (BibTeX / CSL-JSON), annotation fetch, OCR/ALTO sidecars.
- **0.4** — source registry (Gallica, LoC, Wellcome, DPLA…), hooks ✅,
  per-server profiles.

## Contributing

Contributions are welcome. The code is deliberately small and
modular; please keep additions:

- built on Emacs built-ins wherever possible,
- independent of any one IIIF server's quirks,
- covered by at least a small ERT test when they touch parsing or URL
  construction,
- documented with a real docstring.

Bug reports with a minimal reproducing manifest URL or a snippet of
the offending JSON are the most useful kind of issue.

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
