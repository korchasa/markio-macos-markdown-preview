# Markio — Design

How the viewer meets `requirements.md`.

## The shape of it

Five targets, in dependency order:

- **MarkdownKit** — the parser. Pure Swift, no AppKit, no fonts, no theme.
- **MarkioRender** — CoreText typesetting, the virtualized layout, the reading
  view. Depends on MarkdownKit and AppKit.
- **Markio** — the app: documents, windows, menus, preferences, live reload.
- **MarkioQuickLook** — the preview extension: the same two renderer modules
  in Finder's panel.
- **markio-bench** — headless measurement and offscreen rendering.

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

`ExtendedAutolink` is GFM's bare links: `https://…`, `www.…` and an address, all
written without markup. Finding them is easy and stopping them is not, so three
rules carry the file. A link ends before the punctuation that ends the sentence
(`see www.example.com.`), before a bracket that closes an aside rather than a
path (`(see https://example.com/a)`, against `…/a_(b)`), and before an entity
someone appended. An address is the one thing scanned backwards — its local part
has already been read as text when the `@` arrives — and the scan may not reach
back past the text run being built.

Two places refuse a bare link outright: inside `[…]`, because a link inside a
link is neither, and immediately after `](`, because that is a destination. Both
are cheap tests done before any scanning, and that is deliberate — the whole
feature is a comparison on every `h`, `w` and `@` in the document, so what it
costs is decided by how early the common case gets out. Measured on the 32 MB
generated document: whole-document inline parsing went from 143 ms to 152 ms,
about 6%, while the viewport parse a reader actually waits for stayed at
0.2 ms. Getting there took three passes — the first version allocated a needle
per candidate, the second scanned every link destination twice, and both were a
third of the parser's throughput.

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

### Rearranging a table

Sorting and filtering happen on the way into the layout, in `layoutGrid`:
`TableArrangement` is applied to the `HTMLTable` before a single cell is
measured, so the document keeps the order its author wrote and only the picture
of it changes. The arrangement is held per leaf on `BlockLayoutEngine` and
reached through `DocumentLayout`, beside the other state that belongs to a
window rather than to a file. Changing one drops that block's box and its
height, exactly as opening a `<details>` section does.

Sorting is stable and numeric-aware — a column of `40 min`, `$12` and `1,024`
sorts as numbers, or 10 comes before 9 — and a table with a merged cell reports
`canRearrange == false` and is left alone: moving one of its rows would move
text that belongs to a neighbour.

The filter row is drawn between the header and the body by shifting every row
below it down by its own height, so the cells measured above it need no
re-measuring. Its text is a decoration, not content: the segment carries
`textOffset: -1`, which is what keeps find and copy from seeing a word the
document never said. `BlockBox.TableRegion` records the table's frame, its
header cells and its filter row in block coordinates, which is all the view
needs to hit-test a click and to draw the header again over a table that has
scrolled half off the top — `DocumentView.stickyHeaderStrip` decides where that
goes, and draws it by drawing the whole table clipped to one strip.

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

`MermaidDiagram.parse` reads a fence into one of the diagrams below and returns
nil only where Mermaid itself refuses: a kind it does not know, a block left
open or closed twice, a keyword half written, a relation whose ends make no
sense, a flow that returns to where it came from. What this viewer draws is what
Mermaid draws, and that is the whole of the rule.

It was not always. This used to refuse any source it could not honour in full —
the reasoning being that half a graph asserts something its author did not
write. Measuring settled it: every source the tests refused was run through
Mermaid's own renderer, and 70 of the 127 came back as real pictures. Mermaid
does not refuse a line it cannot use; it drops that line and draws the rest, and
a viewer that stops instead is not showing the reader the same document.

So the refusals went, in two kinds. The first were refusals the old rule never
supported anyway: a name of a known kind with nothing under it draws an empty
picture, since a picture with nothing in it can leave nothing out — a
`MermaidDiagram.empty` carries the kind and the layout draws a blank the size of
one line. A lone state, a journey step nobody was named for, a band with no
colour, a box with no name or nobody in it, a radar of two axes or none of its
rings or no curve at all, a treemap branch that also carries a number, a series
running past the names on its axis, a block arrow naming a box no row wrote out,
and an architecture stranger standing where a group's frame would enclose it are
all drawn now — the last by walking the stranger clear rather than by giving up.

The second kind is the line Mermaid drops. A colour nobody can resolve, a share
out of range, a property nobody knows, a class nobody defined, a `:::` naming
one, a `linkStyle` past the last link, a `click` on a node nobody wrote, a
`cssClass` or a C4 `Update…` naming nobody, an unknown `<<mark>>` on a state, a
kanban key this cannot draw, a task told to follow one nobody wrote, a preamble
`theme` or `displayMode` whose value is a word nobody knows: each is passed over
and the diagram is drawn without it. Only the failing half of a line goes —
`fill:chartruse,stroke:red` still gives its stroke. Where two things collide, the
one Mermaid keeps is kept: a class named in a second namespace stays in the
first, a diagram named in both its preamble and its body wears the name it wrote
for itself, a `title` written twice keeps the last, and a box's members are
gathered together so its frame holds nobody else.

A few sources this draws are ones Mermaid answers with its own error graphic: a
bare `classDiagram`, `sankey-beta`, `C4Context` or `block-beta`, a `linkStyle`
numbered past the end, a preamble naming itself twice. Drawing an empty picture
where Mermaid draws a picture of a crash is the one direction the difference is
allowed to run.

A label written between backticks is markdown, and it is the one place where a
`**` means anything other than two stars on the page. Its newline is a break in
the words rather than the end of the statement, so a line with a backtick string
still open swallows the next one before anything is read — the joining happens
where the source is cut into lines, once, rather than in each diagram's own
reader. The emphasis is applied where a line of words is made, so it holds
wherever such words stand: a node's name, an edge's, a frame's. The system face
at a set weight will not be turned bold by a symbolic trait — it answers with the
same face — so the copy is kept only when it really changed, and the bold face is
asked for by weight otherwise.

Mermaid's YAML preamble is read before the diagram is, for the keys that say
what to draw. A quoted value in it may run over several lines, as a stylesheet
written into one does; those lines are swallowed up to the closing quote rather
than read as YAML of their own. The title travels as `MermaidDiagram.titled`, a case wrapping any
other, so the layout draws the diagram exactly as it would have without a name
and then moves it down to make room — one place for a title rather than one per
kind; a `title` with nothing after it is no title at all. `config.kanban`'s
`ticketBaseUrl` and `sectionWidth`, and `displayMode: compact`, reach the reader
that wants them, and a key written over a diagram of another kind is left unused
rather than read as a mistake — which is what Mermaid does with it. A diagram is laid out **once**, at its own size, and fitted afterwards. Width is
what decides where a message label wraps, so a picture laid out to a 700-point
column and the same picture laid out for a window are two different drawings —
different column spacing, different line breaks — and the reader saw one of them
in the page and the other one enlarged. `MermaidLayout.draw` is therefore asked
for `DocumentRenderer.naturalWidth` by every caller; `cropped` cuts the empty
card either side of the picture, `centred` places it in a column that holds it,
and `DocumentRenderer.squeezed` scales the whole drawing down when the column
does not. Cutting and scaling are not layouts, so the page, the enlarged window,
Copy PNG and the written-out file all show one picture at four sizes.

