---
date: 2026-07-25
status: in progress
implements:
  - FR-MENU
  - FR-COMPARE
tags: [menu, native-ui, bugfix]
related_tasks:
  - "[Reorder File menu](reorder-file-menu.md)"
  - "[Side-by-side compare](side-by-side-compare.md)"
---
# Fix stale focused menu state [ANC:task:2026-07-fix-stale-focused-menu-state]

## Goal

Menu items that depend on the focused document's live state (`Stop Comparing`,
`Find Next`/`Find Previous`, the TOC checkmark) must reflect that state
immediately, not only after the user switches windows.

## Overview

### Context

The automated FR-MENU/FR-COMPARE checklist run (real `.app`, accessibility
menu dumps) exposed: right after `Compare Side by Side…` links a pair,
`Stop Comparing` stays disabled; right after `Stop Comparing` unlinks, it stays
enabled. A window-focus switch corrects both. The defect predates the
`FileCommands` refactor — the removed `CompareCommands` used the identical
pattern.

### Current State

`FileCommands`, `FindCommands`, and `TOCCommands` read the focused window's
`DocumentModel` through `@FocusedValue(\.documentModel)`. `FocusedValue` only
re-evaluates a `Commands` body when the focused value itself changes (focus
moves); it does not subscribe to `objectWillChange` of the resolved
`ObservableObject`, so `@Published isCompared` / `findResult` / `tocVisible`
flips are invisible until the next focus change.

### Constraints

- Native SwiftUI mechanism only; no timers, notifications, or menu polling.
- The routing stays per-focused-window; `documentFileURL` (a value type
  republished by the view) keeps using `FocusedValues`.

### Variants

- **A. `@FocusedObject` + `.focusedSceneObject(model)` (selected)** — the
  SwiftUI API built for exactly this: it observes the focused
  `ObservableObject`, so `Commands` bodies re-evaluate on `@Published`
  changes. Pros: one-line change per consumer, removes a custom key. Cons:
  none known. Risk: none — macOS 13+ API, target is macOS 14.
- **B. Republish scalar focused values from the view** (e.g.
  `.focusedSceneValue(\.isDocumentCompared, model.isCompared)`) — works
  because the view observes the model, but multiplies keys per state flag and
  leaves the same trap for the next flag. Rejected.

## Definition of Done

- [ ] FR-COMPARE: `Stop Comparing` enables immediately after linking and
  disables immediately after unlinking, with no window-focus change
  - Test: `manual — maintainer — documents/checklists/compare.md` (steps 3, 7)
  - Evidence: `NO_COLOR=1 make app` + accessibility menu-state dump before/after
- [x] FR-MENU: menu structure and routing regressions stay green
  - Test: `Tests/MarkioTests/MenuArtifactCleanerTests.swift`; `Tests/MarkioTests/FilePathCopyTests.swift`
  - Evidence: `NO_COLOR=1 make check`

## Solution

1. `ContentView`: replace `.focusedSceneValue(\.documentModel, model)` with
   `.focusedSceneObject(model)`.
2. `FileCommands`, `FindCommands`, `TOCCommands`: replace
   `@FocusedValue(\.documentModel) private var model` with
   `@FocusedObject private var model: DocumentModel?`.
3. Remove the now-unused `FocusedDocumentModelKey` and its `FocusedValues`
   accessor; keep `FocusedDocumentFileURLKey`.
4. Sync SDS §3.1d / find-bar wording (`FocusedValues.documentModel` →
   focused scene object) and sharpen the compare checklist to assert the
   immediate (pre-focus-switch) menu state.
5. `make check`, then `make app` and re-run the accessibility verification:
   link → `Stop Comparing` enabled at once; unlink → disabled at once.
