---
date: 2026-07-14
status: in progress
implements:
  - FR-SESSION-RESTORE
tags: [session, recent-documents, window-restore, scroll, sandbox]
related_tasks:
  - "[Daily-use feature backlog](daily-use-feature-backlog.md)"
  - "[Live reload preserves scroll](live-reload-preserve-scroll.md)"
  - "[TOC sidebar](toc-sidebar.md)"
---
# Recent documents + window restore [ANC:task:2026-07-recent-docs-window-restore]

## Goal

Backlog item 4 (post-4.3(a) daily-use wave): make Markio a daily tool instead
of a one-off viewer. (a) File ▸ Open Recent lists recently opened documents;
(b) relaunching the app reopens the documents that were open at quit, each at
its last scroll position. A reader returning to a long agent-written report
lands exactly where they stopped, without re-navigating.

## Overview

### Context

- App is a `DocumentGroup(viewing:)` document app: one window per file, system
  File ▸ Open / Open Recent, window-frame restoration (@Sources/Markio/MarkioApp.swift).
- **Open Recent already exists**: `NSDocumentController` populates it on every
  open; FR-MENU explicitly keeps it (`documents/requirements.md` §3.10). Under
  the App Sandbox the *system* maintains access rights for recent items — no
  app-side bookmark code is needed for the menu itself.
- **Reopen at relaunch is NOT deterministic today**: macOS window restoration
  reopens document windows only when the system setting "Close windows when
  quitting an application" is off. The app also never opts into secure
  restorable state (`applicationSupportsSecureRestorableState` not implemented).
- **Scroll position is not persisted anywhere**: `template.html` preserves
  scroll only across an in-page re-render (live reload / appearance —
  FR-LIVE-RELOAD); nothing survives a window close or app quit.
- MAS sandbox (`packaging/Markio.entitlements`:
  `com.apple.security.app-sandbox` + `files.user-selected.read-only`).
  Persisting *our own* file references across relaunches would require
  security-scoped bookmarks + the `files.bookmarks.app-scope` entitlement;
  system-managed paths (Open Recent, state restoration) carry their own
  sandbox extensions and need none of that.
- Bridge architecture: native→web via `callAsyncJavaScript`; web→native only
  one-way single-string `WKScriptMessageHandler`s (`markioTOC`, `markioCopy`)
  — SRS §4 Sec contract.
- Persistence pattern: small `UserDefaults`-backed stores with injectable
  suite (`ContentWidthStore`, `TOCStore`).

### Current State

- `MarkioApp.swift` — `DocumentGroup` scene + slim `AppDelegate`
  (tabbing opt-out, menu cleaner, CLI open). No termination/restore hooks.
- `DocumentModel.start(text:url:)` — loads template, renders, arms watcher;
  no scroll restore.
- `PreviewController` — bridge methods for render/width/dark/find/TOC; no
  scroll get/set; two message proxies (`markioTOC`, `markioCopy`).
- `template.html` — `render()` captures/restores `window.scrollY` locally;
  debounce-free `scroll` listener posts current-section id to `markioTOC`.
- Tests drive a real offscreen `WKWebView` (`PreviewTestSupport.makeLoadedPreview`).

### Constraints

- Native first; minimalism; read-only viewer (project priorities 1–3).
- No network; bridge stays one-way single-string page→native handlers.
- English artifacts; Swift 6 strict concurrency; zero-warning baseline.
- Scope strictly: recent documents + relaunch restore + scroll restore.
  No other backlog items; do not edit the backlog file.
- Menu/window behavior must be verified in a real `.app` bundle
  (`make app`), not the degraded `make dev` binary.

### Affected Surface

Scout output (verbatim):

