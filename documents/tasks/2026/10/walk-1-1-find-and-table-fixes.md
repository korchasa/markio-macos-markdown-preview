---
date: 2026-10-04
status: done
implements: [VIEW-4, VIEW-12, VIEW-37, VIEW-32]
tags: [find, map, tables, pdf, release-1.1]
related_tasks:
  - [reload-and-compare-keep-the-place](reload-and-compare-keep-the-place.md)
---

# Three defects from the 1.1 pre-release walk

## Goal

Ship 1.1 without three defects a buyer meets in ordinary use: a search result
that cannot be read in the dark appearance, a find bar whose counter and
buttons sit under the map, and an exported PDF whose table breaks a word in
half. The owner chose these three for 1.1 on 2026-10-04; a fourth finding (a
sequence diagram's lifeline running through the label of a message that skips
a participant) waits for a later version.

## Overview

### Context

The walk of the 1.1 release build (Markio Dev, sandboxed, 38 snapshots in both
appearances plus a PDF export) found the three. None is a regression: the code
behind them has not changed since build 13, so all three are in the 1.0 on
sale.

- **A — current match in the dark.** Searching "ledger" in the landing report
  (`screenshots-src/markio/landing.md` in the hub) put the first, current
  match in the front matter. It reads as light grey on bright orange, roughly
  2:1. The same orange marks a task line the stepper has just jumped to.
- **B — find bar over the map.** With matches the map is always shown, and the
  bar's right end — "1 of 17", the two arrows and the close button — lies over
  the strip, whose coloured marks run through the digits.
- **C — a word broken in a PDF table.** On an A4 page the rollout table's
  header "Week" came out as "We" over "ek", while the next column had
  plenty of room.

### Current State

- **A.** `DocumentView.findHighlights` and the task-line highlight in
  `DocumentView.highlights` hand `DocumentRenderer.draw` a rectangle and a
  colour, `palette.findCurrentMatch`. The renderer fills the rectangles first
  and draws the text over them in the text's own colours, so the ink never
  changes. Dark `findCurrentMatch` is `(214, 148, 20)`; dark body text is
  `(230, 232, 236)`.
- **B.** `findBar.trailingAnchor` is pinned to `scrollView.trailingAnchor`
  with a -18 constant (`DocumentWindowController`, the constraint block in
  the window setup). The map is pinned to the same edge, a scroller lane in, at
  `DocumentMapStrip.width`. Nothing keeps the two apart.
- **C.** `BlockLayoutEngine.columnWidths` estimates each column's natural
  width as characters × `bodySize` × 0.55 + padding. When the sum overflows
  the room, it shrinks every column in proportion, down to a floor of three
  `bodySize`. A column whose longest word is wider than its share then has
  that word broken by CoreText, while a column of long sentences keeps slack
  it could have given up.

### Constraints

- Nothing is typeset until visible: measuring a table's words happens in
  that table's own layout, never across the document.
- The light appearance must not change for A: dark text on the light orange
  already reads.
- A table that cannot fit its longest words at all still has to be drawn; it
  falls back to the current proportional shrink rather than overflowing the
  column.

## Definition of Done

- [x] VIEW-4: the current match and the stepped-to task line draw their text in
      a dark ink over the highlight in both appearances, and that ink against
      `findCurrentMatch` is at least 4.5:1.
  - Test: `Tests/MarkioRenderTests/FindHighlightTests.swift::testTheCurrentMatchIsReadableInTheDark`
  - Evidence: `swift test --filter FindHighlightTests`
- [x] VIEW-12, VIEW-37: with the map showing, the find bar ends left of the
      map strip.
  - Test: `Tests/MarkioTests/DocumentWindowTests.swift::testTheFindBarStaysLeftOfTheMap`
  - Evidence: `swift test --filter DocumentWindowTests/testTheFindBarStaysLeftOfTheMap`
- [x] VIEW-32: a table squeezed below its natural width keeps every word of
      every cell on one line while another column still has room to give.
  - Test: `Tests/MarkioRenderTests/TableLayoutTests.swift::testASqueezedTableDoesNotBreakAWord`
  - Evidence: `swift test --filter TableLayoutTests/testASqueezedTableDoesNotBreakAWord`
- [x] The whole gate passes.
  - Evidence: `deno task check`
- [x] A walk of the rebuilt Markio Dev shows all three fixed: the find shot in
      the dark, the find bar against the map, and the rollout table in the
      exported PDF.
  - Evidence: manual — snapshot plan `landing.snapshot.json` (find shot, both
    appearances) and `--export-pdf` on the landing report, read back as
    images.

## Solution

1. **A.** Give `DocumentRenderer.Highlight` an optional ink. When it is set,
   the renderer, after drawing the text, draws each line that meets the
   highlight's rectangles again, clipped to them, with its glyphs filled in
   that ink (text drawing mode `.clip` per line, then a fill). The current
   match and the stepped-to task line pass the light palette's body text
   colour as ink; other matches and the selection pass none. Add a palette
   test for the 4.5:1 ratio and a render test that samples the glyph pixels
   inside a dark current match.
2. **B.** Pin the find bar's trailing edge to the map strip's leading edge,
   less a small gap, instead of to the scroll view. The strip keeps its frame
   while hidden, so the bar does not move when the map appears with the first
   match.
3. **C.** In `columnWidths`, measure each column's widest single word with
   CoreText — bold for a header cell — plus padding, as that column's floor.
   When the natural widths overflow, take the overflow from the columns'
   slack above their floors, in proportion to it. When the floors alone do not
   fit, keep today's proportional shrink.
4. Run the gate, rebuild Markio Dev, and repeat the three walk shots.

## Outcome

- **A.** The clip-mode redraw passed its first test and failed on screen: the
  walk showed the whole match painted in the ink, a dark bar with no word on
  it. The test only checked the darkest pixel, which a solid fill also
  satisfies; it now also requires that at least 40% of the match keeps the
  highlight colour, and it failed that way before the fix. The renderer now
  sets the lines under the highlight again from a copy of the segment's text in
  the ink, over the same ranges, so every glyph lands where the first pass put
  it.
- **B.** The find bar ends 8 pt left of the map strip.
- **C.** The table floors are measured; the landing report's rollout table now
  fits an A4 page with every word whole, and the in-window table is unchanged
  in look.
- Re-walk on Markio Dev at this commit: the find shot in both appearances, the
  find bar against the map, the rollout table in the window and on page 3 of
  the exported PDF.