A diagram is drawn on a white page whatever the page around it is, in ink
chosen against white — `Theme.forDiagrams`. A picture is mostly lines, and lines
are the first thing a dark palette takes away: an outline and the card behind it
differed by a shade nobody could see. Mermaid's own themes assume a white page,
and so do the colours authors set by hand, the pastel `box rgb(...)` of a
sequence diagram among them. The card behind the picture is painted the page the
drawing reports, and outlined in the reader's own border colour so that on a
light document the white card still has an edge. `DiagramContrastTests` states
the ratios: lettering past 7:1, outlines and connecting lines past 3:1.

`config.theme` travels the same way as the title, as a
`MermaidDiagram.themed` wrapping any other, and the layout draws the diagram
underneath against a repainted `Theme`: Mermaid's five colour sets are a handful
of values each — what a box is filled and outlined with, what its words are,
what a line is, what shows behind them — and the wheel a diagram tells its
series apart with moved out of the layout into the theme so a repaint carries it
too. Only the diagram changes; the page around it stays the reader's, because
the theme was written over a fence rather than over the document.
`%%{init: {'theme':'forest'}}%%` says the same thing on a line that looks like a
comment, so directive lines are taken out of the body and read before the
diagram is — passing one over as a comment would draw the picture in colours its
author did not choose, which is the half-truth everything else here avoids. A
directive carries whatever a preamble carries, nested as deeply, so it is read
into the same key paths rather than into a shape of its own: Mermaid's own
documentation writes `showCommitLabel` this way and no other. A setting that
would change the picture and that this cannot follow still refuses the whole
diagram; the words that say nothing about the picture at all — how loudly
Mermaid logs, when it starts — are named one by one and passed over.

`MermaidLayout` places it. A flowchart is ranked by longest path — the edges
relaxed `|V|` times, which gives a topological answer and cannot spin on a cycle
— then each rank is measured, centred against the widest, and laid along the
rank axis. Relaxing over a cycle terminates but settles on a wrong answer: every
node in the loop is pushed to the same late rank, and a state machine that
returns to its start collapses into one row. So a depth-first walk marks the
edges that close a cycle first, and the ranking is run on the graph without
them; the edges themselves are still drawn. All four directions are the same
routine: `TD` and `LR` swap the axes, `BT` and `RL` turn the rank axis over once
every box is placed.

#### Joining two boxes

Wherever a line joins two rectangles, it is drawn by `connection`, and the rules
below are the whole of what it does. They hold for a flowchart and for
everything read into one — a state machine, a C4 model, a block diagram — and
equally for a class diagram, an entity diagram and a requirement diagram, which
have their own layout but the same lines. Mermaid works the same way: one
`insertEdge` serves every one of these, and the diagram decides only the marks
on the ends. They do not hold where the kind of diagram fixes the geometry
itself: a sequence message runs between two lifelines, an architecture edge
leaves by the side its author wrote (`db:R -- L:server`), a git graph runs on
the rails of its branches. Mermaid keeps those apart too, in renderers of their
own.

*Where a line leaves.* By the side facing the box at the other end, which the
direction of the layout settles: down the page, a line leaves the bottom and
arrives at the top. The point on that side is where the line crosses it. A line
joining the two boxes directly is held three tenths of a side in from either end
— left to itself the point slides into a corner, and a line leaving at a corner
reads as a line that missed the box. A line with a lane is held off the corner
itself and no further: the lane already stands beside the box, so the nearest
point on the side is the one the reader would draw, and holding it in only makes
the line swing back out to reach the lane. Where two boxes overlap by so little
that no held-in point exists, they are treated as standing corner to corner. A
line from a box to itself has no facing side at all: it leaves the right-hand
side and comes back to it lower down.

Several lines meeting one side share it. Left alone each would be drawn to the
middle of it, so three classes inheriting from one would put three heads in the
same place and read as a single smudge. They are given their own places along
the side instead, in the order their other ends stand — which is also what keeps
them from crossing on the way in — and a crowd is allowed nearer the corners
than one line is, since a line among several is plainly one of several and the
room matters more than the hold. They are spread no further than tells two heads
apart: a pair pushed to the ends of a wide side leans both lines for no reason a
reader could name. A line with a lane keeps out of this, because where it meets
the box was settled by the lane it runs in.

*How it runs.* Straight, where the two sides face each other and nothing stands
between — down the middle of what the two boxes share, rather than from centre
to centre, because aiming at the centres leans the line whenever the boxes are
not the same width, and one leaning line in a column of upright ones reads as a
mistake. Corner to corner, it runs straight out of the side it leaves by, turns
once half way, and comes in straight at the far end. Past a box that stands
between, it runs out of its side, sweeps into a lane beside that box, runs
straight down the lane, and sweeps out of it to come in square at the far end.
A sweep is a cubic with both handles half way along it, so the bend is even from
end to end, and it is spread over the gap between two ranks at the least however
little the line has to move sideways — a bend as short as that movement turns
hard and then runs straight, which reads as a kink rather than a curve — and
over no more than a share of the run, or it eats the lane it is joining. Which
lane that is, on which side, is settled for the picture as a whole rather than by
each line for itself, and by two rules. A line takes the side where fewer of the
lines already there are ones it would have to cross; only lines whose runs
interleave count, because two nested runs never cross — the longer stands outside
the shorter the way brackets do — and where the two sides come out equal the
nearer wins. Then, on one side, a line that runs past another stands further out
than the one it passes, so runs that share a stretch nest and runs that share
nothing sit in the same lane and cost no room at all. The shortest run is settled
first: a lane goes outside whatever it already runs alongside, so settling the
longest first would leave it innermost with everything it passes crossing over
it. The lane itself is then walked outward past one box at a time until nothing
is left standing in it — clearing only the box that first blocked the straight
line leaves the lane inside whatever stands beyond. The lanes are handed out for the
picture as a whole rather than by each line for itself, so two lines passing the
same box take lanes of their own instead of one. Two boxes joined both ways are
joined by two lines bowed to opposite sides, and which side is which is read in
a fixed direction — the across-direction turns over with the line, so a lane
read in the line's own would put both on the same side. Every curve is flattened
into a run of points, which is what lets a dashed edge keep an even rhythm round
a bend and an arrowhead sit square on the line's real direction.

*Where it arrives.* By the same two rules the exit follows. A frame is its
border and nothing more: its name is written above it and to the left, so
counting the whole strip as the frame's own would stop every line a whole line's
height short with nothing under its head. The name stands in the way as a box
does instead, and only a line that would really cross a name goes round one —
except for the line that ends on the frame the name belongs to, which is on its
way to the border under it. Sending that line out to one side and back is what
crossed the two arrows leaving a state machine's start over each other. The
line stops at the border and never crosses it; the mark on the end is drawn in the room the
line gives up for it and faces along the last stretch of line. A box that is not
a rectangle — a diamond, a circle, a cylinder — has a rectangle standing well
clear of it, so a line stopped at the rectangle would end in mid-air beside the
shape: where a node has an outline of its own, the crossing is found by halving
the run between the centre and the rectangle a dozen times, which needs nothing
from the shape but the path it is already drawn with. Words go beside the line,
clear of both boxes and of each other: in the middle of a short line, in the
first free gap of one that skips a rank, and past the furthest point of a loop.
They are written last, over the nodes, because a line that skips a rank passes
over whatever stands between, and the line is broken around each word so the two
never overlap. The gap between ranks is sized from those words plus an arrowhead
plus a visible run of line on either side — a gap sized to the words alone
leaves a labelled edge looking like a chip with a stub beside it.

