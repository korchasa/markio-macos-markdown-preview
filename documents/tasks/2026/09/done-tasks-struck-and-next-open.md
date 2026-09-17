---
date: 2026-09-08
status: done
implements: [VIEW-8, VIEW-35, VIEW-39]
tags: [task-list, outline, bottom-bar, navigation]
related_tasks: []
---

# Ticked boxes read as done, and the bar leads to the next open one

## Goal

A finished task-list item is struck through where it is drawn — in the body
and in the outline — and the bottom bar's "n of m done" is a way to reach the
next box that is still open, with a keyboard shortcut for the same move.

## Overview

### Context

The owner's request, verbatim: «Выполненные пункты todo-листов нужно выводить
зачёркнутым текстом. И в теле страницы и в оглавлении.» Followed by: «И в
футере, где показывается выполненное, должна быть возможность перейти к
следующему невыполненному. И хоткей для навигации.»

Markio already knows which items are ticked: `Document.taskMarker` reads the
`[x]` at the head of a list item, `BlockLayoutEngine.layoutParagraph` draws the
checkbox from it, and `DocumentSummary` counts ticked-of-total for the bottom
bar and per section for the outline badge. Nothing draws the item's own text
any differently once its box is ticked, and nothing leads from the count to
the boxes it counts.

### Current State

- `Sources/MarkioRender/BlockLayoutEngine.swift` `layoutParagraph`: reads the
  marker, calls `addCheckbox(checked:)`, then builds the text through
  `AttributedBuilder.build` with no knowledge of `isChecked`.
- `Sources/MarkioRender/AttributedBuilder.swift` `build`: applies
  `.strikethroughStyle` per run when the run's own style carries
  `.strikethrough` (`~~…~~`, `<s>`, `<del>`). There is no way to ask for a
  style over the whole block.
- `Sources/Markio/OutlineSidebar.swift` `HeadingCell.configure`: one row per
  heading, a plain label plus a `done/total` badge; the badge goes tertiary
  when the section is fully ticked. Task items themselves are never outline
  rows — the outline lists headings only.
- `Sources/MarkioRender/DocumentSummary.swift`: the background walk visits
  every leaf, reads every marker, and publishes counts and per-section
  progress in batches. It does not record where the open boxes are.
- `Sources/Markio/DocumentWindowController.swift`: `summaryLabel` is a plain
  `NSTextField` label; `recount()` fills it. `documentView.reveal(ordinal:)`
  scrolls a block to a quarter of the way down the view; `visibleRangeChanged`
  receives the visible ordinal range on every scroll and binary-searches
  `outlineOrdinals` for the current section.
- `Sources/Markio/MainMenu.swift`: View menu holds ⌥⌘S outline, ⌥⌘M map,
  ⌥⌘P present, ⌥⌘Z zen, ⌥⌘+/− column; Edit holds ⌘G / ⇧⌘G for find.

### Constraints

- The invariants in `AGENTS.md`: no walk over every block at open time on the
  main thread; the text is held once as bytes; the app never writes the file.
- A linear scan over `leaves` on every keypress is the quadratic-in-disguise
  the rulebook warns about; anything consulted per press is sorted and
  binary-searched, like `outlineOrdinals`.
- `deno task check` is the gate: fmt, lint, debug and release builds, marker
  scan (`TODO`/`FIXME` may not appear in sources outside the two allowed
  files), swift-format lint, tests.
- Documentation in English; `requirements.md`, `design.md`, `README.md` stay
  true after the change.

### Affected Surface

Independent pass by `surface-scout`, with the paths made repo-relative:

