# The document map — a structural strip down the right edge

**2026-08-20 · priority: medium**

A narrow permanent strip at the right edge showing the shape of the whole
document: where the headings are, where code sits, which stretch is a table,
a diagram or a picture, and where the reader is inside all of it. Find marks,
comparison marks and the reading position are layers on the same strip rather
than three separate ribbons.

The scrollbar answers one question — how far down am I — and answers it badly
on a document a thousand screens tall, because the thumb is a few points high
and the same for every document. The map answers the question a reader of a
long report actually has: what is this document made of, and which part of it
is the part I want. An agent's report is heading, prose, code, table, diagram,
repeated fifty times; the map is that rhythm drawn small.

Priority is medium on purpose. It does not carry the 4.3(a) argument the way
the six reader tools do — it makes reading a large document better rather than
making the app a different kind of product — so it goes after that wave, and
it shares one piece of machinery with it (see "Ordering" below).

## Status — 2026-08-22: shipped (`e41a9fd`)

The strip is there on open, in both appearances, and hides itself on a document
shorter than the window. Structure, comparison marks, find marks and the
reading rectangle are four layers on one strip; `FindOverview` is gone as a view
of its own and find behaves as it did. A click on a find mark still selects that
match, a click anywhere else goes to that part of the document, a drag scrolls
it, and hovering names the section. ⌥⌘M and the View menu hide and show it, and
the choice is remembered.

The Ordering section below was followed: the summary walk owns the pass and
publishes the classes, so nothing walks the block array a second time. The cost
is one byte per leaf — 0.2 MB on the 32 MB document the bench generates — and
the bench itself is unchanged, because it measures parsing and structure and
never opens a window.

Two things to know that the plan did not say:

- **A Mermaid fence is classified by its info string alone.** The layout also
  asks whether the diagram parses; the map does not, because reading every fence
  in the document to colour a strip 14 points wide costs more than the strip is
  worth. A fence that says `mermaid` and does not parse therefore shows on the
  map as a diagram and on the page as a fence.
- **A row is named by whatever fills most of it, with prose counted at half.**
  Prose is the background a reader scans past, so where a row holds both, the
  other one is the informative answer. Anything else that landed in the row
  keeps a bit in the row's flag set, and a diagram, table or picture also gets a
  dash of its own colour — which is what keeps one picture visible in a
  thousand screens of prose.

Left undone on purpose: the hover tip names the section but does not preview it,
and the strip is not drawn in the Quick Look extension, which has no scroll view
to pin it beside.

## Status — 2026-08-22, later: reworked into a minimap

The owner looked at the shipped strip and said what it was missing: it must be
substantially wider and show the real content rather than the types of blocks,
with the editors' minimap as the reference. That is the version now in the app,
and it replaces the coloured bins entirely.

What changed:

- **The strip draws the document, not a legend for it.** One row per source
  line, a mark per run of non-space bytes at the column it starts on, read
  straight from `document.bytes` through `LineIndex`. Indentation, line length
  and the rhythm of a paragraph all survive; the block's kind is now the colour
  of that text rather than a bar standing in for it.
- **14 points became 120,** with the reading column inset to match.
- **A long document is shown through a window of lines** centred on the reader
  and clamped at both ends, so only the lines the strip can show are ever read.
  A 130,000-line document maps as cheaply as a note — measured at 2.6 s wall for
  a launch, a scroll to line 41,574 and a shot.
- **Find marks and comparison marks travel as source lines,** so every layer
  sits on the same axis as the rows and slides with them.

Two things learned in the doing, both of which cost a wrong version first:

- **A line is clipped at the map's edge, never wrapped.** With wrapping, rows
  and lines stop matching, and the arithmetic that places the reading rectangle
  drifts — on paragraphs of 500 characters it drifted off the bottom of the
  strip and the rectangle simply vanished. One row to a line makes the index
  `line - startLine`.
- **The window and the rectangle must be computed from the same thing.** The
  first version took the window from the scroll fraction of the document's
  height and the rectangle from the lines of the viewport; heights below the
  viewport are estimates, so the two disagreed and the rectangle fell outside
  its own window.

One thing outside the app was fixed on the way: `--capture` fired from a block
on the main queue, and a main-queue block cannot be interrupted by another one,
so anything the app defers with `DispatchQueue.main.async` never ran before the
shot. Captures of anything deferred — the map's window after a scroll — showed a
state no reader ever sees. It fires from a timer now.

Worth knowing outside this repository: the store screenshots are shots of the
whole window, so they now show a 120-point minimap and need regenerating before
the next submission.

## Status — 2026-08-22, later still: the map got a lane of its own

Three things were wrong with where the strip sat, all reported from the running
app, and all now fixed and covered by
`testTheMapTakesALaneOfItsOwnBesideTheScroller`:

- **The scrollbar belongs to the right of the map.** The strip was pinned to the
  trailing edge of the scroll view, which is where the scroller draws, so one
  covered the other. It now stops a scroller's width short of that edge, and the
  scroller has the lane past it to itself.
- **There is no line down the left of the map.** The strip drew a one-point
  separator there; against the map's own background it read as a black stripe,
  and the edge of the text is enough on its own.
- **The reading area now counts the map.** It was told about the strip through
  `contentInsets`, which shifts what can be scrolled to without narrowing the
  document view — so on a document wide enough the text ran under the map. The
  document view is now sized to what the map leaves, measured off the strip's own
  frame.

The width is set in `ReadingClipView.layout`, and the first attempt at it — a
resize notification — is worth recording as a trap. The notification arrives
after the layout pass that moved the edge, so anything drawn in between shows
the old width; that surfaced as two offscreen snapshots of one document coming
out different sizes in a single run, which is exactly the kind of picture that
would have gone out to the store.

Measured on the running app at the widest reading column: the text stops at
1296.5 points, the map runs 1303 to 1423, and the scroller has 1423 to 1440.

## Status — 2026-08-22, last: the column had to be fitted too, and the map faded

The owner looked at the running build and said the text still ran onto the map.
It did, and the measurement above is how it hid: the page had been narrowed, so
the text ended at 1296.5 points — but it ended there because it was **cut off**
at the edge of the page, not because it fitted. The reading column is fitted by
`fitted`, and that was still measuring the clip view, which runs on underneath
the strip. At the widest reading setting the column overshot the page by 112
points, and every line long enough was clipped mid-word against the map.

Two things follow, and both are now in the code:

- The column is fitted to what the map leaves, not to the clip view, and the
  page and the column are set in one place — resizing the page refits the
  column, so a window drag, a map toggled away and a slider all agree.
- A number that looks right is not a verification. Text ending 6 points short of
  the map read as "it fits" when it meant "it is being cut here". The test now
  asserts the column against the page (`testTheWidestColumnStillStopsAtTheMap`),
  and without the fix it fails with 935 against 823.

The owner also asked for a paler map, so it stops pulling the eye when nobody is
using it. It draws at 0.55 of full strength, and the pointer entering the strip
brings it back to full — the shapes are still readable at rest, which is all the
map is for while the reader is reading.

## What it stands on

Almost all of it exists; this is assembly, not new architecture.

- **`Sources/Markio/FindOverview.swift`** is the prototype: 68 lines, a 12pt
  strip pinned to the scroll view's trailing edge, marks as fractions of the
  document's height, click jumps to the nearest one. The map is that view
  grown a structural background and a reading marker, so the find strip stops
  being a view of its own.
- **`HeightIndex`** answers `offset(of:)` and `index(atOffset:)` in O(log n),
  which is what makes a click on any point of the strip resolvable to a block
  without a scan.
- **`Block` is 24 bytes and holds `kind`, `level`, `flags` and `info`** — every
  classification the map needs is already in the flat array, with no text and
  no typesetting.
- **`DocumentLayout.rebuildEstimates()` already walks every leaf on open.** The
  map does not introduce a new class of full-document work; it adds a second
  reader of a pass that is already made.
- **`DocumentLayout.mark(at:)`** already reports whether a block was added or
  removed while comparing, so the comparison layer is a lookup, not a new
  engine.
- **`DocumentView.onVisibleRangeChange`** already fires on every scroll, and
  `DocumentWindowController.visibleRangeChanged` already binary-searches
  `outlineOrdinals` for the heading that owns the top of the view — the same
  search names the section under the pointer for the hover tip.

## Decisions

- **The axis is document height, not byte offset.** Byte offset would be stable
  and cheap, but it would disagree with the scrollbar beside it: a stretch of
  dense code occupies few bytes and many points. A map whose click lands
  somewhere other than where the thumb says is worse than no map. The cost is
  that heights above the viewport are estimates, so the map settles as blocks
  are measured — the same approximation `updateFindOverview` already documents
  and accepts.
- **Store a class per ordinal, derive the bins.** Keep one `UInt8` per leaf —
  0.5 MB on a 32 MB document, against a 24-byte-per-block tree that is already
  13 MB — and rebuild the pixel bins from it whenever heights change. Binning
  directly would mean re-walking half a million blocks every time the column
  width changes, and `invalidateLayout()` throws every measurement away on a
  zoom step.
- **Bins are pixel rows, not blocks.** A 32 MB document has ~537 000 leaves and
  the strip is a few hundred points tall. Drawing is one pass over an array
  sized by the strip's height in device pixels; each bin keeps the class that
  dominates it plus a flag set for the classes that also landed there, so a
  single diagram inside a wall of prose still leaves a mark.
