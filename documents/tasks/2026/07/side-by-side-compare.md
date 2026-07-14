---
date: 2026-07-14
status: in progress
implements:
  - FR-COMPARE
tags: [compare, scroll-sync, differentiation]
---
# Side-by-side compare — two documents with synchronized scrolling [ANC:task:2026-07-side-by-side-compare]

## Goal

Parallel READING of two Markdown documents (spec v1 vs v2, agent report before/after) with synchronized scrolling. NOT a diff editor. No competitor (Meva, Markdown Lens, Clearly Markdown, MarkFlow, Read.md) has it — a 4.3(a) differentiation driver (backlog item 9).

## Overview

### Context

- Backlog: `documents/tasks/2026/07/daily-use-feature-backlog.md` item 9 (Tier 2). Items 1–8 already shipped on `feature/daily-use-wave1`.
- Existing model: strictly one window per document (`DocumentGroup`, tabbing disabled — FR-MULTIDOC). Per-window state: `DocumentModel` owns preview, watcher, TOC, find, width.
- Scroll plumbing already exists: page → native `markioScroll` (250 ms true-debounced, persistence-oriented) and native → page `setScrollY(y)` / `getScrollY()` (`template.html`, `PreviewController`).
- Registry precedent: `LocalLinkNavigator.attach(_:)` keeps weak per-window targets keyed by document URL — the same pattern fits a compare coordinator.
- Open-second-file precedent: powerbox `NSOpenPanel` + `NSDocumentController.shared.openDocument` (sandbox grant flow) from FR-LOCAL-LINKS.

### Current State

- `Sources/Markio/DocumentModel.swift` — per-window state; `start()` attaches to `LocalLinkNavigator`; no cross-window coordination beyond link anchors.
- `Sources/Markio/PreviewController.swift` — four one-way page→native handlers (`markioTOC`, `markioCopy`, `markioScroll`, `markioLink`); `setScrollY` native→page.
- `Sources/MarkioEngine/Resources/template.html` — `markioScroll` posts a debounced absolute Y (too slow/coarse for live sync); no scroll-fraction API, no sync-mode reporting.
- No pairing concept anywhere; windows are fully independent.

### Constraints

- Native first; minimalism; priority order 1) nativeness 2) minimalism 3) UX.
- Read-only viewer; NOT a diff editor — no content comparison, no highlighting of differences.
- Keep the window-per-document model intact (FR-MULTIDOC) — no merged multi-pane document windows in v1.
- Offline; message-handler payloads stay single-string (SRS §4 Sec).
- Per-window state (TOC, find, width, scroll persistence) must keep working unchanged in compared windows.
- Proportional scrollY-fraction mapping is the accepted v1 mapping precision.
- Menu/window arrangement effects verifiable only in a real `.app` (`make app`).

### Affected Surface

Scout output (verbatim):