The three-tenths hold is a stand-in rather than a rule. Mermaid holds nothing
back from its corners: the exit is simply where the first stretch of the routed
line crosses the border, and it comes out well placed because the router has
already put that stretch somewhere sensible. This has a router only for the lane
case — where, accordingly, the hold is already down to almost nothing — and
everywhere else it joins the two boxes directly, where without the hold the point
slides into a corner. When there is a routed line under every edge, the hold has
nothing left to do and should go rather than sit beside the rule it stands in
for.

A subgraph is laid out as a picture of its own and then placed as if it were a
single box. `placed(chart:…)` calls itself once per frame: the boxes and frames
written directly inside a container are its units, a frame unit is measured by
what it came back holding plus its inset and the strip its name is written in,
and the units are ranked and placed by the same routine the whole chart uses.
That is what makes a frame enclose its own members and nothing else — nothing
outside it was ever laid out in its rectangle — and it is why a frame inside a
frame needs no separate case. A node belongs to the frame it is *written*
inside, which is not always the frame that named it first: a node mentioned by
an edge in one subgraph and then declared inside another belongs to the second,
because that is where its author drew it. A `direction` line inside a frame
turns that frame's own contents and nothing else, so each recursion reads its
container's direction and falls back to the header's.

Ranking works on units rather than boxes, so an edge between two boxes deep in
different frames ranks the frames that hold them, and an edge that names a frame
— `outside --> one` — ranks the frame itself. A frame is an endpoint in its own
right for that reason: `Flowchart.End` is either a box or a frame, an edge that
names one starts or stops on its border, and the boxes it holds are left out of
the obstacles the line is bowed around, because the line stops before it reaches
them. A word that names a frame makes no box: a stand-in node parsed before the
frame was known is folded into the frame it names once the whole source has been
read.

A gantt chart is read twice. A task may point at one written below it —
`until isadded` — and one pass cannot know where that one stands, so the first
reading exists only to find out where every named task begins and ends and is
allowed to be wrong about lengths, and the second reading, given those places,
is the one whose answer is kept. Everything is counted in days, and a day is a
fraction rather than a whole number, so a chart told in hours and minutes —
`dateFormat HH:mm`, `Task A : 10m` — falls out of the same arithmetic; such a
chart names no year at all, so its dates stand on the first day of the epoch and
the axis opens at the first task rather than at the midnight before it. A `vert`
is not a milestone with a different name: it is a heavy rule across the whole
chart, named under the axis, and it takes no row among the bars. An x–y chart names three things and draws two
of them: the axis's own name stands under its categories and a named point
carries its words just above it, while a named series is read and left alone,
because Mermaid draws no legend to put the name in.

A link is read in three parts — the mark it opens with, the line itself, and
the mark it closes with — because every combination of the three is a link
Mermaid draws and there are far too many to spell out one by one. That is what
makes `<-->`, `o--o`, `x--x` and the mixtures fall out of the same reader as
`-->`, and it leaves one ambiguity worth naming: `--` and `==` on their own are
not links but the opening of one with its words inside, so a line that stops
there with nothing lengthening it and no mark at its end is read again as
`-- text -->`. Each end of a link is a list rather than one node, since `&`
joins several into one end, and the edges are the whole cross of the two lists.

A node's shape can be written as brackets around its words or asked for by name
— `A@{ shape: cyl, label: "Store" }`. The two roads meet at `Flowchart.Shape`,
so the metadata block adds no drawing of its own: it is read into the same case
the brackets would have produced, and everything downstream — sizing, the
outline, the marks inside it — is shared. Mermaid answers to three names for
each of its 48 shapes (a semantic one, a short one, and the aliases), so the
reader carries the whole table of 144 names and refuses a name that is in none
of them, because that is where Mermaid stops too. A key the block carries that
says nothing about the picture is passed over; `icon`, `img` and `image` say
the node is a picture whatever else is written beside them.

Not every shape is a box with words in it. A collate mark, a com link and a
junction are read as the symbol alone, so a name written on one belongs to the
diagram and is not drawn inside it. A triangle is only wide enough for words at
its base, so its label is moved there rather than to the middle. A sheet of
paper waves along its foot, so a mark that would otherwise meet the bottom edge
— the line down a lined document, the tag folded into its corner — stops where
the wave starts. The marks inside a box are drawn over it rather than cut out of
it, which keeps the fill and the outline one path and one colour each; the
copies behind a stacked process are the exception, since they stand under the
front one and are drawn before it.

A class diagram and an entity–relationship diagram are one layout: titled boxes
with rows in them, ranked the same way a flowchart is, joined by lines whose
ends carry the meaning — a hollow triangle for inheritance, an open V for a
line that only points, a diamond for composition, a crow's foot for how many.
The two arrowheads are not the same mark: a triangle is closed and filled or
hollow and says one class is another, while `<--` and `<..` merely point and are
drawn as two strokes meeting, the way an arrow on a flowchart is. They differ
only in how they are read
and in which ends their lines may have, which is why `BoxDiagram` is shared and
`ClassDiagram`/`EntityDiagram` are two readers of it. How far apart two ranks
stand is measured from what the relations between them actually draw — both end
marks, the words on the line, and a run of shaft left over. A crow's foot alone
eats most of an ordinary gap, and an entity diagram whose relations have one at
each end came out as two symbols floating with no line between them. Room for
the marks is left at the box as well: a crow's foot stands a little off the
entity rather than on its border, where it would read as part of the frame.
An entity's attribute is
written type first and name second, the order it is declared in: `string email`
and not `email string`, which would say the attribute is called `string`.

A class body opened and closed on one line is one row, whatever it holds:
`class Document { +String text +render() }` draws a single member and not two.
That is Mermaid's own arithmetic rather than a simplification of it — its lexer
reads everything between the braces up to a newline as one token — and it is
why the line is read at all instead of falling back to the source.

An entity is known by an id and shows whatever words are hung off it — `CAR`,
`"This ❤ Unicode"`, `p[Person]`, `a["Customer Account"]` — so the reader keeps
its own id table rather than looking boxes up by what they show; two ids that
show the same words are still two entities. How many stand at each end of a line
can be written as the marks or as the words that mean the same thing, and each
count has a spelling facing either way, so one table serves both ends and the
side a mark stands on is what decides how it is drawn. What is left after the
keywords is a list of entities however long it is, which is why `subgraph one`
draws two boxes and `end` a third: an entity diagram has no frames, and Mermaid
reads those words as names like any other.

