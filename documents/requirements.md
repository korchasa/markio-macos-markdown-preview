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
- **Desc:** When the open file changes on disk, the preview refreshes automatically (FSEvents/`DispatchSource`), preserving the reader's scroll position across the re-render — including Mermaid-bearing documents, whose intermediate layout is shorter while diagrams re-render (the page restores the position after settling; a genuinely shorter document clamps to the nearest valid position).
- **Tasks:** [REF:task:2026-07-live-reload-preserve-scroll | live-reload-preserve-scroll]
- **Scenario:** User edits the file in another editor and saves → preview updates without manual reopen. Key case: an AI agent (Claude/Cursor) keeps writing the document — the reader watches it grow without losing their place.
- **Acceptance:** `Tests/MarkioTests/WatcherTests.swift::testReloadsOnFileChange`; `Tests/MarkioTests/LiveReloadTests.swift::testRerenderPreservesScrollPosition`
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
- **Desc:** A native find HUD (⌘F) searches the rendered content. It is a compact pill (window-background fill, hairline border, drop shadow) floating at the top-center of the content (overlay, not a bar that pushes the document): magnifier glyph, borderless query field, an "N of M" counter (e.g. "3 of 17"), a separator, round previous/next arrows, and a filled close (✕). Matching is case-insensitive and live (recomputed on each keystroke); matching is two-phase (contiguous per-block text + offset→node map), so a match may cross inline element boundaries — syntax-highlight token spans in code blocks, inline formatting in table cells — but never a block boundary. Every match is highlighted as one logical match of 1+ `<mark>` segments; the current match is emphasized (all segments) and scrolled into view. An overview strip (minimap) at the preview's right edge shows one tick per match at its relative document position, the current match's tick accented; indication-only (no pointer events), present only while a search has matches. With the caret in the query field, ↓ / Enter / ⌘G advances to the next match and ↑ / Shift+Enter / ⌘⇧G to the previous (arrows keep the caret in the field), both wrapping around; Esc (or ✕) closes the HUD and removes all highlights and the strip. Search runs only over rendered text nodes, never inside Mermaid SVGs, KaTeX output, or the code-copy UI. Find is per window; a single app-level Find menu drives the focused window. On live reload / appearance re-render, an open search re-applies to the fresh content (marks and minimap rebuilt).
- **Tasks:** [REF:task:2026-07-find-upgrades | find-upgrades]
- **Scenario:** User presses ⌘F, types `alpha` in a doc with three (mixed-case) occurrences → the HUD shows "1 of 3", all three are highlighted, the first is emphasized, three ticks appear at the right edge; Enter cycles "2 of 3", "3 of 3", "1 of 3" with the accented tick following; Esc clears the highlights and the strip.
- **Acceptance:** `Tests/MarkioTests/FindTests.swift::testFindsAllMatchesAndCycles`; `Tests/MarkioTests/FindTests.swift::testCounterText`; `Tests/MarkioTests/FindTests.swift::testFindsAcrossTokenSpansInCodeAndTables`; `Tests/MarkioTests/FindTests.swift::testMinimapTicksFollowMatches`
- **Status:** [x]

