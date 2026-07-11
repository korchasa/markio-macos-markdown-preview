# SRS

## 1. Intro
- **Desc:** Markio — native macOS app that previews Markdown files (read-only). Renders GFM + Mermaid with a minimal, native, distraction-free UX. One in-screen reading control: line width.
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
- **Acceptance:** `manual — maintainer — documents/checklists/window-per-doc.md`; `Tests/MarkioTests/DocumentReadTests.swift::testDecodesUTF8`
- **Status:** [ ]

### 3.2 FR-GFM: Render GitHub Flavored Markdown [ANC:fr:gfm]
- **Desc:** Render full GFM: headings, lists, task lists, tables, fenced code, strikethrough, autolinks, blockquotes, images.
- **Scenario:** A document with a GFM table and a task list renders with correct table layout and checkbox glyphs.
- **Acceptance:** `Tests/MarkioTests/RenderTests.swift::testGFMTableAndTaskList`
- **Status:** [x]

### 3.3 FR-MERMAID: Render Mermaid diagrams [ANC:fr:mermaid]
- **Desc:** Fenced code blocks tagged ```` ```mermaid ```` render as diagrams via vendored `mermaid.js`.
- **Scenario:** A `flowchart` block renders as an SVG diagram, not as raw text.
- **Acceptance:** `Tests/MarkioTests/RenderTests.swift::testMermaidFlowchartRenders`
- **Status:** [x]

### 3.4 FR-HIGHLIGHT: Syntax-highlight code blocks [ANC:fr:highlight]
- **Desc:** Non-mermaid fenced code blocks get syntax highlighting via a vendored highlight library, matching system appearance.
- **Scenario:** A ```` ```swift ```` block shows colored tokens.
- **Acceptance:** `Tests/MarkioTests/RenderTests.swift::testCodeBlockHighlighted`
- **Status:** [x]

### 3.5 FR-LINE-WIDTH: Adjust line width on preview [ANC:fr:line-width]
- **Desc:** A control in a **bottom bar** below the preview adjusts the reading-column width live. The width is an **absolute character count** (CSS `--content-width` in `ch` units — the native CSS char-width unit, = advance of the '0' glyph), stepped through presets **40…200 by 20** (default 80); the slider shows the current value (e.g. `80 ch`). The value persists across launches. By design the column never exceeds the window: when a requested width is wider than the current window can show, the column is capped at the window width (absolute char width is independent of window size only up to that physical limit), so high presets visibly widen the text only on a sufficiently wide/maximized window.
- **Scenario:** User drags the bottom-bar slider → it snaps to the next 20-char preset and the content column reflows immediately to that character width; on relaunch the last width is restored.
- **Acceptance:** `Tests/MarkioTests/LineWidthTests.swift::testWidthPersistsAndReflows`
- **Status:** [x]

### 3.6 FR-LIVE-RELOAD: Live reload on external edits [ANC:fr:live-reload]
- **Desc:** When the open file changes on disk, the preview refreshes automatically (FSEvents/`DispatchSource`), preserving scroll position where feasible.
- **Scenario:** User edits the file in another editor and saves → preview updates without manual reopen.
- **Acceptance:** `Tests/MarkioTests/WatcherTests.swift::testReloadsOnFileChange`
- **Status:** [x]

### 3.7 FR-APPEARANCE: Follow system light/dark [ANC:fr:appearance]
- **Desc:** Rendered content and native chrome follow the system appearance and switch live.
- **Scenario:** Switching macOS to Dark Mode flips the preview theme without restart.
- **Acceptance:** `manual — maintainer — documents/checklists/appearance.md`
- **Status:** [ ]

### 3.8 FR-OFFLINE: No network access [ANC:fr:offline]
- **Desc:** All rendering assets load from the bundle; the web view performs no network requests.
- **Scenario:** With networking disabled, rendering (incl. Mermaid) still works fully.
- **Acceptance:** `Tests/MarkioTests/OfflineTests.swift::testNoNetworkRequests`
- **Status:** [x]

### 3.9 FR-ICON: App icon [ANC:fr:icon]
- **Desc:** The `.app` bundle ships a Markio app icon (document-with-text-lines design). Source PNGs live in `packaging/AppIcon.iconset`; `make app` compiles them to `AppIcon.icns` via `iconutil` and `Info.plist` references it (`CFBundleIconFile`). Shown in Finder, Dock, and the app switcher.
- **Scenario:** User opens `Markio.app` → its Dock/Finder icon is the Markio document glyph, not the generic placeholder.
- **Acceptance:** `manual — maintainer — documents/checklists/icon.md`
- **Status:** [x]

