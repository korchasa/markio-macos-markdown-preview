---
date: 2026-07-14
status: in progress
implements:
  - FR-LOCAL-LINKS
tags: [links, navigation, sandbox]
related_tasks:
  - [daily-use-feature-backlog](daily-use-feature-backlog.md)
  - [toc-sidebar](toc-sidebar.md)
---
# Local link navigation

## Goal

Make links inside rendered documents useful instead of dead clicks: relative
links to other `.md` files open them (new window, per the window-per-document
concept), `#anchor` links scroll within the current document, and
`other.md#section` does both. This is backlog item 6 — a Tier-2
4.3(a)-differentiation driver: none of the five competitors claim it, and it
turns Markio into "a native reader for a repo's living documentation".

## Overview

### Context

- Backlog: `daily-use-feature-backlog.md` item 6 (read-only; items 1–5 already
  shipped on this branch).
- The page is loaded via `loadHTMLString(baseURL: nil)`, so the document base
  is an opaque `applewebdata:` URL. A click on a relative link resolves to
  `applewebdata://<UUID>/other.md`; `LinkPolicy.decide` returns `.block` for
  that scheme — today every relative and `#anchor` click is dead.
- Heading ids exist since the TOC feature: `rebuildTOC()` assigns GitHub-style
  slug ids to `#content h1–h6` on every render, and the page already exposes
  `scrollToHeading(id)`.
- Page→native bridge pattern: three one-way single-string
  `WKScriptMessageHandler`s (`markioTOC`, `markioCopy`, `markioScroll`).
  A link channel would be the fourth, on the same pattern.
- MAS App Sandbox: entitlements are `app-sandbox` +
  `files.user-selected.read-only` + `network.client`
  (`packaging/Markio.entitlements`). The app can read only user-selected
  files (Open panel / Finder / drag / Open Recent, system-managed). A sibling
  `.md` file that was never user-selected is NOT readable — programmatic
  `NSDocumentController.openDocument` on it fails with a sandbox denial in the
  signed build (works in unsandboxed `make dev`). The sibling-access model is
  the key decision of this task and must be documented honestly in SDS.
- External `http(s)`/`mailto`/`tel` links already open in the default browser
  via the navigation delegate → `NSWorkspace`; that behavior must survive.
  Everything else must stay blocked.

### Current State

- `LinkPolicy.swift`: pure scheme-based decision (`http/https/mailto/tel` →
  `.openExternally`, `file` → `.allowInPage`, else `.block`), applied in
  `PreviewController.decidePolicyFor` after the initial template load.
- `template.html`: markdown-it renders plain `<a href>` anchors; the only
  delegated click listener on `#content` serves the code-copy button. No link
  interception.
- Opening documents natively: `DocumentGroup(viewing:)`;
  `NSDocumentController.shared.openDocument(withContentsOf:display:)` is
  already the programmatic path (command-line open in `AppDelegate`); it
  focuses the existing window if the document is already open (one window per
  document).
- `DocumentModel` owns the per-window bridge callbacks; `start(text:url:)`
  runs one-time setup after the first render (scroll restore lives there).

### Constraints

- Native first; the web view owns only content mechanics (scrolling to an
  anchor is page-side; opening files is native).
- MAS sandbox: no entitlement additions unless a variant explicitly argues
  them; signing lives in app-store-factory (cross-repo coordination cost).
- `LinkPolicy` contract: external links keep opening in the default browser;
  everything that is not an in-document anchor, a relative `.md` link, or an
  external link stays blocked.
- Read-only viewer: no editing side effects; strictly item 6 — no Back button
  UI, no other backlog items.
- English artifacts; Conventional Commits; `make check` green.

### Affected Surface

Scout output (verbatim):

