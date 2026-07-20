---
date: 2026-07-16
status: superseded
superseded_by: "[Reorder File menu](reorder-file-menu.md)"
implements:
  - FR-MENU
tags: [daily-use, menu]
---
# Copy focused file path [ANC:task:2026-07-copy-file-path]

## Goal

Copy the active document's absolute filesystem path from Edit without selecting
title-bar text or locating the file in Finder.

## Overview

### Context

Markio already shows each document's full path in its title bar
([REF:fr:multidoc]) and routes app-level commands through focused values. The
read-only Edit menu remains standard; this task adds one native file utility.

### Current State

- `ContentView.fileURL` identifies the window's file synchronously.
- `DocumentModel.documentURL` is populated only during asynchronous `start`, so
  it is not a reliable command-availability source during initial window setup.
- Native clipboard writes already use `NSPasteboard`; tests use uniquely named
  pasteboards to avoid changing the user's clipboard.
- FR-MENU docs drifted from current code: Close/Close All are present and the
  bundle declares English only. This task synchronizes those statements.

### Constraints

- Native AppKit/SwiftUI only; no dependency or web bridge.
- Exact `URL.path`: no URI prefix, percent encoding, newline, or symlink
  resolution.
- Focused file-backed window only; unavailable input must not clear clipboard.
- English title `Copy File Path`; no keyboard shortcut.
- Real `.app` verification is mandatory for menu changes.

## Definition of Done

- [ ] FR-MENU: copying a focused document writes its exact absolute path as plain text
  - Test: `Tests/MarkioTests/FilePathCopyTests.swift::testCopiesAbsoluteFilePathAsPlainText`
  - Evidence: `NO_COLOR=1 make test ARGS="--filter FilePathCopyTests/testCopiesAbsoluteFilePathAsPlainText"`
- [ ] FR-MENU: unavailable file input leaves existing clipboard contents untouched
  - Test: `Tests/MarkioTests/FilePathCopyTests.swift::testUnavailableFileLeavesPasteboardUntouched`
  - Evidence: `NO_COLOR=1 make test ARGS="--filter FilePathCopyTests/testUnavailableFileLeavesPasteboardUntouched"`
- [ ] FR-MENU: the real app exposes an enabled focused-window command after the pasteboard group and no shortcut
  - Test: `manual — maintainer — documents/checklists/menu.md`
  - Evidence: `NO_COLOR=1 make app`

## Solution

1. Publish `ContentView.fileURL` through a dedicated `FocusedValues.fileURL`.
2. Add the action to the reliable post-text-editing group in `EditCommands`
   (SwiftUI drops separate pasteboard-adjacent groups); disable it without a
   focused file URL.
3. Add `FilePathClipboard` with injectable `NSPasteboard`; validate file URL +
   absolute path before clearing/writing `.string`.
4. Test exact Unicode/space-containing paths and nil-input non-mutation with a
   private pasteboard.
5. Run formatting, focused tests, full `make check`, then build and inspect the
   real `.app` menu and clipboard behavior.
