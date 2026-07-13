---
date: 2026-07-13
status: done
implements:
  - FR-TOC
tags: [toc, sidebar, navigation, scroll-spy]
related_tasks:
  - "[Daily-use feature backlog](daily-use-feature-backlog.md)"
  - "[Live reload preserves scroll](live-reload-preserve-scroll.md)"
---
# TOC sidebar with click-to-jump and scroll spy [ANC:task:2026-07-toc-sidebar]

## Goal

Backlog item 2 (post-4.3(a) daily-use wave): a toggleable sidebar showing the
document's heading tree. Click a heading → the preview jumps to it; the
current section stays highlighted as the reader scrolls. Long agent reports
(the core 2026 daily-use scenario) are unreadable without an outline; short
notes don't need one — hence toggleable. Meva and MarkFlow both ship a TOC;
without it Markio loses the "reader for long AI-generated docs" story.

## Overview

### Context

- Request: "TOC sidebar — a sidebar with the document's heading tree; click a
  heading to jump to it; the current section is highlighted as the user
  scrolls. Must be toggleable (long agent reports are unreadable without it;
  short notes don't need it)."
- Source: `documents/tasks/2026/07/daily-use-feature-backlog.md` item 2
  (Tier 1). Scope is item 2 ONLY — no other backlog items.
- Backlog item 1 (live reload preserving scroll) just shipped on this branch
  (commit 040493c): `render()` in `template.html` re-renders `#content` and
  restores window scroll. The TOC must stay consistent after such a
  re-render — headings are re-created DOM nodes, so any cached heading
  references die on every reload.
- Architecture rule (AGENTS.md): native shell owns chrome; the web view owns
  only content rendering. Precedent: the find feature keeps the bar/menu/keys
  native while highlighting lives in the page.
- Documented bridge decision (SRS §5 Interfaces, SDS §3.4): currently NO
  `WKScriptMessageHandler` — all traffic is native→web via
  `callAsyncJavaScript`; web→native is limited to navigation-delegate link
  interception. Continuous scroll-spy needs web→native pushes, which this
  decision currently forbids — the plan must either change it (documented) or
  work around it.

### Current State

- `Sources/Markio/ContentView.swift` — one window: `PreviewView` + find HUD
  overlay + bottom width bar. No sidebar, no split layout.
- `Sources/Markio/DocumentModel.swift` — per-window state (width, find);
  `start`/`reloadFromDisk`/`appearanceChanged` all funnel into
  `preview.render(text)`; after re-render it re-applies an active find
  (`reapplyFindIfActive`) — the same hook point a TOC refresh needs.
- `Sources/Markio/PreviewController.swift` — owns `WKWebView`, no message
  handlers; native→web calls via `callAsyncJavaScript`; navigation delegate
  gates links (`LinkPolicy`).
- `Sources/Markio/Resources/template.html` — `render()` sanitizes and inserts
  HTML, runs Mermaid, restores scroll. Headings render as plain `<h1>`–`<h6>`
  with NO ids (markdown-it default — no anchor plugin), so there is no
  addressable target for jumps yet.
- `Sources/Markio/FindCommands.swift` — pattern for app-level menu commands
  routed to the focused window's `DocumentModel` via `@FocusedValue`.
- `Sources/Markio/ContentWidthStore.swift` — pattern for a persisted global
  reading preference (`UserDefaults`).
- `Sources/Markio/Snapshot.swift` — App Store screenshots capture only the
  `WKWebView` (`takeSnapshot`), not native chrome.
- Tests: `Tests/MarkioTests/` exercises the page via
  `PreviewController.evaluate` (`FindTests`, `LiveReloadTests`,
  `RenderTests`) — the established pattern for testing page-side behavior;
  `PreviewTestSupport.makeLoadedPreview()` boots a loaded controller.

### Constraints

- Native first (priority 1), minimalism (2), UX (3). Read-only viewer; no new
  dependencies; fully offline (vendored assets only).
- The find feature's division of labor is the precedent: native chrome, page
  owns content-side mechanics.
- Scope: backlog item 2 only. No command palette (item 18), no copy-anchor
  (item 11), no section folding (item 16), no `#anchor` link navigation
  (item 6) — even though heading ids are groundwork for 6/11.
- Swift 6 strict concurrency: AppKit/WebKit glue must follow the SDS §7
  patterns (`@MainActor` coordinators, `MainActor.assumeIsolated` in
  `@Sendable` callbacks).
- `make check` (build + comment-scan + format lint + all tests) must stay
  green; menu changes verified in a real `.app` bundle per AGENTS.md.

### Affected Surface

Surface-scout output (verbatim):

```
## Surface

- **Sources/Markio/Resources/template.html** — render function must preserve scroll position when TOC initiates a jump (currently only preserves reader's manual scroll); needs heading extraction and ID assignment; needs current-section tracking on scroll events
- **Sources/Markio/PreviewController.swift** — needs new methods: getHeadings() (extract tree), scrollToHeading(id), setCurrentSection(id); must marshal TOC calls via callAsyncJavaScript
- **Sources/Markio/DocumentModel.swift** — needs @Published tocPresented (toggle state), headings data (tree structure), currentSectionId; needs methods: toggleTOC(), updateHeadings(), scrollToHeading()
- **Sources/Markio/ContentView.swift** — layout must split main area into webview + resizable sidebar; sidebar renders heading tree; sidebar handles heading clicks → model.scrollToHeading()
- **Sources/Markio/MarkioApp.swift** — needs TOCCommands (parallel to FindCommands) registered in .commands block for View ▸ Toggle TOC menu + keyboard shortcut
- **Sources/Markio/ContentWidthStore.swift or new TOCVisibilityStore** — persist TOC visibility state per window via UserDefaults key (tocSidebarVisible or similar)
- **Tests/MarkioTests/RenderTests.swift** — new test: heading extraction from GFM (h1–h6, nested structure, ID generation); verify IDs are unique and scroll-safe
- **Tests/MarkioTests/LiveReloadTests.swift** — new test: TOC heading tree updates on file change; current section highlight refreshes; TOC scroll position independent from main content scroll
- **Tests/MarkioTests/ (new file: TOCTests.swift)** — tests for: tree structure with mixed heading levels, click-to-scroll behavior, current-section highlight as main webview scrolls, TOC state persists across appearance changes
- **documents/requirements.md** — new FR-TOC-SIDEBAR: sidebar with heading tree, click-to-jump, current-section highlight on scroll, toggleable via menu + shortcut, persists across live reload
- **documents/design.md** — new component section: TOCController (manages heading extraction and scroll events), TOCSidebar UI, integration with DocumentModel; data model for heading tree; scroll-position independence between TOC and main content
- **Sources/Markio/Resources/vendor/markdown-it/** — may need custom rule to inject heading IDs (id="heading-slug") if markdown-it doesn't auto-generate them; verify GFM heading rendering includes accessible anchors
- **Makefile** — no changes if template.html inlining already handles all vendor content; verify `make check` includes new TOC tests
- **Sources/Markio/PreviewView.swift** (if exists) or WebViewHost equivalent — webview host must expose a way to receive heading updates from the page (either callback on render, or query after render settles)
- **Package.swift** — verify resource bundle includes template.html with no changes needed unless new vendor libs required
- **Sources/Markio/FindBarControls.swift** or similar pattern — TOC sidebar may reuse similar floating/overlay HUD patterns; check for naming/component overlap
- **Window state restoration** — DocumentGroup + SwiftUI's scene storage may auto-restore TOC visibility per window; verify @SceneStorage integration if needed
- **Menu cleaner (MenuArtifactCleaner.swift)** — if TOC toggle becomes a top-level menu item, verify artifact removal handles it properly on systems where menu is empty
- **ScrollIntoView behavior** — the existing find-bar code uses scrollIntoView(); TOC heading clicks must use same semantics to avoid conflicts or double-scrolls
- **Tests/MarkioTests/FindTests.swift** — regression: ensure find highlighting doesn't interfere with heading IDs or TOC click targets

## Could not rule out

- Whether heading IDs are auto-generated by markdown-it or require a custom plugin
- Whether WKWebView's scrollIntoView block parameter interacts with TOC-driven scrolls (potential UX issue: center vs. nearest neighbor)
- Whether DocumentGroup's state restoration automatically persists per-window UserDefaults keys or requires explicit @SceneStorage binding
- Whether sidebar resize state should persist globally or per-document window
- Whether the "current section highlight during scroll" should snap instantly or fade in (affects JS scroll-event listener debouncing strategy)
- Performance impact of heading tree extraction on very large documents (1 MB+) — may require incremental parsing or memoization
```

Union dispositions (planner ∪ scout):

- `Sources/Markio/Resources/template.html` (heading ids, outline extraction, jump, scroll-spy) — covered-by Solution steps 1–3 / DoD items 1–3
- `Sources/Markio/PreviewController.swift` (outline/jump bridge, scroll-spy delivery) — covered-by Solution step 4
- `Sources/Markio/DocumentModel.swift` (outline state, current section, toggle, refresh-after-render) — covered-by Solution step 5
- `Sources/Markio/ContentView.swift` (sidebar layout + heading rows) — covered-by Solution step 6
- `Sources/Markio/MarkioApp.swift` (register TOC menu command) — covered-by Solution step 7
- New visibility persistence (`TOCStore`, file `Sources/Markio/TOCStore.swift`) — covered-by Solution step 5 / DoD item 4
- New `Tests/MarkioTests/TOCTests.swift` — covered-by DoD items 1–5 (all acceptance tests live here)
- `Tests/MarkioTests/RenderTests.swift` — not affected — heading/outline acceptance tests live in the new `TOCTests.swift` per DoD; RenderTests keeps its FR-GFM/FR-MERMAID scope
- `Tests/MarkioTests/LiveReloadTests.swift` — not affected — the re-render-consistency case is `TOCTests.swift::testOutlineSurvivesRerender` (DoD item 5); LiveReloadTests unchanged
- `documents/requirements.md` (new FR-TOC + §5 bridge decision update) — covered-by DoD item 6
- `documents/design.md` (new TOC component section + bridge decision) — covered-by DoD item 6
- `Sources/Markio/Resources/vendor/markdown-it/**` — not affected — markdown-it emits no heading ids by default; ids are assigned by a post-render DOM walk in `template.html` (no new vendor plugin, offline constraint holds)
- `Makefile` — not affected — `make check` runs `swift test` which auto-discovers new XCTest files (Makefile `check` target has no per-file test list)
- `Sources/Markio/PreviewView.swift` — not affected — thin `NSViewRepresentable` wrapper around the web view (Sources/Markio/PreviewView.swift, 19 lines); outline traffic goes through `PreviewController`
- `Package.swift` — not affected — no new bundle resources or targets; new Swift/test files are auto-discovered by SPM
- `Sources/Markio/FindBarControls.swift` — not affected — the sidebar is a split-panel layout, not a floating HUD; no shared components with the find bar
- Window state restoration / `@SceneStorage` — covered-by Solution step 5: visibility is a global reading preference in `UserDefaults` (same semantics as `ContentWidthStore`), not per-window scene state
- `Sources/Markio/MenuArtifactCleaner.swift` — not affected — the TOC command joins the View menu via `CommandGroup(before: .sidebar)`-style insertion; no command group is emptied, and the cleaner only strips artifacts of emptied groups
- `scrollIntoView` interplay with find — covered-by Solution step 3: TOC jumps use `block:'start'` (heading to viewport top, standard TOC semantics); find keeps `block:'center'`; the two never run concurrently from one gesture
- `Tests/MarkioTests/FindTests.swift` — not affected — find wraps text nodes only; element `id` attributes are untouched by mark-splicing; full suite runs in `make check` regardless

## Definition of Done

- [x] FR-TOC: the sidebar lists the document's headings as a tree (h1–h6,
  nesting visible), in document order
  - Test: `Tests/MarkioTests/TOCTests.swift::testOutlineExtractsHeadingTree`
  - Evidence: `NO_COLOR=1 swift test --filter TOCTests`