- **Classification comes from the block layer only.** Heading level, code,
  table, quote, list, front matter and thematic break are `kind` and `level`
  directly. A Mermaid diagram is a fenced block whose info string reads
  `mermaid`, exactly as `BlockLayoutEngine` decides it. A picture is the one
  guess: a paragraph whose first bytes are `![`. That heuristic is cheap and
  wrong at the edges — a paragraph that opens with an image and continues in
  prose counts as a picture — and the reason it is not an inline parse belongs
  in a comment next to it, or the next reader will "fix" it into one.
- **The build runs off the main thread, in batches.** "Nothing is typeset until
  it is visible" is about typesetting, and the map typesets nothing — but a
  half-million-block classification still must not stand between a reader and
  their first window. Take `FindEngine`'s shape: publish partial classes as
  they arrive, so the map fills in over a moment on a huge document and is
  instant on a normal one.
- **Hidden sections take no room on the map,** because the bins are built from
  the heights, and a block inside a closed `<details>` has height zero. This
  falls out of the design rather than needing a rule, and it is the correct
  behaviour: the map shows the document as it is on screen.

## Where it lands

- `Sources/MarkioRender/DocumentMap.swift` (new) — the classification, the
  binning and the layer model, all of it free of AppKit views so it can be
  tested without a window.
- `Sources/Markio/FindOverview.swift` → `Sources/Markio/DocumentMapStrip.swift`
  — the view: draws the bins, then the comparison marks, then the find marks,
  then the reading rectangle; handles click, drag and hover.
- `DocumentWindowController` — owns the strip, feeds it the visible range,
  hands find matches to a layer instead of to a separate view, and adds the
  right-hand content inset the strip needs.
- `Theme.Palette` — colours for the map's classes in both appearances. They
  must be derived from the existing palette rather than invented, or light and
  dark drift apart the first time either is touched.
- `MainMenu` (View menu, beside the outline item) and `Preferences` — the strip
  is shown or hidden, remembered like `outlineVisible`. `⌘M` is Minimize, so
  `⌥⌘M` beside the outline's `⌥⌘S`.

## What is hard

- **The right edge is already crowded.** `scrollView.hasVerticalScroller` is
  true and no content insets are set anywhere in the sources, so today the
  overlay scroller floats over the text and the find strip floats over both. A
  permanent strip makes that permanent. The strip takes 14pt and the scroll
  view gets a matching trailing inset; the reading column must stay centred in
  what is left, which is where the note in `AGENTS.md` about a document view
  that does not track its width earns its keep.
- **Redrawing on every measurement is a trap.** Each block scrolled into view
  replaces an estimate and changes `totalHeight`. Rebinning on every one of
  those is a full pass over the class array per block laid out. Rebin on a
  threshold — the total moved by more than a bin's worth — and never more than
  once per frame.
- **A drag must not fight the scroll it causes.** Dragging the reading marker
  scrolls the document, which moves the visible range, which moves the marker.
  `syncingScroll` already exists for the two-pane case and is the precedent for
  the guard.
- **Side by side has two documents and one strip.** The map belongs to the main
  pane, like find and the outline. Say so in the code; the alternative — two
  strips — is a different feature and a worse window.
- **A tiny document must not get a decorative strip.** Below a screenful there
  is nothing to map, and the honest behaviour is to hide it, the way the
  summary in the reader-tools wave shows nothing when a document has no
  checkboxes.

## Done when

- The strip is there on open, shows headings, code, tables, diagrams and
  pictures in distinguishable colours in both appearances, and hides itself on
  a document shorter than a screen.
- The reading marker tracks the scroll, a click jumps, a drag scrolls, and
  hovering names the section under the pointer.
- Find marks draw on the same strip, `FindOverview` is gone as a separate view,
  and find behaves exactly as it does today.
- While comparing, added and removed blocks are visible on the strip.
- `deno task bench` shows no change in time to first window at 32 MB, and the
  resident footprint grows by no more than one byte per block.
- `⌥⌘M` and the View menu item hide and show it, and the choice survives a
  relaunch.
- Unit tests in `MarkioRenderTests` cover classification and binning with no
  window and no theme; a `--capture` shot of a large document shows the strip
  drawn.

## Ordering

The classification pass and the document summary from the reader-tools wave
want the same thing: one background walk of the flat block array that publishes
partial results. Whichever lands first should own that walk and expose it, and
the second should subscribe rather than start a second walk. Two independent
half-million-block passes on open is the version of this that gets noticed on a
32 MB file.

## Cost

One and a half to two sessions. Most of it is the bin rebuild policy and the
right-edge layout; the classification itself is an afternoon.
