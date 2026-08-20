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