```
## Surface

**App shell & window management:**
- `Sources/Markio/MarkioApp.swift` — DocumentGroup entry point (lines 1-25); currently one window per file, requires decision on pair-window lifecycle (both close together? independent?), menu for initiating side-by-side — Evidence: `DocumentGroup(viewing:)` owns the window-per-document model.
- `Sources/Markio/MarkioApp.swift` → `AppDelegate` (lines 47-98) — `NSApplication` lifecycle; window tabbing disabled (line 55); state restoration configured (lines 54-69); side-by-side may need app-level state (which pairs exist?) or defer to per-file recent-files — Evidence: `NSWindow.allowsAutomaticWindowTabbing = false`, `NSQuitAlwaysKeepsWindows`.

**Content view & layout:**
- `Sources/Markio/ContentView.swift` (lines 1-192) — single document + optional TOC sidebar + find bar; layout is HStack with sidebar on left. Side-by-side requires: (1) layout variant (two-column instead of one), (2) which TOC shown (left doc only? both? toggle?), (3) find bar scope (per-window or shared?), (4) bottom bar line-width control (per-doc or shared?) — Evidence: lines 15-30 `HStack` layout; lines 17-22 conditional TOC; lines 27-29 find HUD overlay; lines 33-34 bottom bar.

**Document model & state:**
- `Sources/Markio/DocumentModel.swift` (lines 1-222) — per-window state owner: preview, file watcher, width, TOC, find, scroll. Side-by-side requires: (1) which model initiates sync? (2) who owns the scroll-sync algorithm? (3) independent file watchers (live reload in one doc doesn't break the other?), (4) can both docs share a line-width control or independent? — Evidence: lines 8-56 state fields (`preview`, `widthStore`, `tocStore`, `scrollStore`, `findPresented`, etc.); lines 39-55 callbacks (`onCurrentSectionChange`, `onScrollPositionChange`, `onLinkActivated`).

**Preview controller & web view:**
- `Sources/Markio/PreviewController.swift` (lines 1-73+) — owns WKWebView; one instance per window; scroll position change fires `onScrollPositionChange` callback (lines 23-25). Side-by-side requires: (1) two web views (one per document), (2) a sync coordinator that watches both scroll positions and pushes one to the other (proportional or absolute mapping?), (3) both web views process scroll events independently but one drives the other — Evidence: lines 23-25 scroll callback; scroll message handler receives `markioScroll` (line 56).

**Scroll synchronization (NEW component):**
- Needs new `ScrollSynchronizer` or similar — owns two `PreviewController`s' scroll positions, implements sync algorithm, debounces to avoid feedback loops, persists sync state preference — Evidence: none yet; this is a new surface.

**Window pairing/lifecycle (NEW component):**
- Needs representation of "this window is paired with that window" — which window stays open when one is closed? Are they symmetric or primary/secondary? — Evidence: none yet; decision required before implementing.

**Menu commands & routing:**
- `Sources/Markio/MarkioApp.swift` (lines 19-23) — `.commands { }` block adds `ReadOnlyMenuCommands`, `FindCommands`, `TOCCommands`; side-by-side needs new menu item (e.g., File > Open in Compare mode, or View > Split Vertically) — Evidence: command registration pattern.
- `Sources/Markio/FindCommands.swift` (lines 1-38) — app-level Find menu uses `@FocusedValue(\.documentModel)` to route to the key window. Side-by-side requires: does Find apply to both documents? left only? toggle focus? — Evidence: lines 5, 20 `@FocusedValue` routing; lines 25-33 menu button handlers.
- `Sources/Markio/TOCCommands.swift` (lines 1-22) — View menu toggle uses same pattern. Side-by-side requires similar routing decision — Evidence: line 7 `@FocusedValue(\.documentModel)`.
- `Sources/Markio/MenuArtifactCleaner.swift` — artifact removal for menu groups may need updates if a new command group is added.

**TOC sidebar & state:**
- `Sources/Markio/TOCSidebar.swift` (lines 1-...) — native sidebar for one document's headings. Side-by-side requires: (1) which document's TOC shown? (2) two sidebars (clutter vs clarity), or one TOC that toggles between the two documents, or one TOC for left + one for right? — Evidence: sidebar is driven by `model.outline` and `model.currentHeadingID`.
- `Sources/Markio/TOCStore.swift` — visibility preference per app; side-by-side may need per-pair or per-document TOC visibility state.

**Find bar & search:**
- `Sources/Markio/FindBarControls.swift` — floating HUD; currently searches the focused window only. Side-by-side requires: (1) search both documents? (2) show results per document (e.g., "5 in left, 3 in right")? (3) next/prev cycles within current doc or across both? — Evidence: find state lives in `DocumentModel`.
- `Sources/Markio/FindCommands.swift` (mentioned above) — routing.

**Line-width control:**
- `Sources/Markio/ContentView.swift` (lines 135-157 `bottomBar`) — control is per-window. Side-by-side decision: single slider for both documents (synchronized width) or independent per-document? — Evidence: lines 140-151 slider binding to `model.contentWidth`.
- `Sources/Markio/ContentWidthStore.swift` — per-app `UserDefaults` key `contentWidthChars`; side-by-side may persist separate widths per document or a shared pair-width.

**Scroll position persistence:**
- `Sources/Markio/ScrollPositionStore.swift` (lines 1-...) — persists one scroll Y per file path in `UserDefaults`. Side-by-side requires: (1) when a pair is opened on relaunch, do both documents restore their individual scroll positions? (2) or is there a "pair scroll position" (proportional offset)? — Evidence: `scrollPositions: [path: {y, seq}]` map; used in `DocumentModel.start()` (SDS line 82).

**Web-side rendering & scroll:**
- `Sources/MarkioEngine/Resources/template.html` (lines 630-862) — render, scroll, find, TOC functions. Side-by-side requires: (1) when one web view scrolls, does it post a message to native for sync? (2) new message handler for "sync-to-this-position-on-peer"? (3) or all scroll events post as usual and native sync layer decides? — Evidence: lines 840-854 scroll debounce and post to `markioScroll`; lines 858-862 `setScrollY()` API.

**File opening & drag-drop:**
- `Sources/Markio/ContentView.swift` (lines 48-64 `handleDrop`) — drag a file opens it in a new window. Side-by-side requires: (1) new drag target to mean "open in comparison"? (2) or new UI flow (File menu > Open in Compare > choose file)? (3) or Cmd+click on a file in Finder? — Evidence: lines 50-62 drag handler uses `@Environment(\.openDocument)` to open in new window.
- `Sources/Markio/LocalLinkNavigator.swift` — relative Markdown links open new windows; side-by-side requires: do they open in compare mode or standalone? — Evidence: `follow(href:from:)` uses `NSDocumentController.openDocument`.

**Local link navigation with pairs:**
- `Sources/Markio/LocalLinkNavigator.swift` — when opening `other.md#section` and both docs are visible side-by-side, does the anchor scroll the appropriate document or always the most recently active? — Evidence: links route through native open path.

