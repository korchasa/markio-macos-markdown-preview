---
date: 2026-06-18
status: in progress
implements:
  - FR-MULTIDOC
  - FR-OPEN
tags: [architecture, app-shell]
---
# Window-per-document (DocumentGroup)

## Goal

Opening a Markdown file must open a **new window**, not replace the document in the current one. Move from a single shared app model to a native document-based app so each file is its own window, with system-provided Open Recent, window tabbing, and state restoration.

## Overview

### Context

User directive: "приложение на открытии должно открывать новое окно, а не заменять документ." Chosen approach (Variant 2): full macOS document app via SwiftUI `DocumentGroup`, accepting the trade-off of no welcome screen and a system Open panel on fresh launch.

### Current State

- `MarkioApp` = `WindowGroup` + one `@StateObject AppModel` (singleton) + `AppDelegate` bridging Finder/argv opens into that single model.
- `AppModel.open(url)` mutates the single window's document in place (replace, not new window).
- `ContentView` reads the shared model; `onDrop` calls `model.handleDrop` → in-place replace.
- Welcome content rendered when no file (`AppModel.welcome`).

### Constraints

- Native first; `DocumentGroup`/AppKit over custom window plumbing.
- Read-only viewer: document never writable, never dirty, no Save.
- Preserve offline `WKWebView`, line-width control, live reload, appearance follow.
- macOS 14, Swift 6 strict concurrency, zero warnings.

## Definition of Done

- [ ] FR-MULTIDOC: opening a second file opens a second independent window; existing windows are untouched.
  - Test: `manual — maintainer — documents/checklists/window-per-doc.md`
  - Evidence: `make check` green + manual checklist (manual pass pending maintainer)
- [x] FR-MULTIDOC: `MarkdownDocument` decodes UTF-8 file contents and fails fast on non-UTF-8.
  - Test: `Tests/MarkioTests/DocumentReadTests.swift::testDecodesUTF8` / `::testRejectsInvalidUTF8`
  - Evidence: `make test ARGS="--filter DocumentReadTests"` (2 passed)
- [x] FR-LIVE-RELOAD preserved per-window: external edit refreshes that window.
  - Test: `Tests/MarkioTests/LiveReloadTests.swift::testPreviewUpdatesWhenFileChanges`
  - Evidence: `make test ARGS="--filter LiveReloadTests"` (passed)

## Solution

1. Add `MarkdownDocument: FileDocument` (read-only): `text: String`; `readableContentTypes = [md, markdown, plainText]`; `writableContentTypes = []`; `init(data:)` UTF-8 decode (throws on invalid); `init(configuration:)`; `fileWrapper` throws (read-only).
2. Rename `AppModel` → `DocumentModel`, scoped per window. Replace `open(url)`/`bootstrap()` with `start(text:url:)`. Drop welcome path, `presentOpenPanel`, `handleDrop`, `documentTitle`, `currentURL` re-targeting. Keep preview/watcher/width/appearance. Live reload re-reads `url` from disk.
3. `MarkioApp`: `DocumentGroup(viewing: MarkdownDocument.self) { config in ContentView(document:config.document, fileURL:config.fileURL) }`. Drop custom "Open…" command (DocumentGroup provides File ▸ Open / Open Recent).
4. `ContentView`: own `@StateObject DocumentModel`; `.task { start(...) }`; `onDrop` → `@Environment(\.openDocument)` opens a NEW window.
5. `AppDelegate`: slim — only argv handling for `make dev ARGS=...` via `NSDocumentController.shared.openDocument(withContentsOf:)`. Remove `application(open:)` (DocumentGroup handles Finder/Dock/`open`).
6. Update SRS (FR-MULTIDOC, FR-OPEN, §2/§4/§5), SDS (§2 diagram, §3 components, §7), checklist, README, CLAUDE.md architecture note.

## Follow-ups (same session)

- **No window tabs:** `NSWindow.allowsAutomaticWindowTabbing = false` in `AppDelegate` — strictly one window per document, never merged into tabs.
- **Full-path title:** `WindowTitleSetter`/`TitlePinningView` KVO-pins `NSWindow.title` to the document's full path (DocumentGroup re-syncs the file name async, so a one-shot set loses). Trade-off: clears `representedURL` → drops the proxy icon (path > icon, accepted).
- **`.app` packaging:** `packaging/Info.plist` + `make app`/`make prod` build `Markio.app` (under `.build/`) → single instance, all opens become windows in one process, Finder "Open With" works. `make dev` stays the raw binary. Verified live: one PID, two windows, full-path titles.

