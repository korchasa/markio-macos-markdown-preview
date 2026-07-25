---
date: 2026-07-25
status: done
implements:
  - FR-COMPARE
tags: [compare, requirement-change]
related_tasks:
  - "[Side-by-side compare](side-by-side-compare.md)"
  - "[Compare: absolute scroll sync](compare-absolute-scroll-sync.md)"
---
# Inline-diff compare [ANC:task:2026-07-inline-diff-compare]

## Goal

Compare two document versions inside ONE window as a rendered inline diff —
the two-window scroll-mirroring model kept fighting scroll mechanics
(proportional feel, pixel quantization) and still felt hard to control.

## Overview

### Context

Maintainer decision (v3 of FR-COMPARE): replace side-by-side entirely.
`File ▸ Compare…` picks a BASELINE file; the focused window renders the
current document as usual with changed blocks highlighted — added blocks
tinted green, blocks removed since the baseline inserted at their position
as dimmed red blocks. One window, one scroll: the whole mirroring problem
class (echo suppression, delta quantization, clamping) disappears by
construction. The prior product statement "NOT a diff editor" is
deliberately amended: this is still read-only viewing, now of a change set;
no editing or merging.

### Current State

- `CompareCoordinator` pairs windows, tiles, mirrors pixel deltas over the
  `markioSyncScroll` channel; page carries `setCompareSync`/
  `compareScrollBy` and a delta-posting scroll listener.
- `DocumentModel: CompareTarget`; `FileCommands` exposes
  `Compare Side by Side…`/`Stop Comparing` (⇧⌘C).
- An unresolved field defect: mirroring not visible in the real app for the
  maintainer (works in WebView tests) — dies with the mechanism.

### Constraints

- One window; no second window, tiling, or scroll sync — delete that code.
- The current document must render through the normal pipeline (Mermaid,
  KaTeX, highlight, sanitize) — diff decoration is annotation, never a
  rewrite of the render path.
- Offline: the line-diff implementation is vendored in `template.html`
  (small Myers diff), no new dependency.
- Powerbox panel stays the sandbox grant; baseline is read, never opened as
  a window. Picking the document's own file is a no-op. Session-only.
- Block granularity v1: a changed line marks its whole top-level block;
  word-level refinement is a recorded follow-up. Removed runs render
  standalone — constructs that depended on removed context are best-effort.

### Variants

- **A. Rendered block diff in the focused window (selected)** — normal
  render of the current text + `data-line` block map (markdown-it
  `token.map`) + line diff against the baseline; added blocks get a class,
  removed runs render into inserted dimmed blocks. Pros: stays a reader;
  find/TOC/width keep working over the diff; no scroll machinery. Cons:
  block-level granularity.
- **B. Unified source diff** — precise but shows raw Markdown; breaks the
  "read rendered documents" product core. Rejected.
- **C. Two windows + difference highlight** — keeps all sync complexity.
  Rejected.

## Definition of Done

- [x] FR-COMPARE: comparing against a baseline marks added blocks, inserts
  removed blocks, leaves unchanged content unmarked; identical documents
  show no markers; Stop Comparing restores the plain render; self-compare
  is a no-op
  - Test: `Tests/MarkioTests/CompareTests.swift::testDiffMarksAddedBlocks`; `::testDiffInsertsRemovedBlocks`; `::testIdenticalDocumentsShowNoMarkers`; `::testStopComparingRestoresPlainRender`; `::testSelfCompareIsNoOp`
  - Evidence: `NO_COLOR=1 make test ARGS="--filter CompareTests"`
- [x] FR-COMPARE: real-app flow accepted by the maintainer (panel, diff
  view, Stop Comparing, live reload re-diff)
  - Test: `manual — maintainer — documents/checklists/compare.md`
  - Evidence: `NO_COLOR=1 make app`

## Solution

1. Docs: rewrite SRS FR-COMPARE (v3), SDS compare component, compare
   checklist, README compare bullet, module AGENTS; supersede the
   absolute-scroll-sync task.
2. Page: add a `data-line-start`/`data-line-end` core ruler (top-level
   tokens); vendored Myers line diff; `renderDiff(oldText, newText)` =
   `render(newText)` → mark added blocks by line-range intersection →
   insert removed runs (`md.render` + sanitize, dimmed wrapper, Mermaid
   best-effort) → `rebuildTOC()`; diff CSS for both themes; DELETE the
   compare-sync block and exports.
3. `PreviewController`: `renderDiff(old:new:)`; DELETE `markioSyncScroll`
   proxy/validation/`onSyncScroll`, `setCompareSync`, `compareScrollBy`,
   `compareScrollY`.
4. `DocumentModel`: injectable baseline picker (powerbox `NSOpenPanel`
   production impl); `startCompare()` reads the baseline and renders the
   diff (`isCompared = true`); `stopCompare()` re-renders plain; live
   reload re-diffs while compared (baseline re-read; unreadable baseline →
   log + stop compare). DELETE `CompareTarget` conformance and coordinator
   wiring; DELETE `CompareCoordinator.swift`.
5. `FileCommands`: `Compare…` (⇧⌘C) + `Stop Comparing` driven by
   `isCompared`.
6. Tests: rewrite `CompareTests` per DoD; `make check`; real-app pass.