```
## Surface

**Backlog item 4** — Recent documents menu + window restore on relaunch — touches the following surfaces:

### App lifecycle & restoration
- **AppDelegate** — `applicationWillTerminate(_:)` hook needed to capture and persist open documents + scroll positions at quit; `application(_:didFinishLaunchingWithOptions:)` already exists but must route to a window restoration routine. **Evidence:** `Sources/Markio/MarkioApp.swift` lines 47–84 (AppDelegate struct, only has `applicationWillFinishLaunching` and `applicationDidFinishLaunching`).
- **MarkioApp** — the `DocumentGroup` scene currently receives "state restoration for free" per comment (line 5: `[REF:sds:app-shell]`), but that only restores window frames, not document-open state. Must inject a scene restoration flow triggered by the app delegate on launch. **Evidence:** `Sources/Markio/MarkioApp.swift` lines 11–24; `documents/design.md` line 36–38 (`state restoration for free`), line 106 (`state fully system-managed`).

### Recent documents persistence & retrieval
- **Recent files storage** — new UserDefaults-backed store (parallel to `ContentWidthStore`, `TOCStore`) must track a list of recently opened file URLs, with optional security-scoped bookmark data for each (required for MAS sandbox). Reading via `NSDocumentController.shared.recentDocumentURLs` is not sufficient — need custom tracking to capture per-document scroll position. **Evidence:** no existing code; `Sources/Markio/ContentWidthStore.swift` (pattern), `Sources/Markio/TOCStore.swift` (pattern).
- **File ▸ Open Recent menu** — currently a system-provided item in the `DocumentGroup` menu (implicit via `NSDocumentController`), but the app does NOT populate `NSDocumentController.recentDocumentURLs` with scroll-position metadata. The native Recent menu exists but won't restore scroll positions. A custom Recent menu or enhancement to the document controller's recent tracking is needed. **Evidence:** `Sources/Markio/MarkioApp.swift` line 6 comment (`Open Recent`); `documents/requirements.md` line 81 (`Kept: File ▸ Open…, Open Recent`); `documents/design.md` line 52 (`ReadOnlyMenuCommands`).

### Per-document scroll position capture
- **PreviewController** — must expose a new method `getScrollPosition() -> (x: CGFloat, y: CGFloat)` or similar to read the current web-view scroll state. Currently scroll is captured/restored only in-page during a single render (line 385 of template.html), but not exposed to the native side for persistence across app relaunches. **Evidence:** `Sources/Markio/PreviewController.swift` lines 188–197 (`scrollToHeading`), but no `getScroll*` method; `Sources/Markio/Resources/template.html` lines 385, 399.
- **PreviewController** — must expose a method `restoreScrollPosition(_:)` to set scroll position after rendering a document on relaunch. **Evidence:** `Sources/Markio/PreviewController.swift` lines 188–197.
- **template.html** — must expose the current scroll position to native code via a new JS function and/or via a new message handler channel. **Evidence:** `Sources/Markio/Resources/template.html` lines 385, 399 (scroll vars are local to the `render` function, not exposed).

### Per-window state capture at quit
- **DocumentModel** — on app quit (delegated from AppDelegate), must capture this window's file URL, scroll position, and reading width, then persist them as part of a window-restore list. Currently holds `url`, `contentWidth`, `tocVisible` as instance vars but has no method to serialize/save this state. **Evidence:** `Sources/Markio/DocumentModel.swift` lines 9–16, 41–59; no quit/save hook.
- **ContentView** — must receive a signal (via AppDelegate or ScenePhase observation) to tell its `DocumentModel` to save state before the window closes. Currently has no lifecycle hook for this. **Evidence:** `Sources/Markio/ContentView.swift` — no `.onReceive` for app termination; no ScenePhase watching.

### Security-scoped bookmarks (MAS sandbox)
- **FileLoader or a new bookmark manager** — must encode/decode `NSURL.bookmarkData(options:)` for each persisted file URL so that the app can regain file-access rights across relaunches in the sandbox. **Evidence:** `Sources/Markio/FileLoader.swift` (no bookmark handling).
- **packaging/Markio.entitlements** — may need `com.apple.security.files.bookmarks.app-scope` or similar entitlement added if not already present. **Evidence:** task description; entitlements file not yet examined.

### Scroll position persistence store
- **New store class** (parallel to `ContentWidthStore`, `TOCStore`) — must persist a per-file scroll position map to restore the reader's place on relaunch. **Evidence:** no existing code.

### Window state restore list
- **New store class** — must track an ordered list of open file URLs at app quit so the app can reopen them on the next launch. **Evidence:** no existing code.

### Test coverage
- **Tests/** — new tests required for (a) persist/restore cycle of window state, (b) scroll position round-trip, (c) recent files list population, (d) security-scoped bookmark encoding/decoding in sandbox. **Evidence:** `Tests/MarkioTests/` directory; `testWidthPersistsAndReflows`, `testSidebarVisibilityPersists` patterns.

### Template.html scroll API
- **template.html** — must add a new JS function `getScrollPosition()` and/or `getHeadingAtScrollTop()`. **Evidence:** `template.html` lines 385–399, 539, 543.

## Could not rule out
- Whether `DocumentGroup` actually provides any automatic window-state restoration (documents opened on previous launch) or only frame restoration.
- Whether a custom Recent menu is necessary or if `NSDocumentController.recentDocumentURLs` can be extended to carry scroll-position metadata.
- Whether `ScenePhase` observation in SwiftUI can cleanly capture state on app quit, or if direct AppDelegate `applicationWillTerminate` is required.
- Whether per-file reading width (from `ContentWidthStore`) should stay global or become per-file when window restore is implemented.
```

