---
date: 2026-07-14
status: done
implements:
  - FR-MERMAID-ZOOM
tags: [mermaid, zoom, clipboard, webview]
related_tasks:
  - [code-copy-button](code-copy-button.md)
---
# Mermaid zoom & copy [ANC:task:2026-07-mermaid-zoom-copy]

## Goal

Wide Mermaid flowcharts are unreadable at reading-column width — the one class of
content where the fixed column actively hurts. Backlog item 10 (final item of the
daily-use wave): click a rendered diagram → zoom/pan overlay; "Copy PNG" puts a
raster of the diagram on the clipboard (feeding diagrams into chats, docs, slides).
Read.md has tap-to-zoom on iOS; no desktop competitor has diagram copy.

## Overview

### Context

- Backlog: `daily-use-feature-backlog.md` item 10 — "click diagram → zoom/pan; 'copy as PNG'".
- Mermaid renders via vendored `mermaid.min.js`, `securityLevel: 'strict'`,
  `startOnLoad: false`; `render()` awaits `mermaid.run` on `pre.mermaid` nodes
  (template.html ~629–665).
- Clipboard pattern exists: page posts raw text over one-way `markioCopy` handler;
  `PreviewController.handleCopyMessage` writes `NSPasteboard` (injected pasteboard
  in tests — `CodeCopyTests.makeCopyPreview`). In-page `navigator.clipboard` is
  unreliable in the sandboxed `WKWebView`.
- Find walker skips page-UI via parent class `markio-code-ui` (template.html ~986)
  and walks only `#content` — UI outside `#content` is invisible to find.
- **Rasterization constraint (inspected, not assumed):** with `securityLevel:
  'strict'` mermaid keeps `htmlLabels` (labels live in `<foreignObject>`;
  `mermaid.min.js`: `htmlLabels!==!1){let r=e.securityLevel;r==="antiscript"||r==="strict"?…`).
  WebKit does not paint `foreignObject` content when an SVG is loaded as an image
  for canvas drawing — naive "serialize displayed SVG → canvas" produces PNGs with
  blank node labels. Deterministic offline path: re-render the diagram source
  off-screen with `htmlLabels: false` so labels are plain SVG `<text>`, then
  canvas → PNG. (Implementation note: a per-render `%%{init: …}%%` directive
  did NOT disable htmlLabels in mermaid 11.6 — the shipped path swaps the
  global config via `mermaid.initialize` for one render and restores it with
  `initMermaid()`, the same mechanism the theme switch uses.)
- Quick Look extension renders the same template but registers no message
  handlers; the page already guards every `window.webkit.messageHandlers.*` post,
  so the copy button degrades to a no-op there (same as `markioCopy`).
- `Snapshot.swift` scrolls to a mermaid diagram but never clicks — overlay cannot
  appear in marketing shots.

### Current State

- `template.html`: mermaid fences → `pre.mermaid` → SVG in place; no click
  affordance, no copy UI on diagrams (explicitly excluded from FR-CODE-COPY).
- `PreviewController`: five one-way page→native channels (`markioTOC`,
  `markioCopy`, `markioScroll`, `markioLink`, `markioSyncScroll`); SRS §5 states
  "five one-way pasteboard/message handlers" — count changes with a new channel.
- Tests drive the real `WKWebView` (`PreviewTestSupport`, `CodeCopyTests` pattern:
  `evaluate(...)` clicks + expectation on the native callback + injected pasteboard).

### Constraints

- Native first; minimal: no export-to-file pipeline, no settings — overlay + one
  copy affordance only. Web engine stays an implementation detail of content
  rendering; clipboard write is native.
- Offline: no CDN, no new vendored dependencies (canvas + XMLSerializer are
  browser-native).
- Do NOT edit the backlog file; do NOT touch other backlog items.
- Swift 6 strict concurrency; zero-warning baseline; `make check` green.
- Find must not match overlay/button UI text; live reload (re-render) must not
  leave a stale overlay open.

### Affected Surface

Scout output (verbatim):

