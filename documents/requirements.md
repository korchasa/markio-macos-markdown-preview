# SRS

## 1. Intro
- **Desc:** Markview — native macOS app that previews Markdown files (read-only). Renders GFM + Mermaid with a minimal, native, distraction-free UX. One in-screen reading control: line width.
- **Def/Abbr:** GFM = GitHub Flavored Markdown. WKWebView = WebKit web view. SPM = Swift Package Manager. FSEvents = macOS filesystem event API.

## 2. General
- **Context:** Single-window macOS document viewer. Markdown rendered to HTML inside a sandboxed `WKWebView` using vendored offline JS/CSS; the app shell (window, toolbar, menus, file handling) is fully native (AppKit/SwiftUI).
- **Assumptions/Constraints:** macOS only (Apple Silicon + Intel). No network access — all assets vendored. Read-only: no editing/export/plugins. Priority order on conflict: 1) nativeness, 2) minimalism, 3) UX.

## 3. Functional Reqs

### 3.1 FR-OPEN: Open Markdown file [ANC:fr:open]
- **Desc:** User opens a `.md`/`.markdown` file via Open dialog, drag-and-drop onto the window/Dock icon, or "Open With" / `open` from Finder.
- **Scenario:** User drags `notes.md` onto the window → content renders in the preview.
- **Acceptance:** `manual — maintainer — documents/checklists/open.md`
- **Status:** [ ]

### 3.2 FR-GFM: Render GitHub Flavored Markdown [ANC:fr:gfm]
- **Desc:** Render full GFM: headings, lists, task lists, tables, fenced code, strikethrough, autolinks, blockquotes, images.
- **Scenario:** A document with a GFM table and a task list renders with correct table layout and checkbox glyphs.
- **Acceptance:** `Tests/MarkviewTests/RenderTests.swift::testGFMTableAndTaskList`
- **Status:** [ ]

### 3.3 FR-MERMAID: Render Mermaid diagrams [ANC:fr:mermaid]
- **Desc:** Fenced code blocks tagged ```` ```mermaid ```` render as diagrams via vendored `mermaid.js`.
- **Scenario:** A `flowchart` block renders as an SVG diagram, not as raw text.
- **Acceptance:** `Tests/MarkviewTests/RenderTests.swift::testMermaidFlowchartRenders`
- **Status:** [ ]

### 3.4 FR-HIGHLIGHT: Syntax-highlight code blocks [ANC:fr:highlight]
- **Desc:** Non-mermaid fenced code blocks get syntax highlighting via a vendored highlight library, matching system appearance.
- **Scenario:** A ```` ```swift ```` block shows colored tokens.
- **Acceptance:** `Tests/MarkviewTests/RenderTests.swift::testCodeBlockHighlighted`
- **Status:** [ ]

### 3.5 FR-LINE-WIDTH: Adjust line width on preview [ANC:fr:line-width]
- **Desc:** A control on the preview screen adjusts the text content width live (sets CSS `--content-width`); the value persists across launches.
- **Scenario:** User drags the width slider → content column reflows immediately; on relaunch the last width is restored.
- **Acceptance:** `Tests/MarkviewTests/LineWidthTests.swift::testWidthPersistsAndReflows`
- **Status:** [ ]

### 3.6 FR-LIVE-RELOAD: Live reload on external edits [ANC:fr:live-reload]
- **Desc:** When the open file changes on disk, the preview refreshes automatically (FSEvents/`DispatchSource`), preserving scroll position where feasible.
- **Scenario:** User edits the file in another editor and saves → preview updates without manual reopen.
- **Acceptance:** `Tests/MarkviewTests/WatcherTests.swift::testReloadsOnFileChange`
- **Status:** [ ]

### 3.7 FR-APPEARANCE: Follow system light/dark [ANC:fr:appearance]
- **Desc:** Rendered content and native chrome follow the system appearance and switch live.
- **Scenario:** Switching macOS to Dark Mode flips the preview theme without restart.
- **Acceptance:** `manual — maintainer — documents/checklists/appearance.md`
- **Status:** [ ]

### 3.8 FR-OFFLINE: No network access [ANC:fr:offline]
- **Desc:** All rendering assets load from the bundle; the web view performs no network requests.
- **Scenario:** With networking disabled, rendering (incl. Mermaid) still works fully.
- **Acceptance:** `Tests/MarkviewTests/OfflineTests.swift::testNoNetworkRequests`
- **Status:** [ ]

---

## 4. Non-Functional
- **Perf:** Open + first render of a typical (<200 KB) doc < 300 ms on Apple Silicon. Width-slider reflow feels instant (< 1 frame perceptible lag).
- **Reliability:** Malformed Markdown never crashes; renders best-effort.
- **Sec:** No network, no JS bridge beyond the line-width message handler; `WKWebView` confined to bundled file URLs.
- **Scale:** Single-document focus; large docs (multi-MB) render without freezing the UI (off-main-thread load).
- **UX:** Native window/toolbar/menus; minimal chrome; the only persistent on-screen reading control is line width.

## 5. Interfaces
- **UI:** Native macOS window + toolbar (open, line-width control). Standard menu bar (File ▸ Open / Open Recent). Drag-and-drop target. Preview surface = `WKWebView`.
- **Proto (internal):** Native → web view: set Markdown source; set `--content-width`. Web view → native: `WKScriptMessageHandler` for width-change persistence and link-open interception.
- **File types:** `.md`, `.markdown` (UTType conformance declared in the app).

## 6. Acceptance
- **Criteria:** GFM + Mermaid + syntax highlighting render offline from vendored assets; line width adjustable on the preview and persisted; live reload on external edits; system appearance honored; app shell fully native; no network calls.