Union dispositions (variant-sensitive items updated after selection):

- Open Recent menu population — not affected — `DocumentGroup`/`NSDocumentController` registers every open; FR-MENU (`documents/requirements.md` §3.10) keeps the item; sandbox access to recents is system-managed. Verified manually via checklist (DoD 1).
- AppDelegate / MarkioApp launch+restore hooks — covered-by Solution (restoration opt-in) / DoD 2.
- PreviewController scroll bridge (read+write) — covered-by DoD 3.
- template.html scroll API + capture channel — covered-by DoD 3.
- New scroll-position store — covered-by DoD 3.
- DocumentModel / ContentView scroll-restore wiring — covered-by DoD 3.
- Own window-restore list store + security-scoped bookmark manager — not affected — Variant A (selected) delegates reopen to system state restoration; no app-side session list or bookmark code (Solution step 4).
- packaging/Markio.entitlements — not affected — Variant A (selected) needs no new entitlement; system restoration and Open Recent carry their own sandbox extensions (Solution step 4).
- FileLoader — not affected — it reads a plain path; file access at reopen is granted by whichever mechanism opens the document (system restoration / Open Recent extension / bookmark), before `load` runs (`Sources/Markio/FileLoader.swift`).
- Per-file reading width — deferred — out of scope; width stays a global reading preference (SDS §3.5 decision). Recorded under Follow-ups.
- Makefile / packaging steps — not affected — no new build inputs; signing/entitlements applied by app-store-factory (`Makefile` `dist` comment).
- Tests — covered-by DoD 3 (automated) + DoD 1–2 (manual checklist).
- Docs (SRS new FR, SDS components, index, checklist, README) — covered-by DoD 4.

## Definition of Done

- [ ] FR-SESSION-RESTORE: File ▸ Open Recent lists recently opened documents and reopens them (sandbox access intact) in a real `.app` bundle.
  - Test: `manual — maintainer — documents/checklists/session-restore.md`
  - Evidence: checklist items 1–2 pass on `make app` build
- [x] FR-SESSION-RESTORE: relaunching the app reopens the documents that were open at quit (quit with N docs → relaunch → same N windows).
  - Test: `manual — maintainer — documents/checklists/session-restore.md`
  - Evidence: checklist items 3–4 pass on `make app` build (agent-verified 2026-07-14: controlled quit/relaunch cycle with the global "keep windows" setting explicitly OFF restored both document windows, no Open panel — CGWindowList bounds check; visual scroll check item 4 remains in the maintainer pass)
- [x] FR-SESSION-RESTORE: each document's last scroll position is persisted and restored when the document is opened again (incl. after relaunch).
  - Test: `Tests/MarkioTests/SessionRestoreTests.swift::testScrollPositionRoundTrip`; `Tests/MarkioTests/SessionRestoreTests.swift::testScrollSavedOnScrollAndRestoredOnOpen`
  - Evidence: `make test ARGS="--filter SessionRestoreTests"` exits 0
- [x] FR-SESSION-RESTORE section added to SRS with filled `**Acceptance:**`; SDS updated (app shell, webview host, vendor bundle, data); `documents/index.md` row added.
  - Test: `manual — maintainer — SRS/SDS diff review in this task's commit`
  - Evidence: `grep -q "ANC:fr:session-restore" documents/requirements.md`

## Solution

Selected: **Variant A — system state restoration + native scroll-position
store.** No new entitlements; no app-side session/bookmark bookkeeping.

### Files

- `Sources/Markio/ScrollPositionStore.swift` — **new**. `UserDefaults`-backed
  per-file scroll map (key `scrollPositions`), injectable suite (pattern:
  `TOCStore`). Value shape: `[path: ["y": Double, "at": epoch-seconds]]`.
  API: `position(for: URL) -> Double?`, `setPosition(_: Double, for: URL)`.
  Bounded: `maxEntries = 200`; inserting beyond the cap evicts the oldest
  `at`. Malformed stored values are treated as absent (best-effort reads,
  same as the other stores).
- `Sources/Markio/Resources/template.html` — add `setScrollY(y)` (clamped
  `window.scrollTo`, returns applied `window.scrollY`) and `getScrollY()`;
  add a `scroll`-listener poster with a **true debounce**: a page-global
  timer is reset on every scroll event and fires 250 ms after the last one
  (no unload cancellation needed — the page lives exactly as long as its
  web view); when the rounded value changed since the last post it sends
  `String(Math.round(window.scrollY))` to the one-way `markioScroll`
  handler (guarded no-op headless, same pattern as `markioTOC`/`markioCopy`).