- [x] FR-TOC: clicking a heading jumps the preview to that heading
  - Test: `Tests/MarkioTests/TOCTests.swift::testJumpScrollsToHeading`
  - Evidence: `NO_COLOR=1 swift test --filter TOCTests`
- [x] FR-TOC: the current section is highlighted and follows the reader's
  scroll position
  - Test: `Tests/MarkioTests/TOCTests.swift::testCurrentSectionTracksScroll`
  - Evidence: `NO_COLOR=1 swift test --filter TOCTests`
- [x] FR-TOC: the sidebar is toggleable (View menu + keyboard shortcut) and
  the visibility choice persists across launches
  - Test: `Tests/MarkioTests/TOCTests.swift::testSidebarVisibilityPersists`
  - Evidence: `NO_COLOR=1 swift test --filter TOCTests`
- [x] FR-TOC: after a live re-render the TOC still matches the document and
  jump/highlight keep working (item-1 interplay)
  - Test: `Tests/MarkioTests/TOCTests.swift::testOutlineSurvivesRerender`
  - Evidence: `NO_COLOR=1 swift test --filter TOCTests`
- [x] FR-TOC: SRS gains an FR-TOC section with filled `**Acceptance:**`; SDS
  documents the TOC component and any bridge-decision change
  - Test: docs — SRS/SDS sections updated in the same commit
  - Evidence: `grep -q "FR-TOC" documents/requirements.md`

