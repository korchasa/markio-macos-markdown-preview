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

A footnote (`[^label]: text`) is a leaf of its own instead, because it has text
to draw. The scanner opens one wherever a line starts that way, even in the
middle of a run of definitions, which is how people write them: one per line,
no blank line between. Its label goes in the block's `info` range, and
`Document` collects label → block on the same pass that builds the leaf list.
The label is shown as written rather than renumbered — numbering would need the
whole document counted before any block could be drawn, which is the one thing
this design refuses to do.

A `<details>` section is two blocks — the opening tag with its summary, and the
closing tag — with ordinary Markdown between them. CommonMark would make the
whole thing one raw-HTML block ending at a blank line, which is right for a
renderer that emits HTML and useless for one that draws the document: the reader
would be shown the source of their own text. The pairing is done in the same
pass that builds the leaf list, so the layout can know which blocks a closed
section hides before it has drawn anything.

### Inline parsing

Runs on one block's content, producing a **flat array of runs**, not a tree:
kind (text, entity, soft break, hard break, image), a cumulative style mask,
a byte range into the block content, and a link index. Flattening nested
emphasis into cumulative flags is what lets the renderer walk runs in one pass.

The pipeline is tokenize → resolve brackets → resolve emphasis (the CommonMark
delimiter stack, with flanking rules and the rule of three) → flatten.

A `[^label]` whose label the document defines is resolved before ordinary link
matching and comes out as a link to the note's anchor, styled as a marker. The
set of labels has to be handed in: a block knows only itself, and whether those
brackets are a reference is a fact about the document.

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
  is added twice; list markers, checkboxes and footnote labels go through a
  single-line path that aligns to the first line's baseline instead.
- **A line's height is taken from its runs, not from the line.**
  `CTLineGetTypographicBounds` folds a baseline offset into the line's descent,
  so one superscript would make exactly one line of a paragraph taller and the
  leading around it visibly uneven. Each run reports its height unshifted, and
  the shift is sized to fit inside the base font's own ascent and descent. An
  inline picture carries no offset at all: its run delegate reports the room it
  reserved, so the line still grows to hold it.

`DocumentLayout` owns the boxes, keyed by ordinal, with a retain margin around
the visible range. `prepare(range:anchor:)` lays out what is about to be drawn
and evicts what is far away (PERF-4), returning the shift the view must undo.

A closed `<details>` section is a range of ordinals whose height is zero and
whose boxes are empty. Ranges rather than a set of ordinals: a folded section
may hold a hundred thousand blocks, and the question — "is this one hidden?" —
is asked once per block laid out. Toggling one touches only that section: its
blocks lose their boxes and go back to estimates, or to nothing. The blocks
themselves are never dropped, so find and copy still see the folded text.

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

An image inside a sentence takes one object-replacement character with a
CoreText run delegate reserving its box; the picture is drawn where the laid-out
line put it. `InlineImage` owns the rule that decides which images work this
way, and the rule looks at the destination **alone** — never at whether the file
decodes. `FindEngine` projects the same text on a background queue with no
loader and no window, so a picture that turns out to be unreadable draws an
empty frame rather than changing the text under the reader's search.

### Tables

Both kinds go through one layout. Markdown's syntax cannot merge cells, so the
grid it describes is the special case of one that can — every cell one row and
one column wide — and `HTMLTable` is the shape both are expressed in. Column
widths come from the natural width of each column's widest cell, with a spanning
cell sharing its width between the columns it covers; row heights come from the
tallest cell in each row, and a cell spanning rows only has to fit inside all of
them together. Borders are one stroke per cell rather than a grid of lines,
which is what gives a merged cell exactly the border it should have.

`HTMLTable.parse` reads only the tags that describe a grid — `table`, `tr`,
`td`, `th`, and the `rowspan`, `colspan` and alignment attributes — and returns
nil for everything else, including a nested table or one split by a blank line.
The caller then shows the source, which is never wrong, only unhelpful. This is
not a step towards an HTML engine: it exists because an author who needs a
merged cell has no other way to write one.

### Formulas

`MathParser` reads the source between the dollars into a small tree — rows,
atoms, scripts, fractions, roots, accents, faces and the grid environments
(`pmatrix` and its family, `cases`, `aligned`) — and returns nil the moment it
meets anything it does not know. That nil is the whole safety story: there is no
partial formula, no guessed macro, and a document full of LaTeX this cannot set
looks exactly as it did before the typesetter existed.

`\mathbb`, `\mathcal` and `\mathfrak` are handled by substituting characters
rather than by asking for a face, because a font has one ℝ and no way to make
another; `\mathbf`, `\mathit`, `\mathsf` and `\mathtt` are real faces and travel
down the layout as a variant on the context.

`MathLayout` turns the tree into a `MathBox`: glyph runs and rules positioned
around the formula's own baseline, in the renderer's y-down space. Every
distance is a fraction of the base font's size, so a formula in a heading scales
with the heading. The faces are the system serif, italic for variables, and the
spacing comes from TeX's atom classes — which is why `a + b` breathes and `f(x)`
does not, without the author typing a single space. Two details cost a
correction each: the radical is measured from the glyph's *ink* rather than from
the font's ascent, or the bar floats above the arm it is supposed to continue;
and a leading `-` is a sign rather than a subtraction, or `-b` comes out spaced
like an equation. Accents and the limits over a sum are placed against the ink
for the same reason, and by the same helpers.

