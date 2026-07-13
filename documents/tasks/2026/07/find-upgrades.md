---
date: 2026-07-14
status: done
implements:
  - FR-FIND
tags: [daily-use, wave1]
related_tasks:
  - [daily-use-feature-backlog](daily-use-feature-backlog.md)
---
# Find upgrades: minimap, cross-token matching, "N of M" counter [ANC:task:2026-07-find-upgrades]

## Goal

Backlog item 5 (Tier 1, daily-use wave 1): make ⌘F find trustworthy for long
technical documents. Today matches hidden inside syntax-highlighted code are
silently missed and there is no overview of where matches sit in the document —
both undermine the "reader for agent output" positioning that the 4.3(a)
resubmission depends on.

## Overview

### Context

- Backlog: documents/tasks/2026/07/daily-use-feature-backlog.md item 5
  (read-only; do not edit).
- Items 1–4 already shipped on this branch: live-reload scroll preservation,
  TOC sidebar, code-copy button, session restore. template.html now carries
  TOC + scroll + copy handlers that must stay intact.
- Existing find (FR-FIND): native HUD pill (⌘F) → `DocumentModel` →
  `PreviewController.search/findNext/findPrev/clearSearch` →
  `template.html` JS that wraps matches in `<mark class="markio-find">`
  (current: `markio-find-current`), case-insensitive, live per keystroke,
  re-applied after live-reload/appearance re-renders.

### Current State

Of the four requested outcomes:
- (a) highlight all matches, current distinct — ALREADY implemented and
  covered by `Tests/MarkioTests/FindTests.swift::testFindsAllMatchesAndCycles`.
- (b) match counter — ALREADY present but formatted `3/17`; backlog asks for
  a "3 of 17" reading.
- (c) scrollbar minimap — MISSING entirely.
- (d) search inside code blocks/tables — text nodes in code blocks and tables
  ARE searched today, BUT matching is per-text-node: highlight.js splits code
  into token `<span>`s, so any query spanning a token boundary (e.g.
  `const value` in highlighted JS) finds nothing. Same for queries spanning
  inline formatting in table cells/paragraphs. SRS FR-FIND currently even
  documents the limitation ("never inside … code-token markup structure").

### Constraints

- Native first; web view owns content rendering — highlighting and any in-page
  overview strip live in template.html; the shell (HUD, menus) stays native.
- Offline: no new vendor assets, no network.
- Keep intact: TOC handlers, scroll persistence, copy-button UI exclusion from
  matches (`FindTests` + `CodeCopyTests::testFindSkipsCopyUI` must stay green).
- Never mangle Mermaid SVGs / KaTeX output (existing collector exclusions).
- `make check` green; TDD flow (RED → GREEN → REFACTOR → CHECK).
- Scope: only backlog item 5; no other backlog items.

### Affected Surface

Scout output (verbatim):

```
- /Users/korchasa/www/business/markview/Sources/Markio/FindCommands.swift — menu routing; handles ⌘F/⌘G/⌘⇧G commands
- /Users/korchasa/www/business/markview/Sources/Markio/FindBarControls.swift — find bar text field input handling and keyboard navigation
- /Users/korchasa/www/business/markview/Sources/Markio/ContentView.swift — find bar HUD layout, counter display, button handlers; needs minimap/overview strip UI
- /Users/korchasa/www/business/markview/Sources/Markio/DocumentModel.swift — find state (findPresented, findQuery, findResult); may need match-position tracking for minimap
- /Users/korchasa/www/business/markview/Sources/Markio/PreviewController.swift — find bridge to web view; returns FindResult struct (count/current)
- /Users/korchasa/www/business/markview/Sources/Markio/Resources/template.html — search/findNext/findPrev/clearSearch JS functions; collectTextNodes filtering; match wrapping in <mark> elements; CSS for mark colors
- /Users/korchasa/www/business/markview/Tests/MarkioTests/FindTests.swift — find tests; needs new tests for code-block/table search, highlight visual distinction, minimap behavior
- /Users/korchasa/www/business/markview/documents/requirements.md — FR-FIND (section 3.11); needs update for new capabilities (all-highlight distinctness, minimap, code/table search coverage)
- /Users/korchasa/www/business/markview/documents/design.md — SDS §3.7 FindBar; needs update for minimap/overview UI, collectTextNodes filtering scope, match-position API if minimap pulls it
- /Users/korchasa/www/business/markview/documents/tasks/2026/07/daily-use-feature-backlog.md — item 5 (do not edit per user instruction); referenced context only
- PreviewController.swift FindResult struct — may need new field for match positions if minimap consumes position data
- TOC sidebar (/Users/korchasa/www/business/markview/Sources/Markio/TOCSidebar.swift) — document outline affects interplay with find scrolling; ensure find-to-match scrolling doesn't interfere with TOC highlight
- Code-copy UI (template.html decorateCodeBlocks, collectTextNodes skip logic) — must remain excluded from find matches; verify tables/code-block text is searchable (not the Copy button or badge)
- Live reload reapply path (DocumentModel.reapplyFindIfActive(), PreviewController.render(), template.html render()) — must preserve/recompute match positions for minimap across re-renders
- Appearance re-render path (DocumentModel.appearanceChanged()) — same: must reapply find and preserve minimap state on light/dark switch
```