## Solution

Selected variant: **B — native sidebar + outline pull + a single scroll-spy
message handler** (relay decision 2026-07-13). Variant C (NavigationSplitView
adoption) recorded under Follow-ups.

Division of labor (mirrors the find feature): the page owns content mechanics
(heading ids, outline extraction, jump scrolling, current-section math); the
native shell owns all chrome (sidebar view, menu, shortcut, persistence).
Bridge-decision change: the app gains its FIRST `WKScriptMessageHandler` —
exactly one, read-only, page→native, payload = current heading id (string).
SRS §5 + NFR Sec + SDS §3.4 are updated accordingly.

### Steps

1. **Page — heading ids** (`Sources/Markio/Resources/template.html`): after
   `innerHTML` assignment in `render()`, walk `#content` `h1–h6` in document
   order and assign GitHub-style slug ids (lowercase, spaces→`-`, strip
   punctuation, keep unicode letters/digits/`-`/`_`; duplicates deduped with
   `-1`, `-2`, … suffixes). Cache the heading elements + ids in a module var
   (`__toc`), rebuilt on every render (re-render safety — DOM nodes are new).
2. **Page — outline API**: `getOutline()` returns
   `[{level, text, id}]` from the cache; `scrollToHeading(id)` scrolls the
   heading to the viewport top (`scrollIntoView({block:'start'})`), returns
   whether the id existed; `getCurrentSection()` returns the id of the last
   heading whose top edge is at/above a small viewport-top threshold (fallback:
   first heading; empty string when the document has no headings). Headings
   whose trimmed text is empty are excluded from the outline (no navigational
   meaning) but still receive ids.