```
- **LinkPolicy.swift** — currently blocks local file navigation; will need new decision types for "open new window with file" and "scroll to anchor in current document" — `/Users/korchasa/www/business/markview/Sources/Markio/LinkPolicy.swift` lines 4–26.

- **PreviewController.swift, decidePolicyFor navigation delegate** — currently routes LinkPolicy decisions (allowInPage / openExternally / block); will need to handle new decision type for opening files in new windows — `/Users/korchasa/www/business/markview/Sources/Markio/PreviewController.swift` lines 337–360.

- **template.html, link rendering and click handling** — markdown-it currently renders `<a>` tags without click interception; will need logic to intercept link clicks and route file opens / anchors through a new native bridge message handler or URL scheme — `/Users/korchasa/www/business/markview/Sources/Markio/Resources/template.html` (full file; markdown-it `linkify` at line 369, no current link-click handling).

- **ContentView.swift, openDocument environment** — currently only used in drag-and-drop handler (`handleDrop`); will need exposure or bridge from link navigation to invoke `openDocument(at:url)` for new-window file opens — `/Users/korchasa/www/business/markview/Sources/Markio/ContentView.swift` lines 13, 56.

- **DocumentModel.swift** — per-window state; currently has no mechanism to request opening files from link clicks; will need a hook or callback exposed to PreviewController so link navigation can trigger app-level file opens — `/Users/korchasa/www/business/markview/Sources/Markio/DocumentModel.swift` (full file).

- **FileLoader.swift** — simple synchronous file read; will need enhancement to resolve relative paths from the current document's directory to sibling `.md` files — `/Users/korchasa/www/business/markview/Sources/Markio/FileLoader.swift` lines 1–11.

- **PreviewView.swift** — SwiftUI wrapper around WKWebView; no direct changes likely, but will need to understand interaction with PreviewController's navigation delegate — `/Users/korchasa/www/business/markview/Sources/Markio/PreviewView.swift`.

- **AppDelegate.swift** — currently handles command-line file opens; will need a new entry point or bridge to route link-navigation file opens through NSDocumentController (already used for command-line opens) — `/Users/korchasa/www/business/markview/Sources/Markio/MarkioApp.swift` lines 47–98.

- **MarkioApp.swift** — DocumentGroup scene; the window-opening machinery will be invoked by link navigation; no code changes likely but confirms one-window-per-document constraint must be honored — `/Users/korchasa/www/business/markview/Sources/Markio/MarkioApp.swift` lines 8–14.

- **OfflineTests.swift** — currently tests LinkPolicy decisions (HTTP/HTTPS/mailto/tel/file/FTP schemes); will need new assertions for local file link decisions — `/Users/korchasa/www/business/markview/Tests/MarkioTests/OfflineTests.swift` lines 17–21.

- **New test file: LinkNavigationTests.swift** — will need tests for relative path resolution, anchor navigation, file+anchor opens, sandbox access constraints, and integration with window-opening machinery — path would be `/Users/korchasa/www/business/markview/Tests/MarkioTests/LinkNavigationTests.swift`.

- **documents/requirements.md (SRS), new FR** — will need a new functional requirement (e.g., FR-LINK-NAV or FR-LOCAL-LINKS) defining the three behaviors: relative `.md` file opens (new window), `#anchor` scrolls (current document), `file.md#anchor` opens and scrolls — with acceptance tests — `/Users/korchasa/www/business/markview/documents/requirements.md`.

- **documents/design.md (SDS), new section** — will need to document the link navigation architecture: how relative paths are resolved from the current document's directory, the sandbox constraints (MAS App Sandbox access to sibling files), the chosen security model (security-scoped bookmarks vs. same-directory implicit access vs. open-panel re-permission), the page→native bridge (if a new message handler is added), and the interaction with DocumentGroup's window-per-document model — `/Users/korchasa/www/business/markview/documents/design.md`.

- **documents/design.md (SDS), §3.4 WebViewHost component** — the LinkPolicy + navigation delegate description (currently at line 75) will need to explicitly document local file link handling alongside external link handling — `/Users/korchasa/www/business/markview/documents/design.md` lines 73–77.

- **documents/design.md (SDS), §3.1 App shell** — the Interfaces section (lines 37–40) will need to document how files are opened from link navigation, distinct from drag-drop and command-line opens — `/Users/korchasa/www/business/markview/documents/design.md` lines 37–40.

- **documents/design.md (SDS), Data section** — if security-scoped bookmarks or per-document sibling-file access metadata are persisted, this section will need to document the new UserDefaults keys or app-local storage — `/Users/korchasa/www/business/markview/documents/design.md` lines 114–117.

- **packaging/Markio.entitlements** — the MAS App Sandbox entitlement file; will need verification that current entitlements (especially `com.apple.security.files.user-selected.read-write` for opened documents) permit reading sibling files, or documentation of a chosen fallback if not — `/Users/korchasa/www/business/markview/packaging/Markio.entitlements`.