```
- Sources/MarkioEngine/Resources/template.html — Mermaid diagram click interception, zoom overlay UI rendering, SVG→PNG canvas conversion, new message handler post for PNG data (lines ~600-750, near code copy delegation pattern)
- Sources/Markio/PreviewController.swift — new `WKScriptMessageHandler` for Mermaid copy (PNG data from page), similar to `copyMessageProxy` at lines 41–61; `handleMermaidCopyMessage` handler at ~lines 321–330
- Sources/Markio/DocumentModel.swift — may need zoom overlay state per window if native, or bridge callbacks for page-driven zoom
- Sources/Markio/ContentView.swift — may add native zoom overlay/lightbox UI (like find bar overlay at lines 27–29, 71–126), or delegate entirely to page
- Tests/MarkioTests/RenderTests.swift — Mermaid copy test addition (pattern at line 212 for mermaid malformed handling; new tests for click interception, PNG copy, zoom state)
- Tests/MarkioTests/CodeCopyTests.swift — mirror/parallel: MermaidCopyTests.swift or extended as MermaidZoomCopyTests.swift for PNG clipboard, zoom open/close, zoom gesture handling
- Sources/Markio/Snapshot.swift — screenshot flow uses Mermaid diagrams (lines 64–68); zoom overlay must not appear in snapshots or be closed before capture
- Sources/MarkioQuickLook/QuickLookRenderHost.swift — Quick Look extension also renders Mermaid; may need parity handling if zoom is native (currently render-only, no message handlers)
- documents/requirements.md — new FR (e.g. FR-MERMAID-ZOOM or FR-MERMAID-COPY) or enhance §3.3 FR-MERMAID; acceptance tests must pass
- documents/design.md — new section or expansion of §3.6 Vendored web bundle / Mermaid rule; describe zoom overlay interactions, PNG conversion, message handler contract
- Sources/Markio/FindBarControls.swift or ContentView.swift find implementation — ensure find doesn't match inside new Mermaid zoom overlay UI decoration (parallel to code-copy exclusion at SDS §3.6 copy-button rule)
- Sources/MarkioEngine/Resources/template.html CSS (lines 11–200) — new styles for zoom overlay container, dismiss button, pan/zoom controls, backdrop; SVG handling for Mermaid-specific interactivity
- Package.swift or Makefile — no new dependencies (canvas→PNG and SVG interop are browser-native); verify vendored mermaid.js supports diagram export or selection
- Sources/Markio/PreviewController.swift — new bridge method (e.g. `getMermaidSVG()`) if PNG conversion delegates to native, or purely page-driven via canvas blob → message handler
- Tests/MarkioTests/PreviewTestSupport.swift — helper to evaluate JavaScript on Mermaid diagrams for zoom test automation (pattern at CodeCopyTests line 35–36)
```

Union dispositions:

- `Sources/MarkioEngine/Resources/template.html` (JS + CSS: click/zoom overlay, hover UI, rasterization, handler post) — covered-by DoD items 1–3
- `Sources/Markio/PreviewController.swift` (new `markioCopyImage` proxy + handler) — covered-by DoD item 2
- `Sources/Markio/DocumentModel.swift` — not affected — overlay and zoom state are page-owned; no native window state (Sources/Markio/DocumentModel.swift holds file/TOC/find state only, no render UI state)
- `Sources/Markio/ContentView.swift` — not affected — no native overlay chrome added; the lightbox is content rendering, owned by the web view per architecture (CLAUDE.md Architecture)
- `Tests/MarkioTests/` new `MermaidZoomTests.swift` — covered-by DoD items 1–4
- `Tests/MarkioTests/RenderTests.swift` — not affected — existing mermaid render tests unchanged; new behavior tested in a dedicated suite
- `Sources/Markio/Snapshot.swift` — not affected — snapshot flow never clicks a diagram (Snapshot.swift:64–68 only `scrollIntoView`), overlay opens on click only
- `Sources/MarkioQuickLook/QuickLookRenderHost.swift` — not affected — extension registers no message handlers; page guards every `messageHandlers.*` post (template.html markioCopy pattern), copy degrades to no-op; zoom overlay working there is acceptable render-only behavior
- `documents/requirements.md` — covered-by DoD item 5 (new FR-MERMAID-ZOOM section + §5 Interfaces handler count 5→6)
- `documents/design.md` — covered-by DoD item 5 (SDS §3.6 mermaid interaction contract)
- Find interplay (walker in template.html, not FindBarControls) — covered-by DoD item 4
- `Package.swift` / `Makefile` — not affected — no new dependencies, no new targets or build steps
- `Tests/MarkioTests/PreviewTestSupport.swift` — covered-by DoD items 1–4 (extend only if a shared helper is actually needed)

## Definition of Done