**Window title & path display:**
- `Sources/Markio/WindowTitleSetter.swift` — shows full file path in title bar. Side-by-side windows both show paths; no change needed unless a merged window is desired (unlikely).

**Documentation:**
- `documents/requirements.md` (SRS) — FR-MULTIDOC (line 19) currently enforces one window per document. Side-by-side is an exception or new FR? Likely new FR-COMPARE, which notes the limitation and how it composes with multidoc — Evidence: line 20 "strictly one window per document".
- `documents/design.md` (SDS) — §2 Arch (lines 7-32) and §3 Components will need updates: new subsystem for sync coordinator, new layout variant in ContentView, possibly new state in AppDelegate or app-wide model. §5 Logic will document the sync algorithm (proportional scroll? absolute? debounce strategy?).
- `documents/tasks/2026/07/daily-use-feature-backlog.md` (lines 1-58) — backlog item 9 (lines 34) references this feature; a task file will be created at `documents/tasks/2026/07/side-by-side-compare.md` with design decisions (variants: how pair is opened, how sync works, how layout is organized).

**Tests:**
- New tests for scroll synchronization: `Tests/MarkioTests/SyncScrollTests.swift` (hypothetical) — test that two PreviewControllers' scroll positions track proportionally/absolutely — Evidence: pattern from existing tests like `LineWidthTests.swift`, `TOCTests.swift`.
- New tests for window pairing lifecycle: verify windows close/reopen together if paired; verify unpaired windows are independent — Evidence: pattern from `SessionRestoreTests.swift`.
- Menu routing tests: verify Find/TOC commands route to correct window in side-by-side layout.
- Drag-drop and file-open tests: verify new comparison-open paths work.
- Integration test: render two documents side-by-side, scroll one, verify the other synchronizes.

**Configuration & packaging:**
- `Makefile` (lines 1-113) — build system; no changes needed unless new build steps for bundling pair state.
- `Package.swift` (lines 1-63) — no changes needed; same targets, same dependencies.
- `packaging/Info.plist` — no changes needed unless multi-window app-level state requires new keys (unlikely; AppKit state restoration handles it).