A class diagram's `note` is a slip of paper laid beside the picture rather than
in it. One tied to a box stands to that box's left, joined to it by a dotted
line, and is slid further left until it covers nothing — a note laid over a box
says less than no note at all. One standing on its own has no box to belong to,
so it goes in a row above everything. Either may end up outside the rectangle
the boxes were laid out in, which needs no arithmetic here: the drawing is
measured by what was drawn, so the picture grows to hold them.

A mindmap is a tree, and depth alone decides the column, so every node the same
number of steps from the root lines up. A parent is then centred on the children
it opens, which is what makes a branch read as one thing however deep it goes. A
root taller than everything it opens would land above the top of the picture, so
the whole tree is dropped back into view once it is placed. Each top-level
branch keeps one colour to its last leaf, and a connector near the root is drawn
thicker than one near a twig. `::icon(fa fa-book)` belongs to the node above it
and adds nothing to the picture: it asks for a glyph out of a font that has to
be fetched, and Mermaid itself draws nothing for it on a page that has not
already loaded that font, which is every page here. A cloud and a bang are a
ring of arcs and a ring of spikes around the ellipse the words sit in, so the
two shapes only a mindmap has need no new machinery to place.

A timeline is columns. A section is a band over the run of periods it owns, so
its span says which columns belong to it without a line joining them; under the
band each period is a tinted head with a dot on the axis, and what happened in
it is a stack of cards below. The colour comes from the section where there is
one and from the column where there is not. `timeline TD` turns the whole thing
a quarter turn: the rule runs down the page, each period is a row with its name
on the left and its cards on the right, and a section is a band across the rows
it owns. It is a second drawing rather than a transposed one, because the words
do not turn with the picture — a name reads left to right either way.

A quadrant chart is a square cut in four, with each quarter's name along its own
top edge rather than through the middle of it, which is where the points are.
All four quarters carry the same faint tint. Giving each one a colour of its own
was the obvious thing to do and the wrong one: on a chart cut this way a red
quarter and a green quarter are a verdict, and the author wrote four names, not
four verdicts. A colour the author *did* write is drawn: a point may say how big
it is and in what colours, on its own line or through a `classDef` it wears with
`:::`, and what the point says wins over what its class says. A
point's name goes to the right of its dot, and if that name would leave the
square or land on something already drawn it is tried on the left and then a
line up or down, in that order — every dot is placed before any name, so a name
is never allowed to cover a point it does not belong to. An xy chart is bars and lines over named categories, and
several bar series share a category by each taking a slice of it. Its y axis is
named above itself rather than turned on its side: rotated glyphs are the one
thing this drawing has no way to place.

A git graph is one lane per branch, a column per commit, and a curve wherever a
branch left its parent or merged back — so a lane is never a line floating on
its own. `gitGraph TB:` turns the lanes down the page rather than across it:
the same graph, with the two axes swapped and the branch names moved above their
lanes. A `cherry-pick` is drawn as a dotted line back to the commit it copied,
because a copy is the same work said twice rather than one line running on, and
it says so in a tag: `cherry-pick:MERGE|parent:B` — the commit it was picked
from, and, when that commit was a merge and so had two sides to pick from, the
parent it came through. Without that tag the copy is a dot on a lane with a
dotted line running off it and nothing saying what it is. A tag the author wrote
stands instead of it.
A commit nobody named is written by its place in the graph — the first is `0`,
the next `1` — because that is the half of Mermaid's own name for it that means
anything. The other half is, in the words of Mermaid's own documentation, "a
unique & random ID": seven hex characters drawn afresh every time the picture is
drawn, so they are not a hash of anything and no reader can look them up. Writing
a string of that shape here would put an identifier in front of the reader that
refers to nothing, and working one out from the source instead would only make
the invention repeatable. `showCommitLabel: false` takes the names away
altogether, which is what an author who does not want them writes; a tag is not
a name and stays. Two commits are never named: a copy, which goes by its tag,
and a merge its author did not name, which is read from the two lines meeting at
it and says nothing more for a number under it. Those are Mermaid's own three
rules, written in the one condition it draws a commit label under. The names set
how far apart the commits stand across the page: a name is far wider than the dot
it belongs to, and Mermaid turns its names on their side to fit them where this
one gives them the room. A tag is not allowed the same say — it may run to a
sentence, and holding the commits that far apart would stretch the whole graph
for one word — so a tag overlaps whatever stands beside it and the picture grows
only by what hangs off either end. What a commit
is decides how its
dot is drawn: a merge is hollow because it is the one commit belonging to two
lines at once, a `REVERSE` is crossed out, a `HIGHLIGHT` is ringed. A `type:`
nobody here draws is refused rather than read as an ordinary commit — that is
the same rule as everywhere else, applied to a word that would otherwise vanish
without a trace in the picture.

A journey is read downwards rather than as a curve. A section is a band over the
run of steps it owns, and each step is a card under that band in the same
colour, so a section looks like a group of its own instead of a stripe with
loose boxes below it; the bands are held apart and outlined for the same reason.
Under the cards runs the axis, and from each step a dotted line drops to a face
drawn at the height of its score — a smile, a straight mouth or a frown. The
score is what the author wrote the step for, so it is drawn as a face rather
than as a height alone: a dot on a line says a number, and a number here is a
feeling. Who was there is written on the step's own card, under its name.

A Gantt chart counts days from its first task and nothing here knows about
calendars beyond turning a written date into a day number and back, which is why
`after`/`until` references, durations in days, weeks and hours, and bars all
work in the same units. `dateFormat` is read token by token — `YYYY`, `MM`, `DD`
and whatever stands between them — so a chart written any way Mermaid allows
lands on the right days. `excludes` and `includes` turn a length into a count of
working days: the bar then reaches further along the calendar than its `3d` says,
and the days off are shaded behind it so the difference is visible rather than
mysterious. A milestone and a `vert` rule are drawn at a moment rather than over
a stretch — a diamond and a heavy line — but the length each was written with is
still its own: the task under one begins where it ends and the chart reaches as
far as it does, so only the drawing ignores it. The axis carries whole dates,
year included: a chart that runs over a new year would otherwise label two
different days the same way. How wide a date is decides both how wide the plot
has to be and how many ticks can be labelled, so the number of ticks follows
from the room rather than being fixed at five. That room is only the starting
point for the step itself, which is the next round amount of time above it —
worked out from the span alone it lands on figures nobody counts in, seven
minutes or nineteen hours. A chart told in hours then puts its ticks at round
moments of the clock, so one opening at 17:32 is still read against 17:35 and
17:40; a chart told in days already starts on a whole day, and counting its ticks
from any other one would only move the first of them off the edge of the plot.

A packet diagram is a row per word of bits. A gap between two fields is a run of
bits the author left unspoken, and it is drawn as the empty stretch it is; two
fields over one bit is a packet nobody could read, and that is refused. A field
that spans a word boundary is
drawn as one box per row. A bit is wide enough that the longest field name fits
inside its own box, so a header whose fields are named at all is drawn wider
than the bits alone would need. The bit numbers over the boxes are placed after
the boxes are: the number that ends a row is written first, then each remaining
one only where it does not touch a number already there — a 32-bit word cannot
show all thirty-two of its numbers at a readable size, and a row of numbers
printed over each other measures nothing.

