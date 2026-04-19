# xiiif roadmap

This roadmap reflects the state of `xiiif` at version `0.1.0`. Items
closer to the top are more likely to land first; later items are
deliberately speculative.

## 0.2 — fill in the obvious gaps

- [x] **Asynchronous fetch.** Replace `url-retrieve-synchronously`
  with a non-blocking flow that keeps Emacs responsive on slow
  manifests. *(shipped)*
- [x] **Collections.** Detect `type: "Collection"` and render a
  browser that recurses into members on demand. *(shipped)*
- [ ] **Structures / ranges.** Surface `structures` (v2) and `Range`
  hierarchies (v3) as a navigable tree in a third buffer.
- [x] **Thumbnail preview.** When `display-graphic-p', render the
  canvas thumbnail inline in the canvas detail buffer using
  `create-image`. *(shipped)*
- [x] **info.json integration.** On demand, fetch the Image API
  `info.json` and display the advertised sizes, tiles and profile
  compliance level. *(shipped)*
- [x] **Better error surfaces.** Distinguish 401/403/404 from
  transport errors with tailored messages, and remember the offending
  URL for a one-key retry. *(shipped)*

## 0.3 — DH / GLAM conveniences

- [x] **Bulk derivative export.** Mark canvases in the browser and
  dump all selected derivatives to a directory with a uniform naming
  scheme. *(shipped)*
- **Org-capture template.** Ship an `org-capture` template that
  produces a standard note from a manifest, ready to drop in a
  research journal.
- [x] **Citation export.** Generate BibTeX / CSL-JSON entries from
  manifest metadata (title, date, rights, provider). *(shipped)*
- **Annotation fetch.** Follow `AnnotationCollection` links from a
  canvas and show annotations in a read-only buffer.
- [x] **transcript/ALTO sidecars.** When a canvas's `seeAlso' links
  OCR (ALTO / hOCR / plain text), fetch it and display extracted
  text in a dedicated sidecar buffer. *(shipped)*

## 0.4 — extensibility

- [x] **Source registry.** An alist of named IIIF endpoints
  (Gallica, Wellcome, Internet Archive by default) with identifier
  prompts and URL templates.  `xiiif-open-source' picks one and
  dispatches through `xiiif-open-manifest'. *(shipped)*
- **Hooks.** `xiiif-after-load-manifest-hook`,
  `xiiif-canvas-format-functions` and friends so users can extend the
  UI without patching the package.
- **Per-server profiles.** A `xiiif-server-profile` record that can
  override default region/size/format and authentication headers.

## Later / uncertain

- **Presentation API 2 → 3 normalization.** Beyond the current
  tolerant parser, an explicit `xiiif-upgrade-manifest` that returns
  a canonical v3-shaped alist.
- **IIIF Search API 1.0.** Query search endpoints exposed on a
  manifest and display hits as navigable results.
- **Transcription editor.** Write Web Annotation JSON back to a
  target server (probably gated behind a deliberate switch; writes
  are out of scope for 0.x).
- **Mirador handoff.** A single command that opens the current
  manifest in an external Mirador installation for users who do want
  a GUI once they have triaged the manifest in Emacs.

Anything not on this list is fair game to propose. The rule is:
if it earns its keep in a real workflow without dragging in
dependencies, it is welcome.
