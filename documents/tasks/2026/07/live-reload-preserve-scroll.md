---
date: 2026-07-13
status: done
implements:
  - FR-LIVE-RELOAD
tags: [live-reload, scroll, webkit]
related_tasks:
  - "[Implement Markio app](../../2026/06/implement-markview-app.md)"
  - "[Daily-use feature backlog](daily-use-feature-backlog.md)"
---
# Live reload preserves scroll position

## Goal

Backlog item 1 (post-4.3(a) daily-use wave): when the opened `.md` file changes
on disk, the rendered view updates automatically **and keeps the reader's
scroll position**. Key 2026 scenario: the user watches Claude/Cursor write a
document and sees it grow without re-opening — today every save of a
diagram-bearing doc yanks the view away from where they were reading.

## Overview

### Context

Live reload itself already ships (FR-LIVE-RELOAD: `FileWatcher` →
`DocumentModel.reloadFromDisk` → `PreviewController.render`), with tests
(`WatcherTests`, `LiveReloadTests`). The SRS Desc even says "preserving scroll
position where feasible" — but the implementation does not preserve it in the
headline scenario.

**Reproduced defect (plan-phase experiment, real 800×600 webview frame):**
- Plain-text doc: re-render keeps `window.scrollY` (500 → 500). Benign.
- Doc with a Mermaid diagram + long text: scroll to 15627 → re-render → 11651.

Root cause: `render()` in `template.html` assigns `#content.innerHTML`
(Mermaid blocks become short `pre.mermaid` source text), then `await
mermaid.run()` inflates them back into tall SVGs. During the intermediate
layout the document is thousands of px shorter, WebKit clamps the window
scroll to the shrunken max, and nothing restores it after the page settles.
Exactly the AI-agent scenario: agent docs are Mermaid/KaTeX-heavy, and each
save jumps the reader up by the diagram height.

### Current State

- `Sources/Markio/FileWatcher.swift` — debounced DispatchSource watcher,
  atomic-save re-arm. Works; untouched.
- `Sources/Markio/DocumentModel.swift` — `reloadFromDisk()` re-reads the file
  off-main and calls `preview.render(text)`; `appearanceChanged()` also
  re-renders (same scroll loss on theme switch).
- `Sources/Markio/Resources/template.html` — `render(markdown)` replaces
  `#content.innerHTML`, awaits `mermaid.run()`; no scroll handling.
- `Sources/Markio/Snapshot.swift` — sets scroll explicitly after each render
  (lines 66, 76), independent of this change.
- Find: after re-render `reapplyFindIfActive()` re-runs `search()`, whose
  `setCurrent()` scrolls the current match into view (template.html:462) —
  intended find behavior, takes precedence over pixel restoration.

### Constraints

- Web view owns content rendering; native shell owns OS integration
  (AGENTS.md architecture rule) — scroll of the *rendered page* is page
  territory.
- Read-only viewer; no new dependencies; offline (vendored assets only).
- Scope: backlog item 1 only. Persisting scroll across app relaunches is
  backlog item 4 (recent documents + window restore) — explicitly out.
- Pixel-preserving semantics: the reader stays where they were; no
  "follow tail" auto-scroll (not requested).

### Affected Surface

Scout output (verbatim):