A kanban board is a column per list and a card per item, and the indentation is
what separates the two — the first line's indent is the column level, and
anything deeper is a card. A line shallower than the first would leave it unclear
what is a column and what is a card, so it is refused. A card's priority tints
its left edge. A card's words wrap at a readable measure and break only between
words, so one long title makes a tall card rather than a board six times too
wide to look at; every column takes the same width, because a board whose
columns differ in width reads as a board with a column that matters more. A
card's ticket id is
kept apart from the rest of its metadata, because a preamble may say where
tickets live — `config.kanban.ticketBaseUrl` — and then the id is a link, drawn
in the colour a link is written in and underlined, the way Mermaid shows it. The
rest of the metadata is set against the card's far edge. The picture shows a
link but does not follow one: nothing in a drawn diagram is clickable here.

A requirement diagram is read into the same `BoxDiagram` a class diagram uses: a
requirement is a titled box with its id, its text and its verification method in
the rows, and `satisfies`/`verifies` and the rest are the lines between them. The
rows are written the way a reader would say them rather than the way the source
spells them — `verifymethod: Test` becomes `Verification: Test` — because the
keyword is the source's grammar and the box is what a person reads. That applies
to the words the syntax chooses from and not to the author's own: a risk and a
verification method come out of a fixed list and are capitalised, while an
element's `type` is whatever its author called the thing, and it stays as
written. What kind of box it is stands over its name in the source's own
brackets, `<<Requirement>>` and `<<Element>>`, rather than in quotation marks:
those brackets are how the diagram is written and how everyone who reads one
expects to see it. A relation only points, so it ends in an open V and not in a
filled head.

A Sankey diagram ranks its nodes the way a flowchart does and then gives each one
a bar as tall as the larger of what reaches it and what leaves it. The ribbons
are drawn before the bars, each leaving and arriving in the order the flows were
written, so a bar is never hidden under what leaves it. A flow that returns to
where it came from would make the ranks meaningless, so a cycle is refused —
as it is by Mermaid itself, which cannot lay one out either. Each
bar is labelled with its name and its total, because a diagram whose whole
subject is how much goes where should not make its reader estimate the amounts
from the height of a ribbon.

A treemap is squarified: a row takes one more rectangle only while doing so
leaves every rectangle in it closer to square than stopping would. A branch's
value is the sum of what it holds, summed upwards over the flat array, which
already has every child after its parent. Every rectangle is labelled with its
name and its value, branches included; a named root is given a head row across
the top so its own total is visible above the parts it splits into. Several
roots are given a parent that is never itself drawn, and that parent, having no
name, gets no head row. A `classDef` paints the rectangle that asked for it and
everything that rectangle holds, handed down in one forward pass over the same
flat array, because a section's colour is what tells a reader the parts under it
belong together.

A C4 diagram has no layout of its own — it is read into a `Flowchart` whose
shapes come from what each element is, and an element followed by a brace is a
frame rather than a box: a deployment node holds what runs on it, and the brace
at the end of the line is the only thing that says which of the two it is.
Otherwise: a person is a stadium, a `*Db` a cylinder,
a `*Queue` a subroutine, and anything `_Ext` is filled paler because it is
outside the system under discussion. The kind, the name and the description are
three lines of one label, which is what multi-line labels were added for and what
`<br/>` in an ordinary flowchart now gets as well. A C4 diagram names itself on a
`title` line rather than in a preamble, so `C4Diagram.parse` hands that name back
beside the chart and the reader wraps the pair in the same `titled` case a
preamble produces — one way of drawing a diagram's name, whichever way it was
written. A boundary inside a boundary is a frame inside a frame, which the
flowchart draws.

C4 hangs `$key="value"` settings off its lines, and writes the same settings
again in the `Update…` lines underneath, which repaint what has already been
written. Both go through one reader: the keys that name a colour paint the box,
the frame or the line, and the rest — where Mermaid nudges a word, how many
shapes it packs into a row, the sprite it draws, the tag it hangs off a box — is
read and let go, for the same reason `Rel_U` is. This ranks and draws its own
graph, so a hint about someone else's layout says nothing about this picture. A
key nobody knows, a colour that is no colour, and an `Update…` line naming
something nobody wrote are all refused, because any of them may be the thing the
author cared about.

An architecture diagram takes its grid from its edges, and `align` is an edge
with nothing drawn on it: `align row a b c` stands the three side by side the
same way an `a:R -- L:b` would, without a line between them. A `junction` is a
service with no name and no picture, there so that four edges can meet at one
point; it is given a two-point tile and no icon, so the lines run into each other
rather than into a box. In that language
`db:L -- R:server` is not decoration — it says the server stands to the left of
the database — so the parser walks the edges from the first service outwards and
gives every service a cell. Edges whose sides are opposite put two services side
by side; any other pair puts the second over one and along one, which is why such
an edge is drawn with a bend. When two services are sent to one cell the second
walks on in the same direction until a cell is free, and a service already placed
keeps where it stands — the first edge that named it is the one that settled it.
A service belonging to no group may be placed where a group's frame would enclose
it, and a frame drawn around somebody who is not in the group says something the
source does not; so the stranger is walked to the right of the block until it
stands clear, which is where Mermaid keeps it too. Moving one can push it into
the next group, so the sweep repeats until nothing moves. A group written inside
a group is a frame inside a frame, each with a strip of its own for its name. The
five icons Mermaid ships are drawn as filled silhouettes with their detail cut
back out in the page's own colour, and each is the picture people already draw
that thing as: a rack of three shelves with their lamps for a server, a hard
drive with its platter and arm for a disk, a cylinder for a database. All five
share one ink. A colour per kind would tell the reader that a database and a
server differ in some way the author never wrote down, and the same reasoning
keeps the four quarters of a quadrant chart one colour. An icon from a
downloadable pack would have to be fetched, and this app fetches nothing, so any
name that is not one of the five is drawn as the question mark Mermaid itself
draws for a name it cannot resolve.

A radar chart is a spoke per axis and a closed shape per curve, with the rings
drawn either as circles or as polygons through the spokes, whichever the source
asked for. A curve short of a value has no shape to close, so it is dropped and
the rest of the chart is drawn — which is what Mermaid does with one. A chart
left with no curve at all is a bare web, and a bare web is what its axes say it
is, so it is drawn. Two axes make a line rather than a shape, and `ticks 0`
leaves the web without rings; both are what Mermaid draws. With no `max` written
the outer ring is the largest value there is, which is what fills the circle.

A block diagram fills a grid of a stated width, cell by cell in reading order,
wrapping when the next cell would not fit and again when the row is full. Every
column is the same width, because a grid whose columns drifted would stop being
the grid its author counted out. The blocks themselves are `Flowchart.Node`s, so
the shapes, the `classDef` colouring and the arrow drawing are the ones a
flowchart already has.

