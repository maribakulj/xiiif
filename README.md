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
- [Structures (Ranges)](#structures-ranges)
- [Collections](#collections)
- [IIIF Image API URLs](#iiif-image-api-urls)
- [Org integration](#org-integration)
- [Region viewer](#region-viewer)
- [Anchors and Content State](#anchors-and-content-state)
- [Scripting](#scripting)
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

| Field           | Value                                                        |
| --------------- | ------------------------------------------------------------ |
| Version         | `0.4.0`                                                      |
| Stability       | Feature-complete for 0.4; APIs may still shift before 1.0    |
| Emacs           | 27.1 or newer                                                |
| Built on        | `url.el`, `json.el`, `tabulated-list`, `cl-lib`, `image`, `auth-source` (for `:auth` profiles) |
| External deps   | none (optional: `plz` for a curl-based HTTP backend)         |
| License         | GPL-3.0-or-later                                             |

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
M-x xiiif-open RET https://example.org/iiif/book1/manifest RET
```

A `*XIIIF Manifest*` buffer opens with the manifest's label, summary,
metadata pairs, and the canvas count. Press `RET` to jump to the
canvas browser, `RET` on a canvas to drill in, and `y` to copy a
ready-to-use Image API URL.

`xiiif-open` is the one command you need to remember. Give it a
Manifest, a Collection or a Canvas URL, a Content State token, a
viewer URL carrying `iiif-content=`, or raw Content State JSON — it
works out which it is. A Collection lands you in `*XIIIF Collection*`,
same `RET` to descend into the next level (manifest or
sub-collection).

`M-x xiiif-open-recent` re-opens any URL you have visited before
(persisted across Emacs restarts).

`M-x xiiif-open-source` dispatches by institution: pick from the
built-in registry (Gallica, Wellcome, Internet Archive), type the
local identifier, and the full manifest URL is assembled for you.
Add your own endpoints with `customize-variable xiiif-sources`.

## Commands

All commands are autoloaded.

### Primary

| Command                     | What it does                                                     |
| --------------------------- | ---------------------------------------------------------------- |
| `xiiif-open`                | Any IIIF reference: resource URL, Content State token, or JSON.  |
| `xiiif-open-manifest`       | Prompt for a URL, fetch asynchronously, dispatch by type.        |
| `xiiif-open-source`         | Pick a registered IIIF source and open a manifest by identifier. |
| `xiiif-browse-canvases`     | Open the canvas browser for the current manifest.                |
| `xiiif-open-canvas`         | Open the canvas at point or the current canvas.                  |
| `xiiif-copy-image-url`      | Copy a derivative URL. `C-u` prompts for all parameters.         |
| `xiiif-download-image`      | Download a derivative for the current/contextual canvas.         |
| `xiiif-download-marked`     | Bulk-download every marked canvas in the browser to a directory. |
| `xiiif-show-info-json`      | Fetch and display the Image API `info.json` for a canvas.        |
| `xiiif-show-structures`     | Open the structural navigator (Ranges) for the current manifest. |
| `xiiif-show-annotations`    | Fetch and display non-painting annotations for the current canvas. |
| `xiiif-show-ocr`            | Fetch and display an ALTO/hOCR/plain-text OCR sidecar.           |
| `xiiif-search`              | Query the current manifest's IIIF Search 1.0 service.            |
| `xiiif-view-canvas`         | Open the step-by-step region viewer on a canvas (`v`).           |
| `xiiif-select-region`       | Focus a region typed as `X,Y,W,H` — no pointer needed (`r`).    |
| `xiiif-annot-create`        | Create an anchored note for the current view or canvas (`n`).    |
| `xiiif-open-in-mirador`     | Open the current view (canvas+region) in an external Mirador.    |
| `xiiif-open-in-openseadragon` | Deep-zoom one canvas in OpenSeadragon, framed on the region.   |
| `xiiif-open-content-state`  | Open a location from a IIIF Content State token or URL.          |
| `xiiif-export-content-state`| Export the current location as a token, JSON, or viewer URL.     |
| `xiiif-insert-org-link`     | Insert a manifest, canvas, image link, or metadata block.        |
| `xiiif-export-citation`     | Export the manifest as BibTeX or CSL-JSON (insert or kill-ring). |

### Stable names

`SPEC_V1.md` §15 fixes the names third-party code should call. They
are the ones that survive as the implementation moves underneath.

| Stable name                 | Today                                                            |
| --------------------------- | ---------------------------------------------------------------- |
| `xiiif-open`                | Any IIIF reference — resource URL, Content State, or token.      |
| `xiiif-search-ocr`          | Same command as `xiiif-search`; the Search service indexes OCR.  |
| `xiiif-create-annotation`   | `xiiif-annot-create`, plus optional anchor/title/body arguments. |
| `xiiif-open-external-viewer`| Mirador or OpenSeadragon, chosen by capability (Spec §8).        |
| `xiiif-select-region`       | Numeric region selection, in the viewer or opening it.           |

### Auxiliary

| Command                     | What it does                                                     |
| --------------------------- | ---------------------------------------------------------------- |
| `xiiif-copy-manifest-url`   | Copy the current manifest URL to the kill ring.                  |
| `xiiif-show-raw-json`       | Open the raw JSON for the current context.                       |
| `xiiif-refresh`             | Re-fetch the current resource and redisplay.                     |
| `xiiif-open-recent`         | Pick from recently opened resource URLs.                         |
| `xiiif-retry-last`          | Re-issue the most recent failed fetch.                           |
| `xiiif-toggle-thumbnails`   | Enable or disable inline canvas-thumbnail previews.              |
| `xiiif-cache-clear`         | Drop in-memory state (does not touch the history file).          |
| `xiiif-cache-clear-http`    | Wipe the on-disk HTTP response cache.                            |
| `xiiif-upgrade-manifest`    | Return a canonical v3-shaped alist from a v2/v3 manifest JSON.   |
| `xiiif-upgrade-collection`  | Return a canonical v3-shaped alist from a v2/v3 collection JSON. |
| `xiiif-annot-visit`         | Reopen the location recorded in the Org entry at point.         |

## Buffers and keymaps

`xiiif` uses six buffers, each in its own derived major mode. They
share a vocabulary of keys.

| Buffer                 | Mode                       | Underlying mode        |
| ---------------------- | -------------------------- | ---------------------- |
| `*XIIIF Manifest*`     | `xiiif-manifest-mode`      | `special-mode`         |
| `*XIIIF Canvases*`     | `xiiif-canvas-list-mode`   | `tabulated-list-mode`  |
| `*XIIIF Canvas*`       | `xiiif-canvas-mode`        | `special-mode`         |
| `*XIIIF Collection*`   | `xiiif-collection-mode`    | `tabulated-list-mode`  |
| `*XIIIF Image Info*`   | `xiiif-info-mode`          | `special-mode`         |
| `*XIIIF Structures*`   | `xiiif-structures-mode`    | `special-mode`         |
| `*XIIIF Annotations*`  | `xiiif-annotations-mode`   | `special-mode`         |
| `*XIIIF OCR*`          | `xiiif-ocr-mode`           | `special-mode`         |
| `*XIIIF Search*`       | `xiiif-search-mode`        | `tabulated-list-mode`  |
| `*XIIIF View*`         | `xiiif-view-mode`          | `special-mode`         |

Common bindings:

| Key   | Action                                                         |
| ----- | -------------------------------------------------------------- |
| `RET` | Open / drill in                                                |
| `o`   | Same as `RET` in list buffers                                  |
| `y`   | Copy the contextually useful URL                               |
| `d`   | Download the contextual image (canvas browser, canvas detail)  |
| `v`   | Open the region viewer for the canvas (canvas browser, canvas detail) |
| `n`   | Create an anchored note for the canvas (canvas detail)         |
| `m` / `u` / `U` / `t` | Mark / unmark / unmark-all / toggle-mark a canvas (canvas browser) |
| `D`   | Bulk-download every marked canvas (canvas browser)             |
| `i`   | Insert an Org link (or copy to kill-ring in read-only buffers) |
| `I`   | Fetch and display the image service `info.json` (canvas detail)|
| `a`   | Fetch and display annotations for the canvas (canvas detail)   |
| `O`   | Fetch and display an OCR/ALTO/hOCR sidecar (canvas detail)     |
| `J`   | Show raw JSON                                                  |
| `g`   | Refresh                                                        |
| `q`   | `quit-window`                                                  |
| `c`   | Jump to canvas browser (manifest overview)                     |
| `s`   | Open the structural navigator (manifest overview, if any)      |
| `n/p` | Next / previous structure entry (structures buffer)            |
| `RET` | Open the viewer on a hit/annotation that carries a region      |

The region viewer (`*XIIIF View*`) has its own keys: arrows or
`hjkl` pan (half a screen, `C-u` for a fine step), `+`/`-`/`0` zoom
in / out / reset, `r` type a region numerically, `y` copy the exact
view URL, `M` hand off to Mirador, `O` to OpenSeadragon, `a` create
an anchored note, `g` reload, `q` quit.

`i` does the right thing depending on the buffer: when the current
buffer is writable (like an Org buffer you've switched to), the link
is inserted at point; when called from a read-only xiiif buffer, the
link is placed on the kill-ring with a notification, ready to yank.

## Structures (Ranges)

Many GLAM manifests declare a hierarchical table of contents in the
`structures` field — chapters, sections, folios — as IIIF `Range`
objects. `xiiif-show-structures` (bound to `s` in the manifest
overview) opens a `*XIIIF Structures*` buffer that renders the full
tree with one line per range or canvas:

```
* Book structure
  * Front matter
    - Folio 1r
  * Body
    - Folio 1v
```

`RET` on a canvas line opens the canvas detail buffer; `RET` on a
range line opens that range's first reachable canvas. `n` / `p` (and
`TAB` / `<backtab>`) move between entries. The parser accepts both
v3 (Range with inline `items`) and v2 (`sc:Range` with `canvases` +
`ranges` references resolved against sibling ranges), with cycle
detection for malformed manifests.

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

### Inline thumbnails

On a graphic Emacs display, the canvas detail buffer fetches a small
IIIF Image API derivative of the canvas and inserts it inline as its
last section. The canvas's declared `thumbnail` field is used when
present; otherwise a URL is synthesized from the image service at
`xiiif-ui-thumbnail-size` (default `!200,200`).

The preview is fetched asynchronously after the text has rendered, so
the buffer is usable immediately; failures are silent. Toggle the
feature with `M-x xiiif-toggle-thumbnails` or set
`xiiif-ui-show-thumbnails` to `nil` in init.

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

### `org-capture` template

Two helpers make it trivial to produce a ready-to-file research note
from the manifest currently loaded in xiiif:

- `xiiif-org-capture-headline` — the manifest title, suitable for a
  headline.
- `xiiif-org-capture-body` — a block with a manifest link, an
  optional canvas link (if `xiiif-current-canvas` is set) and a
  `#+begin_xiiif` metadata block including a `:notes:` line.

Wire them into `org-capture-templates`:

```elisp
(with-eval-after-load 'org-capture
  (add-to-list 'org-capture-templates
               '("x" "IIIF manifest note" entry
                 (file+headline "~/org/research.org" "IIIF")
                 "* %(xiiif-org-capture-headline)\n%(xiiif-org-capture-body)\n%?"
                 :empty-lines 1)))
```

Both helpers signal `user-error` when no manifest is loaded, so the
capture template fails loudly instead of silently writing an empty
note.

## Region viewer

`xiiif` deliberately has no continuous deep-zoom viewer — Emacs's
single-threaded redisplay cannot do 60fps GPU zoom, and that is not
the goal. What it does have is a careful *step-by-step* region
viewer for close reading and supervision, with a precise handoff to
Mirador for the rest.

`xiiif-view-canvas` (`v` in the canvas detail or browser) opens
`*XIIIF View*` on a canvas. It fetches the image `info.json`, derives
a zoom scale table from the advertised `sizes`/`tiles` (or a
`1/16 … 1` default), and shows one region at a time:

| Key            | Action                                              |
| -------------- | --------------------------------------------------- |
| arrows / `hjkl`| Pan by half a screen (`C-u` for a fine step)        |
| `+` / `-` / `0`| Zoom in / out / reset to the whole canvas           |
| `r`            | Type a region as `X,Y,W,H` (or `X,Y,W,H%`)          |
| `y`            | Copy the exact Image API URL of the current view    |
| `M`            | Hand the canvas+region off to Mirador               |
| `O`            | Hand the same view off to OpenSeadragon             |
| `a`            | Create an anchored note for the current view        |
| `g` / `q`      | Reload / quit                                        |

`r` prompts with the region currently on screen, so the coordinates
are readable — and editable — without reading them off the picture.

Each navigation cancels the previous view's in-flight fetches, shows
the cached image (or a rescaled proxy) immediately, then fetches the
sharp version through the scheduler and prefetches the neighbouring
regions. Fetched bytes are cached on disk, so revisiting a region
costs no network. On a HiDPI display the viewer requests physical
pixels and shows them at `1/factor` for crispness. On a level-0
image server it only ever requests advertised sizes, so no URL 404s.
Off a graphic display it prints the Image API URL instead of failing.

`RET` on a search hit or an annotation that carries a region opens
the viewer straight at that region.

## Anchors and Content State

An **anchor** is `xiiif`'s canonical, serialisable description of one
exact spot of a source:

```elisp
(:xiiif-anchor-version 1
 :manifest "https://example.org/iiif/book1/manifest"
 :canvas   "https://example.org/iiif/book1/canvas/p1"
 :region   (100 150 400 300)      ; canvas pixels, omit for a whole canvas
 :label    "Illuminated initial")
```

Being plain data, it round-trips through `prin1`/`read`, the note
backends and the scripting surface. It bridges to **IIIF Content
State 1.0**: `xiiif-content-state-url` encodes an anchor as a
`?iiif-content=` token for a web viewer, and `xiiif-open-content-state`
reads a pasted Content State URL, token or raw JSON back and jumps to
it — the viewer when it names a region, the canvas detail otherwise.
This is what lets `xiiif`, an external agent and a web viewer look at
the same place.

`xiiif-annot-create` (`n` in the canvas detail, `a` in the viewer)
turns the current view into a note. It builds the context anchor,
prompts for a title and body, and delegates to
`xiiif-annot-backend-function`. The default Org backend appends an
entry to `xiiif-annot-org-file` whose `:PROPERTIES:` drawer records
the whole anchor (`:XIIIF_MANIFEST:`, `:XIIIF_CANVAS:`,
`:XIIIF_REGION:`, `:XIIIF_CONTENT_STATE:`), followed by the manifest
link, the region's Image API link and a Content State URL.
`xiiif-annot-visit`, run on such an entry, reopens exactly that view.
Personal backends (Denote, a Markdown vault, Obsidian) belong in your
config; the package ships only the extension point and the Org
backend.

## Scripting

`xiiif` exposes a small, prompt-free surface an external process — a
research agent driving Emacs through `emacsclient --eval`, or a
shell script — can use without any interactive UI. None of these
read the minibuffer; failures are signalled (never a muted
`user-error`), so `emacsclient -e` sees them.

| Function                     | What it does                                    |
| ---------------------------- | ----------------------------------------------- |
| `xiiif-batch-open`           | Load and render a manifest, return a summary alist. |
| `xiiif-batch-goto`           | Navigate to an anchor or a Content State token/URL. |
| `xiiif-batch-current-view`   | The anchor of the current view, or nil.         |
| `xiiif-batch-annotate`       | Store an anchored note with no prompts.         |

```sh
# Load a manifest and read back its summary
emacsclient -e '(xiiif-batch-open "https://example.org/iiif/m")'

# Jump to a spot, note it, and get the current anchor back
emacsclient -e '(xiiif-batch-goto "https://mirador/?iiif-content=...")'
emacsclient -e '(xiiif-batch-annotate (xiiif-batch-current-view) "Lettrine" "note")'
```

This is the pull direction only: the agent reads and writes the view
state. There is no server or socket in `xiiif`; a real-time "follow
mode" would live in user config.

The synchronous helpers (`xiiif-api-fetch-json`, `xiiif-ocr-fetch-sync`,
`xiiif-image-download`, `xiiif-image-fetch-info`) remain available for
scripting; no interactive path calls them.

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
- `xiiif-range`            — id, type, label, canvas-ids, sub-ranges,
  raw; v2 `ranges` id-references are linked in place.

The parser accepts both IIIF Presentation API 2.x
(`sequences`/`images`/`manifests`/`collections`) and 3.x (`items`)
shapes and falls back gracefully when either side is missing.
Multilingual `label` and `value` values are resolved via
`xiiif-preferred-languages` (default: `("en" "none" "und")`).
v2-style `sc:` type prefixes are stripped on the way in.

## Architecture

```
xiiif/
  xiiif.el            ; package entry, public commands, dispatch
  xiiif-errors.el     ; shared define-error symbols
  xiiif-api.el        ; sync + async HTTP, JSON parse, typed errors
  xiiif-http-cache.el ; on-disk ETag / Last-Modified cache
  xiiif-core.el       ; data model, tolerant v2/v3 parser
  xiiif-cache.el      ; in-memory state + persisted recent list
  xiiif-image.el      ; IIIF Image API URL builder, download
  xiiif-annotations.el; non-painting annotations fetch + parse
  xiiif-ocr.el        ; ALTO / hOCR / text sidecar fetch + extract
  xiiif-profiles.el   ; per-host HTTP/Image profiles
  xiiif-sources.el    ; named IIIF endpoint registry
  xiiif-upgrade.el    ; v2 -> v3 manifest/collection normalisation
  xiiif-search.el     ; IIIF Search API 1.0 client
  xiiif-ui.el         ; major modes & buffers
  xiiif-org.el        ; Org link / metadata insertion
  xiiif-cite.el       ; BibTeX / CSL-JSON export
  tests/              ; ERT tests
  examples/           ; sample manifest + collection fixtures
```

| Module          | Responsibility                                                      |
| --------------- | ------------------------------------------------------------------- |
| `xiiif`             | Autoloaded user commands; dispatches between manifest and collection; drives the bulk-download queue and refresh cancellation. |
| `xiiif-errors`      | `define-error' symbols (`xiiif-error`, `xiiif-network-error`, `xiiif-http-error`, `xiiif-parse-error`) shared by every layer. |
| `xiiif-url`         | URL policy: allowed schemes, link-local and cloud-metadata refusals, private hosts behind an explicit opt-in. |
| `xiiif-api`         | Sync + async HTTP over a switchable url/plz backend, JSON parse, cancellable handles, auth-source-aware request headers. |
| `xiiif-json`        | The one decoder for JSON entering from outside: xiiif's shapes, and a nesting bound checked without recursion. |
| `xiiif-fetch`       | Request scheduler: concurrency cap, per-host politeness, Retry-After, dedup, priorities, grouped cancellation. |
| `xiiif-core`        | `cl-defstruct' types, the tolerant v2/v3 parser, canvas memoisation and `xiiif-manifest-find-canvas' hash index. |
| `xiiif-cache`       | `xiiif-cache-select' unified selector, recent URL ring, debounced safe persistence. |
| `xiiif-http-cache`  | On-disk conditional (ETag/304) response cache with LRU eviction. |
| `xiiif-image-cache` | On-disk image byte cache (LRU) backing the viewer. |
| `xiiif-image`       | `xiiif-image-url', `xiiif-image-download-async', `xiiif-image-fetch-info-async', the `info.json' parser, `xiiif-image-closest-size'. |
| `xiiif-region`      | `(x y w h)' regions parsed from Media Fragments and v2/v3 selectors. |
| `xiiif-anchor`      | Canonical anchors and IIIF Content State 1.0 import/export. |
| `xiiif-osd`         | OpenSeadragon handoff: a generated local page, since OpenSeadragon is a library with no URL scheme to hand off to. |
| `xiiif-view`        | The step-by-step region viewer: state model, geometry, rendering, navigation. |
| `xiiif-annotations` | Fetch + parse non-painting annotations; orchestrates inline + external pages and AnnotationCollection pagination. |
| `xiiif-ocr`         | ALTO / hOCR / plain-text sidecar fetch + extraction; ALTO word boxes. |
| `xiiif-profiles`    | Per-host regexp-matched profiles: HTTP headers, Image API defaults, politeness interval, `auth-source' bearer lookup. |
| `xiiif-sources`     | Named IIIF endpoint registry with optional URL-encoded identifier substitution. |
| `xiiif-ui`          | Derived modes; renders every xiiif buffer. |
| `xiiif-org`         | `xiiif-org-insert-*' and `org-capture' helpers. |
| `xiiif-annot`       | Anchored note creation with a pluggable backend (Org by default). |
| `xiiif-batch`       | Prompt-free scripting surface for `emacsclient --eval'. |
| `xiiif-cite`        | `xiiif-citation-metadata', `xiiif-citation-bibtex', `xiiif-citation-csl-json'. |

## Customization

All options live under the `xiiif` group (`M-x customize-group RET xiiif`).

### HTTP and scheduling

| Option                          | Default                                          |
| ------------------------------- | ------------------------------------------------ |
| `xiiif-api-timeout`             | `30` seconds                                     |
| `xiiif-api-user-agent`          | `xiiif.el/<version> Emacs/<version>`             |
| `xiiif-api-backend`             | `auto` (use `plz` when installed, else `url`)    |
| `xiiif-api-max-body-size`       | `50 MiB` (reject larger responses)               |
| `xiiif-json-max-depth`          | `100` nested containers (reject deeper JSON)     |
| `xiiif-fetch-max-concurrent`    | `4` in-flight requests                           |
| `xiiif-fetch-host-interval`     | `0.15` s between requests to a host              |
| `xiiif-fetch-max-retries`       | `3` (429/503 with `Retry-After`)                 |
| `xiiif-http-cache-max-entries`  | `512` cached responses                           |
| `xiiif-image-cache-max-bytes`   | `200 MiB` of cached image bytes                  |
| `xiiif-search-max-pages` / `xiiif-annotations-max-pages` | `20` paginated pages   |

The `plz` backend is entirely optional and detected at runtime; with
no extra packages `xiiif` uses Emacs's built-in `url` library.

### Viewer and notes

| Option                         | Default                                           |
| ------------------------------ | ------------------------------------------------- |
| `xiiif-view-cache-size`        | `8` decoded region images per buffer              |
| `xiiif-view-prefetch`          | `t` (prefetch neighbouring regions)               |
| `xiiif-mirador-base-url`       | `https://projectmirador.org/embed/`               |
| `xiiif-default-external-viewer`| `auto` (OpenSeadragon for a zoomable canvas, else Mirador) |
| `xiiif-osd-library-url`        | OpenSeadragon 4 on jsDelivr (point it at a local copy) |
| `xiiif-annot-org-file`         | `~/.emacs.d/xiiif/notes.org`                      |
| `xiiif-annot-backend-function` | `xiiif-annot-org-store`                           |

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

### Thumbnails

| Option                          | Default      |
| ------------------------------- | ------------ |
| `xiiif-ui-show-thumbnails`      | `t`          |
| `xiiif-ui-thumbnail-size`       | `"!200,200"` |

### Recents

| Option                           | Default                          |
| -------------------------------- | -------------------------------- |
| `xiiif-history-file`             | `~/.emacs.d/xiiif-history.el`    |
| `xiiif-history-size`             | `25`                             |
| `xiiif-history-save-debounce`    | `2.0` seconds idle               |

The history file is read with `read' and whitelisted by shape, so a
tampered file cannot execute arbitrary code.  Rapid navigation is
coalesced into one write via an idle timer; `kill-emacs-hook' flushes
any pending save before Emacs exits.  Set the debounce to `0` for
pre-0.2 immediate-write behaviour.

### Per-server profiles

`xiiif-server-profiles' is an alist of `(URL-REGEXP . PLIST)`
entries.  The first regexp to match a request URL wins.

```elisp
(setq xiiif-server-profiles
      '(("\\`https://auth\\.example\\.org"
         :label "My institutional IIIF"
         :auth  (:scheme "Bearer")          ; token from auth-source
         :image (:size "!2048,2048" :format "png"))))
```

Supported plist keys:

- `:headers` — alist of `(NAME . VALUE)` appended to every matching request.
- `:auth` — plist instructing xiiif to resolve an `Authorization`
  header from `auth-source` at request time (preferred over
  embedding secrets in `:headers`).  Accepts `:host` (defaults to
  the matched URL host), `:user`, and `:scheme` (defaults to
  `"Bearer"`).  Explicit `:headers` with the same name still win.
- `:image` — Image API overrides (`:region`, `:size`, `:rotation`,
  `:quality`, `:format`) that sit between the caller's explicit
  arguments and the global `xiiif-image-default-*' customs.
- `:notes` — free text shown next to the label in diagnostics.

### Named sources

`xiiif-sources' ships a handful of GLAM endpoints (Gallica,
Wellcome, Internet Archive) used by `M-x xiiif-open-source`.  Add
your own with a `:manifest-url' `format' template (single `%s') or
a `:manifest-url-fn' of one argument.  Set `:encode-id t' to pass
the identifier through `url-hexify-string' before substitution;
the default keeps ARK-style IDs with literal slashes intact.

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
      -l tests/xiiif-cite-test.el \
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
long-term plan. Highlights so far:

- **0.2** — async fetch ✅, Collections ✅, `info.json` integration ✅,
  finer-grained HTTP error reporting ✅, structures/ranges navigation ✅,
  inline thumbnail preview ✅.
- **0.3** — bulk derivative export ✅, `org-capture` template ✅, citation
  export (BibTeX / CSL-JSON) ✅, annotation fetch ✅, OCR/ALTO sidecars ✅,
  HTTP cache ✅, v2→v3 upgrade ✅, IIIF Search ✅, Mirador handoff ✅.
- **0.4** — network v2 (scheduler, plz backend, caches) ✅, region
  viewer ✅, canonical anchors + Content State ✅, anchored notes ✅,
  batch scripting surface ✅.

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
