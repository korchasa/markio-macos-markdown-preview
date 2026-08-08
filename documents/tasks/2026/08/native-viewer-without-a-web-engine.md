# Markio 2 — a native viewer with no web engine

**2026-08-08**

## Goal

Build a separate, independent Markdown viewer, using Markio only as a
reference for what a reader needs. No web view, no HTML, no JavaScript.
Optimize for speed and for memory on large documents.

## Decisions

- **Four targets, not one.** MarkdownKit (pure Swift, no AppKit), MarkioRender
  (CoreText + AppKit), Markio2 (the app), markio2-bench (headless). The split
  is what keeps a font metric from leaking into the parser.
- **Bytes, not `String`.** The whole scan path works on `[UInt8]` and `Int32`
  ranges. `String` is built once per visible block. This is the decision the
  performance numbers come from.
- **Blocks eagerly, inline lazily.** The block scan runs over the file; inline
  parsing runs per block when it is about to be drawn and is discarded when it
  leaves the viewport.
- **A Fenwick tree over block heights.** Offsets, total height and hit-testing
  are O(log n) from the first frame, over estimates that are replaced by
  measurements as blocks are seen. `setHeight` returns the shift so the view
  can undo it and keep the reader's place.
- **Find searches plain text reproduced without a theme**, rather than an
  index. An index would be the second copy of the document this project exists
  to avoid.
- **The build enforces the premise.** `deno task check` fails if WebKit,
  JavaScriptCore or HTML loading appears in the sources.

## Measured

Release build, generated documents:

- 1 MB — parse 1.9 ms (520 MB/s), 10 436 blocks, structure 0.4 MB (38%),
  viewport inline 0.4 ms
- 8 MB — parse 14.7 ms (545 MB/s), 84 725 blocks, structure 3.0 MB (38%),
  viewport inline 0.3 ms
- 32 MB — parse 69.3 ms (462 MB/s), 341 868 blocks, structure 12.2 MB (38%),
  viewport inline 0.3 ms, whole-document inline 353 ms
- Peak resident across all three runs: 73.6 MB

Opening an 8 MB document in the app costs the same wall clock as opening an
8 KB one; the ~3 s of a scripted launch is AppKit process start, not the
document.

## Bugs worth remembering

Recorded in `AGENTS.md` and the module files. The four that cost the most:

1. Indented code was invisible because the indent was measured with a cap.
2. Link destinations printed twice, because syntax was dropped by token kind
   instead of by byte offset.
3. The app trapped on launch: `NSDocument` is main-actor isolated and
   concurrent reading moves construction to a background queue.
4. The window opened as a bare title bar: every edge was pinned to a neighbour,
   so the content's fitting size was 1×31 and AppKit sized the window to it.

## Not done

- Images are marked, not decoded; no diagrams
- ANSI colour in code blocks
- No Quick Look extension, no diff view
- The app is not registered anywhere for signing or release, and must not be
  without the owner's say-so