`block:ID … end` is a grid inside a cell of the grid, and the same routine lays
it out, which is why a block inside a block needs no case of its own. The name is
optional — a bare `block` opens a frame no arrow can reach, which is a way of
grouping alone. A block arrow carries the sides it points at rather than one of
four directions, so `(x)` points left and right at once and `(x, down)` all
three; it is drawn as a bar with a point on every side it names, and each point's
base spans whatever room the other axis left, so a cross of four never runs
outside itself. The grid
is measured in the narrowest column any framed block needs, and a plain cell
takes several of those columns at once, so the author's own column count still
says where a row wraps while what is written inside a frame still fits. A frame
is drawn in the gap around the cells it holds, and an edge may name it — the
same `Flowchart.End` a subgraph gets. `blockArrowId<["words"]>(down)` is a fat
arrow with words in it: a shaft and a head worked out from the cell it stands
in, and kept to its own girth rather than stretched across a whole row, where it
would read as a band and not an arrow.

A ZenUML diagram is a sequence diagram written as code, and it is read into one.
The work is the stack of callers: `B.method()` is a call from wherever the reader
has got to, the braces after it put `B` on top until they close, and `return`
goes back to whoever is one step down. The braces also raise the bar on the
callee's lifeline, which is what the sequence layout already draws for
`activate`. A call with nobody calling it comes from the nameless stick figure
Mermaid draws in that case, standing to the left of everyone — which is also how
a sequence diagram's `actor` is drawn, since both mean somebody rather than
something.

A pie chart is wedges from twelve o'clock with a legend beside them, and its
colours are written down rather than taken from the theme: a pie says which
slice is which by colour, so the colours have to stay apart from each other on
either background. A state machine has no layout of its own at all — it is read
into a `Flowchart` whose start and end are a filled dot and a ring, because that
is the only thing about it a flowchart cannot already draw. `state Big { … }` is
written out as a `subgraph`, so a machine inside a machine is a frame inside a
frame. `[*]` inside one is that machine's own beginning and end rather than the
whole diagram's, so the points are named after the state that holds them — two
composite states each get their own dot and their own ring. A `<<fork>>` and a
`<<join>>` are the same solid bar and a `<<choice>>` is a diamond, all three
drawn without the name the author gave them, because it is the mark that is
read. A note is written out as a node of its own on a dotted, headless link, so
the placing a note needs is the placing an edge already had.

A class diagram's `namespace` is laid out as a picture of its own and then placed
as one box, the same way a subgraph inside a flowchart is: it is the only way a
frame can be sure to hold its own classes and nobody else's. A cross-namespace
line is drawn between the boxes themselves, since every box has an absolute place
once its namespace has one.

A sequence diagram is columns with dashed lifelines, walked in document order.
Somebody made part way through — `create participant Carl` — has their box on the
message that makes them rather than at the top, and somebody destroyed has a
second box where their lifeline stops; an arrow to either of those boxes ends at
its edge instead of running through the name written inside it.
Each gap between two lifelines is as wide as what crosses that gap, and no
wider. The words of a message go over its arrow, so a gap sized to the
participant boxes alone leaves them hanging off both lifelines — but one
spacing for every column, which is what a sequence diagram usually gets, hands
the room the wordiest message anywhere needs to every gap in the picture: a
diagram of a dozen short calls and one long one came out two or three times the
width it had anything to say in. `spacing` starts every gap at two boxes side
by side and then lets each message and each note over two or more participants
ask for the gaps it crosses, together, taking only what they are short of.
Short crossings are settled first, so a message reaching across the picture
does not widen gaps its neighbours have already paid for. On the diagrams this
was written for it takes a third off the width. The words
stand clear of the arrow by their own descenders rather than by a fixed few
points, which is what stops the tail of a `y` from crossing the line.
The walk hands back three lists — block frames, activation bars and the
messages and notes themselves — because they are painted in that order: a frame
is behind its contents, and a bar is behind the arrows that start and end it. A
block's frame cannot be drawn until its contents have been placed, which is why
the whole body is laid out before anything below the participant boxes appears.
An arm of a block carries the word that opened it and its condition; an arm
written without a condition still gets the word — `else` in an `alt`, `and` in a
`par` — because a divider with nothing beside it reads as an accident. A frame
is drawn as a dashed rectangle and the walk leaves a gap under it before the
next thing, which is how a reader tells one block from the next: two solid
frames whose edges met read as a single box with a line through it, and the
dashes are what the diagrams everyone learned this from use. A `rect`
is a block like any other whose frame is a wash of colour with no outline and no
word on it, painted before the lifelines so the messages stay on top; a `box` is
a named column — its colour runs the whole height of the participants declared
inside it, not just the band its name is written in, so a reader following a
lifeline down can see at any point which group it belongs to. It is that colour
and nothing else: an outline the height of the picture crosses every message
passing between two groups, and a word written across that line is the one word
in the diagram nobody can read. A `box` written without a colour takes the
faintest tint the theme has, since it no longer has an outline to be seen by. Both take their
colour through the same CSS reader every other diagram uses, so `rgba()` fades
them over the page rather than hiding it.

A colour behind a whole column is behind the lettering too, which is why it
goes through `wash` first. Behind a band of heading, an author's colour had only
the group's own name over it; behind the column it has every message label,
every lifeline and every note in the group. So the colour is mixed with the page
until the faintest ink in a diagram — a message label — stands at
`readableContrast`, which is the 7:1 the palette itself is chosen against. A
colour already that pale passes through untouched, which is what happens to most
of them: of the five in the diagram this was written for, three were left
exactly as written and two were lightened by a few points.

The same rule then went everywhere else an author's colour lands under the
picture's own ink, because `box` was only the kind that had been looked at:
`style A fill:#111` on a flowchart node arrived with the theme's dark ink still
on top of it and came out at 1.02:1 — a word that is in the picture and not on
the screen. `authorFill` runs a node's fill, a subgraph's, a class or entity
box's through `wash`, and the treemap runs its tiles through it a tile at a
time, since a tile is painted over its parent rather than over the page and a
class paints a section and everything in it. `wash` takes the ink it has to
stand up to and the strength the colour will be drawn at, so a tile painted at
half strength is not paled for a contrast it already had. An author who wrote
`color:` as well as `fill:` has answered the question themselves: the page is no
longer somewhere worth moving to, and both are kept exactly as written.

Lettering in a colour off the wheel had the same fault without an author
anywhere near it. A git graph wrote each branch's name in that branch's own
colour on the white page, where the paler half of the wheel came out at 2.2:1 —
the word saying which line is which was the one word in the picture nobody could
read. The colour moved behind the word as a tag and the word is written in the
ordinary ink, which is how the section bands of a timeline, a journey and a
kanban board had it all along. Turned on its side the graph writes those tags
side by side over lanes 46 points wide, so a lane is now at least as wide as the
tag naming it: two tags that met in the middle read as one word twice as long.

`DiagramLegibilityTests` is what keeps this true for the next kind of diagram.
It draws one sample of every kind the layout knows, and for every word in the
picture it finds the topmost thing painted under it, composites the part-strength
fills the way the screen does, and measures the pair. The check is the layout's
own bar of 7:1, and it runs again over author-written fills, on a light page and
a dark one. It found treemap tiles and git branch names on its first run.

