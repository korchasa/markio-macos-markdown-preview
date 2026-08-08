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

## Tests

`Tests/MarkioRenderTests`: the Fenwick tree against naive prefix sums, and the
plain-text parity described above.