### 3.10 FR-MENU: Read-only menu surface [ANC:fr:menu]
- **Desc:** "Good enough" minimal-surgery approach: remove only the document-write commands meaningless for a read-only viewer, via the two contractual SwiftUI command groups that hold them (`ReadOnlyMenuCommands`: `.newItem`→∅, `.saveItem`→∅); leave everything else standard so macOS auto-disables inapplicable items and localizes them for free. A thin AppKit pass (`MenuArtifactCleaner`) removes the cosmetic artifacts SwiftUI emits when a group is emptied (a title-less placeholder drawn as "NSMenuItem" + orphaned separators). Removed from File: New, Save, Save As…, Duplicate, Rename…, Move To…, Revert To, Share, Close, Close All (the latter two fall out of `.saveItem`; window still closes via the title-bar button). Kept: File ▸ Open…, Open Recent. **Edit menu left fully standard** (Undo/Redo/Cut/Copy/Paste/Delete/Select All) — auto-disabled on non-editable content and properly localized; no custom buttons. View/Window/Help and the app menu unchanged. Localization: the bundle declares `CFBundleLocalizations` (en, ru) so standard items render in the system language (Файл, Правка, Открыть…).
- **Scenario:** On a Russian system the File menu reads `Файл ▸ Открыть…, Открытие недавних` (no New/Save/Rename/Share, no "NSMenuItem"); `Правка` shows the standard, localized Edit items.
- **Acceptance:** `Tests/MarkioTests/MenuArtifactCleanerTests.swift::testRemovesPlaceholderAndTrailingSeparators` (artifact removal); `manual — maintainer — documents/checklists/menu.md` (semantic removal + localization)
- **Status:** [x]

### 3.13 FR-FRONTMATTER: Render leading YAML frontmatter [ANC:fr:frontmatter]
- **Desc:** A YAML frontmatter block delimited by `---` fences at the **very top** of a document (first line exactly `---`, a later line exactly `---`) renders as a distinct, readable metadata block — a syntax-highlighted YAML box (vendored highlight.js `yaml` grammar) with a subtle border and a "frontmatter" caption — instead of the mangled setext-heading + `<hr>` markdown-it produces without a frontmatter rule. Recognized **only** at document start (a `---` block anywhere else stays a normal thematic break / setext heading); a document without frontmatter is unchanged. Best-effort: an opening `---` with no closing fence falls through to default parsing, never crashing (NFR Reliability). Offline — reuses the already-vendored highlight.js, no new dependency.
- **Tasks:** [REF:task:2026-07-add-frontmatter-display | add-frontmatter-display]
- **Scenario:** A note starting with `---\ntitle: Hello\ntags: [a, b]\n---\n\n# Body` shows the metadata as a highlighted YAML box and `# Body` as an `<h1>`; a `---` on its own line mid-document still renders a horizontal rule.
- **Acceptance:** `Tests/MarkioTests/RenderTests.swift::testFrontmatterRendersAsMetadata`
- **Status:** [x]