`FolderAccess` is the one place that knows what a sandboxed copy may read. The
sandbox hands over the document that was opened and nothing else — not the
folder it sits in, and not the picture beside it — so a document saying
`![a picture](pic.png)` drew VIEW-16's empty frame on the Mac App Store and
nowhere else: every local build is unsigned, and an unsigned build has no
sandbox at all, which is why this survived to a shipped version. There is no
entitlement that widens a document to its folder; the only way in is the reader
pointing at that folder in a panel, and `files.bookmarks.app-scope` to keep the
grant across relaunches. The ask is driven from the failure rather than from the
open: `ImageLoader` reports a file it could not read, a file inside a granted
folder is taken to be a broken file and not a locked one, and a folder is asked
about once however many pictures a document has in it. Paths are compared with
their symlinks resolved as far as the disk allows — a panel answers `/tmp/notes`
where the document arrived as `/private/tmp/notes`, and comparing the spellings
says the folder was never granted.

The Quick Look extension keeps the old behaviour, and that is not an oversight.
It is a separate sandbox with its own identity, so an app-scoped bookmark the
app holds means nothing inside it, and a preview has nowhere to put a panel: a
picture beside a document previewed with the Space bar draws the empty frame.
Nothing promises otherwise — what Quick Look is offered is the rendering,
diagrams and formulas included.

A diagram in the reading column is as wide as the column, which is why a click
on one enlarges it. `DiagramWindow` shows the one drawing at
its natural size, magnified and pannable; Copy PNG and the written-out file go
through the same renderer. None of them keeps a drawing beside the block:
re-reading the fence costs a parse of a few lines, and a second copy of every
picture on screen would cost exactly what this viewer refuses to spend. The
width asked for is a limit and not a frame, and `cropped` cuts away the empty
card either side, so what leaves is the picture and nothing else.

How large that window opens is a question about lettering rather than about
pictures. Fitting the whole picture into the screen is the obvious answer, and
it fails for exactly the diagrams that need the window most: sixteen
participants across 1748 points stand at 0.37 and set their message labels at
3.7 points — sharp, and unreadable, which is what the reader opened the window
to escape. `openingMagnification` takes that fit and floors it at the
magnification where the smallest lettering a diagram sets —
`MermaidLayout.smallestLabelFactor` of the theme's control label — is still
`readableTextSize` points tall. A picture that fits at that magnification is
shown whole, and one that does not opens at its top left with the rest scrolled
to; ⌘0 still goes back to the whole picture. The panel then takes the room it
is offered instead of keeping the picture's shape, because what will not fit is
scrolled to rather than left out.

A click on a diagram opens the panel; a double click on the panel hands the
picture to a viewer. The two gestures used to share the diagram in the page, and
they cannot: the panel opens under the pointer, so the first of a double click's
two clicks opened it and the second landed on the panel rather than on the
document. Waiting out `NSEvent.doubleClickInterval` before opening made the
click answer nothing for most of a second on a Mac whose double-click speed is
set slow. Moving the second gesture onto the panel costs nothing — a single
click there means nothing anyway, since a reader who has just opened a picture
is looking at it — and leaves the click in the page immediate. `openFile` is
named rather than called straight so a test can watch the file being handed over
without Preview opening on somebody's screen.

Neither gesture is visible, which is why the panel carries a strip above the
picture: a close button on the left, Open in Preview on the right. Apple's
guidance for a modal view on macOS is a dismiss button in the content itself,
and Quick Look — where this whole gesture comes from, and what Notes and Mail
put behind the space bar — arranges exactly these two controls this way. Without
the strip the panel had one way out, Escape, which a reader has to know before
they need it; the panel now fills nearly the whole screen, so the document
behind it is barely there to click.

Opening has to feel like nothing happened but the picture. Laying a diagram out
costs a few milliseconds; filling its bitmap at two pixels per point costs a
third of a second for the largest of these, and all of it is spent on the main
thread with the click unanswered. So the first paint is `firstBitmapScale`, one
pixel per point, which the same measurement puts at five to ten milliseconds,
and the redraw that follows a change of magnification — deferred anyway, so that
a pinch costs one drawing and not thirty — brings the density the magnification
really wants. The picture is soft for that one redraw and on screen at once.

That only works if a drawing knows how wide it really is, and for a while none
of them did. Each kind reported the width of the boxes it had laid out, which is
not the same thing: a line bowed around a box reaches past them, and so does a
word that outgrew the card it was written in. Both used to be cut off by the
edge of the bitmap. So every drawing is now measured by what is in it — the
union of every decoration's own rectangle, glyph runs read back from the lines
that carry them — and if any of it landed outside, the whole picture is slid
back into view. Measuring the output rather than the plan is what makes this
cover the kinds nobody has thought about yet, including the ones added later.

Everything it produces is `BlockBox.Decoration` — filled and stroked paths, and
the glyph runs added for formulas — so the diagram draws in the window and in
the offscreen PNG by the same path as the text, and nothing about a diagram
reaches `DocumentRenderer`. `Decoration` has no dash pattern, so a dashed line
is a path of short segments rather than a sixth case every renderer would have
to honour. The block types nothing: the fence's own text stays the block's
plain text, which keeps the diagram findable and copyable as the source its
author wrote.

### Pages, slides and focus

Three ways of showing the same layout, none of them a second renderer.

`PageLayout` walks the blocks in order and cuts where a page ends, at a line
boundary inside a block rather than through a line; `PDFExport` draws each slice
with `DocumentRenderer.draw` into a PDF context, which is what makes the text
real glyphs and the diagrams vector paths. It lays out one block at a time so
the box cache's eviction still bounds memory on a document nobody could hold at
once. `PrintableDocument` is the same drawing behind `NSView`, so Print and
Export are one path.

`Slides.split` answers where a deck breaks — the author's thematic breaks if
there are any, otherwise the shallowest heading level that divides the document
more than once — and returns an empty list for a document that is not a deck.
`PresentationWindow` shows one range at a time and scales it to fit rather than
laying it out again at another width.

Focus is the disclosure machinery pointed at headings: `DocumentLayout.setFocus`
adds the folded ranges to the same sorted `hidden` list a closed `<details>`
uses, keeping every heading visible. Nothing is dropped, so find, copy and the
outline are unaffected, and the blocks that are folded away simply have no
height.

### The map down the right edge

The map is a minimap in the editors' sense: it draws the text, not a legend for
it. A reader recognises a place in a document by its shape — a wall of prose, a
short list, an indented block of code — and none of that survives a bar of
colours saying "code here, prose there".

`DocumentMap` is arithmetic over the flat block array, the line index and the
raw bytes, with no AppKit in it. `classify` answers what one leaf is from `kind`,
`level` and `info` alone — a Mermaid fence by its info string, a picture by a
leaf whose first bytes past the container scaffolding are `![` — and the result
is one byte per leaf, which is what colours a row. `rows(document:classes:
fromLine:maxRows:columns:)` reads the bytes of the lines the strip can show and
returns one `Row` per line, holding the runs of non-space as (column, length):
tabs count as four columns, a continuation byte of a UTF-8 character counts as
none, and a line wider than the map is cut off at its edge.

Three decisions are load-bearing.

*Only the window is read.* A document longer than the strip is shown through a
window of lines, so a map of 32 MB costs what a map of a note costs. The window
is centred on the lines the viewport is showing and clamped at both ends, which
is also what keeps the reading rectangle inside it: window and rectangle are
computed from the same lines, and heights below the viewport are still
estimates.

