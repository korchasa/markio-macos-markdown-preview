# Reader tools — a wave of five

Five features chosen from a longer list, with the owner's priorities attached:
clickable code paths (high), a presentation and a focus mode (high), vector PDF
export (high), tables you can sort and filter (medium), and copy with formatting
(low).

They have one thing in common worth stating up front: none of them is another
way to render Markdown. Version 1.0 was rejected under guideline 4.3(a) as a
concept already on the store, and a viewer that opens a report, walks you to the
line of code it names, prints it as a vector PDF and shows it as a deck is not
the same product as a Markdown previewer. That is the argument these five make
together, and it is a better answer to 4.3(a) than any single one of them.

## The gate: the sandbox reaches the document and nothing beside it

**Two of the five need a file the reader did not open, and today the app cannot
read one.** The shipped entitlements grant `com.apple.security.app-sandbox` and
`com.apple.security.files.user-selected.read-only` and nothing else, so a
document opened through Finder or the open panel comes with access to itself.
Its folder is not included, and neither is the picture beside it.

Measured, not reasoned. `deno task app` produces an unsigned bundle, so the
sandbox is off in every local run — which is why nobody has seen this. Signing a
copy with `packaging/Markio.entitlements` and opening a document through
LaunchServices turns it on:

- sandboxed, ad-hoc signed with the shipping entitlements: `![a picture](pic.png)`
  beside the document draws the **empty frame** VIEW-16 promises for a picture
  that cannot be read.
- the same bundle, same document, signed without entitlements: the picture is
  there.

So on the Mac App Store, today, images next to a document do not appear, and a
relative link to another `.md` almost certainly fails the same way — it is the
same access, and `LinkResolver` resolves it to a sibling path. README and
VIEW-16 both promise the picture. **This is a live defect in the version now in
review, not a limitation of the plan.** Reproduce with a probe copy that carries
its own `CFBundleIdentifier` — the app sets `NSQuitAlwaysKeepsWindows`, so a
probe under the real id silently restores the previous session's windows and
photographs the wrong document.

The fix is one decision: ask the reader once for the document's folder through
an `NSOpenPanel` and keep a security-scoped bookmark
(`com.apple.security.files.bookmarks.app-scope`), so the grant survives a
relaunch. It is the only route that stays inside the sandbox rules — there is no
entitlement for "the folder my document is in". It has to be honest about what
it buys: the panel appears when a document actually points outside itself
(a picture, a relative link, a code path), never on open, and refusing it leaves
today's behaviour rather than an error.

This lands first. Clickable code paths cannot verify a path without it, and the
image defect is worth fixing on its own.

## Order

1. Folder access (the gate above) — unblocks 2, fixes a shipped promise.
2. Focus mode — the cheapest of the five, and it reuses machinery that exists.
3. Clickable code paths — the strongest differentiator of the wave.
4. Vector PDF export — self-contained, no dependency on the others.
5. Presentation mode — the other half of the mode work.
6. Sortable tables — most UI for the least architecture.
7. Copy with formatting — smallest gain, and the owner ranked it low.

## 1. Clickable code paths (high)

An agent's report is full of `Sources/MarkioRender/Mermaid.swift:214`, and today
that is inert text. Recognise it, and a click opens the file at that line in the
editor that owns it.

Where it lands: recognition belongs in `MarkdownKit` beside the autolink scanner
(`InlineParser`), because it is a property of the text and must be visible to
`BlockPlainText` so find and copy agree with the drawing. The click region is
already modelled — `BlockBox.LinkRegion` plus `linkTargets` — so the view needs
no new hit-testing. Opening is `NSWorkspace.open`, which needs no read access;
`LinkResolver` gains a fourth `Target`.

What is hard, in order:

- **`LinkResolver` is default-deny on purpose.** A relative path that is not
  Markdown is inert "so a document can never talk the viewer into opening an
  arbitrary file". This feature is exactly that path becoming live, so the rule
  has to be replaced by a narrower one, written down: only a path that resolves
  inside the folder the reader granted, only a file that exists, never an
  absolute path, and the click opens it in another app rather than reading it
  here.
- **Which editor, and how to name a line.** There is no portable "open at line".
  VS Code and Cursor take `vscode://file/<path>:<line>`, Xcode takes `xed -l`,
  BBEdit and Sublime have their own. A URL scheme is a launch, not a read, so
  the sandbox permits it — but the app has to know which one the reader wants.
  A preference with a small list, defaulting to the system handler for the file
  type (which loses the line number), is the honest shape.
- **False positives.** `2026-08-13` is not a path and `foo.md:12` inside a code
  fence is a string in someone's program. Recognise only outside fenced code,
  only with a directory separator or a known source extension, and only when the
  file is there — existence is the filter that makes the rest safe.

The same pass gives the second half for free: a relative link or an image whose
target does not exist can be marked in the drawing instead of failing silently.
Agents invent paths, and a viewer that shows which ones are real is worth the
feature on its own.

Done when: a path in prose is clickable, opens at the right line in the
configured editor, a path that does not exist is not clickable, a path inside a
fence is never touched, and find and copy see exactly the characters they saw
before.

Cost: two to three sessions, the editor preference included.

## 2. Vector PDF export and print (high)

`DocumentRenderer` already draws through one path for the screen and the
offscreen PNG. A `CGPDFContext` is a third caller of the same code, and because
CoreText draws real glyphs and Mermaid draws `CGPath`s, the result is a PDF
whose text is selectable and whose diagrams are curves. Every web-based renderer
prints its diagrams as bitmaps. This is the cheapest place where the no-web-engine
decision shows up as something a reader can hold.