### 3.12 FR-MATH: Render LaTeX math [ANC:fr:math]
- **Desc:** Inline `$…$` and block `$$…$$` LaTeX render as typeset math via vendored KaTeX (offline). Math is tokenized at **parse time** (a markdown-it rule) so `*`/`_`/`\` inside a formula are never mangled by emphasis/escape rules, and `$` inside a code span stays literal. A money guard (no digit immediately after the closing `$`) keeps `$5 and $10`-style text literal. Malformed math renders best-effort (KaTeX error node), never crashing the render (NFR Reliability). Rendered math sets no explicit color → inherits `CanvasText`, following light/dark automatically.
- **Tasks:** [REF:task:2026-07-add-math-support | add-math-support]
- **Scenario:** A doc with inline `$E = mc^2$` and a block `$$\int_0^\infty e^{-x^2}\,dx$$` shows typeset math (display math centered), not raw TeX; `Pay $5 and $10` stays literal.
- **Acceptance:** `Tests/MarkioTests/RenderTests.swift::testMathRendersWithKatex`
- **Status:** [x]

### 3.14 FR-INLINE-HTML: Render sanitized inline HTML [ANC:fr:inline-html]
- **Desc:** Raw inline/block HTML in Markdown renders as real elements (GitHub parity) — e.g. `<table>` with `rowspan`/`colspan` that GFM pipe tables cannot express, `<details>`/`<summary>`, `<kbd>`, `<sub>`/`<sup>` — instead of escaped literal text. The entire markdown-it output passes through a DOMPurify allowlist gate (vendored, pinned) **before** DOM insertion: `<script>`/`<style>` elements, event-handler attributes (`onerror`, `onclick`, …), and `javascript:`/unknown-protocol URLs are stripped and never execute. Generated markup survives the gate: KaTeX HTML+MathML, hljs token spans, `pre.mermaid` blocks, task-list `<input>` checkboxes. A missing sanitizer asset fails the render loudly — content is never inserted unsanitized.
- **Tasks:** [REF:task:2026-07-render-inline-html-sanitized | render-inline-html-sanitized]
- **Scenario:** A document with one raw `<table>` using `rowspan`/`colspan` `<th>` cells renders a real table; `<img src=x onerror="…">` and `<script>` render nothing and execute nothing.
- **Acceptance:** `Tests/MarkioTests/RenderTests.swift::testInlineHTMLTableRenders`; `Tests/MarkioTests/RenderTests.swift::testInlineHTMLSanitized`
- **Status:** [x]

### 3.15 FR-TOC: Table-of-contents sidebar [ANC:fr:toc]
- **Desc:** A toggleable **native** sidebar lists the document's headings (`h1`–`h6`) as an indented tree in document order. Clicking a heading scrolls the preview so that heading sits at the top of the viewport; while the reader scrolls, the entry for the current section (the last heading at/above the viewport top) stays highlighted and visible in the sidebar. Toggled via `View ▸ Show/Hide Table of Contents` (⌥⌘S, the macOS sidebar convention); the visibility choice is a global reading preference persisted across launches (`UserDefaults`, like the line width). Heading anchors are GitHub-style slugs deduplicated with numeric suffixes, assigned by the page on every render — so after a live reload / appearance re-render the outline is re-pulled and jump/highlight keep working ([REF:fr:live-reload | FR-LIVE-RELOAD] interplay). A document with no headings shows an empty-state placeholder. The sidebar is native chrome (the web view still owns only content rendering); the scroll-spy is one of the two one-way page→native messages (see §5).
- **Tasks:** [REF:task:2026-07-toc-sidebar | toc-sidebar]
- **Scenario:** Reading a long agent-written report, the user presses ⌥⌘S → the heading tree appears; clicking "Results" jumps the preview there; scrolling onward moves the highlight to the next section; the file is re-saved by the agent → the tree matches the new document. Relaunching the app keeps the sidebar shown.
- **Acceptance:** `Tests/MarkioTests/TOCTests.swift::testOutlineExtractsHeadingTree`; `Tests/MarkioTests/TOCTests.swift::testJumpScrollsToHeading`; `Tests/MarkioTests/TOCTests.swift::testCurrentSectionTracksScroll`; `Tests/MarkioTests/TOCTests.swift::testSidebarVisibilityPersists`; `Tests/MarkioTests/TOCTests.swift::testOutlineSurvivesRerender`
- **Status:** [x]

### 3.16 FR-CODE-COPY: Copy button on code blocks [ANC:fr:code-copy]
- **Desc:** Hovering a fenced code block reveals a **Copy** button and, for tagged fences, a language badge (the first word of the fence info string; untagged fences get no badge but keep the button) in the block's top-right corner. Clicking Copy places the block's **raw code text** (exactly the fence content — no highlight markup, no badge/button text) on the system clipboard: the page posts the text through the one-way `markioCopy` message handler and the native shell writes `NSPasteboard` (in-page `navigator.clipboard` is unreliable in the sandboxed `WKWebView`). The button flashes "Copied" (~1.5 s) as feedback. Mermaid blocks (diagram copy is a separate concern) and the frontmatter box are excluded; the Copy label and badge text are never find matches ([REF:fr:find | FR-FIND] interplay). Decoration is rebuilt on every render, so it survives live reloads ([REF:fr:live-reload | FR-LIVE-RELOAD]).
- **Tasks:** [REF:task:2026-07-code-copy-button | code-copy-button]
- **Scenario:** Reading an agent-written runbook, the user hovers a ```` ```bash ```` block → a `bash` badge and Copy appear; clicking Copy puts the command on the clipboard, ready to paste into a terminal.
- **Acceptance:** `Tests/MarkioTests/CodeCopyTests.swift::testCopyButtonCopiesRawCode`; `Tests/MarkioTests/CodeCopyTests.swift::testLanguageBadgeFromFenceInfo`; `Tests/MarkioTests/CodeCopyTests.swift::testMermaidAndFrontmatterExcluded`; `Tests/MarkioTests/CodeCopyTests.swift::testFindSkipsCopyUI`
- **Status:** [x]