- [x] FR-MERMAID-ZOOM: clicking a rendered Mermaid diagram opens an in-page overlay showing the diagram with pan (drag) and zoom (buttons + scroll wheel); Esc, the close button, and a backdrop click close it
  - Test: `Tests/MarkioTests/MermaidZoomTests.swift::testClickOpensZoomOverlay`, `::testZoomAndPanTransform`, `::testOverlayCloses`
  - Evidence: `make test ARGS="--filter MermaidZoomTests"`
- [x] FR-MERMAID-ZOOM: "Copy PNG" (hover button on the diagram and a button in the overlay) places a raster PNG of the diagram on the system clipboard via a new one-way `markioCopyImage` page→native channel (base64 PNG → `NSPasteboard` `.png`); the PNG is non-blank (pixel check: more than one distinct color) and both buttons work
  - Test: `Tests/MarkioTests/MermaidZoomTests.swift::testCopyPNGWritesRasterToPasteboard` (hover button + pixel check), `::testOverlayCopyPNGButtonCopies` (overlay button)
  - Evidence: `make test ARGS="--filter MermaidZoomTests"`
- [x] FR-MERMAID-ZOOM: the rasterization path produces label-bearing SVG (no `foreignObject`) so PNG text survives WebKit's SVG-as-image limitation
  - Test: `Tests/MarkioTests/MermaidZoomTests.swift::testRasterSVGCarriesTextLabelsNoForeignObject`
  - Evidence: `make test ARGS="--filter MermaidZoomTests"`
- [x] FR-MERMAID-ZOOM: find never matches the diagram UI text ("Copy PNG", overlay controls); a re-render (live reload) closes any open overlay
  - Test: `Tests/MarkioTests/MermaidZoomTests.swift::testFindSkipsMermaidUI`, `::testRerenderClosesOverlay`
  - Evidence: `make test ARGS="--filter MermaidZoomTests"`
- [x] FR-MERMAID-ZOOM: SRS gains section FR-MERMAID-ZOOM with filled `**Acceptance:**` (+ §5 Interfaces channel count updated); SDS documents the overlay + rasterization + `markioCopyImage` contract; index row added
  - Test: SRS/SDS sections exist with `[ANC:fr:mermaid-zoom]` anchor and a runnable acceptance reference; index row present
  - Evidence: `grep -q "ANC:fr:mermaid-zoom" documents/requirements.md && grep -q "MermaidZoomTests" documents/requirements.md && grep -q "markioCopyImage" documents/design.md && grep -q "fr:mermaid-zoom" documents/index.md`
- [x] `make check` green on the final state
  - Test: full project check
  - Evidence: `make check`

## Solution

Selected variant: **B — in-page lightbox for zoom/pan; Copy PNG via off-screen
re-render with `htmlLabels: false` and a new one-way `markioCopyImage` channel.**

### Files

- `Sources/MarkioEngine/Resources/template.html` — CSS + JS: diagram hover UI,
  zoom overlay, rasterization pipeline, `markioCopyImage` post.
- `Sources/Markio/PreviewController.swift` — `copyImageMessageProxy`,
  `handleCopyImageMessage`, `onImageCopied` test callback.
- `Tests/MarkioTests/MermaidZoomTests.swift` — new suite (6 tests, DoD items 1–4).
- `documents/requirements.md` — new §3.22 FR-MERMAID-ZOOM `[ANC:fr:mermaid-zoom]`;
  §5 Interfaces: five → six one-way handlers.
- `documents/design.md` — SDS mermaid-interaction contract (overlay, raster path,
  `markioCopyImage`).
- `documents/index.md` — FR row.

### Page (template.html)

1. **Decoration** — in `render()` after `mermaid.run`, call `decorateMermaid()`:
   for each `pre.mermaid` that contains an `svg`, wrap in `div.markio-mermaid`
   (position: relative), attach `div.markio-code-ui` (same class as code-copy →
   find-walker skip is inherited) with one `button.markio-mermaid-copy` "Copy PNG".
   Store the diagram source text on the wrapper (`data` not needed — keep the
   original `pre.mermaid` textContent? No: mermaid.run replaces text with SVG.
   Save source before run: render() already has the fence content — capture
   `node.textContent` into `node.dataset.markioSrc` before `mermaid.run`).
   Rebuilt every render (live-reload safe).