Union dispositions (selected variant: B — cross-token range search + in-page minimap + counterText):

- template.html search/clearSearch/setCurrent + CSS — covered-by DoD (c), (d)
- ContentView.swift find HUD counter — covered-by DoD (b)
- FindResult (PreviewController.swift) counter formatting — covered-by DoD (b)
- Tests/MarkioTests/FindTests.swift — covered-by DoD (a)–(d) tests
- documents/requirements.md FR-FIND — covered-by DoD (e)
- documents/design.md SDS §3.7 / §3.9 render pipeline — covered-by DoD (e)
- FindCommands.swift — not affected — menu wiring reads only
  `findResult.count`; semantics unchanged (Sources/Markio/FindCommands.swift:28-33)
- FindBarControls.swift — not affected — key handling (Enter/arrows/Esc) is
  independent of match mechanics (Sources/Markio/FindBarControls.swift:65-87)
- DocumentModel.swift — not affected — state flow unchanged; minimap is
  page-side and is rebuilt by the existing `reapplyFindIfActive()` re-search
  after re-renders (Sources/Markio/DocumentModel.swift:157-160)
- TOCSidebar.swift / scroll-spy interplay — not affected — find keeps
  `scrollIntoView({block:'center'})`; the scroll-spy `scroll` listener
  (`window.addEventListener('scroll', postCurrentSection)`,
  Sources/Markio/Resources/template.html:539) already reacts to any scroll
  source, including find jumps
- Code-copy UI exclusion — covered-by DoD (d) regression
  (CodeCopyTests::testFindSkipsCopyUI stays green)
- Live-reload / appearance re-render — covered-by DoD (d) via existing
  re-apply path; minimap recomputed because `search()` rebuilds it
- daily-use-feature-backlog.md — not affected — read-only per request

## Definition of Done

- [x] FR-FIND (a): every match highlighted, current match visually distinct
  - Test: `Tests/MarkioTests/FindTests.swift::testFindsAllMatchesAndCycles`
  - Evidence: `make test ARGS="--filter FindTests"`
- [x] FR-FIND (b): find bar counter reads "N of M" (e.g. "3 of 17")
  - Test: `Tests/MarkioTests/FindTests.swift::testCounterText`
  - Evidence: `make test ARGS="--filter FindTests"`
- [x] FR-FIND (c): overview strip at the preview's right edge shows one tick
  per match at its relative document position; the current match's tick is
  distinct; strip disappears when search is cleared/closed
  - Test: `Tests/MarkioTests/FindTests.swift::testMinimapTicksFollowMatches`
  - Evidence: `make test ARGS="--filter FindTests"`
- [x] FR-FIND (d): a query spanning syntax-highlight token boundaries matches
  inside fenced code blocks; matches inside table cells are found; copy-button
  UI text is still never a match
  - Test: `Tests/MarkioTests/FindTests.swift::testFindsAcrossTokenSpansInCodeAndTables`
  - Evidence: `make test ARGS="--filter FindTests"`
- [x] FR-FIND (e): SRS FR-FIND and SDS §3.7 describe the new behavior
  (minimap, cross-token matching, counter format); stale "never inside
  code-token markup structure" wording removed
  - Test: n/a (doc change)
  - Evidence: `grep -qi "overview strip\|minimap" documents/requirements.md documents/design.md`

## Solution

Selected variant: **B — two-phase cross-token search + in-page minimap + testable counter**.

### Files

- `Sources/Markio/Resources/template.html` — rewrite `search()`, extend
  `setCurrent`/`clearSearch`, add minimap builder + CSS.
- `Sources/Markio/PreviewController.swift` — add `FindResult.counterText`.
- `Sources/Markio/ContentView.swift` — find HUD counter uses `counterText`.
- `Tests/MarkioTests/FindTests.swift` — new tests (counter format, cross-token
  code/table matching, minimap ticks).
