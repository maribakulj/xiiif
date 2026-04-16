# xiiif — an Emacs-native IIIF workbench

`xiiif` is an Emacs package for exploring [IIIF](https://iiif.io) resources
from inside Emacs. It is built for people who already live in Emacs and
work with cultural-heritage and research collections: GLAM practitioners,
librarians, curators, DH scholars, and anyone who needs to triage
manifests, pull derivatives, and paste clean references into notes.

`xiiif` is **not** a graphical viewer like Mirador or Universal Viewer.
It is a text-first, structure-first, scriptable Emacs tool:

- Open a IIIF Presentation Manifest by URL.
- Inspect it in a readable overview buffer — label, summary, metadata, canvas count.
- Browse canvases in a sortable tabulated list.
- Drill into a canvas to see its image-service base and a ready-to-use Image API URL.
- Copy or download derivatives with the IIIF Image API URL scheme.
- Drop links and metadata blocks straight into Org.

The raw JSON is still one keystroke away when you need it — but you are
not forced to stare at it as the default experience.

## Why this might be useful

Most IIIF tooling targets web viewers and end-user presentation. Research
and GLAM workflows often want the opposite: the ability to enumerate,
script, annotate, and reference IIIF resources without leaving a
text-based environment. `xiiif` is aimed at that side of the ecosystem.

Typical use cases:

- Quickly surveying an unfamiliar manifest — is it v2 or v3? How many
  canvases? Which ones expose a IIIF Image API service?
- Building a research note in Org that cites specific folios with
  properly formed manifest and image URLs.
- Pulling a specific thumbnail, tile, or derivative for inclusion in a
  paper, slide, or dataset.
- Scripting bulk extraction with Emacs Lisp — e.g. `mapcar`-ing over
  canvases to dump `info.json` URLs for downstream tools.

## Status

**Version:** `0.1.0` — first serious cut.
**Stability:** MVP. APIs may change while the package stabilizes.
**Emacs:** 27.1 or newer (uses `url.el`, `json.el`, `tabulated-list`, `cl-lib`).
**Dependencies:** none outside built-in Emacs.

## Installation

### With `use-package` and a local clone

```elisp
(use-package xiiif
  :load-path "~/src/xiiif"
  :commands (xiiif-open-manifest
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

## Usage

Open any IIIF Presentation Manifest URL:

```
M-x xiiif-open-manifest RET https://example.org/iiif/book1/manifest RET
```

You land in `*XIIIF Manifest*` with a compact overview. From there:

- `RET` or `c` — open the canvas browser
- `y` — copy the manifest URL
- `i` — insert an Org link at the next Org position
- `J` — inspect the raw JSON
- `g` — re-fetch the manifest
- `q` — bury the buffer

The canvas browser (`*XIIIF Canvases*`) is a `tabulated-list-mode`
buffer. On any row:

- `RET` / `o` — open that canvas in the detail buffer
- `y` — copy the default Image API URL
- `d` — download a derivative (prompts for size, format, destination)
- `i` — insert an Org link for the canvas
- `g` — refresh
- `q` — bury

The canvas detail buffer (`*XIIIF Canvas*`) shows the canvas id, size,
the painting image URL, the detected IIIF Image API service and its
`info.json` URL, and a ready-to-use default derivative URL.

## Commands

| Command                     | What it does                                                 |
| --------------------------- | ------------------------------------------------------------ |
| `xiiif-open-manifest`       | Prompt for a URL, fetch, parse, show the overview buffer.    |
| `xiiif-browse-canvases`     | Open the canvas browser for the current manifest.            |
| `xiiif-open-canvas`         | Open the canvas at point or the current canvas.              |
| `xiiif-copy-image-url`      | Copy an Image API URL. `C-u` prompts for all parameters.     |
| `xiiif-download-image`      | Download a derivative for the current/contextual canvas.     |
| `xiiif-insert-org-link`     | Insert a manifest, canvas, image link, or metadata block.    |
| `xiiif-copy-manifest-url`   | Copy the current manifest URL to the kill ring.              |
| `xiiif-show-raw-json`       | Open the raw JSON for the current context.                   |
| `xiiif-refresh`             | Re-fetch the current manifest and redisplay.                 |
| `xiiif-open-recent`         | Pick from recently opened manifest URLs.                     |

## IIIF Image API URLs

`xiiif-image-url` builds URLs of the form:

```
{base}/{region}/{size}/{rotation}/{quality}.{format}
```

Defaults are: `full` / `max` / `0` / `default` / `jpg`. They are
customizable via `xiiif-image-default-*`. In Lisp:

```elisp
(xiiif-image-url canvas
                 :region "0,0,1024,1024"
                 :size   "!512,512"
                 :rotation "0"
                 :quality "gray"
                 :format  "png")
```

`xiiif-image-info-url` returns the `info.json` endpoint of the service.

## Org integration

`xiiif-insert-org-link` interactively picks between:

- `manifest` — an Org link to the manifest URL, labeled with its title.
- `canvas`   — an Org link to the canvas id, labeled with the canvas title.
- `image`    — an Org link to the default image-API derivative.
- `metadata` — a small `#+begin_xiiif / #+end_xiiif` block with title,
  manifest URL, canvas label, canvas id, image URL, and a `:notes:` line.

These are plain Org links and plain block elements — they do not require
any Org extensions to work.

## Data model

Internally, `xiiif` parses every manifest into three `cl-defstruct`
types:

- `xiiif-manifest` — url, id, type, label, summary, metadata, thumbnail,
  items, raw.
- `xiiif-canvas`   — id, type, label, width, height, thumbnail,
  image-url, image-service, raw.
- `xiiif-image-service` — id (base URL), type, profile.

The parser accepts both IIIF Presentation API 2.x (`sequences`/`images`)
and 3.x (`items`/`AnnotationPage`) shapes and falls back gracefully when
either side is missing. Multilingual `label` values are resolved via
`xiiif-preferred-languages` (default: `("en" "none" "und")`).

## Customization

All options live under the `xiiif` group:

- `xiiif-api-timeout` — HTTP timeout in seconds (default 30).
- `xiiif-preferred-languages` — language-tag preference list.
- `xiiif-image-default-region`, `-size`, `-rotation`, `-quality`, `-format`.
- `xiiif-image-download-directory` — default destination for downloads.
- `xiiif-history-file`, `xiiif-history-size` — recent-manifests persistence.

## Development

Tests use ERT and require no external package.

```
cd xiiif
emacs -batch -L . -L tests \
      -l tests/xiiif-api-test.el \
      -l tests/xiiif-core-test.el \
      -l tests/xiiif-image-test.el \
      -f ert-run-tests-batch-and-exit
```

A tiny v3 manifest lives in `examples/sample-manifest.json`; the tests
parse it as their main fixture.

## Roadmap

See [`ROADMAP.md`](ROADMAP.md) for the short-, medium-, and long-term
plan. In short: better manifest introspection, a few asynchronous
operations, first-class support for IIIF Collections, and a light
thumbnail preview via Emacs image-mode.

## Contributing

Contributions are welcome. The code is deliberately small and modular;
please keep additions:

- built on Emacs built-ins wherever possible,
- independent of any one IIIF server's quirks,
- covered by at least a small ERT test when they touch parsing or URL
  construction,
- documented with a real docstring.

Bug reports with a minimal reproducing manifest are the most useful
kind of issue.

## License

GPL-3.0-or-later. See [`LICENSE`](LICENSE).
