# SRS

## 1. Intro
- **Desc:** Markview — native macOS app that previews Markdown files (read-only). Renders GFM + Mermaid with a minimal, native, distraction-free UX. One in-screen reading control: line width.
- **Def/Abbr:** GFM = GitHub Flavored Markdown. WKWebView = WebKit web view. SPM = Swift Package Manager. FSEvents = macOS filesystem event API.

## 2. General
- **Context:** Document-based macOS viewer: each opened file is its own window (`DocumentGroup`), with system-provided Open Recent, window tabbing, and state restoration. Markdown rendered to HTML inside a sandboxed `WKWebView` using vendored offline JS/CSS; the app shell (window, toolbar, menus, file handling) is fully native (AppKit/SwiftUI).
- **Assumptions/Constraints:** macOS only (Apple Silicon + Intel). No network access — all assets vendored. Read-only: no editing/export/plugins. Priority order on conflict: 1) nativeness, 2) minimalism, 3) UX.

## 3. Functional Reqs

### 3.1 FR-OPEN: Open Markdown file [ANC:fr:open]
- **Desc:** User opens a `.md`/`.markdown` file via Open dialog, drag-and-drop onto the window/Dock icon, or "Open With" / `open` from Finder. Each open targets a window (per [REF:fr:multidoc | FR-MULTIDOC]).
- **Scenario:** User chooses `notes.md` via ⌘O → it renders in a window.
- **Acceptance:** `manual — maintainer — documents/checklists/open.md`
- **Status:** [ ]

### 3.1a FR-MULTIDOC: One window per document [ANC:fr:multidoc]
- **Desc:** Each opened file gets its own window (`DocumentGroup`). Opening another file never replaces the content of an existing window — it opens a new window (or focuses the existing one if already open). Strictly one window per document: window tabbing is disabled (`NSWindow.allowsAutomaticWindowTabbing = false`), so documents never merge into tabs regardless of the system "prefer tabs" setting. Each window's title bar shows the document's full filesystem path (not just the file name). Documents are read-only (no editing/saving); the document model loads UTF-8 text and fails fast on non-UTF-8.
- **Scenario:** With `a.md` open, the user opens `b.md` → a second window appears; the `a.md` window is unchanged.
- **Acceptance:** `manual — maintainer — documents/checklists/window-per-doc.md`; `Tests/MarkviewTests/DocumentReadTests.swift::testDecodesUTF8`
- **Status:** [ ]

### 3.2 FR-GFM: Render GitHub Flavored Markdown [ANC:fr:gfm]
- **Desc:** Render full GFM: headings, lists, task lists, tables, fenced code, strikethrough, autolinks, blockquotes, images.
- **Scenario:** A document with a GFM table and a task list renders with correct table layout and checkbox glyphs.
- **Acceptance:** `Tests/MarkviewTests/RenderTests.swift::testGFMTableAndTaskList`
- **Status:** [x]

### 3.3 FR-MERMAID: Render Mermaid diagrams [ANC:fr:mermaid]
- **Desc:** Fenced code blocks tagged ```` ```mermaid ```` render as diagrams via vendored `mermaid.js`.
- **Scenario:** A `flowchart` block renders as an SVG diagram, not as raw text.
- **Acceptance:** `Tests/MarkviewTests/RenderTests.swift::testMermaidFlowchartRenders`
- **Status:** [x]

### 3.4 FR-HIGHLIGHT: Syntax-highlight code blocks [ANC:fr:highlight]
- **Desc:** Non-mermaid fenced code blocks get syntax highlighting via a vendored highlight library, matching system appearance.
- **Scenario:** A ```` ```swift ```` block shows colored tokens.
- **Acceptance:** `Tests/MarkviewTests/RenderTests.swift::testCodeBlockHighlighted`
- **Status:** [x]

### 3.5 FR-LINE-WIDTH: Adjust line width on preview [ANC:fr:line-width]
- **Desc:** A control on the preview screen adjusts the text content width live (sets CSS `--content-width`); the value persists across launches.
- **Scenario:** User drags the width slider → content column reflows immediately; on relaunch the last width is restored.
- **Acceptance:** `Tests/MarkviewTests/LineWidthTests.swift::testWidthPersistsAndReflows`
- **Status:** [x]

### 3.6 FR-LIVE-RELOAD: Live reload on external edits [ANC:fr:live-reload]
- **Desc:** When the open file changes on disk, the preview refreshes automatically (FSEvents/`DispatchSource`), preserving scroll position where feasible.
- **Scenario:** User edits the file in another editor and saves → preview updates without manual reopen.
- **Acceptance:** `Tests/MarkviewTests/WatcherTests.swift::testReloadsOnFileChange`
- **Status:** [x]

### 3.7 FR-APPEARANCE: Follow system light/dark [ANC:fr:appearance]
- **Desc:** Rendered content and native chrome follow the system appearance and switch live.
- **Scenario:** Switching macOS to Dark Mode flips the preview theme without restart.
- **Acceptance:** `manual — maintainer — documents/checklists/appearance.md`
- **Status:** [ ]

### 3.8 FR-OFFLINE: No network access [ANC:fr:offline]
- **Desc:** All rendering assets load from the bundle; the web view performs no network requests.
- **Scenario:** With networking disabled, rendering (incl. Mermaid) still works fully.
- **Acceptance:** `Tests/MarkviewTests/OfflineTests.swift::testNoNetworkRequests`
- **Status:** [x]

---

## 4. Non-Functional
- **Perf:** Open + first render of a typical (<200 KB) doc < 300 ms on Apple Silicon. Width-slider reflow feels instant (< 1 frame perceptible lag).
- **Reliability:** Malformed Markdown never crashes; renders best-effort.
- **Sec:** No network, no JS bridge beyond the line-width message handler; `WKWebView` confined to bundled file URLs.
- **Scale:** Multiple independent document windows; each handles large docs (multi-MB) without freezing the UI (off-main-thread load).
- **UX:** Native document windows/toolbar/menus (Open Recent, tabs, restore via `DocumentGroup`); minimal chrome; the only persistent on-screen reading control is line width.

## 5. Interfaces
- **UI:** Native document windows (`DocumentGroup`) + toolbar (line-width control). Standard menu bar (File ▸ Open / Open Recent), state restoration. One window per document — no window tabs. Drag a file onto a window → opens it in a new window. Preview surface = `WKWebView`.
- **Proto (internal):** Native → web view: set Markdown source; set `--content-width`. Web view → native: `WKScriptMessageHandler` for width-change persistence and link-open interception.
- **File types:** `.md`, `.markdown` (UTType conformance declared in the app).

## 6. Acceptance
- **Criteria:** GFM + Mermaid + syntax highlighting render offline from vendored assets; line width adjustable on the preview and persisted; live reload on external edits; system appearance honored; app shell fully native; no network calls.