```
## Surface

**Core implementation surfaces for live reload with scroll preservation:**

- `DocumentModel.reloadFromDisk()` method (line 118-128 in `/Users/korchasa/www/business/markview/Sources/Markio/DocumentModel.swift`) — currently re-renders without preserving scroll position; must capture scroll before `preview.render()` and restore after

- `PreviewController` class (lines 8-137 in `/Users/korchasa/www/business/markview/Sources/Markio/PreviewController.swift`) — needs two new public methods to get/set scroll position via JS bridge (`getScrollPosition()` / `setScrollPosition(y)`)

- `template.html` JavaScript rendering engine (lines 334-347 in `/Users/korchasa/www/business/markview/Sources/Markio/Resources/template.html`) — `render()` function resets the DOM; needs two new JS entrypoints `getScrollPosition()` and `setScrollPosition(y)` to store/restore `document.documentElement.scrollTop` or `window.pageYOffset`

**Parallel render-triggering implementations that may interact with scroll:**

- `DocumentModel.appearanceChanged()` method (lines 60-64) — also calls `preview.render(currentText)` when system appearance changes; should preserve scroll for consistency with live reload

- `Snapshot.swift` (lines 66, 76) — already manipulates scroll via `scrollIntoView()` and `window.scrollTo(0, 0)` for screenshot capture; establishes precedent for scroll manipulation pattern

**Find functionality interaction with reload:**

- `DocumentModel.reapplyFindIfActive()` method (lines 100-105) — re-runs find search after re-render; if scroll position changes during render, find match visibility/highlighting may be affected

- Find mark highlighting in `template.html` (line 462) — `setCurrent()` calls `scrollIntoView()` to focus the current match; must not conflict with scroll restoration logic

**State and observers:**

- `DocumentModel` fields (lines 12-15) — `watcher` and `currentText` already exist; must add `scrollPosition` field to cache scroll between reload cycles

- `FileWatcher` class (`/Users/korchasa/www/business/markview/Sources/Markio/FileWatcher.swift` lines 1-82) — already monitors file changes and calls `onChange` callback; integrates with scroll-preserve flow via `DocumentModel` callback chain

**Test coverage for the feature:**

- `LiveReloadTests.swift` (entire file at `/Users/korchasa/www/business/markview/Tests/MarkioTests/LiveReloadTests.swift`) — `testPreviewUpdatesWhenFileChanges()` exercises the reload flow; new test cases needed for scroll preservation (e.g., scroll to middle of document, edit file, verify scroll position unchanged)

- `FindTests.swift` (lines 8-46) — tests find highlighting; `testFindsAllMatchesAndCycles()` verifies match visibility; scroll changes during reload may affect test expectations

**Documentation and requirements:**

- `documents/tasks/2026/07/daily-use-feature-backlog.md` (item 1, lines 20-21) — source of requirement; describes "re-render on disk change, preserve scroll position"

- `documents/design.md` section 3.1b (lines 57-60) — documents `DocumentModel` purpose; must update to describe scroll preservation responsibility

- `documents/requirements.md` — [REF:fr:live-reload] anchor exists (referenced in design.md line 5); requirement must specify scroll-preservation acceptance criteria

- `README.md` (line 16) — lists "Live reload on external edits" as a feature; no mention of scroll preservation (add if user-visible)

**Configuration and integration:**

- `ContentView.task { }` (line 34 in `/Users/korchasa/www/business/markview/Sources/Markio/ContentView.swift`) — calls `model.start(text:url:)` which arms the watcher; initial render starts at top (natural); subsequent reloads triggered by `FileWatcher` must preserve scroll

- `PreviewView.swift` (lines 7-13) — NSViewRepresentable hosting the web view; no state management needed but structure confirms view ownership by PreviewController

- `ContentView.bottomBar` (lines 127-149) — line-width control; interacts with scroll by reflowing content; must ensure scroll restoration happens after render but independent of width changes

**App-level lifecycle and state restoration:**

- `MarkioApp.swift` — (likely at `/Users/korchasa/www/business/markview/Sources/Markio/MarkioApp.swift`) — when a window is restored from recent files or state snapshot, reload enters the same scroll-preservation flow as manual file edits

- `WindowTitleSetter` (referenced in ContentView line 32) — KVO-observes window changes but unrelated to scroll

## Queries used

- `find /Users/korchasa/www/business/markview -name "*.swift" | head -30` — locate source files
- `find /Users/korchasa/www/business/markview -path "*/vendor/*" -o -path "*/template*"` — locate web assets
- `grep -r "scroll" /Users/korchasa/www/business/markview/Sources --include="*.swift" --include="*.html"` — find existing scroll manipulation
- `grep -r "scrollTop\|scrollY\|scrollPosition"` — check for existing scroll position state (found none)
- Direct file reads: FileWatcher.swift, DocumentModel.swift, PreviewController.swift, template.html, LiveReloadTests.swift, Snapshot.swift, design.md

## Not examined (budget)

- `documents/requirements.md` (SRS) — opened design.md which references it but didn't read the full requirements doc to check FR-LIVE-RELOAD acceptance criteria format
- Test utilities in `Tests/MarkioTests/PreviewTestSupport.swift` — test infrastructure likely exists but not reviewed
- `MarkioApp.swift` and `AppDelegate` — app-level initialization and window restoration lifecycle (exists but path not verified)
- `FileLoader.swift` — file I/O wrapper; used by DocumentModel but not examined for caching or state implications
- `LinkPolicy.swift` — link navigation policy (orthogonal to reload)
- All vendor JS libraries under `Resources/vendor/` — rendering dependencies, no changes needed
- `Makefile` and packaging scripts — build/test infrastructure, orthogonal to feature

## Could not rule out

- Whether macOS's `window.pageYOffset` (read) or `window.scrollY` should be used (both standard; need platform testing)
- Whether WebKit's `WKWebView` scroll state resets on `callAsyncJavaScript` (likely no, but not empirically verified)
- Whether scroll restoration should be async/await gated on a post-render settlement (similar to Snapshot's `settle()` delay for Mermaid) or synchronous
- Whether the scroll position should be keyed per-document (filename/URL) and persisted across sessions, or only preserved within a single editing session (user requirement not specified in the backlog item)
- Interaction with future Tier-1 features (TOC sidebar, Copy button) that will also manipulate scroll; whether scroll-position restoration needs coordination
- Whether `DocumentModel.appearanceChanged()` should preserve scroll or reset to top when theme changes (currently unspecified; visual layouts may shift on theme change)
```