### 3.11 FR-FIND: Find text in document [ANC:fr:find]
- **Desc:** A native find HUD (⌘F) searches the rendered content. It is a compact pill (window-background fill, hairline border, drop shadow) floating at the top-center of the content (overlay, not a bar that pushes the document): magnifier glyph, borderless query field, a `current/total` counter, a separator, round previous/next arrows, and a filled close (✕). Matching is case-insensitive and live (recomputed on each keystroke); every match is wrapped in a `<mark>` and the current one is emphasized and scrolled into view. With the caret in the query field, ↓ / Enter / ⌘G advances to the next match and ↑ / Shift+Enter / ⌘⇧G to the previous (arrows keep the caret in the field), both wrapping around; Esc (or ✕) closes the HUD and removes all highlights. Search runs only over rendered text nodes, never inside Mermaid SVGs or code-token markup structure. Find is per window; a single app-level Find menu drives the focused window. On live reload / appearance re-render, an open search re-applies to the fresh content.
- **Scenario:** User presses ⌘F, types `alpha` in a doc with three (mixed-case) occurrences → the HUD shows `1/3`, all three are highlighted, the first is emphasized; Enter cycles `2/3`, `3/3`, `1/3`; Esc clears the highlights.
- **Acceptance:** `Tests/MarkioTests/FindTests.swift::testFindsAllMatchesAndCycles`
- **Status:** [x]

### 3.10 FR-MENU: Read-only menu surface [ANC:fr:menu]
- **Desc:** "Good enough" minimal-surgery approach: remove only the document-write commands meaningless for a read-only viewer, via the two contractual SwiftUI command groups that hold them (`ReadOnlyMenuCommands`: `.newItem`→∅, `.saveItem`→∅); leave everything else standard so macOS auto-disables inapplicable items and localizes them for free. A thin AppKit pass (`MenuArtifactCleaner`) removes the cosmetic artifacts SwiftUI emits when a group is emptied (a title-less placeholder drawn as "NSMenuItem" + orphaned separators). Removed from File: New, Save, Save As…, Duplicate, Rename…, Move To…, Revert To, Share, Close, Close All (the latter two fall out of `.saveItem`; window still closes via the title-bar button). Kept: File ▸ Open…, Open Recent. **Edit menu left fully standard** (Undo/Redo/Cut/Copy/Paste/Delete/Select All) — auto-disabled on non-editable content and properly localized; no custom buttons. View/Window/Help and the app menu unchanged. Localization: the bundle declares `CFBundleLocalizations` (en, ru) so standard items render in the system language (Файл, Правка, Открыть…).
- **Scenario:** On a Russian system the File menu reads `Файл ▸ Открыть…, Открытие недавних` (no New/Save/Rename/Share, no "NSMenuItem"); `Правка` shows the standard, localized Edit items.
- **Acceptance:** `Tests/MarkioTests/MenuArtifactCleanerTests.swift::testRemovesPlaceholderAndTrailingSeparators` (artifact removal); `manual — maintainer — documents/checklists/menu.md` (semantic removal + localization)
- **Status:** [x]

### 3.12 FR-MATH: Render LaTeX math [ANC:fr:math]
- **Desc:** Inline `$…$` and block `$$…$$` LaTeX render as typeset math via vendored KaTeX (offline). Math is tokenized at **parse time** (a markdown-it rule) so `*`/`_`/`\` inside a formula are never mangled by emphasis/escape rules, and `$` inside a code span stays literal. A money guard (no digit immediately after the closing `$`) keeps `$5 and $10`-style text literal. Malformed math renders best-effort (KaTeX error node), never crashing the render (NFR Reliability). Rendered math sets no explicit color → inherits `CanvasText`, following light/dark automatically.
- **Tasks:** [REF:task:2026-07-add-math-support | add-math-support]
- **Scenario:** A doc with inline `$E = mc^2$` and a block `$$\int_0^\infty e^{-x^2}\,dx$$` shows typeset math (display math centered), not raw TeX; `Pay $5 and $10` stays literal.
- **Acceptance:** `Tests/MarkioTests/RenderTests.swift::testMathRendersWithKatex`
- **Status:** [x]

---

## 4. Non-Functional
- **Perf:** Open + first render of a typical (<200 KB) doc < 300 ms on Apple Silicon. Width-slider reflow feels instant (< 1 frame perceptible lag).
- **Reliability:** Malformed Markdown never crashes; renders best-effort.
- **Sec:** No network, no JS bridge beyond the line-width message handler; `WKWebView` confined to bundled file URLs.
- **Scale:** Multiple independent document windows; each handles large docs (multi-MB) without freezing the UI (off-main-thread load).
- **UX:** Native document windows/menus (Open Recent, tabs, restore via `DocumentGroup`); minimal chrome; the only persistent on-screen reading control is line width, in a bottom bar.

## 5. Interfaces
- **UI:** Native document windows (`DocumentGroup`) + a bottom bar (line-width control). Standard menu bar (File ▸ Open / Open Recent), state restoration. One window per document — no window tabs. Drag a file onto a window → opens it in a new window. Preview surface = `WKWebView`.
- **Proto (internal):** Native → web view (via `callAsyncJavaScript`): set Markdown source (`render`), set reading width (`setContentWidth`, `ch`), set appearance (`setDark`), find text (`search`/`findNext`/`findPrev`/`clearSearch`). Web → native: no message handler — link clicks are intercepted by the `WKNavigationDelegate` (external links open in the default browser via `NSWorkspace`); width changes persist natively (slider → `UserDefaults`).
- **File types:** `.md`, `.markdown` (UTType conformance declared in the app).

## 6. Acceptance
- **Criteria:** GFM + Mermaid + syntax highlighting render offline from vendored assets; line width adjustable on the preview and persisted; live reload on external edits; system appearance honored; app shell fully native; no network calls.