**Per-window state isolation:**
- Each `DocumentModel` owns its own `PreviewController`, `FileWatcher`, width/TOC/scroll stores. Side-by-side sync layer will create a NEW coordination mechanism (sync coordinator) that sits ABOVE the two independent DocumentModels and coordinates scroll only — Evidence: current design is per-window-independent; sync is a new cross-window concern.

## Could not rule out

- **Window lifecycle pairing semantics** — if windows are "paired", closing one may close the other (user-hostile) or open independently (loses the UX metaphor).
- **Scroll sync algorithm** — proportional vs absolute vs heading-based vs time-based.
- **Focus and key events** — which window's TOC/Find bar is active when both are visible.
- **Per-document vs. shared reading width.**
- **Drag-and-drop into a pair.**
```

Union dispositions (planner ∪ scout):

- `Sources/Markio/MarkioApp.swift` (commands registration + AppDelegate) — covered-by Solution step 4 (register `CompareCommands`)
- New pairing + sync coordinator (`CompareCoordinator`) — covered-by Solution steps 2–3 and DoD items 1–3; closure semantics: windows are symmetric peers, closing one only drops the pair — the other window stays open and independent (weak refs, no close-coupling)
- `Sources/Markio/DocumentModel.swift` — covered-by Solution step 3 (attach/expose sync hooks; per-window state otherwise untouched)
- `Sources/Markio/PreviewController.swift` — covered-by Solution step 2 (sync scroll channel + fraction API)
- `Sources/MarkioEngine/Resources/template.html` — covered-by Solution step 1 (sync-mode reporting + fraction get/set + echo suppression)
- `Sources/Markio/ContentView.swift` two-pane layout — not affected — chosen variant keeps two separate windows; per-window layout unchanged (`ContentView.swift:16` HStack untouched)
- `Sources/Markio/FindCommands.swift`, `TOCCommands.swift`, `FindBarControls.swift`, `TOCSidebar.swift`, `TOCStore.swift` — not affected — per-window state stays per-window; `@FocusedValue` already routes menus to the key window (`FindCommands.swift`, `TOCCommands.swift` inspected)
- Line-width control (`ContentWidthStore.swift`, bottom bar) — not affected — remains the existing global preference applied per window (`ContentView.swift:135-157`)
- `Sources/Markio/ScrollPositionStore.swift` — not affected — sync-driven scrolls flow through the existing debounced `markioScroll` persistence; each document keeps its own saved position (`template.html:836-850`)
- `Sources/Markio/LocalLinkNavigator.swift` — not affected — link-driven opens never auto-join a pair (explicit menu action only); registry pattern reused, code untouched (`LocalLinkNavigator.swift` inspected)
- `Sources/Markio/WindowTitleSetter.swift`, `MarkdownDocument.swift`, `FileLoader.swift`, `FileWatcher.swift` — not affected — file I/O and titles are per-document and unchanged
- `Sources/Markio/MenuArtifactCleaner.swift` — not affected in code — new command group adds a real item, not a placeholder; verified via manual checklist (DoD item 4)
- `Makefile`, `Package.swift`, `packaging/Info.plist` — not affected — no new targets, resources, or plist keys (inspected)
- SRS / SDS / `documents/index.md` / README — covered-by DoD items 2 and 5
- Pair persistence across relaunch — deferred — human choice (see Follow-ups)
- Drag-a-file-to-compare gesture — deferred — human choice (see Follow-ups)
- Find/TOC jump in one window moving the peer (sync follows any scroll, incl. programmatic jumps) — covered-by Solution step 1 (deliberate: sync mirrors every scroll; documented in SDS)

## Definition of Done

- [x] FR-COMPARE: scrolling one of two linked previews scrolls the other to the same fraction of ITS OWN scrollable height (`scrollY / (scrollHeight − viewport)` equal on both sides), in both directions
  - Test: `Tests/MarkioTests/CompareTests.swift::testScrollMirrorsToLinkedPeerProportionally`
  - Evidence: `make test ARGS="--filter CompareTests"`
- [x] FR-COMPARE: mirroring produces no feedback loop (applying a synced position does not re-emit a sync event that moves the source)
  - Test: `Tests/MarkioTests/CompareTests.swift::testNoFeedbackLoopBetweenLinkedPeers`
  - Evidence: `make test ARGS="--filter CompareTests"`
- [x] FR-COMPARE: unlinking stops mirroring; closing/deallocating either side drops the pair (weak references, no retain)
  - Test: `Tests/MarkioTests/CompareTests.swift::testUnlinkStopsMirroring`; `Tests/MarkioTests/CompareTests.swift::testDeallocatedPeerDropsPair`
  - Evidence: `make test ARGS="--filter CompareTests"`
- [ ] FR-COMPARE: `File ▸ Compare Side by Side…` in a real `.app` prompts for the second file, opens it, tiles both windows left/right, and enables sync; `File ▸ Stop Comparing` unlinks
  - Test: `manual — maintainer — documents/checklists/compare.md`
  - Evidence: `make app && open .build/Markio.app` + checklist walk
- [x] FR-COMPARE: SRS section added with filled `**Acceptance:**` (anchor `fr:compare`), SDS component section added, `documents/index.md` row added, README updated
  - Test: SRS/SDS/index/README diff present in the same commit
  - Evidence: `grep -q "FR-COMPARE" documents/requirements.md documents/design.md documents/index.md README.md`

## Solution

Selected: **Variant B — window pairing + live proportional sync channel.** Two normal document windows (window-per-document intact), paired by a coordinator; the page reports a live scroll fraction over a new one-way single-string channel; echo suppressed one-shot on the page.

### Step 1 — Page sync API (`Sources/MarkioEngine/Resources/template.html`)

- `setCompareSync(enabled)` — toggles live sync reporting (default off; QL extension never enables it).
- Scroll listener (the existing one): when sync is enabled, post `String(fraction)` to `webkit.messageHandlers.markioSyncScroll` on **every** scroll event (no debounce — this channel is for live mirroring; the debounced `markioScroll` persistence channel is untouched). `fraction = scrollY / max(1, scrollHeight − innerHeight)`, clamped to [0,1]; a non-scrollable document reports 0.
- One-shot echo suppression: `setScrollFraction(f)` computes the target Y; if it differs from the current Y by >1 px, sets `__compareSuppress = true` and scrolls; the next scroll event consumes the flag and does NOT post to the sync channel. If the target equals the current position, the flag is NOT set (no event will fire — a lingering flag would swallow the next genuine user scroll).
- `setScrollFraction(f)` returns the applied fraction; `getScrollFraction()` for seeding/tests. Guarded no-op when the handler is absent (headless/QL).

### Step 2 — Native bridge (`Sources/Markio/PreviewController.swift`)

- Fifth `ScriptMessageProxy` registered as `markioSyncScroll`; handler validates a string parseable as a finite Double in [0,1] (else dropped) → `onSyncScroll: ((Double) -> Void)?` callback.
- `setCompareSync(_ enabled: Bool) async` and `@discardableResult setScrollFraction(_ f: Double) async -> Double?` via `callAsyncJavaScript` — best-effort, log on failure (same contract as `setScrollY`).

### Step 3 — `CompareCoordinator` (new `Sources/Markio/CompareCoordinator.swift`) + `DocumentModel` glue

- `protocol CompareTarget: AnyObject` — `documentURL: URL?`, `setCompareSyncEnabled(Bool) async`, `applyScrollFraction(Double) async`, `pushCurrentState() async` (seed peer on link), `hostWindow: NSWindow?`.
- `@MainActor final class CompareCoordinator` (`static let shared`; init takes an injectable open primitive like `LocalLinkNavigator`): weak registry of attached targets (`attach(_:)` from `DocumentModel.start`, mirroring the link-navigator pattern); one weak `Pair` (a,b) per window — a window is in at most one pair; a new compare replaces its old pair.
- `beginCompare(from:)` — powerbox `NSOpenPanel` (Markdown types, explanatory message; the user's "Open" click IS the sandbox grant, same as FR-LOCAL-LINKS) → picking the initiator's own document is a guarded no-op (FR-MULTIDOC means the same file can never occupy two windows, so self-pairing is impossible by construction — recorded as a constraint, not a test) → if the picked URL is already attached, link directly; else record a pending pair and open via `NSDocumentController.shared.openDocument` (already-open file focuses; window-per-document preserved). **Sequencing:** a pending pair completes only from the new window's `DocumentModel.start()` AFTER its first render finishes (attach happens post-render), so the peer's page is scrollable before any fraction is applied; seeding (initiator's current fraction → peer) always runs after the link is established. On link: enable sync on both, seed the peer, tile windows.
- `scrollChanged(from:fraction:)` — re-entrancy-guarded; applies the fraction to the peer. Page-side one-shot suppression prevents the echo; the native guard prevents synchronous re-entry.
- `unlink(for:)` — disables sync on both sides; deallocated/closed windows drop out via the weak refs (no retain, no close-coupling: closing one window never closes the other).
- Tiling: pure `func tileFrames(in screen: NSRect) -> (left: NSRect, right: NSRect)` (unit-testable halves split) + a thin applier setting both windows' frames on the initiator's screen.
- `DocumentModel`: conforms to `CompareTarget`; wires `preview.onSyncScroll` → `coordinator.scrollChanged(from:self,…)`; `start()` calls `coordinator.attach(self)` and completes a pending pair; exposes `startCompare()` / `stopCompare()` / `isCompared` for the menu.

### Step 4 — Menu (`Sources/Markio/CompareCommands.swift`, register in `MarkioApp`)

- `CompareCommands: Commands` — `CommandGroup(after: .saveItem)` (File menu; the save group is emptied, its anchor persists): `File ▸ Compare Side by Side…` (enabled when a document window is focused) and `File ▸ Stop Comparing` (enabled while the focused window is paired), routed through the existing `FocusedValue(\.documentModel)`. Registered by adding `CompareCommands()` to the `.commands { }` block in `MarkioApp.swift` (next to `FindCommands()` / `TOCCommands()`).

### Step 5 — Docs

- SRS: new `### 3.21 FR-COMPARE` section with anchor (`fr:compare`), `**Tasks:**` back-pointer to this task, filled `**Acceptance:**`; update §4 Sec + §5 Proto (four→five one-way handlers, new page entrypoints).
- SDS: new component `CompareCoordinator` section; update WebViewHost handler list, vendored-bundle template API list, §5 Logic.
- `documents/index.md`: FR-COMPARE row. README: user-facing feature bullet. New `documents/checklists/compare.md` (menu command, panel, tiling, live sync, stop/close behavior in a real `.app`).

### Error handling

- Malformed sync payloads dropped at the handler (same as `markioScroll`). Bridge failures logged, never thrown (NFR Reliability). Open-panel cancel is a no-op; a failed `openDocument` logs and clears the pending pair.

### Verification

- `make test ARGS="--filter CompareTests"` (all DoD tests), then full `make check`.
- Manual: `make app && open .build/Markio.app` + `documents/checklists/compare.md` (tiling and menu exist only in a real `.app`).

### Manual verification note

The menu/panel/tiling DoD item stays unchecked: the implementing session ran
headless (Apple Events to System Events denied, `-1743`), so the real-`.app`
GUI walk could not be driven programmatically. `make app` builds and launches
cleanly; walk `documents/checklists/compare.md` on the next interactive
session, then flip the item.

## Follow-ups

- Pair persistence across relaunch (re-link compared windows after quit) — deferred, needs a UX decision; v1 pairs are session-only.
- Drag-a-file-onto-a-window-edge "compare with this" gesture — deferred; menu command is the v1 entry point.
- Heading-based (structural) scroll alignment for documents with diverging section lengths — deferred; v1 uses proportional fraction per the request.