Where it lands: a new file in `MarkioRender` beside `DocumentRenderer`, a menu
item in `MainMenu`, and `NSSavePanel` in `DocumentWindowController` — the panel
is also the sandbox grant for writing, which is why export is a command and not
a folder-watching feature.

What is hard:

- **Pagination.** Blocks are laid out one at a time and a box knows its height,
  so a page break between blocks is easy; a block taller than a page is not. A
  long fence or a tall table has to break at a line boundary, which means
  paginating inside `BlockBox.Segment.lines` and drawing a slice of a box.
  A diagram that does not fit scales down, the way it already does for a narrow
  column.
- **The invariant.** "Nothing is typeset until it is visible" is about opening a
  document, not about a command that means "typeset all of it". Export walks
  page by page and drops each page's boxes before the next, so a 32 MB document
  exports in bounded memory. Write that reasoning next to the code or the next
  reader will think it is a violation.
- **Print is the same context.** `NSPrintOperation` gives a `CGContext` per
  page; if pagination lives apart from the PDF writer, printing is nearly free.

Done when: a document exports to PDF with selectable text and vector diagrams,
a page break never cuts a line in half, ⌘P prints the same pages, and the
exported file opens in Preview at the size the page says.

Cost: two to three sessions, most of it pagination.

## 3. Presentation mode and focus mode (high)

Two ways of reading the same document, sharing one idea: show less of it.

**Focus** collapses every section but the one the reader is in, by heading.
The machinery exists — a closed `<details>` is already a range of ordinals with
zero height and empty boxes, kept as ranges precisely because a folded section
may hold a hundred thousand blocks. Focus is that mechanism driven by the
outline instead of by a disclosure triangle, plus a click target on the heading
itself. Find and copy keep seeing the folded text, which is already true today.

**Presentation** splits at thematic breaks (`---`) and shows one slide per
screen, full screen, arrows to move. It reuses the layout engine with a fixed
width and the existing zoom ladder, so a deck is a document read at a different
size rather than a second renderer.

What is hard: presentation needs a window mode that is not the document window —
no sidebar, no bottom bar, no find — and a decision about what a slide is when
the document has no `---` in it at all (answer: top-level headings, and if there
are none, it is not a deck and the menu item stays disabled). Slides that
overflow their screen are the pagination problem from the PDF work, which is an
argument for doing PDF first and reusing it.

Done when: ⌥⌘F folds every section but the current one and unfolds on the same
key; a document with thematic breaks enters presentation, moves with the arrows,
leaves on Escape, and shows a slide too tall for the screen scaled rather than
cut.

Cost: focus, half a session to one. Presentation, two.

## 4. Tables you can sort and filter (medium)

Click a column header to sort, type in a filter row to keep the rows that match,
and the header stays put while the rows scroll. The file is never touched — this
is state on the window, like zoom or the scroll position, and it must not be
persisted into anything that looks like a document change.

Where it lands: `HTMLTable` is the shape both kinds of table already share, so
sorting is a permutation of its rows applied when `BlockLayoutEngine` builds the
box. The view needs a hit test on the header row and a per-block piece of state
keyed by ordinal.

What is hard: a sticky header has to be drawn after the block it belongs to and
clipped to the block's rectangle, and `DocumentView` currently draws one
continuous sheet of blocks with no overlay layer. Sorting also needs to guess
what a column holds — number, date, or text — and be stable, or two clicks on
the same header produce two different orders. A merged cell (`rowspan`) makes
sorting meaningless; a table that has one keeps its header inert rather than
sorting wrongly.

Done when: clicking a header sorts and re-clicking reverses, the filter row
hides non-matching rows, find still finds text in a hidden row's source, the
sticky header disappears with its table, and a table with merged cells refuses
to sort.

Cost: one and a half to two sessions.

## 5. Copy with formatting (low)

Copy a selection and paste it into Mail, Slack or Notes with its styles intact.
The pieces are there: each `BlockBox.Segment` holds an `NSAttributedString`, so
the selection already has an attributed form; `copy(_:)` currently throws it
away and writes `plainText`.

What is hard is narrower than it looks but real: the attributes are CoreText
keys, and RTF wants AppKit ones — `kCTFontAttributeName` and `.font` happen to
be the same string, `kCTForegroundColorAttributeName` and `.foregroundColor` do
not, and the colour is a `CGColor` where RTF needs an `NSColor`. So a
translation pass is unavoidable. Beyond styled runs, three things need their own
answer: a table (RTF has `NSTextTable`, and mapping a merged cell onto it is
work), a diagram (paste it as an image attachment — the PNG path already exists
for Copy PNG), and a formula (glyphs positioned by hand, with no attributed
representation at all; paste its source).

Ship it in two steps rather than one: styled text, headings, code spans, lists
and links first, since that is most of what anyone copies; tables and diagrams
after, if they turn out to be wanted. Plain text stays on the pasteboard beside
the rich flavour, so nothing that pastes today pastes differently.

Done when: pasting into TextEdit keeps bold, code, headings and links; pasting
into a plain-text field is byte-identical to today; a diagram pastes as a
picture or, in step one, as its source.

Cost: half a session to one for step one.

## Not in this wave

The other five ideas from the same list — live tail of a document being written,
compare against a git revision or a macOS file version, reading from a pipe,
folder-wide search, task progress in the bottom bar — were not chosen. Two of
them (tail, pipe) are the strongest 4.3(a) argument of the whole list and are
worth revisiting once these five land.