2. **Zoom overlay** — a singleton `div#markio-zoom` appended to `document.body`
   (outside `#content` → invisible to find), hidden by default. Click on the
   rendered SVG (delegated listener on `#content`, ignoring clicks on the copy
   button) opens it: clone the displayed SVG into the overlay stage, reset
   `scale=1`/`tx=ty=0`, apply via CSS `transform`. Controls (top-right):
   `+`, `−`, `⟲` (reset), `Copy PNG`, `✕`. Wheel → zoom around cursor;
   drag → pan; Esc / backdrop click / ✕ → close. `render()` closes the overlay
   if open (stale content).
3. **Rasterization** — `copyMermaidPNG(src)`:
   a. `markioRasterSVG(src)`: swap the global mermaid config to
      `htmlLabels: false` (top-level + flowchart/class/state) via
      `mermaid.initialize`, `mermaid.render(id, src)` off-screen, restore with
      `initMermaid()` in `finally` → SVG string with `<text>` labels (no
      `foreignObject` elements). (A per-render `%%{init}%%` directive was the
      original plan but does not disable htmlLabels in mermaid 11.6.)
   b. Parse width/height from the SVG viewBox (fallback: width/height attrs),
      scale ×2 (clamp longest side ≤ 8192 px).
   c. `new Image()` from `data:image/svg+xml` URL → draw to canvas. Decision:
      fill the canvas with the page's computed background color so pasted PNGs
      are readable on any surface; matches what the user sees.
   d. `canvas.toDataURL('image/png')` → strip prefix → post base64 string to
      `window.webkit.messageHandlers.markioCopyImage` (guarded — headless/QL
      no-op). Errors logged via `console.warn`, never thrown.
   e. Button flashes "Copied" ~1.5 s (optimistic, same as code-copy).

### Native (PreviewController.swift)

4. Register sixth one-way proxy `markioCopyImage` in `init`;
   `handleCopyImageMessage`: guard name + non-empty `String` body +
   `Data(base64Encoded:)` succeeds → `pasteboard.clearContents()` +
   `setData(_, forType: .png)`; log + return on failure (fail fast, no silent
   drop); fire `onImageCopied?(data)` for tests. `// [REF:fr:mermaid-zoom]`.

### TDD order (RED → GREEN per DoD item)

1. `testClickOpensZoomOverlay` — render flowchart, JS-click the SVG, assert
   `#markio-zoom` visible and contains a cloned `svg`.
2. `testZoomAndPanTransform` — click `+` button twice / simulate wheel, assert
   stage transform scale grows; drag (dispatch pointer events) changes translate.
3. `testOverlayCloses` — Esc closes; re-open; backdrop click closes; re-open;
   ✕ closes.
4. `testRerenderClosesOverlay` — open overlay, `render()` again, assert hidden.
5. `testRasterSVGCarriesTextLabelsNoForeignObject` — call the page's raster-prep
   step for the flowchart source, assert produced SVG string has `<text>` and no
   `<foreignObject>`.
6. `testCopyPNGWritesRasterToPasteboard` — injected pasteboard, click hover
   "Copy PNG", await `onImageCopied`, assert pasteboard `.png` data decodes to
   `NSBitmapImageRep` with positive pixel size AND more than one distinct pixel
   color (non-blank raster — end-to-end guard against the foreignObject
   blank-canvas failure mode).
6a. `testOverlayCopyPNGButtonCopies` — open the overlay, click its "Copy PNG"
   button, await `onImageCopied`, assert `.png` data lands on the pasteboard.
7. `testFindSkipsMermaidUI` — search "Copy PNG" → 0 matches (hover UI); with
   overlay open search "reset"/control labels → 0 matches (overlay outside
   `#content`).

### Docs

8. SRS: add FR-MERMAID-ZOOM section (Desc/Scenario/Acceptance/Status, Tasks
   back-pointer `[REF:task:2026-07-mermaid-zoom-copy | mermaid-zoom-copy]`);
   update §4 **Sec:**/§5 **Proto** "five one-way" → "six one-way" handler count.
   SDS: extend the mermaid/copy component section with the overlay + raster
   contract. Index: FR row. README: one feature bullet (user-facing).

### Verification

- `make fmt` (long inline JS strings in tests) → `make check` (build,
  comment-scan, format lint, full tests).
- `make test ARGS="--filter MermaidZoomTests"` for the suite alone.

### Error handling

- Raster failures (mermaid.render throws on malformed source, image decode
  fails, canvas too large) → `console.warn`, button flashes "Failed" (~1.5 s),
  no native post. Native side: invalid base64 / empty body → log error, no
  pasteboard write.
- All `messageHandlers` posts guarded for headless/Quick Look contexts.

## Follow-ups

_(none yet)_