```
## Surface

- `Sources/MarkioRender/BlockLayoutEngine.swift:229-252` (`layoutParagraph`) — this is the body renderer for a task-list paragraph: it reads `document.taskMarker(...)`, draws the checkbox (`addCheckbox`, lines 1022+), then builds the styled text via `AttributedBuilder.build` with no knowledge of `task.isChecked`. This is the primary fix site for "body text of a completed item shown struck through."
- `Sources/MarkioRender/AttributedBuilder.swift:38-70+` (`build`) — the function that turns inline runs into an `NSAttributedString`; strikethrough is already applied per-run when `run.style.contains(.strikethrough)` (line 200-202). Making a checked task line strike through everything needs either a new parameter here or the caller forcing the flag on every run.
- `Sources/MarkdownKit/TaskList.swift` — `Document.taskMarker` / `TaskMarker.isChecked` is the single source of truth for "is this list item done"; both the body renderer and the summary/count logic already read it, so no new parsing is needed, only new consumers of the existing flag.
- `Sources/MarkioRender/BlockPlainText.swift:46-58` — produces the plain-text projection of a task paragraph (used by Find/Copy) and also calls `taskMarker`; it does not add strikethrough markers today (plain text has no styling), so it is unaffected unless the plan wants Find/Copy text to carry a textual marker too (unlikely, but worth the planner's explicit call).
- `Sources/MarkioQuickLook/PreviewViewController.swift` — the Quick Look extension renders through the same `MarkioRender` (`BlockLayoutEngine`), so a fix in the shared layout engine propagates here automatically; not a separate implementation to touch, but a consumer to re-verify (QuickLook is a sandboxed WKWebView-free host per `AGENTS.md` gotchas, so the same code path applies).
- `Sources/Markio/OutlineSidebar.swift:59-105,154-162` (`HeadingCell.configure`) — this IS the app's "оглавление" (table of contents / outline sidebar). It renders only `Document.Heading` (from `##`-style headings), populated from `Document.headings()` in `Sources/MarkdownKit/Document.swift:220-235`, whose `text` field is a plain, unstyled `String` (`InlineText.plain`). Task-list items are list items, never headings, so **no outline row ever corresponds to an individual todo item** — the outline only shows a numeric "done/total" badge per heading section (line 154+, fed by `DocumentSummary.SectionProgress`), not the item text itself, styled or otherwise.
- `Sources/MarkioRender/DocumentSummary.swift:100-115` — already counts checked vs. unchecked tasks per heading section for the sidebar's progress badge; this is a producer of outline data but has no channel for "this specific list item is done" text, only aggregate counts. Relevant if the plan decides to add such a channel.
- `documents/requirements.md:154` (`VIEW-8`) — the SRS line documenting current checkbox-rendering behavior ("Task list items show a real checkbox, checked or not, and are not …"); needs updating to state the new strikethrough behavior once implemented, per the project's own doc-upkeep rule.
- `documents/design.md:149,158` — SDS description of how checkboxes are drawn as decorations in `BlockLayoutEngine`; would need a short addition describing the strikethrough-when-checked behavior if the design doc is meant to stay accurate.
- `Tests/MarkdownKitTests/InlineParserTests.swift:129-140` (`testTaskListMarker`) — existing unit test on `taskMarker`; a natural place to extend or a neighbor for a new rendering-level test.
- `Tests/MarkioRenderTests/DocumentSummaryTests.swift:16-24` and `Tests/MarkioRenderTests/PlainTextParityTests.swift:122` — both build fixture documents containing `- [x] ...` lines; the parity test in particular guards that `BlockPlainText` output matches `BlockLayoutEngine` output, so if strikethrough is only added on the attributed-string side (not on `plainText`), this existing invariant is unaffected, but it is exactly the kind of test that should be checked for expectations that assume "no extra styling."
- `Sources/MarkioRender/RichText.swift:82` — reads `.strikethroughStyle`/`.strikethroughColor` attributes when producing rich-text output (Copy as Rich Text / drag-out); a downstream consumer of whatever attributes `AttributedBuilder` sets, so a checked task's strikethrough (once added) would automatically also appear in copied rich text — worth the planner noting as an implied, in-scope side effect, not a separate implementation.
- `Sources/MarkioRender/CompareEngine.swift` — grepped for `taskMarker`/checkbox handling: none found. It likely reuses the same paragraph-layout path for diff rendering (not confirmed in depth); worth a check whether a compare/diff view of two document versions also needs the same strikethrough treatment for checked items, or whether it takes an entirely separate code path.
- `Sources/MarkioRender/BlockLayoutEngine.swift:997-1024` (`addListMarker`, `addCheckbox`) — measurement/decoration code specifically for task-list items; not text styling, but adjacent code the planner will touch or step around when adding strikethrough.