- `documents/requirements.md`, `documents/design.md` — FR-FIND / SDS §3.7
  updated to the new behavior.

### Page-side search redesign (template.html)

1. `__find.matches` becomes an array of **logical matches**, each an array of
   `<mark class="markio-find">` segments (1+ per match; multi-segment when the
   match crosses element boundaries such as highlight.js token spans).
2. `search(query)`:
   - `clearSearch()` first (restores pristine text nodes), then collect nodes
     via the existing `collectTextNodes` (all exclusions preserved: svg,
     katex, markio-code-ui, script/style).
   - Build ONE haystack string + offset map `[{node, start}]`. Between nodes
     whose nearest block ancestor differs, append `U+0000 (NUL)` so a match can
     never span a block boundary (paragraph→paragraph, cell→cell). Nearest
     block ancestor = walk up to first tag in a BLOCK_TAGS set (P, LI, TD, TH,
     PRE, H1–H6, BLOCKQUOTE, DT, DD, CAPTION, DIV, …), else `#content`.
   - Find case-insensitive occurrences in the lowercased haystack (advance by
     needle length — non-overlapping, same as today).
   - Wrap occurrences **from the last to the first** (and segments within a
     match from last to first): for each covered node segment use
     `splitText` + wrap in `<mark>`; reverse-order processing keeps earlier
     map offsets valid (splitText only truncates the tail of the map's node).
   - Group segment marks into one logical match; reverse collected groups into
     document order; `setCurrent(0)`; rebuild minimap; return
     `{count, current}` (bridge contract unchanged).
3. `setCurrent(i)`: toggle `markio-find-current` on EVERY segment of the
   previous/new group; `scrollIntoView({block:'center'})` on the group's first
   segment; move the minimap's current-tick class.
4. `clearSearch()`: unchanged unwrap-and-normalize (it already handles multiple
   marks) + remove the minimap element.
5. Minimap: `div#markio-find-minimap` appended to `document.body` (OUTSIDE
   `#content`, so render() innerHTML swaps never orphan listeners and the
   strip is never a search target). Fixed strip at the right edge
   (`position:fixed; right:0; top:0; bottom:0; width:10px;
   pointer-events:none`). One absolutely-positioned tick per logical match;
   its position is `top = (pageY / docHeight) * 100%` where
   `pageY = firstSegment.getBoundingClientRect().top + window.scrollY`
   (document-absolute Y) and `docHeight = document.documentElement.scrollHeight`.
   The current match's tick gets an accent class. A `resize` listener re-runs
   the same computation over the stored match groups (both pageY and docHeight
   change on reflow). Rebuilt by every `search()`, removed by `clearSearch()`.
   Indication-only (no click-to-jump) per minimalism rule.
6. Live reload / appearance: no new code — `DocumentModel.reapplyFindIfActive()`
   re-runs `search()`, which rebuilds marks and minimap against fresh DOM.

### Native side

7. `FindResult.counterText: String` — a computed property on the existing
   `FindResult` struct in `Sources/Markio/PreviewController.swift` =
   `"\(current) of \(count)"` ("3 of 17", "0 of 0") — unit-testable formatter;
   `ContentView.findBar` displays it instead of `current/count`.

### Error handling

- Bridge contract and best-effort error handling are unchanged
  (`callFind` still decodes `{count, current}`; JS failures log and yield
  `.empty`).
- `search()` never throws on odd DOM: nodes with no parent are skipped, empty
  query returns `{0,0}` after clearing, `U+0000 (NUL)` cannot appear in a query
  string typed into `NSTextField`.

### TDD order

1. RED: `testCounterText` (pure unit), `testFindsAcrossTokenSpansInCodeAndTables`
   (fenced `js` block + GFM table; query spans token boundary),
   `testMinimapTicksFollowMatches` (tick per match, current tick moves on
   findNext, strip removed on clearSearch; after a second `render()` +
   re-`search()` exactly ONE strip exists — no duplicate strips across
   re-renders). Confirm failures.
2. GREEN: implement 1–7 minimally.
3. REFACTOR: keep `collectTextNodes` shared; no behavior change.
4. CHECK: `make fmt` then `make check` (fmt first — long inline strings in
   RenderTests-style DOM assertions trip swift-format line length).

### Verification

- `make test ARGS="--filter FindTests"` — all find tests green.
- `make check` — full build + lint + tests green.
- Existing regressions guarded: `testFindsAllMatchesAndCycles` (plain-text
  matches stay single-segment: mark count unchanged), `CodeCopyTests::
  testFindSkipsCopyUI`, TOC/scroll tests untouched.

## Follow-ups

_None yet._
