---
date: 2026-07-25
status: to do
implements:
  - FR-COMPARE
  - FR-MENU
tags: [compare, native-ui]
related_tasks:
  - "[Inline-diff compare](inline-diff-compare.md)"
---
# Split compare view [ANC:task:2026-07-split-compare-view]

## Goal

A GitHub/GitLab-style side-by-side diff INSIDE the compare window — baseline
left, current right, changed blocks aligned opposite each other — as a
second layout the reader can toggle against the inline view.

## Overview

### Context

Maintainer decision after accepting inline diff. Key property that makes
this cheap where two-window side-by-side was expensive: both columns live
in ONE scroll container, so alignment is a static layout pass (spacers),
not runtime scroll mirroring. The Myers `lineDiff` and the `data-line`
block map already exist in the page.

### Current State

- `renderDiff(oldText, newText)` renders the current text normally and
  annotates it (added classes, removed-run inserts).
- `DocumentModel.renderCompare` drives it; `FileCommands` shows
  `Compare…` / `Stop Comparing`.
- The menu checklist still names the pre-rename `Compare Side by Side…`
  item — sync it in this pass.

### Constraints

- Both versions render FULL-fidelity (whole-text `md.render` per column) —
  never chunk-wise; the diff stays annotation + spacer alignment.
- One scroll container; no scroll-event machinery of any kind.
- Layout preference is a global reading preference (`UserDefaults`), like
  TOC visibility; default = inline.
- TOC and in-page heading ids come from the CURRENT column only (baseline
  headings get no ids); find covers both columns.
- Alignment re-runs after Mermaid settles, on window resize, and on width
  change; asynchronous late height changes are best-effort (realign on
  resize covers most).
- Menu: one checkmark toggle `Compare Side by Side` in the View menu
  (moved from File after user feedback — layout is a view concern), in the compare
  group, enabled only while compared.

## Definition of Done

- [ ] FR-COMPARE: split layout shows baseline left / current right with
  removed blocks marked left, added blocks marked right, and pairs of
  unchanged blocks aligned to the same vertical offset; the toggle switches
  layouts live and the preference persists
  - Test: `Tests/MarkioTests/CompareTests.swift::testSplitLayoutShowsBothVersionsWithMarks`; `::testSplitAlignsSharedBlocks`; `::testSplitToggleSwitchesLayoutLive`; `::testSplitPreferencePersists`
  - Evidence: `NO_COLOR=1 make test ARGS="--filter CompareTests"`
- [ ] FR-MENU: File compare group reads `Compare…` / `Stop Comparing`; View
  carries the `Compare Side by Side` toggle (enabled iff compared) in the real app
  - Test: `manual — maintainer — documents/checklists/menu.md`
  - Evidence: `NO_COLOR=1 make app`

## Solution

1. Docs: SRS FR-COMPARE split paragraph + acceptance, FR-MENU group text;
   SDS 3.12; both checklists (menu item names incl. the stale pre-rename
   title); README bullet.
2. Page: `renderDiff(old, new, split)` dispatches to the inline path or
   `renderDiffSplit` — grid `.markio-split` with `-old`/`-new` columns,
   whole-text render per column, mark removed (left) / added (right) blocks
   by run intersection, `alignSplit` inserts `margin-top` spacers at each
   same-run's first block pair (sequential top measurement), realign on
   resize + width change; `rebuildTOC` skips `.markio-split-old` headings.
3. `PreviewController.renderDiff(old:new:split:)`.
4. `CompareLayoutStore` (TOCStore twin, key `compareSplitLayout`);
   `DocumentModel.compareSplit` published + `setCompareSplit` re-rendering
   the active diff.
5. `TOCCommands` (View menu): checkmark `Toggle("Compare Side by Side")`.
6. Tests per DoD (WebView-backed + store roundtrip); `make check`; real-app
   pass.