## Queries used
- `find . -maxdepth 2 -type d` (survey top-level dirs)
- `grep -rln -i "checkbox|task.*list|taskitem|- \[x\]|isChecked|\[ \]" --include='*.swift'` across `Sources`/`Tests`
- `cat Sources/MarkdownKit/TaskList.swift`
- `grep -n "taskMarker|TaskMarker|isChecked" -r Sources Tests`
- `grep -n "strikethrough|NSAttributedString.Key.strikethrough|.strikethroughStyle"` across `Sources`
- `grep -n "outline|Outline" -il Sources/Markio/*.swift Sources/MarkioRender/*.swift`
- Read `BlockLayoutEngine.swift` around `layoutParagraph`/`addCheckbox`, `DocumentSummary.swift` in full head
- `grep -n "struct Heading" -A 15 Sources/MarkdownKit/*.swift`
- `grep -rln "Heading\b"` across MarkdownKit/MarkioRender
- `grep -rn "DocumentMap"` across relevant sources (checked the right-edge minimap as a possible second "TOC")
- Read `Sources/Markio/OutlineSidebar.swift` in full relevant sections
- `grep -n "addCheckbox" -A 25 BlockLayoutEngine.swift`
- Read `AttributedBuilder.swift` build signature
- `grep -rn "taskMarker|\[x\]|isChecked|task list|TaskList"` across `Tests`
- `grep -n "checkbox|addCheckbox|task" -i` in `DocumentLayoutTests.swift`
- `grep -n -i "task|checkbox|todo|strikethrough"` in `documents/requirements.md`, `documents/design.md`
- `grep -rln "BlockLayoutEngine|AttributedBuilder|OutlineSidebar" Sources/MarkioQuickLook`, then `grep -rln "MarkioRender" Sources/MarkioQuickLook`
- `grep -n "setHeadings|headings()" Sources/Markio/DocumentWindowController.swift`
- `grep -n "taskMarker|itemHead|checkbox|addCheckbox" CompareEngine.swift BlockPlainText.swift`

## Not examined (budget)
- `Sources/MarkioRender/CompareEngine.swift` was only grepped, not read in full — did not confirm whether its diff-rendering path shares `layoutParagraph`/`AttributedBuilder` directly or has its own text-styling code that would also need the strikethrough change.
- `Sources/markio-bench` and `Sources/markio-viewbench` (bench/snapshot tooling) were not checked for any task-list-specific rendering assumptions (e.g. golden-image tests that would need re-baselining after a visual change).
- `test-fixtures/` directory contents were not inspected for existing task-list `.md` fixtures that visual/snapshot tests might reuse.
- Did not open `Sources/Markio/Snapshot.swift` or `Sources/Markio/DocumentMapStrip.swift` in depth (only grepped) to fully rule out that the document-map strip (right-edge minimap) encodes checked/unchecked task state visually in a way the user could be calling "оглавление."