`$$…$$` carries one extra bit from the parser, `InlineStyle.displayMath`, and it
decides one thing: whether a sum writes its range above and below its sign or
beside it. Display style stops at the first script, the way it does in TeX, and
an integral keeps its limits beside it either way, because they are read along
its slope.

Getting the box onto the line reuses the inline-picture machinery exactly: one
placeholder character carrying a run delegate with the formula's width, ascent
and descent, plus the box itself as an attribute. `BlockLayoutEngine` reads back
where the line breaker put the placeholder and emits the glyphs as decorations,
drawn after the highlights so a selection tints a formula instead of covering
it. `BlockPlainText` asks `MathFormula.canTypeset` — parsing only, no fonts, so
it is safe on the find queue — and emits the same placeholder for the same
sources. That is what keeps a match offset landing on the same character in
both.

### Diagrams

`MermaidDiagram.parse` reads a fence into a flowchart or a sequence diagram and
returns nil for everything else, including the constructs inside those two that
the layout cannot draw — a subgraph inside a subgraph, a tinted band, a click
handler, a colour it does not know. The rule is the same one the formula
typesetter follows: a diagram is drawn whole or shown as source, because half a
graph asserts something its author did not write.

`MermaidLayout` places it. A flowchart is ranked by longest path — the edges
relaxed `|V|` times, which gives a topological answer and cannot spin on a cycle
— then each rank is measured, centred against the widest, and laid along the
rank axis. All four directions are the same routine: `TD` and `LR` swap the
axes, `BT` and `RL` turn the rank axis over once every box is placed. Edges are
drawn between box centres and clipped to the boxes, so an edge across a rank or
back up the graph needs no special case; their words are written last, over the
nodes, because an edge that skips a rank passes over whatever stands between.

A subgraph is given a strip of the cross axis to itself — the same strip on
every rank — and that is what makes its frame enclose its own members and
nothing else: no node outside the group is ever placed in the strip. The strips
are ordered by the rank their contents first appear on, so the graph still reads
from its first node onwards.

A class diagram and an entity–relationship diagram are one layout: titled boxes
with rows in them, ranked the same way a flowchart is, joined by lines whose
ends carry the meaning — a hollow triangle for inheritance, a diamond for
composition, a crow's foot for how many. They differ only in how they are read
and in which ends their lines may have, which is why `BoxDiagram` is shared and
`ClassDiagram`/`EntityDiagram` are two readers of it.

A pie chart is wedges from twelve o'clock with a legend beside them, and its
colours are written down rather than taken from the theme: a pie says which
slice is which by colour, so the colours have to stay apart from each other on
either background. A state machine has no layout of its own at all — it is read
into a `Flowchart` whose start and end are a filled dot and a ring, because that
is the only thing about it a flowchart cannot already draw.

A sequence diagram is columns with dashed lifelines, walked in document order.
The walk hands back three lists — block frames, activation bars and the
messages and notes themselves — because they are painted in that order: a frame
is behind its contents, and a bar is behind the arrows that start and end it. A
block's frame cannot be drawn until its contents have been placed, which is why
the whole body is laid out before anything below the participant boxes appears.

Everything it produces is `BlockBox.Decoration` — filled and stroked paths, and
the glyph runs added for formulas — so the diagram draws in the window and in
the offscreen PNG by the same path as the text, and nothing about a diagram
reaches `DocumentRenderer`. `Decoration` has no dash pattern, so a dashed line
is a path of short segments rather than a sixth case every renderer would have
to honour. The block types nothing: the fence's own text stays the block's
plain text, which keeps the diagram findable and copyable as the source its
author wrote.

### Comparing versions

`CompareEngine` diffs the two versions line by line — hashes, not slices, with
the common head and tail trimmed before any table is built — and produces one
Markdown buffer containing both, plus the byte ranges that came from each side.
A blank line goes in wherever the origin changes, or a replaced paragraph's old
and new text would parse as a single block and take a single mark.

Side by side takes the same edit script and builds two documents instead of one
— the baseline with what it lost, the current file with what it gained — so the
window can put a layout in each of two scroll views. The unchanged lines are in
both, which is what makes the columns run level until a change pushes them
apart. The offsets are copied rather than scaled for the same reason. Only the
right-hand pane is the document: find, the outline and every command still work
on it alone, so the second column adds a view and no state.

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
  on hover, and `--capture-click=<x>,<y>` clicks once, which is how folding a
  section away is checked. `markio2-bench snapshot` draws a document offscreen at any width,
  scroll offset and appearance, and takes an optional baseline so a comparison
  can be looked at the same way. Both work without screen recording permission,
  which is what makes visual checks possible from a script.
- The Quick Look extension is checked structurally — bundle layout, plist,
  ad-hoc signature, entry point, the `@objc` class name the plist pins — and the
  rendering it does is the renderer's, already covered by its own tests. What
  only a real Finder panel can show is checked by hand.