- **CLAUDE.md, Documentation Map section** — if new components are added (e.g., LinkNavigationBridge, RelativePathResolver), the map must be updated to point from those components to SRS/SDS sections — `/Users/korchasa/www/business/markview/CLAUDE.md`.

- **documents/tasks/2026/07/daily-use-feature-backlog.md** — item 6 definition; this is read-only per the user request, but the task plan/implementation log will need to reference this file as context — `/Users/korchasa/www/business/markview/documents/tasks/2026/07/daily-use-feature-backlog.md` line 31.

- **ResourceLocator.swift** — file-loading utility; may need inspection to understand asset bundling model when resolving relative paths from the open document — `/Users/korchasa/www/business/markview/Sources/Markio/ResourceLocator.swift`.

- **Makefile** — the build/test interface; will need to run new link navigation tests as part of `make check` — `/Users/korchasa/www/business/markview/Makefile`.

- **Package.swift** — SwiftPM manifest; unlikely to need changes (no new external dependencies expected) but must verify it declares the test target correctly — `/Users/korchasa/www/business/markview/Package.swift`.
```

Union dispositions (variant B selected):

- `template.html` link-click interception — covered-by Solution step 2
- New page→native link message handler in `PreviewController.swift` — covered-by Solution step 3
- `DocumentModel.swift` link-activation wiring — covered-by Solution step 5
- Native relative-path resolver (new component) — covered-by Solution step 1
- Sandbox sibling-access model — covered-by Solution step 4 (open-panel powerbox grant; variant B decision)
- SRS new FR-LOCAL-LINKS section — covered-by Solution step 6
- SDS: new component section + §3.4 WebViewHost + §3.1 App shell Interfaces (link-driven opens, distinct from drag-drop / command-line) + §5 Rules + NFR Sec — covered-by Solution step 6
- SDS §4 Data — not affected — variant B persists nothing (pending anchors are in-memory, consume-once; no new `UserDefaults` keys, no bookmarks)
- New tests (`LinkTests`) — covered-by DoD items 1–4 (TDD RED steps)
- `LinkPolicy.swift` — not affected — clicks the page intercepts never reach the delegate; non-intercepted clicks keep resolving to `applewebdata:`/external schemes, and the existing table (`http/https/mailto/tel` external, else block) already yields the required behavior (inspected `Sources/Markio/LinkPolicy.swift:17-26`, `Sources/Markio/PreviewController.swift:337-360`)
- `OfflineTests.swift` LinkPolicy assertions — not affected — `LinkPolicy` table unchanged (same inspection)
- `ContentView.swift` `openDocument` environment — not affected — programmatic opens go through `NSDocumentController.shared.openDocument` (the established path, `MarkioApp.swift:88`), not the SwiftUI drag-drop action (inspected `ContentView.swift`)
- `FileLoader.swift` — not affected — resolution is a new pure component; `FileLoader` keeps reading the already-open document only (inspected `Sources/Markio/FileLoader.swift`)
- `PreviewView.swift` — not affected — no navigation-delegate surface there (inspected)
- `AppDelegate` / `MarkioApp.swift` — not affected — `NSDocumentController.shared` is callable from any component; no new app-level entry point needed (inspected `MarkioApp.swift:47-98`)
- `packaging/Markio.entitlements` — not affected — variant B adds no entitlement (powerbox `NSOpenPanel` grants ride on the existing `files.user-selected.read-only`)
- `CLAUDE.md` Documentation Map — covered-by Solution step 6 (map row for the new `*Link*` sources)
- Backlog file — not affected — read-only context per request
- `ResourceLocator.swift` — not affected — vendored-asset inlining is orthogonal to document-relative links (inspected)
- `Makefile` — not affected — `swift test` discovers new XCTest files automatically (inspected `Makefile`)
- `Package.swift` — not affected — test target globs the directory; no new dependency (inspected)
- `documents/index.md` — covered-by DoD item "SRS/SDS/index updated" (FR row added at planning time)

## Definition of Done

- [x] FR-LOCAL-LINKS (b): clicking a `#anchor` link scrolls the current document to that heading (no navigation, no new window)
  - Test: `Tests/MarkioTests/LinkTests.swift::testAnchorLinkClickScrollsToHeading`
  - Evidence: `make test ARGS="--filter MarkioTests.LinkTests"`
