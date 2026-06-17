---
date: 2026-06-17
status: done
tags: [init, scaffolding]
related_tasks:
  - "[Implement Markview app](implement-markview-app.md)"
---
# Init: project context & first scaffold

## Goal

Capture the discovered context of the Markview repo at init time and define the first implementation slice, so future sessions can start from a documented baseline rather than re-deriving the architecture.

## Overview

### Context

Native macOS Markdown previewer. Product brief: GFM + Mermaid support; priorities (in order) nativeness → minimalism → UX; read-only preview only; line width adjustable directly on the preview screen. Architecture decided at init: native AppKit/SwiftUI shell + confined offline `WKWebView` for content (Mermaid requires a JS engine). Tooling: SwiftPM + `Makefile`. See `AGENTS.md`, `documents/requirements.md` (SRS), `documents/design.md` (SDS).

### Current State

Repo contains only an empty source skeleton and a stale SwiftPM build cache — no application code, no manifest:

```
Sources/Markview/Resources/vendor/   (empty)
.build/                              (stale cache from a prior build; gitignored)
AGENTS.md, CLAUDE.md -> AGENTS.md
documents/requirements.md, documents/design.md
```

No `Package.swift`, no `.swift` sources, no `Makefile`, no commits yet (`main` has no history). The `.build` cache references WebKit/JavaScriptCore/SwiftUI and a `Markview_Markview.bundle/template.html`, confirming the intended hybrid design.

### Constraints

- macOS only; native shell mandatory (web engine confined to content rendering).
- Offline: vendor all JS/CSS under `Sources/Markview/Resources/vendor`; no network/CDN.
- Read-only previewer — no editing/export/plugins.
- Tooling = SwiftPM + `Makefile` (no Deno / foreign toolchain).
- This init delivered documentation only — no application code was written.

## Definition of Done

Each item below is the entry point for a follow-up `plan`; acceptance references are declared in the SRS FRs they implement.

- [x] FR-OPEN: SwiftPM `Package.swift` + executable target `Markview` builds via `make check`
  - Test: `Tests/MarkviewTests/RenderTests.swift::testGFMTableAndTaskList`
  - Evidence: `make check`
- [x] FR-LINE-WIDTH: line-width control reflows content and persists
  - Test: `Tests/MarkviewTests/LineWidthTests.swift::testWidthPersistsAndReflows`
  - Evidence: `make test ARGS="--filter LineWidthTests"`

## Solution

[To be filled after a `plan` selects the first implementation slice. Suggested first slice: `Package.swift` + minimal window hosting a `WKWebView` that renders a hardcoded GFM doc from `template.html` + vendored parser — proves the hybrid pipeline end-to-end before adding watcher/width/mermaid.]