- `Sources/Markio/PreviewController.swift` — third weak `ScriptMessageProxy`
  registered as `markioScroll`; validation: non-empty string parseable as a
  non-negative Double, else dropped; `onScrollPositionChange: ((Double) ->
  Void)?` callback. New bridge method `setScrollY(_ y: Double) async ->
  Double?` (`@discardableResult`; logs + nil on bridge failure — the same
  contract as `setContentWidth`; the returned applied/clamped value is
  consumed by the tests).
- `Sources/Markio/DocumentModel.swift` — `init(defaults: UserDefaults =
  .standard)` now feeds all three stores (`ContentWidthStore`, `TOCStore`,
  new `ScrollPositionStore`); wires `onScrollPositionChange` → store write
  keyed by the window's `url`; in `start(text:url:)`, after the first render
  (and outline refresh), restores the saved position via
  `preview.setScrollY(saved)` — this covers relaunch, Open Recent, and ⌘O
  reopen alike. The restore is deliberately unconditional and runs exactly
  once per window (guarded by the existing `started` flag) — it never fires
  again while the user reads, so manual scrolling is never clobbered.
- `Sources/Markio/MarkioApp.swift` (`AppDelegate`) —
  `applicationSupportsSecureRestorableState → true`; in
  `applicationWillFinishLaunching` set `NSQuitAlwaysKeepsWindows = true` in
  the app's defaults domain (`UserDefaults.standard.set`, NOT
  `register(defaults:)` — the registration domain loses to the user's
  NSGlobalDomain setting; the app domain wins) so quitting Markio always
  keeps its windows and `DocumentGroup`/AppKit reopens the same documents on
  relaunch. Sandbox access on reopen is system-managed.
- `Tests/MarkioTests/SessionRestoreTests.swift` — **new**:
  `testScrollPositionRoundTrip` (store save/load + eviction at the cap),
  `testScrollSavedOnScrollAndRestoredOnOpen` (two `DocumentModel`s over a
  shared test suite: scroll session 1 → `markioScroll` persists; session 2
  `start` restores `window.scrollY`).
- Docs: SRS §3.17 FR-SESSION-RESTORE (`[ANC:fr:session-restore]`, Tasks
  back-pointer, runnable Acceptance) + §4 Sec / §5 Proto (third one-way
  handler `markioScroll`, `setScrollY`); SDS §3.1 app shell (restoration
  opt-in decision), §3.4 webview host (bridge additions), §3.6 vendor bundle
  (scroll-persist rule), §4 Data (`scrollPositions` key), new §3.9
  ScrollPositionStore component; `documents/index.md` FR row;
  `documents/checklists/session-restore.md` (Open Recent + relaunch-reopen
  manual checks); `README.md` feature bullet.

### Error handling

- Bridge failures: logged via `os.Logger`, never thrown to UI (NFR
  Reliability), mirroring existing `setContentWidth`/find handling.
- `markioScroll` payload validation drops anything but a non-negative
  numeric string.
- A saved position larger than the reopened (possibly shorter) document is
  clamped by the browser in `setScrollY` — no explicit bounds code needed.
- Corrupt `scrollPositions` defaults → treated as empty (viewer must open
  regardless).

### Verification

1. TDD per component (RED → GREEN → REFACTOR → CHECK):
   store test → store; bridge test → template + `PreviewController`;
   integration test → `DocumentModel` wiring.
2. `make fmt` (long inline JS strings in tests) then `make check` — must
   exit 0.
3. Real-bundle verification (mandatory, per project rule): `make app`,
   `open .build/Markio.app <fixture.md>`, quit, relaunch → the same
   document window reopens (checked via System Events window list);
   File ▸ Open Recent lists the fixture. Scroll restore in the real app is
   covered by the manual checklist (mechanics proven by the automated
   integration test). If DocumentGroup restoration misbehaves in the real
   bundle → STOP and report (no AppKit workarounds without a human call).
   NB: the local `make app` bundle is unsigned → no App Sandbox; this step
   proves the restoration mechanics, while sandbox-specific reopen access
   (system-managed; no bookmark entitlement expected) is re-verified on a
   signed TestFlight build — recorded in the checklist and Follow-ups.

## Follow-ups

- Per-file reading width (scout raised it) — deliberately out of scope; width
  remains a global reading preference per SDS §3.5 decision.
- Scroll restore for the Find state / TOC selection across relaunch — not
  requested; only scroll position is restored.
- Sandbox re-verification on a signed build: the local `make app` bundle is
  unsigned (no App Sandbox), so reopen-at-relaunch under the sandbox is
  confirmed on the next TestFlight build (expected to be system-managed,
  no new entitlement).
