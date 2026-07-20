---
date: 2026-07-17
status: to do
implements:
  - FR-MENU
  - FR-COMPARE
tags: [menu, native-ui]
related_tasks:
  - "[Copy focused file path](copy-file-path.md)"
  - "[Side-by-side compare](side-by-side-compare.md)"
---
# Reorder File menu [ANC:task:2026-07-reorder-file-menu]

## Goal

Group file-opening, focused-document, and closing actions in native reading order.

## Overview

### Context

The real app currently renders File as Open/Open Recent → Close/Close All →
Compare/Stop, while Copy File Path lives in Edit. The user selected File for
path copy because it targets the document, not editable content. A real-menu
tracking test then exposed a SwiftUI runtime defect: empty `.newItem`
replacement corrupts Open Recent and can drop adjacent custom commands after
the menu updates. `DocumentGroup(viewing:)` plus the bundle's `Viewer` role is
correct, but the tested runtime still supplies a disabled `newDocument:` item.
The user selected a narrow SwiftUI/AppKit hybrid after comparing alternatives.

### Current State

- Working-tree `FileCommands` owns one `.saveItem` replacement with the required
  custom-action and closing groups; native Open/Open Recent remain intact.
- `MenuArtifactCleaner` identifies native New by its public action and preserves
  all other items, but its one-shot delegate installation is not durable:
  SwiftUI restores its own File delegate during later app updates.
- Independent `FindCommands`, focused document values, exact path copying, and
  document-controller Close All are already implemented and unit-tested.

### Constraints

- SwiftUI remains command/focus owner; no hand-built File or Open Recent menu.
- AppKit removes only public `NSDocumentController.newDocument(_:)` after the
  original SwiftUI delegate updates a top-level menu; no title/index/private
  selector matching.
- The cleaner installs before menu tracking and repairs SwiftUI delegate resets
  through public application lifecycle callbacks; no timers, input monitors,
  menu-tracking observers, or menu reconstruction.
- Visible File order: Open/Open Recent → Copy/Compare/Stop → Close/Close All.
- One separator between the focused-document group and closing group.
- Copy File Path stays shortcut-free and writes the exact opened path.
- Close All targets documents through `NSDocumentController`, never arbitrary
  visible windows.
- Real `.app` verification targets an exact process ID + executable path.

## Definition of Done

- [ ] FR-MENU: File contains Copy File Path once, Edit contains none, and focused-window path copy stays exact
  - Test: `Tests/MarkioTests/FilePathCopyTests.swift::testCopiesAbsoluteFilePathAsPlainText`; `manual — maintainer — documents/checklists/menu.md`
  - Evidence: `NO_COLOR=1 make test ARGS="--filter FilePathCopyTests"`; `NO_COLOR=1 make app`
- [ ] FR-MENU: File order is Open/Open Recent → Copy/Compare/Stop → Close/Close All with no visible placeholder or stray separator
  - Test: `manual — maintainer — documents/checklists/menu.md`
  - Evidence: `NO_COLOR=1 make app`
- [ ] FR-MENU: Copy File Path, Close, and Close All are disabled without a document; Close All closes document windows only
  - Test: `manual — maintainer — documents/checklists/menu.md`
  - Evidence: `NO_COLOR=1 make app`
- [ ] FR-COMPARE: Compare/Stop remain focused-window commands and compare behavior is unchanged
  - Test: `Tests/MarkioTests/CompareTests.swift`; `manual — maintainer — documents/checklists/compare.md`
  - Evidence: `NO_COLOR=1 make test ARGS="--filter CompareTests"`; `NO_COLOR=1 make app`

## Solution

1. Update FR-MENU, SDS menu ownership, README, module docs, index, and manual
   checklists before source changes.
2. Restore independent `FindCommands`; move shared focused-document keys into
   `FocusedDocumentValues.swift` and rename `fileURL` to `documentFileURL`.
3. Replace `ReadOnlyMenuCommands` + `CompareCommands` + file-copy portion of
   `EditCommands` with one `FileCommands` owner:
   - leave `.newItem` and native Open/Open Recent untouched;
   - replace `.saveItem` once with Copy File Path, Compare, Stop, a divider,
     Close, and Close All.
4. Give `MenuArtifactCleaner` an idempotent installer: wrap the current SwiftUI
   delegate before tracking, forward its update first, remove only native
   `newDocument:`, and normalize separators only when removal occurs. Install
   after launch and repair from `applicationDidBecomeActive` /
   `applicationDidUpdate`; never nest wrappers.
5. Disable focused-document/closing actions when `documentFileURL == nil`;
   implement Close All with `NSDocumentController.closeAllDocuments`.
6. Keep `FilePathClipboard` coverage; add exact selector/delegate-order menu
   tests; run focused Find/Compare/menu tests, formatting, then `make check`.
7. Build the real app, launch exact `.build/Markio.app`, bind automation to its
   process ID after verifying the executable path, and exercise File/Edit,
   Open Recent, two-window routing, close fallback, no-document states, and
   repeated menu updates.
