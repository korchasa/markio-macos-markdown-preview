---
date: 2026-06-17
status: in progress
implements:
  - FR-OPEN
  - FR-GFM
  - FR-MERMAID
  - FR-HIGHLIGHT
  - FR-LINE-WIDTH
  - FR-LIVE-RELOAD
  - FR-APPEARANCE
  - FR-OFFLINE
tags: [implementation, swift, webkit]
related_tasks:
  - "[Init: project context & first scaffold](init-project-context.md)"
---
# Implement Markio app

## Goal

Turn the documented design into a working native macOS Markdown viewer: native
SwiftUI/AppKit shell + confined offline `WKWebView` rendering GFM, Mermaid, and
syntax highlighting, with an on-screen line-width control.

## Overview

### Context

Init session produced docs only (SRS/SDS/AGENTS). This session builds the app
per the SDS architecture. Vendored web assets fetched once from jsDelivr and
committed; runtime stays offline.

### Current State

Implemented. SwiftPM executable `Markio` + test target. `make check` green.

### Constraints

- Native shell mandatory; web engine confined to content rendering.
- Offline: all JS/CSS vendored under `Sources/Markio/Resources/vendor`.
- Read-only previewer; no editing/export/plugins.

## Definition of Done

- [x] FR-GFM: tables + task lists render
  - Test: `Tests/MarkioTests/RenderTests.swift::testGFMTableAndTaskList`
  - Evidence: `make check`
- [x] FR-MERMAID: fenced `mermaid` blocks render as SVG
  - Test: `Tests/MarkioTests/RenderTests.swift::testMermaidFlowchartRenders`
  - Evidence: `make check`
- [x] FR-HIGHLIGHT: code blocks syntax-highlighted
  - Test: `Tests/MarkioTests/RenderTests.swift::testCodeBlockHighlighted`
  - Evidence: `make check`
- [x] FR-LINE-WIDTH: width reflows live and persists
  - Test: `Tests/MarkioTests/LineWidthTests.swift::testWidthPersistsAndReflows`
  - Evidence: `make check`
- [x] FR-LIVE-RELOAD: external edits trigger reload
  - Test: `Tests/MarkioTests/WatcherTests.swift::testReloadsOnFileChange`
  - Evidence: `make check`
- [x] FR-OFFLINE: shell has no external URLs; links externalized
  - Test: `Tests/MarkioTests/OfflineTests.swift::testNoNetworkRequests`
  - Evidence: `make check`
- [ ] FR-OPEN: open via dialog / drop / Finder (manual)
  - Test: `manual — maintainer — documents/checklists/open.md`
  - Evidence: manual checklist
- [ ] FR-APPEARANCE: follow system light/dark (manual)
  - Test: `manual — maintainer — documents/checklists/appearance.md`
  - Evidence: manual checklist

## Solution

- **Package**: SwiftPM executable target `Markio` (macOS 14, Swift 6 mode) +
  `MarkioTests`. Resources `template.html` + `vendor/` copied flat to bundle
  root so the page's relative URLs resolve.
- **Vendored assets** (`Resources/vendor`): markdown-it 14 (+ task-lists plugin,
  wrapped as a browser global), highlight.js 11 (common langs) with github
  light/dark themes, mermaid 11 (UMD), github-markdown-css 5.
- **Shell (native)**: `MarkioApp` (SwiftUI `App`) + `AppDelegate` (Finder
  opens, activation), `ContentView` (preview + toolbar width slider),
  `AppModel` (state, open/drop/reload wiring).
- **Web bridge**: `PreviewController` owns the `WKWebView`; `loadTemplate`,
  `render`, `setContentWidth`, `setDark` via `callAsyncJavaScript`; navigation
  delegate uses pure `LinkPolicy` to confine to `file:` and externalize web links.
- **Logic types** (testable): `FileLoader`, `FileWatcher` (FSEvents-style
  `DispatchSource`, atomic-save re-arm, debounce), `ContentWidthStore`
  (UserDefaults + clamp), `ResourceLocator`.
- **Tooling**: `Makefile` (`check` = build + comment-scan + `swift format` lint +
  `swift test`); `.swift-format` (4-space, 100 cols).

### Key decisions surfaced

- Deployment target raised macOS 13 → 14 to use modern SwiftUI `onChange`
  cleanly and keep a zero-warning build.
- markdown-it configured `html:false` (read-only viewer drops raw inline HTML
  for safety); GFM tables/strikethrough/linkify on; mermaid `securityLevel:strict`.