3. **Page — scroll spy**: a `scroll` listener (computed synchronously — the
   cached heading list makes it O(headings); no rAF, which does not fire in
   offscreen test web views) recomputes the current section and, when it
   changes, posts the id via
   `window.webkit.messageHandlers.markioTOC.postMessage(id)` (guarded — absent
   handler is a no-op so the page also works under plain `evaluate` tests).
   Change detection: the listener remembers the last posted id and posts only
   on a transition — rapid scrolling produces at most one message per section
   boundary crossed, never a message storm.
   Jump scrolling reuses the same path; find keeps `block:'center'` semantics.
4. **Native — bridge** (`Sources/Markio/PreviewController.swift`):
   - `struct TOCItem: Equatable, Identifiable { level: Int; text: String; id: String }`
     (sibling of `FindResult`).
   - `outline() async -> [TOCItem]` (`return getOutline();` — decode array of
     dicts; bridge failure → logged, returns `[]`, best-effort like find),
     `scrollToHeading(_ id: String) async`, `currentSection() async -> String?`.
   - Register `WKScriptMessageHandler` for name `markioTOC` on the
     configuration's `userContentController` via a weak proxy `NSObject`
     (`ScriptMessageProxy`) — the content controller retains its handler
     strongly, a direct self-registration would cycle
     webView→config→handler→controller.
   - `var onCurrentSectionChange: ((String) -> Void)?` invoked on the main
     actor with the validated string payload.
   - Update the `init` doc comment — it currently reads "no message handlers"
     and would go stale (plan-critic finding).