### 3.17 FR-SESSION-RESTORE: Recent documents + window restore [ANC:fr:session-restore]
- **Desc:** Markio behaves like a daily tool across launches. (1) File ▸ Open Recent lists recently opened documents (system-provided by `DocumentGroup`/`NSDocumentController`; sandbox access to recents is system-managed). (2) Quitting with documents open and relaunching reopens the same document windows — deterministically, regardless of the user's global "Close windows when quitting an application" setting: the app opts into secure state restoration and sets `NSQuitAlwaysKeepsWindows` in its own defaults domain. (3) Every document reopens at its last scroll position: the page reports the debounced scroll offset over a third one-way `markioScroll` message, natively persisted per file path (`UserDefaults`, bounded map with oldest-entry eviction), and restored once after the window's first render — covering relaunch, Open Recent, and plain reopen alike. A saved position beyond a now-shorter document clamps to the nearest valid position.
- **Tasks:** [REF:task:2026-07-recent-docs-window-restore | recent-docs-window-restore]
- **Scenario:** Reading a long agent-written report, the user quits at §7; relaunching Markio brings the same windows back, the report already scrolled to §7. Next day the user picks yesterday's runbook from File ▸ Open Recent — it opens where they stopped reading.
- **Acceptance:** `Tests/MarkioTests/SessionRestoreTests.swift::testScrollPositionRoundTrip`; `Tests/MarkioTests/SessionRestoreTests.swift::testScrollSavedOnScrollAndRestoredOnOpen`; `manual — maintainer — documents/checklists/session-restore.md` (Open Recent + relaunch reopen in a real `.app`)
- **Status:** [x]

### 3.18 FR-LOCAL-LINKS: Local link navigation [ANC:fr:local-links]
- **Desc:** Links inside rendered documents are functional. (a) A relative link to another `.md`/`.markdown` file opens that file in a new window (one window per document, [REF:fr:multidoc | FR-MULTIDOC]); the page intercepts the click and posts the raw href to the native side, which resolves it against the document's directory (default-deny grammar: scheme-less relative paths only, `..` allowed, Markdown extensions only) and opens it via `NSDocumentController`. Under the MAS App Sandbox a target the app cannot read (never user-selected) triggers a powerbox `NSOpenPanel` pre-pointed at the file — one "Open" click grants access; previously opened/recent files open silently (system-managed access). (b) A `#anchor` link scrolls the current document to the heading (TOC slug ids, [REF:fr:toc | FR-TOC]). (c) `other.md#section` opens the file and scrolls it to the section after its first render — also when the target document is already open (its window is scrolled directly). External `http(s)`/`mailto`/`tel` links keep opening in the default browser; every other link (non-Markdown relative targets, absolute paths, unknown schemes) stays blocked ([REF:fr:offline | FR-OFFLINE]).
- **Tasks:** [REF:task:2026-07-local-link-navigation | local-link-navigation]
- **Scenario:** Reading a repo's `README.md`, the user clicks `[design](docs/design.md#render-pipeline)` → a panel asks once for permission to open `design.md`; after "Open" a new window shows the file scrolled to "Render pipeline". A click on `[top](#intro)` scrolls the current window; a click on `https://example.com` opens the browser.
- **Acceptance:** `Tests/MarkioTests/LinkTests.swift::testAnchorLinkClickScrollsToHeading`; `Tests/MarkioTests/LinkTests.swift::testRelativeMarkdownLinkPostsLinkMessage`; `Tests/MarkioTests/LinkTests.swift::testLocalLinkResolverResolvesRelativeAndRejectsOthers`; `Tests/MarkioTests/LinkTests.swift::testPendingAnchorStoreRoundTripAndConsumeOnce`; `Tests/MarkioTests/LinkTests.swift::testFollowDeliversAnchorToAlreadyOpenTarget`; `Tests/MarkioTests/LinkTests.swift::testNonMarkdownAndExternalLinksNotHijacked`; `manual — maintainer — documents/checklists/local-links.md` (new-window open + sandbox grant flow in a real `.app`)
- **Status:** [x]