Union dispositions (planner ∪ scout):

- `Sources/Markio/Resources/template.html` `render()` — covered-by Solution step 2 (capture/restore at the mutation site).
- `DocumentModel.reloadFromDisk()` — covered-by Solution step 2 (gains preservation through the shared `render()` path; no Swift change).
- `DocumentModel.appearanceChanged()` — covered-by Solution step 2 (same shared path; theme switch now also preserves scroll — consistent, per scout's "could not rule out" resolved in favor of preserve).
- `DocumentModel.start()` initial render — not affected — fresh page has `scrollY == 0`, restore is a no-op (template.html render path, verified in plan-phase experiment).
- `PreviewController` bridge — not affected in the selected variant — no new bridge methods; scout's `getScrollPosition`/`setScrollPosition` sketch belongs to the rejected native-side variant (see Variant B in plan discussion).
- `DocumentModel` new `scrollPosition` field — not needed in the selected variant — state lives transiently inside one `render()` invocation (scout item tied to Variant B).
- `Snapshot.swift` — not affected — explicitly sets scroll after each render (`Snapshot.swift:66` `scrollIntoView`, `:76` `scrollTo(0,0)`), overriding any preserved value.
- Find (`reapplyFindIfActive`, `setCurrent` scrollIntoView, `FindTests`) — not affected — after restore, an active find re-runs and `setCurrent()` scrolls the current match into view (template.html:462), intentionally taking precedence; FindTests exercise search on a freshly rendered doc, no reload interplay.
- `FileWatcher` — not affected — change fires correctly today (`Tests/MarkioTests/WatcherTests.swift`).
- `ContentView` / `PreviewView` / `MarkioApp` / `WindowTitleSetter` — not affected — no render-path or scroll logic (ContentView only forwards `start`/width; verified reads).
- Line-width control — not affected — width changes set a CSS var without re-render; reflow scroll behavior unchanged (template.html `setContentWidth`).
- Scroll persistence across relaunches / per-document keying — deferred — human choice (backlog item 4 territory; see Follow-ups).
- SRS FR-LIVE-RELOAD acceptance + SDS §3.6/§5 + README — covered-by DoD item 3 and Commit-phase doc sync.
- `Tests/MarkioTests/LiveReloadTests.swift` — covered-by DoD item 1 (new scroll test lives here).

## Definition of Done

- [x] FR-LIVE-RELOAD: a re-render of a Mermaid-bearing document preserves `window.scrollY` (the plan-phase repro: scroll near bottom, re-render, position unchanged — today it drops by the diagram height)
  - Test: `Tests/MarkioTests/LiveReloadTests.swift::testRerenderPreservesScrollPosition`
  - Evidence: `NO_COLOR=1 swift test --filter LiveReloadTests`
- [x] FR-LIVE-RELOAD: existing reload behavior intact — external edit still updates the rendered view (regression)
  - Test: `Tests/MarkioTests/LiveReloadTests.swift::testPreviewUpdatesWhenFileChanges` (existing)
  - Evidence: `make check`
- [x] FR-LIVE-RELOAD: SRS acceptance lists the new scroll test; SDS render-pipeline text describes scroll preservation
  - Test: docs — SRS/SDS sections updated in the same commit
  - Evidence: `grep -q testRerenderPreservesScrollPosition documents/requirements.md`

## Solution

Selected: **Variant A — JS-side capture/restore in `render()`** (quick-fix and
architecturally-correct archetypes collapsed; fixes the intermediate-layout
clamp at the mutation site, inside the page that owns rendering).

Files to modify:

1. `Tests/MarkioTests/LiveReloadTests.swift` — **RED**: add
   `testRerenderPreservesScrollPosition`. Concrete spec (verified in the
   plan-phase experiment, which reproduced scrollY 15627 → 11651 with exactly
   this setup):
   - `controller.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)`
     right after `makeLoadedPreview()` — a zero-size frame collapses SVG
     heights to ~0 and hides the clamp.
   - Document: a 40-node Mermaid chain
     (`"```mermaid\nflowchart TD\n" + (1...40).map { "n\($0)[Node \($0)]" }
     .joined(separator: " --> ") + "\n```"`) followed by 300 paragraphs of
     filler text — the rendered SVG is ~4000 px taller than its source text.
   - `render(doc)` → read `scrollHeight` → `window.scrollTo(0, height-100)`
     → assert `scrollY` took → `render(doc)` again (this IS
     `reloadFromDisk`'s render leg; the watcher→reload leg is already covered
     by `testPreviewUpdatesWhenFileChanges`) → assert `window.scrollY`
     unchanged. Must fail on parent.
2. `Sources/Markio/Resources/template.html` — **GREEN**: in `render(markdown)`
   capture `window.scrollX`/`window.scrollY` on entry; after the `innerHTML`
   assignment and the awaited `mermaid.run()`, call `window.scrollTo(x, y)`.
   Comment carries `[REF:fr:live-reload]` + the clamp rationale. No new JS
   entrypoints, no Swift changes; the browser clamps the restore when the new
   document is genuinely shorter (nearest valid position — correct). Settle
   race check (critique #3): the awaited `mermaid.run()` inserts the final
   SVGs before it resolves — the same settle point the plan-phase experiment
   measured at; the test asserts immediately after `render()` returns, so a
   race between restore and late layout would fail the test.
3. `documents/requirements.md` — FR-LIVE-RELOAD: Desc states scroll
   preservation across re-renders (incl. Mermaid docs); add the new test to
   `**Acceptance:**`. (The `**Tasks:**` back-pointer was already written
   during planning — a ship-skill plan-phase step, not an implementation
   step.)
4. `documents/design.md` — §5 Logic (render algorithm) + §3.6 interfaces note:
   `render()` preserves window scroll across the innerHTML/mermaid cycle.

Error handling: none new — `render()` stays best-effort; `window.scrollTo`
does not throw; a failed `mermaid.run` is already caught inside `render()`,
and the restore runs after that catch, so scroll is restored on the error path
too.

Verification:
- `NO_COLOR=1 swift test --filter LiveReloadTests` — new test green.
- `make check` — full gate (build, comment-scan, format lint, all tests).

## Follow-ups

- Scroll persistence across app relaunches and per-document scroll memory —
  backlog item 4 (recent documents + window restore); out of this task's scope.
- Element-anchor-based restoration (stay glued to the same *content element*
  when text is inserted above the viewport) — revisit if pixel preservation
  proves insufficient in daily use; see Variant C in the plan discussion.
