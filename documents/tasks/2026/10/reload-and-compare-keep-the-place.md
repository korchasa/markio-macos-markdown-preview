---
date: 2026-10-02
status: to do
implements: [VIEW-10, VIEW-17, VIEW-26]
tags: [live-reload, compare, scroll]
related_tasks: []
---

# A reload or a comparison moves the reader up a quarter of the window

## Goal

Keep the reader on the line they were reading when the file is rewritten on disk
and when a comparison starts, changes mode or stops. VIEW-10 requires it, and the
store description promises it in so many words: *"the view reloads exactly where
you were reading"*. Today it is true only at the very top of a document.

## Overview

### Context

Found on 2026-10-02 while recording a store preview of the app. A report was
open in a 1200x760-point window at two zoom steps, scrolled to the middle, and
another process rewrote the file twice. Each rewrite moved the top of the view
up: from 721 to 544 points, then from 544 to 464.5. The move is a quarter of the
window plus however far into its top block the reader had scrolled, and it adds
up: a report an agent rewrites every few seconds walks the reader steadily
towards its beginning. At the top of a document nothing moves, which is why the
defect had not been seen.

The same jump happens when a comparison starts (inline or side by side), when
the view switches between the two, and on Stop Comparing.

### Current State

`DocumentWindowController.show(document:comparison:)` is the one place every
document swap goes through — `documentDidReload`, `rebuildComparison`,
`showPlainDocument`. It takes the block at the top of the view as an anchor and,
after `layout.replace`, calls `documentView.reveal(ordinal:)` on it.

`reveal(ordinal:)` (`Sources/MarkioRender/DocumentView.swift`) exists for find,
the outline and the map strip: it leaves its target *"a comfortable way down
from the top"*, `top - visibleRect.height * 0.25`. Used to restore a position it
makes two errors at once: it drops the reader's offset inside the anchor block,
and it adds the quarter-window margin.

The anchor is an ordinal, so it also points at a different block whenever blocks
are added or removed above the reader — which is exactly what a comparison does
when it puts removed lines back.

`testAReaderComesBackToWhereTheyLeftTheDocument` covers reopening (VIEW-9).
Nothing covers the position across a reload or a comparison.

### Constraints

- Nothing is typeset until it is visible: finding the anchor again must not walk
  or measure the whole document.
- `reveal(ordinal:)` keeps its margin for find, the outline and the map strip.
- The app never writes the document it shows.

## Definition of Done

- [ ] VIEW-10: after an external rewrite that leaves the text above the reader
      unchanged, the top of the view shows the same line at the same height,
      within 1 point.
  - Test: `Tests/MarkioTests/DocumentWindowTests.swift::testAReloadKeepsTheReaderOnTheSameLine`
  - Evidence: `swift test --filter DocumentWindowTests/testAReloadKeepsTheReaderOnTheSameLine`
- [ ] VIEW-10: three rewrites in a row leave no accumulated drift.
  - Test: `Tests/MarkioTests/DocumentWindowTests.swift::testRepeatedReloadsDoNotDrift`
  - Evidence: `swift test --filter DocumentWindowTests/testRepeatedReloadsDoNotDrift`
- [ ] VIEW-10: when blocks are added above the reader, the block that was at the
      top is still at the top.
  - Test: `Tests/MarkioTests/DocumentWindowTests.swift::testTextAddedAboveDoesNotMoveTheReader`
  - Evidence: `swift test --filter DocumentWindowTests/testTextAddedAboveDoesNotMoveTheReader`
- [ ] VIEW-17, VIEW-26: starting an inline comparison, switching to side by side
      and stopping keep the same unchanged block at the top of the view.
  - Test: `Tests/MarkioTests/DocumentWindowTests.swift::testComparingKeepsTheReaderInPlace`
  - Evidence: `swift test --filter DocumentWindowTests/testComparingKeepsTheReaderInPlace`
- [ ] The whole gate passes.
  - Evidence: `deno task check`
- [ ] The built app follows a live rewrite without moving: open a long document
      scrolled to the middle, rewrite the file during the delay, and the capture
      shows the same heading at the same height as before the rewrite.
  - Evidence: manual — `.build/Markio.app/Contents/MacOS/Markio doc.md --capture-after=5 --capture=/tmp/after.png`

## Solution

1. In `show(document:comparison:)`, record before the swap the anchor block,
   the distance from its top to the top of the view, and a hash of the anchor
   block's source bytes.
2. After `layout.replace`, find the anchor again: the block with the same bytes
   nearest the old ordinal, searching outward over a bounded number of blocks
   (block byte ranges come from the parse, so no typesetting is needed). When no
   block matches — the anchor itself was rewritten — use the old ordinal.
3. Scroll so that block sits at the recorded distance from the top. Go through
   the clip view and repeat on the next turn of the run loop, as the reopen
   restore does, because the blocks scrolled onto are measured only then.
4. Leave `reveal(ordinal:)` as it is for its other callers.
5. Add the four tests above. Each one asserts on the clip view's `bounds.minY`
   relative to the anchor block's offset, not on pixels.
