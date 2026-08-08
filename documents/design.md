# Markio 2 — Design

How the viewer meets `requirements.md`.

## The shape of it

Five targets, in dependency order:

- **MarkdownKit** — the parser. Pure Swift, no AppKit, no fonts, no theme.
- **MarkioRender** — CoreText typesetting, the virtualized layout, the reading
  view. Depends on MarkdownKit and AppKit.
- **Markio2** — the app: documents, windows, menus, preferences, live reload.
- **Markio2QuickLook** — the preview extension: the same two renderer modules
  in Finder's panel.
- **markio2-bench** — headless measurement and offscreen rendering.

The split is what keeps the parser testable and fast: nothing in MarkdownKit
can accidentally reach for a font metric, and nothing in the app can reach past
the layout to the parse tree's internals.

## The one idea

A large document is cheap only if you never touch all of it. Three rules follow
from that, and most of the design is their consequence:

1. **The source is held once, as bytes.** Everything else refers to it by byte
   range. `String` never appears on the scan path — grapheme-aware types
   allocate and normalize, which at 32 MB is the whole budget.
2. **Blocks are parsed; inline content is not.** The block scan runs over the
   whole file. Inline parsing runs per block, when that block is about to be
   drawn, and is thrown away when it leaves.
3. **Nothing is typeset until it is visible.** Heights start as estimates and
   are replaced by measurements as blocks come on screen.

## MarkdownKit

### Representation

- `LineIndex` — the start of every line as `Int32`, plus one byte per line
  recording how much container scaffolding (`> `, list indent) to skip. This is
  the index everything else is phrased in.
- `Block` — 24 bytes: kind, level, flags, parent, first line, line count, an
  info range (the fence's language, a table's alignment) and one auxiliary
  field. A tree by parent index, not by pointer.
- `ByteRange` — two `Int32`. Two of these are the bulk of every block, so
  halving them halves the tree. It caps a document at 2 GiB, far past where a
  viewer stays usable.
- `Document` — the facade: bytes, blocks, line index, the leaves in reading
  order, and the link reference definitions. `content(of:)` is the only place
  bytes are copied into a `String`, and it is called per visible block.

### Block scanning

One pass, line by line, in the two phases CommonMark describes: match the open
containers, then open new ones, then classify what is left as a leaf. A stack of
open frames carries the content indent and the fence state.

Three rules cost more than they look and are worth naming, because each was a
bug first:

- **Four columns of indentation is code — unless a paragraph is open.** The
  indent has to be measured without a cap, then branched on; capping the
  measurement at three columns makes indented code invisible.
- **A list frame always matches in the container phase**, so a block quote or a
  leaf that follows a list has to close the dangling list explicitly before it
  opens.
- **Loose lists**: a pending blank line marks a list loose only where content
  genuinely continues that list. A brand-new list after a blank starts tight.

Link reference definitions are stripped by advancing the owning block's first
line, so the definition never reaches the renderer.

### Inline parsing

Runs on one block's content, producing a **flat array of runs**, not a tree:
kind (text, entity, soft break, hard break, image), a cumulative style mask,
a byte range into the block content, and a link index. Flattening nested
emphasis into cumulative flags is what lets the renderer walk runs in one pass.

The pipeline is tokenize → resolve brackets → resolve emphasis (the CommonMark
delimiter stack, with flanking rules and the rule of three) → flatten.

Every token carries the byte offset it was emitted from. Dropping the syntax of
a link — `[text](url)`, `[text][ref]`, `<autolink>` — is done **by byte range**
over those offsets. Dropping by token kind instead misses the tokenizations that
do not correspond one-to-one with the syntax, and the destination gets printed
twice.

## MarkioRender

### Heights: a Fenwick tree

`HeightIndex` is a binary indexed tree over block heights. It answers three
questions in O(log n): the offset of block *i*, the total height, and which
block contains a given offset (by descending the tree in powers of two). It is
built in O(n) from estimates, and `setHeight` returns how much everything below
just moved — which is what the view needs in order not to move the text under
the reader (UI-2).

Estimates come from byte counts per block kind. They are wrong, but only until
the block is seen, and the error only ever affects the scrollbar.

### Boxes

`BlockLayoutEngine` turns one leaf into a `BlockBox`: segments (an attributed
string and its laid-out `CTLine`s), decorations (a code block's tinted rounded
rect, a quote's bar, a checkbox path, a table's grid) and link regions. Line
breaking is manual — `CTTypesetterSuggestLineBreak` per line — so a paragraph
never becomes one giant `CTFrame`.

Two details that are not obvious:

- **Code blocks are built span by span** so byte offsets never have to be
  converted to UTF-16 positions. Highlighting is skipped above 128 KiB.
- **A single line positioned by its line box sags**, because half the leading
  is added twice; list markers and checkboxes go through a single-line path that
  aligns to the first line's baseline instead.

`DocumentLayout` owns the boxes, keyed by ordinal, with a retain margin around
the visible range. `prepare(range:anchor:)` lays out what is about to be drawn
and evicts what is far away (PERF-4), returning the shift the view must undo.

### Drawing

`DocumentView` is a flipped `NSView`. `viewWillDraw` prepares the visible
range, applies the anchor shift to the clip view, then `draw` walks only the
ordinals that intersect the dirty rect. The reading column is centred by
`contentX`; the view spans the full scroll width so there is something to
centre inside.

