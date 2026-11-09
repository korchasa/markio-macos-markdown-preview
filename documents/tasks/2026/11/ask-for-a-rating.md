---
date: 2026-11-09
status: done
implements: [UI-4]
tags: [store, rating]
---

# Ask macOS for a rating on the third opening

## Goal

Give readers who use Markio a chance to rate it in the Mac App Store without
any screen of the app's own. The owner approved the feature on 2026-11-09:
after a reader has opened three documents, ask macOS for a rating with the
system's request, at most once per version.

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
- No request on the app's first launch, and none before the document has drawn.
- A scripted run (`--capture`, `--snapshot`, `--export-pdf`, `--dump-menu`) is
  not a reader and must neither count nor ask.

## Definition of Done

- [x] UI-4: the third opening asks, the first two do not; a version asks once;
      a later version needs three new openings; the first launch never asks.
  - Test: `Tests/MarkioTests/ReviewRequestTests.swift`
  - Evidence: `deno task test --filter ReviewRequestTests`
- [x] The whole gate passes.
  - Evidence: `deno task check`
- [x] A walk of the sandboxed build shows no request after the first and second
      openings, the request two seconds after the third, and no counting of
      windows restored at relaunch.
  - Evidence: manual — a copy of `.build/Markio.app` under its own bundle id,
    signed ad hoc with `packaging/Markio.entitlements`; openings with
    `open -a`, the record read from the copy's preferences, and the
    `dev.markio.app` / `review` line in `log show --info`.

## Solution

1. `ReviewRequest` (`Sources/Markio/ReviewRequest.swift`) keeps two keys in
   `UserDefaults`: the openings since the last request and the version last
   asked in. `recordOpening()` returns early when this version has asked,
   otherwise adds one and answers yes at three. A launch that began with
   neither key is the first launch: it keeps counting and does not ask, so the
   first opening of a later launch asks instead.
2. `MarkdownDocumentController` overrides
   `openDocument(withContentsOf:display:completionHandler:)` and counts a
   completion that brought a new document and displays it. State restoration
   uses `reopenDocument(for:withContentsOf:display:completionHandler:)`, so a
   restored window never arrives here.
3. On a yes, `SKStoreReviewController.requestReview()` runs two seconds later,
   after the window has drawn, and an info line is logged under
   `dev.markio.app` / `review`.
4. A process started with any `--` argument builds no `ReviewRequest`.

## Outcome

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