### 3.19 FR-QUICKLOOK: Quick Look preview extension [ANC:fr:quicklook]
- **Desc:** Pressing Space on a `.md`/`.markdown` file in Finder shows the document rendered by Markio's engine — GFM, Mermaid diagrams, KaTeX math, frontmatter box — following the system light/dark appearance. Implemented as a **view-based** Quick Look preview extension (`.appex` under `Contents/PlugIns/`, principal class a `QLPreviewingController` hosting its own `WKWebView`): the data-based QL API executes no JavaScript, which Mermaid requires. The extension is render-only: no message handlers, and every post-initial-load navigation is cancelled (link clicks do nothing). It carries its own copy of the engine resource bundle. Non-UTF-8 or unreadable files hand the error back to Quick Look, which falls back to the system plain-text preview. Registered for `net.daringfireball.markdown` only — never `public.plain-text`, so `.txt` previews stay untouched. The `.appex` is hand-assembled by `make app` (no Xcode): SwiftPM binary linked with entry `_NSExtensionMain`, plus Info.plist and the resource bundle; ad-hoc-signed locally so pluginkit loads it (distribution signing in app-store-factory, nested extension first).
- **Tasks:** [REF:task:2026-07-quicklook-extension | quicklook-extension]
- **Scenario:** In Finder the user selects an agent-written `report.md` and presses Space → the panel shows the rendered document: tables laid out, the flowchart as an SVG diagram, math typeset — before the app is ever opened.
- **Acceptance:** `make app && test -x .build/Markio.app/Contents/PlugIns/MarkioQuickLook.appex/Contents/MacOS/MarkioQuickLook && test -d .build/Markio.app/Contents/PlugIns/MarkioQuickLook.appex/Contents/Resources/Markio_MarkioEngine.bundle && codesign --verify .build/Markio.app/Contents/PlugIns/MarkioQuickLook.appex` (structure + signature); `Tests/MarkioTests/QuickLookTests.swift::testLoadsUTF8MarkdownAndRejectsBinary` (input gate); `manual — maintainer — documents/checklists/quicklook.md` (real Finder/Quick Look rendering)
- **Status:** [ ]

### 3.20 FR-AI-ARTIFACTS: AI-artifact rendering [ANC:fr:ai-artifacts]
- **Desc:** Artifacts AI agents emit into Markdown render cleanly: (a) ANSI SGR escape sequences inside fenced code blocks render as colored/styled text (no raw escape residue); (b) ```diff``` fenced blocks show full-width green/red line backgrounds for `+`/`-` lines in light and dark appearance; (c) long unbroken tokens (paths, hashes, URLs) in prose, inline code, and table cells wrap without widening the layout, while code blocks keep horizontal scrolling. Detection is content-based (ESC + `[` in any non-mermaid fence, regardless of language tag — an ANSI-bearing block trades language highlighting for color rendering). On ANSI blocks the Copy button ([REF:fr:code-copy | FR-CODE-COPY]) copies the visible text with escape codes stripped — a deliberate deviation from byte-exact fence content. Offline, no new dependencies; the supported SGR subset is documented in SDS §3.6.
- **Tasks:** [REF:task:2026-07-ai-artifact-rendering | ai-artifact-rendering]
- **Scenario:** A doc with a pasted agent log containing `\x1b[31mERROR\x1b[0m` shows "ERROR" in red, not `[31m` garbage; a ```diff``` block shows green/red full-width line backgrounds; a 300-char path in a table cell wraps inside the column.
- **Acceptance:** `Tests/MarkioTests/RenderTests.swift::testANSIEscapesRenderAsColors`; `Tests/MarkioTests/RenderTests.swift::testDiffBlockLineBackgrounds`; `Tests/MarkioTests/RenderTests.swift::testLongTokensDoNotBreakLayout`; `Tests/MarkioTests/RenderTests.swift::testANSIBlocksKeepFindAndCopy`
- **Status:** [x]