## Could not rule out
- The user's phrase "в оглавлении" (in the table of contents) has no literal target in the current code: `OutlineSidebar` only lists markdown headings, never individual task-list items, and task items are never headings. Either (a) the user means something else by "оглавление" (e.g. the document minimap, or a different, not-yet-built panel), or (b) the request implies a new feature — showing task items themselves in a navigable list — that does not exist yet. This is a real ambiguity the planner should resolve with the user rather than silently pick one interpretation.
- Whether `CompareEngine.swift`'s diff view needs the same strikethrough treatment could not be confirmed without a deeper read (see "Not examined").
```

The scout's second message (the bottom-bar navigation) arrived after the
scout was dispatched, so the surface for it is the planner's own.

Disposition, one bullet per item from both lists:

- `BlockLayoutEngine.layoutParagraph` — covered-by DoD "body strike".
- `AttributedBuilder.build` — covered-by DoD "body strike" (a block-wide
  style parameter).
- `MarkdownKit/TaskList.swift` — not affected — `taskMarker` already returns
  `isChecked`; no parsing changes (`Sources/MarkdownKit/TaskList.swift:15-37`).
- `BlockPlainText.swift` — not affected — plain text carries no styling, and
  `PlainTextParityTests` compares strings, not attributes
  (`Sources/MarkioRender/BlockPlainText.swift:46-58`).
- `MarkioQuickLook/PreviewViewController.swift` — not affected as code —
  renders through the same `BlockLayoutEngine`; the release build in
  `deno task check` compiles it (`Sources/MarkioQuickLook`, no own layout).
- `OutlineSidebar.HeadingCell.configure` — covered-by Solution 3 (task rows
  beside the heading rows; the owner chose this reading at variant selection).
- `Document.headings()` / `Heading.text` — not affected — the label is still
  built from the plain text; the strike is an attribute added in the cell
  (`Sources/MarkdownKit/Document.swift:229-246`).
- `DocumentSummary.count` — covered-by Solution 2 (the walk records every box).
- `DocumentWindowController` (`summaryLabel`, `recount`,
  `visibleRangeChanged`, `reveal`) — covered-by Solution 4.
- `DocumentView` (find highlights) — covered-by Solution 5.
- `MainMenu.viewMenu` — covered-by Solution 4.
- `documents/requirements.md` VIEW-8, VIEW-35, new VIEW-39 — covered-by DoD
  "docs".
- `documents/design.md` Boxes / Markio sections — covered-by DoD "docs".
- `README.md` — covered-by DoD "docs" (checked for a feature line that names
  checkboxes or the summary at commit time).
- `Tests/MarkdownKitTests/InlineParserTests.swift` — not affected — the
  marker parser does not change.
- `Tests/MarkioRenderTests/DocumentSummaryTests.swift` — covered-by DoD "next
  open box" (a test for the recorded ordinals).
- `Tests/MarkioRenderTests/PlainTextParityTests.swift` — not affected — see
  `BlockPlainText` above; the suite is run in the review phase.
- `RichText.swift` (copy with styles) — not affected as code — it reads the
  attributes the builder sets, so a copied done item carries its strike, which
  matches what is drawn (`Sources/MarkioRender/RichText.swift:82`).
- `CompareEngine.swift` — not affected — it merges two documents into one
  `MarkdownKit.Document` (`DocumentWindowController.displayed`), which the
  same engine lays out; there is no second text-styling path (`grep
  layoutParagraph|AttributedBuilder|BlockLayoutEngine CompareEngine.swift`
  returns nothing).
- `addListMarker` / `addCheckbox` — not affected — decoration geometry stays;
  only the text beside it changes.
- `markio-bench snapshot`, `--capture` — not affected as code; used as the
  evidence path for the visual check.
- Store screenshots in the hub (`screenshots/markio/`) — deferred — human
  choice; a screenshot showing a task list would change look and belongs to
  the hub, not this repo.
- `test-fixtures/demo.md` (has `[x]` and `[ ]` lines) — not affected as code;
  used as the capture fixture.
- `DocumentMapStrip` — covered-by Solution 6 (a layer for the open boxes).

## Definition of Done

- [x] Body strike: the text of a ticked task item is drawn struck through;
      an unticked one is not.
      `(VIEW-8, Tests/MarkioRenderTests/TaskStrikeTests.swift::testATickedBoxStrikesItsText, deno task test)`
- [x] Outline rows: every task item appears in the outline under its heading
      as one row holding the first line of its text, truncated with an
      ellipsis and never wrapped; a ticked one is struck through; clicking a
      row scrolls to the item.
      `(VIEW-35, Tests/MarkioTests/OutlineRowsTests.swift, deno task test)`
- [x] Next open box: the bar's count is a stepper — ‹ n of m done › — and the
      count itself, the › button, ⌥⌘J and the View menu item "Next Open
      Task" scroll to the next open box after the current one (after the top
      of the view when none is current), wrapping to the first; ‹, ⌥⇧⌘J and
      "Previous Open Task" go the other way.
      `(VIEW-39, Tests/MarkioTests/OpenTaskNavigationTests.swift, deno task test)`
- [x] Current box: the open box reached by the stepper is highlighted in the
      body the way find's current match is, and the highlight goes when the
      reader scrolls it away or the document reloads.
      `(VIEW-39, Tests/MarkioRenderTests/TaskStrikeTests.swift::testTheCurrentOpenTaskIsHighlighted, deno task test)`
- [x] Map layer: the map down the right edge marks the lines of the open
      boxes in a tint of their own.
      `(VIEW-39, Tests/MarkioTests/DocumentMapStripTests.swift::testOpenTasksAreMarked, deno task test)`
- [x] Docs: VIEW-8 and VIEW-35 amended, VIEW-39 added to
      `documents/requirements.md`; `design.md` and `README.md` say the same.
      `(VIEW-39, manual — korchasa, grep -n "VIEW-39" documents/requirements.md)`
- [x] Gate: `deno task check` exits 0.
      `(BUILD-1, deno task check, deno task check)`
- [x] Looked at: `--capture` of `test-fixtures/demo.md` in light and dark
      shows the ticked line struck, the outline rows, the stepper and the
      map marks.
      `(VIEW-8, manual — korchasa, .build/Markio.app/Contents/MacOS/Markio test-fixtures/demo.md --capture=<png>)`

## Solution

Selected: variant 3, the task navigator, with the owner's reading of the
outline — task items become outline rows of their own.

### 1. Body strike — `MarkioRender`

- `AttributedBuilder.build` gains `blockStyle: InlineStyle = []`, merged into
  every text run's style before the font and attributes are chosen. The
  strike therefore uses the run's own foreground colour, as `~~text~~` does.
- `BlockLayoutEngine.layoutParagraph` passes `.strikethrough` when
  `task.isChecked`. Plain text (`BlockPlainText`) is untouched.
- Test: `DocumentLayoutTests.testATickedBoxStrikesItsText` lays out
  `- [x] Done\n- [ ] Open`, reads the first segment's attributes at
  offset 0 and expects `.strikethroughStyle` on the ticked box only.

### 2. The walk records the boxes — `DocumentSummary`

- `Result` gains `newTasks: [TaskEntry]` where
  `TaskEntry { ordinal: Int, section: Int, isChecked: Bool, title: String }`
  — only the entries counted since the previous flush, so a flush costs the
  batch and never copies what was already sent. `section` is the index of
  the heading the item sits under, −1 before the first heading. `title` is
  the item's plain text up to its first newline (the walk already computes
  the text for the word count) and capped at 120 characters — a one-line row
  cannot use more. The copy is of the same kind and size as the heading
  texts `headings()` already keeps, and nothing else of the paragraph stays
  alive.
- The receiver appends, so its array is in document order and the ordinals
  of the open boxes are sorted and binary-searchable without a second pass.
- Test: `DocumentSummaryTests` — a document with two headings and three
  boxes yields three entries with the right section, state and first line.

### 3. Outline rows — `OutlineSidebar`

- The sidebar's model becomes `rows: [Row]`, `enum Row { case heading(Int),
  case task(TaskEntry) }`. `setHeadings` builds heading-only rows at once
  (as today). `setProgress(_:)` keeps redrawing badges in place as today;
  `addTasks(_:)` appends the batch's entries to `tasks` and asks for a
  rebuild. Rebuilds are coalesced: at most one every 250 ms while entries
  keep arriving, plus one when the count completes, so a 32 MB document
  costs a few hundred rebuilds over its 39-second walk instead of one per
  batch. A rebuild merges headings and tasks by ordinal into `rows`,
  recomputes `headingRows`, calls `reloadData()` and re-applies the current
  section's selection, so the highlight does not flicker.
- `headingRows: [Int]` maps a heading index to its row; `setCurrent(heading:)`
  selects `headingRows[heading]`; `tableViewSelectionDidChange` maps the
  selected row back through `rows` to either `onSelectHeading(Int)` or
  `onSelectTask(ordinal: Int)`. The two index spaces never meet.
- `TaskCell`: one label, indented one step past its heading's level, font
  11.5 regular, `.byTruncatingTail`, `maximumNumberOfLines = 1`; a ticked
  item gets `.strikethroughStyle` and `.tertiaryLabelColor`, an open one
  `.secondaryLabelColor`. `OutlineSidebar.taskTitle(_:)` is a static that
  returns the attributed string, so the test reads it without a window.
- Test: `OutlineRowsTests` — `setHeadings` + `setProgress` produce the
  expected row order and the ticked row's attributes.

### 4. The stepper and the moves — `DocumentWindowController`

- The bar: `summaryLabel` stays; two small borderless buttons `‹` and `›`
  (`NSButton`, `.inline` style, `chevron.left/right` SF symbols, font 10)
  flank it and are hidden when there is no open box. A click on the label
  itself is `nextOpenTask`. The buttons' tooltips carry the shortcut.
- State: `openTasks: [Int]` (ordinals of unchecked entries, appended from
  each batch) and `currentOpenTask: Int?` — the ordinal of the highlighted
  box, not an index, so a batch that grows the array cannot move it.
- `outline.onSelectHeading = jumpToHeading`, `outline.onSelectTask =
  { reveal(ordinal:) and highlight }`.
- `static func nextOpenTask(after position: Int, in open: [Int]) -> Int?`
  and `previousOpenTask(before:in:)` — binary search, wrapping. Pure, so
  `OpenTaskNavigationTests` covers them without a window.
- `@objc nextOpenTask(_:)` / `previousOpenTask(_:)`: the position is the
  current open box's ordinal when one is current, else the top of the
  visible range; the target is revealed and highlighted through
  `documentView.setCurrentTask(ordinal:)`. Scrolling the current box out of
  view (`visibleRangeChanged`) drops `currentOpenTask` and the highlight;
  `recount()` drops both when the document reloads.
- Menu: View ▸ "Next Open Task" ⌥⌘J, "Previous Open Task" ⌥⇧⌘J, after Zen
  Mode and before the zoom separator. `MenuTests` pins the shortcuts.

### 5. The highlight — `DocumentView`

- `setCurrentTask(ordinal: Int?)` keeps one ordinal; the draw pass adds a
  block-wide `DocumentRenderer.Highlight` for it in the current-match
  colour, the same way `findHighlights` does for the current match.
- The highlight list for a box is built by an internal
  `highlights(box:ordinal:)` the draw pass calls, so
  `DocumentLayoutTests.testTheCurrentOpenTaskIsHighlighted` reaches it
  through `@testable import MarkioRender` without drawing.

### 6. The map layer — `DocumentMapStrip`

- This layer comes from variant 3, which the owner chose; the request
  itself did not name the map.
- `setOpenTasks(lines: [Int])`: a fifth layer between the changes and the
  find marks, drawn as short bars in `theme.palette.secondaryText` at 60%.
  The controller feeds it the source lines of the open ordinals through
  `DocumentMap.firstLine(displayed, ordinal:)` — the same call that feeds
  the find marks — on the coalesced outline ticks, not on every batch.
- `Tests/MarkioTests/DocumentMapStripTests.swift::testOpenTasksAreMarked`
  reads the lines the strip holds (`DocumentMapStrip` lives in the app
  target, so the test does too).

### 7. Docs

- `requirements.md`: VIEW-8 says a ticked box's text is struck; VIEW-35 says
  the outline lists the boxes under their headings; new VIEW-39 states the
  stepper, the shortcuts, the highlight and the map layer.
- `design.md`: Boxes (block-wide style), Markio (the stepper and the outline
  rows), the map (fifth layer).
- `README.md`: the feature list, if it names the summary or checkboxes.

### Error handling

No I/O and no new failure modes: an ordinal outside the layout is refused by
`reveal` already; an empty `openTasks` disables the buttons and makes the
actions no-ops.

### Verification

```
deno task test
deno task check
.build/Markio.app/Contents/MacOS/Markio test-fixtures/demo.md --capture=/tmp/tasks-light.png
```

## Follow-ups

- Verified 2026-09-08: body strike, outline rows, stepper and both appearances
  by offscreen `--snapshot` of a six-box report; the step itself by a test
  through a real window (`testTheActionStepsThroughTheOpenBoxes`). A keystroke
  sent by AppleScript never reached the window, so the highlight was verified
  by `testTheCurrentOpenTaskIsHighlighted` rather than by a picture.

- Store screenshots in the hub (`screenshots/markio/`) may show a task list
  and would then look different from the shipped app — a hub-side check, not
  this repository's.
