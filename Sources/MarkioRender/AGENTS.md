# MarkioRender

CoreText typesetting, the virtualized layout, and the reading view. Everything
here is `@MainActor` except the parts that deliberately are not.

## Rules

- **Only visible blocks are laid out.** `DocumentLayout` measures on demand and
  evicts outside a retain margin. Anything that loops over `document.leaves` at
  setup time defeats the design; if you need a whole-document answer, prove it
  is O(1) per block and cheap, or do it off the main thread in batches.
- **`HeightIndex` is the only source of geometry.** Offsets, total height and
  hit-testing by offset all go through the Fenwick tree. Do not keep a parallel
  array of positions.
- **`setHeight` returns a shift, and the caller must apply it.** Replacing an
  estimate with a measurement moves everything below it; doing that silently
  while someone scrolls up is what makes a virtualized view feel broken.
- **`DocumentRenderer` holds the drawing**, so the view and the offscreen PNG
  take the same path. Draw in the view directly and the offscreen render stops
  being evidence.
- **`BlockPlainText` must match `AttributedBuilder` character for character.**
  Soft break is a space, hard break is a newline, an image is its marker. A
  test asserts it; when you change one, change the other in the same commit.
- **`CodeText` is the only place a fenced block's colour is decided.** Diff
  bands, ANSI colour and syntax highlighting are three branches of one function
  that returns the attributed string, the plain text and the tints together —
  add a fourth there, not in the layout engine.
- **A comparison is merged in the source, never in the layout.** `CompareEngine`
  produces one Markdown buffer plus the ranges each side contributed; everything
  downstream sees ordinary Markdown. Nothing but `DocumentLayout.mark(at:)` may
  learn that a comparison is in progress.
- `Theme` is not `Sendable` — `CTFont` and `CGColor` are not. `Metrics` is.

## Where the bodies are buried

- **A single line positioned by its line box sags below the baseline**, because
  half the leading gets added twice. Markers and checkboxes go through
  `Typesetter.singleLine`, which aligns to the first line's baseline.
- **Code blocks are built span by span** so byte offsets never convert to
  UTF-16 positions. Highlighting is skipped above 128 KiB.
- **`contentX` centres the column inside the view's width**, so the view has to
  span the whole scroll area. If the column hugs the left edge, the document
  view is not tracking the scroll view's width.
- **Merging two versions without a separator merges their paragraphs.** Two
  consecutive lines are one block to the parser, so the old text and the new
  text of a replaced paragraph would be tinted as a single removal. A blank line
  wherever the origin changes is what keeps them apart.
- **Images are decoded at draw width, never at natural size.** `ImageLoader`
  goes through `CGImageSourceCreateThumbnailAtIndex` with a byte budget; loading
  a full-size photo undoes the memory design in one line.
- **Whether an inline picture is drawn depends on its destination alone.**
  `InlineImage` decides, and it must not ask whether the file decodes: Find
  projects the same text with no loader, and the two have to agree character
  for character. An unreadable picture leaves an empty frame.
- **A line's height comes from its runs, not from `CTLineGetTypographicBounds`.**
  That call folds a baseline offset into the descent, so a single superscript
  would make one line of a paragraph taller than its neighbours. Run bounds are
  unshifted; a run delegate — an inline picture — still reports its full height,
  which is what keeps room for pictures.
- **A closed section hides blocks; it never removes them.** Zero height and an
  empty box, kept as ranges of ordinals. Dropping the blocks would be simpler
  and would silently break find, copy and every ordinal the view holds.
- **A footnote's gutter is measured from its own label.** Labels are free text,
  and a fixed indent either wastes space or lets `[^design-notes]` run into the
  note.
- **`MathFormula.canTypeset` and `MathFormula.box` must agree exactly.** One
  decides what Find sees, the other what is drawn, and a disagreement moves
  every match offset in the block. Keep the decision in the parser, which needs
  no font, and let the layout be total.
- **Anything placed against another glyph is measured from its ink**
  (`CTLineGetBoundsWithOptions(.useGlyphPathBounds)`), not from the font's
  ascent — the radical's bar, an accent, the limits over a sum, a bracket grown
  to a matrix. A font leaves room above its tallest glyph; measure that instead
  and the mark floats a whole x-height clear of what it belongs to. This has
  cost a correction once per new user of it, so use `inkTop`/`inkBottom`.
- **Display style is one bit and it moves one thing.** `$$…$$` sets
  `InlineStyle.displayMath`, and the layout reads it in a single place: a sum
  writes its range above and below its sign instead of beside it. It stops at
  the first script, the way it does in TeX, and an integral ignores it, because
  its limits are read along its own slope.
- **A formula's glyphs are drawn after the highlights.** They are decorations,
  and decorations are painted first — a selection would cover the formula
  instead of tinting it.
- **A diagram is drawn whole or not at all.** `MermaidDiagram.parse` returns nil
  for every construct the layout cannot draw — a nested subgraph, a tinted band,
  a colour name it does not know — so the fence falls back to a code block.
  Adding a keyword to the accepted list without drawing it is how a graph starts
  asserting something its author did not write.
- **A subgraph owns a strip of the cross axis.** Its frame is the bounding box
  of its members, and that box is only honest because no node outside the group
  is ever placed in the strip. Any change to flowchart placement has to keep
  that property, or a frame starts enclosing nodes that do not belong to it.
- **A drawn diagram types nothing**, so its block has no segments and its plain
  text is the fence's own source. That is deliberate: find still locates the
  diagram, copy still yields something useful, and there is no text to
  highlight because there is no text. It is also what Copy PNG and the enlarged
  window are built on — both re-read that source rather than keeping a second
  drawing beside the block.

## Tests

`Tests/MarkioRenderTests`: the Fenwick tree against naive prefix sums, the
plain-text parity described above, the ANSI parser, image blocks and their
fallbacks, code regions, the bounded file reader, and the compare engine — down
to the block separation that keeps a replaced paragraph from reading as one.