---

## 4. Non-Functional
- **Perf:** Open + first render of a typical (<200 KB) doc < 300 ms on Apple Silicon. Width-slider reflow feels instant (< 1 frame perceptible lag).
- **Reliability:** Malformed Markdown never crashes; renders best-effort.
- **Sec:** No network; the JS bridge is native→web calls plus four one-way page→native message handlers, each carrying a single string: `markioTOC` (current heading id — [REF:fr:toc | FR-TOC]), `markioCopy` (raw code text → `NSPasteboard` — [REF:fr:code-copy | FR-CODE-COPY]), `markioScroll` (debounced scroll offset → per-document position store — [REF:fr:session-restore | FR-SESSION-RESTORE]), and `markioLink` (raw clicked href → default-deny native resolver — [REF:fr:local-links | FR-LOCAL-LINKS]); `WKWebView` confined to bundled file URLs. Raw inline HTML passes a DOMPurify allowlist sanitizer before DOM insertion ([REF:fr:inline-html | FR-INLINE-HTML]).
- **Scale:** Multiple independent document windows; each handles large docs (multi-MB) without freezing the UI (off-main-thread load).
- **UX:** Native document windows/menus (Open Recent, tabs, restore via `DocumentGroup`); minimal chrome; the only persistent on-screen reading control is line width, in a bottom bar.

## 5. Interfaces
- **UI:** Native document windows (`DocumentGroup`) + a bottom bar (line-width control). Standard menu bar (File ▸ Open / Open Recent), state restoration. One window per document — no window tabs. Drag a file onto a window → opens it in a new window. Preview surface = `WKWebView`.
- **Proto (internal):** Native → web view (via `callAsyncJavaScript`): set Markdown source (`render`), set reading width (`setContentWidth`, `ch`), set appearance (`setDark`), find text (`search`/`findNext`/`findPrev`/`clearSearch`), read the outline (`getOutline`), jump to a heading (`scrollToHeading`), read the current section (`getCurrentSection`), restore the reading position (`setScrollY`). Web → native: four one-way `WKScriptMessageHandler`s — `markioTOC` (the page pushes the current heading id when it changes on scroll — [REF:fr:toc | FR-TOC]), `markioCopy` (a copy-button click pushes the block's raw code text, written to `NSPasteboard` — [REF:fr:code-copy | FR-CODE-COPY]), `markioScroll` (the page pushes the debounced scroll offset, persisted per document — [REF:fr:session-restore | FR-SESSION-RESTORE]), and `markioLink` (a click on a relative Markdown link pushes the raw href; native code resolves and opens it — [REF:fr:local-links | FR-LOCAL-LINKS]); external link clicks are intercepted by the `WKNavigationDelegate` (open in the default browser via `NSWorkspace`), `#anchor` clicks scroll in-page; width changes persist natively (slider → `UserDefaults`).
- **File types:** `.md`, `.markdown` (UTType conformance declared in the app).
- **System integration:** Quick Look preview extension for `net.daringfireball.markdown` (Space in Finder — [REF:fr:quicklook | FR-QUICKLOOK]).

## 6. Acceptance
- **Criteria:** GFM + Mermaid + syntax highlighting render offline from vendored assets; line width adjustable on the preview and persisted; live reload on external edits; system appearance honored; app shell fully native; no network calls.