*One row to a line.* Wrapping a long line onto several rows made the rectangle
drift away from the line it marks — with prose paragraphs of 500 characters the
drift ran off the bottom of the strip. Clipping makes the row index arithmetic:
`line - startLine`.

*The classification rides on the walk `DocumentSummary` already makes*, rather
than starting a second pass over half a million blocks: whichever of the two
landed first owns the walk, and the summary landed first.

*The strip has a lane of its own.* It sits inside the scroll view but stops a
scroller's width short of its trailing edge, so the scroller draws to the right
of the map instead of over it — the map is aimed at with the pointer, and it
cannot be the one thing the scroller covers. What the map leaves is the reading
area, and it decides two widths, not one: the document view is resized to it in
`ReadingClipView.layout`, and the reading column is fitted into it in `fitted`.
Each of the three was wrong on its own at some point. `contentInsets` shifts
what can be scrolled to without narrowing the document view, so the text ran
under the map on any document wide enough to reach it. A resize notification
arrives after the pass that moved the edge, which a store screenshot — drawn
straight after layout — recorded as text at the old width. And a column fitted
to the clip view, which runs on beneath the strip, reached past the map's left
edge and was cut off there: 112 points of text on the map at the widest reading
setting, which is what the reader saw and the geometry alone did not show.

*The map is pale until it is used.* It is beside the page for as long as the
document is open, and at full strength it competes with the words being read. It
draws at a little over half strength, and the pointer entering the strip brings
it back to full.

`DocumentMapStrip` draws the text, then the comparison marks, then the find
marks, then the reading rectangle. It grew out of the find overview, which was
the third of those layers all along; find matches and comparison marks travel as
source lines now, so they land on the map's own axis. The rows are rebuilt at
most once a turn of the run loop, and only when the window, the strip's height or
its width actually moved. The reading rectangle is the exception and moves with
the scroll itself, because a marker that lags a turn behind is visible.

### Copying with styles

`RichText` translates the CoreText attributes a box already carries into the
AppKit ones RTF wants — the font key is the same string, the colour key is not,
and its value is a `CGColor` where AppKit wants an `NSColor`. A link's
destination is set on the attributed text when it is built, which CoreText
ignores and the RTF writer does not. The plain flavour is written exactly as
before, separators between table cells included, because a rich paste is an
addition and nothing that pastes today may paste differently.

A whole block selected gets more than its runs. A table is rebuilt as an
`NSTextTable` — one `NSTextTableBlock` per cell, carrying the square it sits in,
the squares it spans and the alignment its column asked for — so the cells stay
editable text on the other side instead of a picture of a grid. That needs one
fact the segments never held, which cell each of them is, so `BlockBox` carries
a `TableGrid` recorded from the *arranged* table: sorted and filtered as the
reader sees it, because pasting the order in the file would paste something
nobody looked at. A diagram becomes the picture it is drawn as, carried in a
file wrapper because that is what survives being written out.

Only a whole block. Three cells of five have no honest grid and half a diagram
is not a picture, so a partial selection keeps the text it had. Pictures also
force a third flavour: RTF cannot carry one, so a selection holding a diagram
writes RTFD as well, first, since the order the flavours are written is the
order an application chooses between them.

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

## Markio

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
- Zoom lives on the window, not in the theme's callers: `Theme.Metrics.scaled(by:)`
  multiplies every measurement at once — type, spacing, indents, corner radii,
  rule thickness with a floor of half a point — and records the factor, which is
  how the fonts built outside that scale (the control label) and the Mermaid
  layout find it. Steps come from a fixed ladder rather than repeated
  multiplication, so zooming in four times and out four times returns to the
  size it started at. The starting size is the document's own if it has one,
  otherwise `SystemTextSize.zoom`: macOS keeps a text size in Accessibility
  settings and exposes no way to read the category, so the one public reading is
  `NSFont.preferredFont(forTextStyle: .body)` measured against
  `NSFont.systemFontSize` — a system that says nothing yields exactly 1. A
  window's zoom is kept in the same record as its scroll position, because it is
  the same kind of fact about how a document was left, and ⌘0 deletes it.
- Live reload watches the file with a `DispatchSource` vnode source and
  re-arms after each event, because an atomic save replaces the vnode.
- The menu bar is built in code before launch completes, so it exists before
  the first window.
- Command-line files are collected in `applicationWillFinishLaunching`, because
  AppKit asks whether to open an untitled document before
  `applicationDidFinishLaunching` runs (UI-3).

## MarkioQuickLook

A hand-assembled `.appex` under the app's `PlugIns`, ad-hoc signed by
`deno task app` because pluginkit will not load an unsigned or unsandboxed
extension. The binary's entry point is `_NSExtensionMain`, set by linker flags;
`main.swift` exists only because SwiftPM wants an entry symbol and is never run.

`preparePreviewOfFile` parses, lays out, installs the view and calls the
completion handler on one turn. There is nothing to await, which is why the
preview cannot hang — and why the extension needs no network entitlement, the
one a sandboxed `WKWebView` must have or its helper never launches.

## The icon

Drawn in code (`markio-bench icon`) into `packaging/Assets.xcassets`, compiled
to `Assets.car` by `deno task app` and referenced by name. Every size is the
same drawing scaled, expressed in fractions of the canvas, so the 16 px icon
cannot drift from the 1024 px one. The loose `AppIcon.icns` actool emits is
deleted: it caps at 256×256 and anything preferring it gets a blurry icon.

## Verifying it

- `deno task check` is the gate. Its web-engine scan is what keeps PROD-1 true,
  and it builds both configurations: the release compiler sees the whole module
  at once and rejects captures the debug build accepts, so a gate that built only
  debug would pass a tree from which no bundle could be made.
- Tests cover the block scanner (structure dumps), the inline parser (run
  dumps), the Fenwick tree against naive prefix sums, and the parity between
  find's plain text and the renderer's.
- `MarkioTests` depends on the executable target itself, which is how the
  window is testable without carving a module out of the app shell. What it
  holds is what a window has to allow: a drag on its edge, expressed the way
  AppKit expresses one — a size constraint at priority 510 — has to win against
  everything the window's own content asks for. It also puts the autosaved
  window frame back afterwards, so running the tests never decides how wide the
  app opens next.
- `--capture=<path>` draws the real window to a PNG; `--capture-hover=<x>,<y>`
  parks the pointer first, which is the only way to see a control that appears
  on hover, and `--capture-click=<x>,<y>` clicks once, which is how folding a
  section away is checked. `markio-bench snapshot` draws a document offscreen at any width,
  scroll offset and appearance, and takes an optional baseline so a comparison
  can be looked at the same way; `markio-bench diagram` draws one Mermaid source
  alone and exits 3 when the layout refuses it. All of them work without screen
  recording permission, which is what makes visual checks possible from a script.
- The Quick Look extension is checked structurally — bundle layout, plist,
  ad-hoc signature, entry point, the `@objc` class name the plist pins — and the
  rendering it does is the renderer's, already covered by its own tests. What
  only a real Finder panel can show is checked by hand.