`DocumentRenderer` holds the actual drawing, so the on-screen view and the
offscreen PNG take the same path — that is what makes the offscreen render
evidence about the real thing (BUILD-5). The compare bands are drawn there too,
for the same reason; only the controls that belong to the pointer — the language
badge and the Copy pill on a fenced block — live in the view, so an offscreen
render never has a button floating on it.

### Code, terminals and pictures

`CodeText` is the one place that decides what a fenced block looks like: a
`diff` block becomes bands, a block carrying escape bytes goes through
`AnsiText`, anything else is syntax-highlighted. It returns the attributed
string, the plain text Find and Copy see, and the tints — built together, so the
three cannot drift apart.

`AnsiText` parses SGR sequences into coloured spans and removes every other
escape: a cursor-motion sequence describes a terminal that is not there, and
printing it would show as mojibake.

A paragraph that is nothing but an image becomes the image. `ImageLoader`
decodes through Image I/O at the width the block is drawn at, so a 6000-pixel
photo costs what an 1800-pixel one does, and holds a bounded cache that evicts
oldest-first. Only local files beside the document are read — there is no
network path, so a remote address falls back to the alt text.

### Comparing versions

`CompareEngine` diffs the two versions line by line — hashes, not slices, with
the common head and tail trimmed before any table is built — and produces one
Markdown buffer containing both, plus the byte ranges that came from each side.
A blank line goes in wherever the origin changes, or a replaced paragraph's old
and new text would parse as a single block and take a single mark.

The point of merging in the *source* is that nothing downstream has to know:
the parser, the layout, the outline and find all see ordinary Markdown, so find
covers the removed text for free. `DocumentLayout.mark(at:)` is the only new
question, and it is answered by a binary search over the marked ranges.

### Find

`BlockPlainText` reproduces, without a font or a theme, exactly the characters
`AttributedBuilder` puts on screen — soft break as a space, hard break as a
newline, an image as its marker. That is what lets `FindEngine` search a huge
document without typesetting any of it, and why a test asserts the two agree
character for character: a match offset from one highlights a range in the
other.

The search runs on a background queue with a generation token, flushes its first
hit immediately and then in batches, and indexes nothing (PERF-6).

## Markio2

- `MarkdownDocument` is a read-only `NSDocument`. Its parse result sits behind
  a lock because `NSDocument` declares `read(from:)` nonisolated. It does
  **not** opt into concurrent reading: AppKit would then build the document on
  a background operation queue, and every main-actor member of `NSDocument`
  traps under Swift 6 isolation checking. The parse that would move off the
  main thread costs 69 ms for 32 MB — not worth taking the document out of the
  main actor to win.
- `DocumentWindowController` wires the scroll view, the outline, the find bar
  and the width slider. Every edge in that layout is pinned to a neighbour, so
  the content has no height of its own and AppKit would size the window down to
  a bare title bar; explicit floor and preference constraints on the scroll view
  are what give the window a size.
- Live reload watches the file with a `DispatchSource` vnode source and
  re-arms after each event, because an atomic save replaces the vnode.
- The menu bar is built in code before launch completes, so it exists before
  the first window.
- Command-line files are collected in `applicationWillFinishLaunching`, because
  AppKit asks whether to open an untitled document before
  `applicationDidFinishLaunching` runs (UI-3).

## Markio2QuickLook

A hand-assembled `.appex` under the app's `PlugIns`, ad-hoc signed by
`deno task app` because pluginkit will not load an unsigned or unsandboxed
extension. The binary's entry point is `_NSExtensionMain`, set by linker flags;
`main.swift` exists only because SwiftPM wants an entry symbol and is never run.

`preparePreviewOfFile` parses, lays out, installs the view and calls the
completion handler on one turn. There is nothing to await, which is why the
preview cannot hang — and why the extension needs no network entitlement, the
one a sandboxed `WKWebView` must have or its helper never launches.

## The icon

Drawn in code (`markio2-bench icon`) into `packaging/Assets.xcassets`, compiled
to `Assets.car` by `deno task app` and referenced by name. Every size is the
same drawing scaled, expressed in fractions of the canvas, so the 16 px icon
cannot drift from the 1024 px one. The loose `AppIcon.icns` actool emits is
deleted: it caps at 256×256 and anything preferring it gets a blurry icon.

## Verifying it

- `deno task check` is the gate. Its web-engine scan is what keeps PROD-1 true.
- Tests cover the block scanner (structure dumps), the inline parser (run
  dumps), the Fenwick tree against naive prefix sums, and the parity between
  find's plain text and the renderer's.
- `--capture=<path>` draws the real window to a PNG; `--capture-hover=<x>,<y>`
  parks the pointer first, which is the only way to see a control that appears
  on hover. `markio2-bench snapshot` draws a document offscreen at any width,
  scroll offset and appearance, and takes an optional baseline so a comparison
  can be looked at the same way. Both work without screen recording permission,
  which is what makes visual checks possible from a script.
- The Quick Look extension is checked structurally — bundle layout, plist,
  ad-hoc signature, entry point, the `@objc` class name the plist pins — and the
  rendering it does is the renderer's, already covered by its own tests. What
  only a real Finder panel can show is checked by hand.