- [x] FR-LOCAL-LINKS (a): clicking a relative link to a `.md`/`.markdown` file is intercepted by the page and handed to the native side (link message posted with the raw href); the native side resolves it against the document's directory and opens it in a new window (one window per document)
  - Test: `Tests/MarkioTests/LinkTests.swift::testRelativeMarkdownLinkPostsLinkMessage`; `Tests/MarkioTests/LinkTests.swift::testLocalLinkResolverResolvesRelativeAndRejectsOthers`
  - Evidence: `make test ARGS="--filter MarkioTests.LinkTests"`
- [x] FR-LOCAL-LINKS (c): a relative `.md` link with an anchor (`other.md#section`) opens the file and scrolls it to the section after its first render (also when the target document is already open)
  - Test: `Tests/MarkioTests/LinkTests.swift::testPendingAnchorStoreRoundTripAndConsumeOnce`
  - Evidence: `make test ARGS="--filter MarkioTests.LinkTests"`
- [x] FR-LOCAL-LINKS: external `http(s)`/`mailto`/`tel` links keep opening in the default browser; relative non-`.md` links and unknown schemes stay blocked (dead click, no navigation)
  - Test: `Tests/MarkioTests/LinkTests.swift::testNonMarkdownAndExternalLinksNotHijacked`; existing `Tests/MarkioTests/OfflineTests.swift::testLinkPolicy`
  - Evidence: `make test ARGS="--filter MarkioTests.LinkTests"; make test ARGS="--filter MarkioTests.OfflineTests"`
- [ ] FR-LOCAL-LINKS: new-window open + the chosen sandbox sibling-access flow verified in a real `.app` bundle
  - Test: `manual — maintainer — documents/checklists/local-links.md`
  - Evidence: checklist file exists and is walked on the built `.app` (`make app`)
- [x] FR-LOCAL-LINKS: SRS section (with `**Acceptance:**`), SDS component section (incl. the honest sandbox-access decision), and `documents/index.md` row exist
  - Test: n/a (doc artifact)
  - Evidence: `grep -q "\[ANC:fr:local-links\]" documents/requirements.md && grep -A8 "FR-LOCAL-LINKS" documents/requirements.md | grep -q "Acceptance:" && grep -q "REF:fr:local-links" documents/design.md documents/index.md`
- [x] Project check green
  - Test: full suite
  - Evidence: `make check`

## Follow-ups

- "Back returns" from the backlog item text: with window-per-document, the
  source window stays open behind the new one, which covers the reading flow;
  a dedicated Back control is deliberately NOT part of this task (minimalism;
  would need per-window navigation history). Revisit only if daily use shows
  the need.
- Variant C (folder-level security-scoped bookmarks: one grant per repo,
  `com.apple.security.files.bookmarks.app-scope` entitlement, bookmark store
  with staleness handling, app-store-factory signing coordination) is the
  recorded evolution path if per-file powerbox grants prove annoying in daily
  use. Deliberately not in this task.

## Solution

Selected: **Variant B** — page-side click interception (fourth one-way
page→native handler) + native open via `NSDocumentController`, with a
powerbox `NSOpenPanel` fallback when the sandbox denies reading a
not-yet-authorized target. No new entitlements; no persistent bookmark state.

Components (create/modify):

1. **`Sources/Markio/LocalLink.swift` (new)** — pure, unit-testable link
   grammar:
   - `struct LocalLink: Equatable { let fileURL: URL; let anchor: String? }`
   - `enum LocalLinkResolver { static func resolve(href:documentURL:) -> LocalLink? }`
     Accepts only scheme-less, non-absolute hrefs whose path (before an
     optional `#fragment`) percent-decodes cleanly and ends in
     `.md`/`.markdown` (case-insensitive). Resolves against the document's
     directory (`..` traversal allowed — repo docs use it), returns the
     `standardizedFileURL` plus the decoded non-empty fragment. Everything
     else → `nil` (default-deny stays).