5. **Native — state + persistence** (`Sources/Markio/DocumentModel.swift`, new
   `Sources/Markio/TOCStore.swift`): `TOCStore` persists `tocSidebarVisible`
   (Bool, default `false`, injectable `UserDefaults` suite — same shape as
   `ContentWidthStore`; a global reading preference, not per-window scene
   state). `DocumentModel` gains `@Published tocVisible/outline/
   currentHeadingID`, `toggleTOC()` (flip + persist), `jumpToHeading(id)`, and
   a private `refreshOutline()` called after every render — in `start`,
   `reloadFromDisk`, and `appearanceChanged`, right next to
   `reapplyFindIfActive()` (item-1 interplay: outline re-pulled after each live
   re-render). Wires `preview.onCurrentSectionChange` → `currentHeadingID`.
6. **Native — sidebar UI** (new `Sources/Markio/TOCSidebar.swift`,
   `Sources/Markio/ContentView.swift`): `ContentView` body becomes
   `HStack(spacing: 0) { if model.tocVisible { TOCSidebar(...); Divider() };
   preview }`; find overlay stays on the preview pane; the bottom width bar
   spans the whole window (safe-area inset on the HStack). `TOCSidebar`:
   fixed-width (220 pt) native `ScrollView` + `LazyVStack` of plain buttons —
   indentation `12 pt × (level−1)`, secondary text, current row highlighted
   (accent-tinted rounded background); `ScrollViewReader` keeps the current row
   visible as the reader scrolls; click → `model.jumpToHeading(id)`. Empty
   outline → a dimmed "No headings" placeholder.
7. **Native — menu + shortcut** (new `Sources/Markio/TOCCommands.swift`,
   `Sources/Markio/MarkioApp.swift`): `TOCCommands: Commands` adds
   `View ▸ Show/Hide Table of Contents` (`⌥⌘S`, the macOS sidebar-toggle
   convention — Finder/Mail) via `CommandGroup(after: .sidebar)` and the
   existing `FocusedValue(\.documentModel)` routing; registered in
   `MarkioApp.commands`. Disabled when no document window is focused.
8. **Tests** (new `Tests/MarkioTests/TOCTests.swift`, TDD RED-first, DoD
   items 1–5): outline extraction (levels/order/dedup), jump, scroll-spy
   (pull assertion via `getCurrentSection` + full push path polled through
   `onCurrentSectionChange`), `TOCStore` persistence round-trip on a private
   suite, outline consistency across re-render.
9. **Docs**: SRS — new `### 3.15 FR-TOC` (`[ANC:fr:toc]`, `**Tasks:**`
   back-pointer to this task, filled `**Acceptance:**`), §5 Proto updated
   (outline/jump native→web; the single `markioTOC` page→native handler), NFR
   Sec updated (bridge wording). SDS — §3.4 WebViewHost "no message handler"
   decision superseded (one read-only handler), new component `3.8 TOCSidebar`,
   §2 subsystems + §5 Logic touched, §7 "Deferred: … TOC sidebar" entry
   removed. `documents/index.md` FR row added.
10. **Verification**: `make fmt` → `make check` (build, comment-scan, format
    lint, full test suite) green; `make app` + osascript menu dump confirms the
    View-menu item in a real bundle; evidence commands from DoD.

### Error handling

All bridge calls are best-effort with logged failures (`Log.preview`),
matching the established find/render contract: `outline()` → `[]`,
`currentSection()` → `nil`, `scrollToHeading` → logged no-op. The message
handler validates the payload type (non-empty `String`) and drops anything
else. A document with no headings renders an empty sidebar (placeholder), no
errors.

### Dependencies

None added. All page-side logic is hand-written in `template.html` (no new
vendor libs); native side is SwiftUI/WebKit only.

## Follow-ups

- Variant C (NavigationSplitView window restructure — system sidebar material,
  toolbar toggle) recorded as a possible future evolution if a file-tree /
  multi-column navigation ever lands; out of scope now (minimalism).
- Sidebar resize/width persistence deferred — fixed 220 pt in v1.
- Heading ids are groundwork for backlog items 6 (`#anchor` links) and 11
  (copy heading anchor) — both explicitly NOT implemented here.
