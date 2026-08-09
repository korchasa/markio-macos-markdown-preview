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

Mermaid's YAML preamble is read before the diagram is, for the keys that say
what to draw. The title travels as `MermaidDiagram.titled`, a case wrapping any
other, so the layout draws the diagram exactly as it would have without a name
and then moves it down to make room — one place for a title rather than one per
kind; a `title` with nothing after it is no title at all. `config.kanban`'s
`ticketBaseUrl` and `sectionWidth`, and `displayMode: compact`, reach the reader
that wants them, and a key written over a diagram of another kind is left unused
rather than read as a mistake — which is what Mermaid does with it. `config.theme` travels the same way as the title, as a
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
author did not choose, which is the half-truth everything else here avoids.

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

Edges are drawn between box centres and clipped to the boxes, so an edge across
a rank or back up the graph needs no special case. Two straight lines between
the same pair of boxes would land on top of each other, and a line drawn to a
box three ranks away would cut through everything in between, so an edge is
bowed: it is given a lane — the pairs are counted, and the *n*th edge between
the same two boxes is offset by its place in that count — and then pushed
sideways until it clears the box frames it would otherwise cross. The curve is
flattened into a path, which is what lets a dashed edge keep an even rhythm
around the bend and an arrowhead sit square on the line's real direction. An
edge with no bow to make and two boxes standing one over the other is drawn
straight down the middle of what they share, rather than from centre to centre:
aiming at the centres leans the line whenever the two boxes are not the same
width, and one leaning line in a column of upright ones reads as a mistake.
Their words are written last, over the nodes, because an edge that skips a rank
passes over whatever stands between, and the line is broken around each word so
the two never overlap. The gap between ranks is sized from those words plus an
arrowhead plus a visible run of line on either side — a gap sized to the words
alone leaves a labelled edge looking like a chip with a stub beside it.

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
is the one whose answer is kept. An x–y chart names three things and draws two
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
ends carry the meaning — a hollow triangle for inheritance, a diamond for
composition, a crow's foot for how many. They differ only in how they are read
and in which ends their lines may have, which is why `BoxDiagram` is shared and
`ClassDiagram`/`EntityDiagram` are two readers of it. An entity's attribute is
written type first and name second, the order it is declared in: `string email`
and not `email string`, which would say the attribute is called `string`.

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
one and from the column where there is not.

A quadrant chart is a square cut in four, with each quarter's name along its own
top edge rather than through the middle of it, which is where the points are. A
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
because a copy is the same work said twice rather than one line running on.
What a commit is decides how its
dot is drawn: a merge is hollow because it is the one commit belonging to two
lines at once, a `REVERSE` is crossed out, a `HIGHLIGHT` is ringed. A `type:`
nobody here draws is refused rather than read as an ordinary commit — that is
the same rule as everywhere else, applied to a word that would otherwise vanish
without a trace in the picture.

A journey is a line that rises and falls over the steps it is scored on, with
the sections banded above it and each step's name and actors written under its
own column. The top and bottom rules are held a dot's radius inside the plot, or
a five would ride up into the band above it and a one would sit on the names.

A Gantt chart counts days from its first task and nothing here knows about
calendars beyond turning a written date into a day number and back, which is why
`after`/`until` references, durations in days, weeks and hours, and bars all
work in the same units. `dateFormat` is read token by token — `YYYY`, `MM`, `DD`
and whatever stands between them — so a chart written any way Mermaid allows
lands on the right days. `excludes` and `includes` turn a length into a count of
working days: the bar then reaches further along the calendar than its `3d` says,
and the days off are shaded behind it so the difference is visible rather than
mysterious. A milestone has no length, so it is drawn as a diamond on its day rather
than a bar nobody would see. The axis carries whole dates, year included: a
chart that runs over a new year would otherwise label two different days the
same way. How wide a date is decides both how wide the plot has to be and how
many ticks can be labelled, so the number of ticks follows from the room rather
than being fixed at five.

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
keyword is the source's grammar and the box is what a person reads.

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
name, gets no head row.

A C4 diagram has no layout of its own — it is read into a `Flowchart` whose
shapes come from what each element is: a person is a stadium, a `*Db` a cylinder,
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

An architecture diagram takes its grid from its edges. In that language
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
back out in the page's own colour; an icon from a downloadable pack would have to
be fetched, and this app fetches nothing, so any name that is not one of the five
is drawn as the question mark Mermaid itself draws for a name it cannot
resolve.

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
it out, which is why a block inside a block needs no case of its own. The grid
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
A column is as wide as the longest message written across it — divided by how
many columns that message spans, since a message reaching further has more of
them to spread over — because the words go over the arrow, and a column sized to
the participant boxes alone leaves them hanging off both lifelines. The words
stand clear of the arrow by their own descenders rather than by a fixed few
points, which is what stops the tail of a `y` from crossing the line.
The walk hands back three lists — block frames, activation bars and the
messages and notes themselves — because they are painted in that order: a frame
is behind its contents, and a bar is behind the arrows that start and end it. A
block's frame cannot be drawn until its contents have been placed, which is why
the whole body is laid out before anything below the participant boxes appears.
An arm of a block carries the word that opened it and its condition; an arm
written without a condition still gets the word — `else` in an `alt`, `and` in a
`par` — because a divider with nothing beside it reads as an accident. A `rect`
is a block like any other whose frame is a wash of colour with no outline and no
word on it, painted before the lifelines so the messages stay on top; a `box` is
a titled band above the participants declared inside it, and both take their
colour through the same CSS reader every other diagram uses, so `rgba()` fades
them over the page rather than hiding it.

A diagram in the reading column is as wide as the column, which is why clicking
one opens `DiagramWindow`: the same source laid out again at the width of the
window, not the same picture magnified — a diagram's type does not simply scale,
and a graph drawn smaller to fit the column has ranks it could have spread out.
Copy PNG goes through the same renderer. Neither keeps a drawing beside the
block: re-reading the fence costs a parse of a few lines, and a second copy of
every picture on screen would cost exactly what this viewer refuses to spend.
In both, the width asked for is a limit and not a frame: a picture is centred in
the room it is given, so a small diagram in a wide window would come back
sitting in a field of empty card. A drawing narrower than the room is laid out a
second time at its own size, and what leaves is the picture and nothing else.

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
- `Markio2Tests` depends on the executable target itself, which is how the
  window is testable without carving a module out of the app shell. What it
  holds is what a window has to allow: a drag on its edge, expressed the way
  AppKit expresses one — a size constraint at priority 510 — has to win against
  everything the window's own content asks for. It also puts the autosaved
  window frame back afterwards, so running the tests never decides how wide the
  app opens next.
- `--capture=<path>` draws the real window to a PNG; `--capture-hover=<x>,<y>`
  parks the pointer first, which is the only way to see a control that appears
  on hover, and `--capture-click=<x>,<y>` clicks once, which is how folding a
  section away is checked. `markio2-bench snapshot` draws a document offscreen at any width,
  scroll offset and appearance, and takes an optional baseline so a comparison
  can be looked at the same way; `markio2-bench diagram` draws one Mermaid source
  alone and exits 3 when the layout refuses it. All of them work without screen
  recording permission, which is what makes visual checks possible from a script.
- The Quick Look extension is checked structurally — bundle layout, plist,
  ad-hoc signature, entry point, the `@objc` class name the plist pins — and the
  rendering it does is the renderer's, already covered by its own tests. What
  only a real Finder panel can show is checked by hand.