2. **`Sources/Markio/Resources/template.html`** — a second delegated click
   listener on `#content` for `a[href]` (raw attribute, not the resolved
   property):
   - `#fragment` → `preventDefault()`; scroll via the existing
     `scrollToHeading(decodeURIComponent(fragment))` (TOC slug ids).
   - href with a scheme (`/^[a-zA-Z][a-zA-Z0-9+.-]*:/`) or `//`-prefixed →
     untouched: the navigation delegate keeps deciding (http/https → default
     browser via `NSWorkspace`, everything else blocked).
   - other relative hrefs → `preventDefault()`; if the path part ends in
     `.md`/`.markdown` → post the raw href to the `markioLink` handler
     (guarded for headless); otherwise nothing (dead click stays dead).

3. **`Sources/Markio/PreviewController.swift`** — fourth
   `ScriptMessageProxy` registered as `markioLink`; validated single-string
   payload → `onLinkActivated: ((String) -> Void)?` (same pattern as
   `markioTOC`/`markioCopy`/`markioScroll`). `LinkPolicy` and
   `decidePolicyFor` stay byte-identical.

4. **`Sources/Markio/LocalLinkNavigator.swift` (new)** — `@MainActor` app-wide
   singleton owning cross-window navigation state:
   - Pending anchors: `[standardized path: anchor]`, consume-once.
   - Weak registry of `LocalLinkTarget`s (protocol: `documentURL`,
     `navigate(toAnchor:)`) — one per started `DocumentModel`.
   - `follow(href:from documentURL:)`: resolve → record pending anchor →
     open. Open flow: `FileManager.isReadableFile` → direct
     `NSDocumentController.shared.openDocument(withContentsOf:display:)`;
     not readable (sandbox denial or missing file — indistinguishable inside
     the sandbox) → `NSOpenPanel` pre-pointed at the target (directoryURL,
     markdown content types, one-file, message explaining the grant); the
     user's "Open" click IS the powerbox grant; open the user-picked URL.
     Cancel → no-op.
   - After a successful open of an already-open document, deliver the pending
     anchor to the registered target directly (its window never re-renders).
   - Injectable open/panel closures so unit tests drive the pending/registry
     logic without AppKit UI.

5. **`Sources/Markio/DocumentModel.swift`** — wiring:
   - `preview.onLinkActivated → LocalLinkNavigator.shared.follow(href:from:)`.
   - Conforms to `LocalLinkTarget`; `attach`es to the navigator in `start()`.
   - In `start()`, after the saved-scroll restore: consume a pending anchor
     for this document and `scrollToHeading` it (anchor wins over the saved
     position — the user explicitly asked for the section).

6. **Docs** — SRS: new `### FR-LOCAL-LINKS` (+`[ANC:fr:local-links]`,
   `**Tasks:**` back-pointer, acceptance refs, §4 Sec + §5 Proto updated to
   four handlers); SDS: new component `LocalLinkNavigator` documenting the
   sandbox decision honestly (per-file powerbox grant, no bookmarks, recents
   open silently because their access is system-managed) + §3.4 bridge list +
   §3.1 App shell Interfaces (link-driven opens as a third programmatic open
   path, distinct from drag-drop and command-line) + §5 Rules; §4 Data stays
   untouched (nothing persisted). `documents/index.md` FR row; new checklist
   `documents/checklists/local-links.md` (real-`.app` new-window + grant
   flow); AGENTS.md Documentation Map row for `*Link*` sources.

Honesty note on the sandbox claim (critic #3): "a never-selected sibling is
unreadable in the sandboxed build" is App Sandbox *documented* semantics
(`files.user-selected.read-only` grants per-selection), not something this
session verified on a signed build. The design is correct under either
outcome — `isReadableFile` gates the panel, so if the OS grants broader
access the panel simply never appears. The signed-build behavior is exactly
what `documents/checklists/local-links.md` verifies manually.

Error handling: resolver failures and cancelled panels are silent no-ops
(default-deny, dead click); `openDocument` errors are logged via `os.Logger`
(best-effort per NFR Reliability); a pending anchor pointing at a heading that
does not exist is a no-op (`scrollToHeading` returns false). No error paths
throw across the bridge.

Verification: TDD per DoD (each item's test written RED first);
`make fmt` before `make check` (long inline strings in WebView tests);
final `make check` green; manual checklist walked on `make app` build
(documented as manual acceptance — sandbox behavior is not unit-testable).
