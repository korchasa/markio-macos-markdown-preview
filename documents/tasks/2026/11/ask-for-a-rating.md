---
date: 2026-11-09
status: done
implements: [UI-4]
tags: [store, rating]
---

# Ask macOS for a rating at the end of a read

## Goal

Give readers who use Markio a chance to rate it in the Mac App Store without
any screen of the app's own. The owner approved the feature on 2026-11-09:
after a reader has opened three documents, ask macOS for a rating with the
system's request, at most once per version.

The same day the owner moved the moment (2026-11-09): the first version asked
two seconds after the third opening, which is the moment a reader has just
started reading, and Apple's StoreKit guidance says to ask "at a time that
doesn't interrupt what someone is trying to achieve", at the end of something
they finished, and not on first launch or during onboarding. The request now
comes when the reader closes a document window they have had open for at least
30 seconds, never on the first day of use, and never while the app quits.

## Overview

### Context

- The store listing has few ratings, and macOS only shows its rating sheet when
  the app asks. Apple limits the sheet to three times a year per reader and may
  show nothing at all; the app decides only when to ask.
- Markio restores the windows that were open when it quit. A relaunch that
  brings back three documents is not three openings.
- The Quick Look extension renders the same documents in Finder and must not
  count.

### Current State

- `MarkdownDocumentController` in `Sources/Markio/AppDelegate.swift` only
  refuses new documents and names the document class.
- Nothing in the app asks for a rating.

### Constraints

- Speed and memory rank first (Priorities, item 1): the opening path may pay
  for one `UserDefaults` write and nothing else.
- No network request of the app's own (PROD-3): the request is handed to macOS.
- No request on the calendar day of the first counted opening, none for a
  window open under 30 seconds, and none for the closes AppKit makes while the
  app quits.
- The version is spent only by a request that was actually made.
- A scripted run (`--capture`, `--snapshot`, `--export-pdf`, `--dump-menu`) is
  not a reader and must neither count nor ask.

## Definition of Done

- [x] UI-4: three openings make the request due; it is made on closing a window
      open 30 s or more, not under 30 s, not while quitting, not on the day of
      the first opening (a calendar day, not 24 hours); a record with no first
      day takes today; the decision alone does not spend the version; a version
      asks once; a later version needs three new openings.
  - Test: `Tests/MarkioTests/ReviewRequestTests.swift`
  - Evidence: `deno task test --filter ReviewRequestTests`
- [x] The whole gate passes.
  - Evidence: `deno task check`
- [x] A walk of the sandboxed build shows: no request on the first day; no
      request for a window closed after 2 s; the macOS sheet after closing a
      window open 42 s once the first day is in the past; no second request in
      the same version; no request when quitting with the request due.
  - Evidence: manual — a copy of `.build/Markio.app` under its own bundle id,
    without the Quick Look extension, signed ad hoc with
    `packaging/Markio.entitlements`; windows closed with their close button
    through the Accessibility API, the record read from the copy's
    preferences, the `dev.markio.app` / `review` lines in `log show --info`,
    and the sheet captured by window id.

## Solution

1. `ReviewRequest` (`Sources/Markio/ReviewRequest.swift`) keeps three keys in
   `UserDefaults`: the openings since the last request, the version last asked
   in, and the date of the first counted opening. `recordOpening()` returns
   early when this version has asked, otherwise adds one; the first opening
   ever also stores the date. The opening path stays at two reads and one
   write.
2. `MarkdownDocumentController` overrides
   `openDocument(withContentsOf:display:completionHandler:)` and counts a
   completion that brought a new document and displays it. State restoration
   uses `reopenDocument(for:withContentsOf:display:completionHandler:)`, so a
   restored window never arrives here.
3. `DocumentWindowController` notes `systemUptime` when it is created and, in
   `windowWillClose`, hands the time the window was open to the controller.
   `asksOnClose(openFor:terminating:)` says yes for 30 s or more, not quitting,
   three openings, a version not yet asked, and a day other than the first; a
   record without a first day takes today and stores it.
4. On a yes, `SKStoreReviewController.requestReview()` runs on the next turn of
   the main queue, after the window has gone, followed by `markAsked()`. Each
   close logs one info line under `dev.markio.app` / `review`.
5. `AppDelegate.applicationShouldTerminate` sets `isTerminating` on the
   controller. AppKit closes every window after that call during a quit, so
   those closes say `terminating: true` and never ask.
6. A process started with any `--` argument builds no `ReviewRequest`.

## Outcome

### Close-time version

- Tests: 578 before, 584 after (the 4 opening-time tests replaced by 10);
  `deno task check` green.
- Walk on a sandboxed copy (`codesign -d --entitlements -` shows the sandbox,
  the user-selected read-write and the app-scope bookmark entitlements):
  - first day, a fresh record: three openings stored `reviewRequestOpenings = 3`
    and today as the first day; closing `terminal.md` after 42 s logged
    `asks: false`, and no rating window appeared;
  - quitting on the first day logged both closes with `terminating: true`,
    right after AppKit's "Termination commencing": AppKit does close the
    windows on quit, after `applicationShouldTerminate`;
  - first day set to yesterday, the request due, relaunch, two restored windows
    left open 34 s, then quit: both closes logged `terminating: true,
    asks: false`, nothing asked, the record unchanged;
  - relaunch: the restored windows did not count (openings 3 → 4 only for the
    newly opened `compare-old.md`); closing it after 2 s logged `asks: false`;
    closing `demo.md` after 42 s logged `asks: true`, "asking macOS for a
    rating" 31 ms later, StoreKit's "Starting review request", and the
    `storeuid` sheet "Enjoying Markio Walk?" appeared; the record then held
    version `1.1` and openings 0; "Not Now" dismissed it;
  - closing `images.md` after 62 s in the same version logged `asks: false`,
    and no rating window appeared.
- The sheet is a window of the system's `storeuid` process, so it appears
  after the window that triggered it has closed; asking after the close works
  with `SKStoreReviewController.requestReview()` as it is.
- Correction to the first version's walk below: macOS did draw that walk's
  sheet. A `storeuid` window reading "Enjoying MarkioWalk?" was still on screen,
  never dismissed, when this walk began, although the earlier walk's screenshot
  did not show it.

### First version (opening-time, replaced the same day)

- Tests: 574 before, 578 after (4 new); `deno task check` green.
- Walk on a sandboxed copy (`codesign -d --entitlements -` shows the sandbox and
  the two file entitlements), first launch with a fresh record:
  - first launch, `demo.md` opened: openings 1, no request;
  - quit and relaunch with no file: `demo.md` restored, openings still 1;
  - `images.md` opened: no request; `terminal.md` opened at 20:06:28: openings
    reset to 0, version `1.1` stored, and at 20:06:30.46 the log has
    "asking macOS for a rating", followed by StoreKit's own
    "Starting review request";
  - quit and relaunch: three windows restored, record unchanged;
    `compare-old.md` opened: no request, record unchanged.
- macOS drew no rating sheet during the walk. The build does not come from the
  store, and another app was in front again by the screenshot taken 3.8 s
  after the third opening, so the walk proves the request and not the sheet.
