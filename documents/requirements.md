# Markio 2 — Requirements

What the viewer must do. How it does it is `design.md`.

## Purpose

Read Markdown on macOS, natively, at a speed and memory cost that does not
change when the document gets large. Markio 2 exists because a viewer built on
a web engine pays for the engine on every document: a browser process to start,
a DOM to build, and a second copy of the text to hold. Removing the engine is
the product, not an implementation detail.

## Scope

In: viewing local Markdown files, one window per document.
Out: editing, exporting, converting, syncing, and anything that needs a network.

---

## PROD — Product

- **PROD-1** The app renders Markdown without a web engine. No WebKit, no
  JavaScript runtime, no HTML anywhere in the rendering path. This is checked
  by the build, not by convention (see BUILD-2).
- **PROD-2** The app never modifies a document it opens. There is no save path
  and no dirty state.
- **PROD-3** The app works with no network. It makes no outbound request and
  declares no network entitlement.
- **PROD-4** One window per document; several documents open at once.

## PARSE — Reading the source

- **PARSE-1** CommonMark blocks: ATX and setext headings, paragraphs, block
  quotes (nested, with lazy continuation), bullet and ordered lists (nested,
  tight and loose), fenced and indented code, thematic breaks, HTML blocks,
  link reference definitions.
- **PARSE-2** GitHub extensions: tables with per-column alignment, task list
  items, strikethrough, autolinks.
- **PARSE-3** YAML front matter at the head of the file is a block of its own,
  not prose.
- **PARSE-4** Inline: emphasis and strong (CommonMark delimiter rules,
  including the rule of three and flanking), code spans, links (inline,
  reference, autolink), images, character entities, hard and soft breaks.
- **PARSE-5** Inline HTML that carries a text style — `b`, `strong`, `i`, `em`,
  `cite`, `s`, `del`, `strike`, `u`, `ins`, `mark`, `kbd`, `code`, `samp`,
  `tt`, `var`, `sup`, `sub`, and `br`/`wbr` — becomes that style. Every other
  tag is dropped with its content kept. There is no HTML parser beyond this
  mapping.
- **PARSE-6** Math between `$…$` or `$$…$$` is read as a formula. The subset is
  the LaTeX that turns up in prose: letters and numbers, Greek, the common
  operators, relations and arrows, scripts, fractions, roots of any degree,
  bracket sizing, accents, the blackboard, script and fraktur alphabets, the
  bold, italic, sans and monospace faces, the matrix environments, `cases` and
  `aligned`, `\text{…}` and the upright function names. `$$…$$` also says the
  formula is written in display style. Anything outside the subset — an unknown
  command, an environment with no layout here, an unbalanced brace — is not
  read at all, and the source stands as written.
- **PARSE-7** Malformed UTF-8 is displayed, not rejected: a viewer must show
  whatever it was handed.
- **PARSE-8** Parsing never depends on the theme, the window, or AppKit.
- **PARSE-9** A line of the form `[^label]: text` is a footnote, and `[^label]`
  in the prose is a reference to it. A reference whose label nothing defines
  stays the literal brackets the author typed.
- **PARSE-10** `<details>`, `<summary>` and `</details>`, each on a line of its
  own, mark a collapsible section. What lies between them is ordinary Markdown,
  not raw HTML.
- **PARSE-11** A `<table>` written with tags is read as a grid, `rowspan` and
  `colspan` included. Anything the reader cannot resolve into a grid stays raw
  HTML.
- **PARSE-12** A ```mermaid fence is read as a diagram when it is a flowchart
  (`flowchart`/`graph`, any of the four directions, with its shapes, subgraphs,
  `classDef`/`class`/`style` colouring and labelled links) or a sequence diagram
  (with `loop`, `alt`/`else`, `opt`, `par`, notes, activation bars and
  `autonumber`), a `pie` chart, a `stateDiagram-v2`, a `classDiagram`, an
  `erDiagram`, a `mindmap`, a `timeline`, a `journey`, a `gantt` chart written in
  the default date format, a `quadrantChart`, an `xychart-beta`, a `gitGraph`
  whose lanes run across the page, a `packet-beta`, a `kanban` board, a
  `requirementDiagram`, a `sankey-beta`, a `treemap-beta`, a C4 diagram
  (`C4Context` and its four siblings), an `architecture-beta` whose services
  use the icons Mermaid ships, a `radar-beta`, a `block-beta` or a `zenuml`
  written as calls, replies and the blocks around them. Every other diagram kind, and every construct
  inside the ones it reads that the layout cannot draw — a nested subgraph, a
  composite state, a namespace, a tinted band, a click handler, a mindmap icon,
  an excluded weekday, a cherry-pick, a gap between packet fields, a flow that
  returns to where it came from, a C4 restyling, an icon from a downloaded pack,
  a group inside a group, architecture edges that send two services to the
  same place, a radar curve short of a value, a block inside a block, or a
  ZenUML call with nobody calling it — is not read, and the fence stays a
  fenced block.
- **PARSE-13** A node's label is broken where its author broke it: `<br/>` and
  its spellings start a new line rather than becoming a space.

## VIEW — What the reader sees

- **VIEW-1** A single reading column, centred, its width set in characters and
  adjustable from the menu and a slider in the bottom bar. The setting persists.
- **VIEW-2** Light and dark follow the system appearance and switch live.
- **VIEW-3** A table-of-contents sidebar (⌥⌘S) showing the heading tree, with
  the section under the reader highlighted; clicking a heading jumps to it. Its
  visibility persists.
- **VIEW-4** Find (⌘F) with next and previous, matches highlighted in place.
- **VIEW-5** Text selection across blocks, select-all, and copy.
- **VIEW-6** Links are clickable. A link to a local file opens it in the app;
  anything else goes to the system handler.
- **VIEW-7** Code blocks are syntax-highlighted for the common languages, in
  both appearances.
- **VIEW-8** Task list items show a real checkbox, checked or not, and are not
  editable.
- **VIEW-9** The scroll position of a document is restored when it is reopened.
- **VIEW-10** When the file changes on disk, the view reloads and the reader
  keeps their place. A write that does not change the bytes changes nothing.
- **VIEW-11** A Markdown file dropped on a window opens. A file the app does
  not read is not accepted, so the drop never promises what it cannot do.
- **VIEW-12** While a search is running, a strip at the right edge shows where
  every match sits in the whole document, with the current one picked out;
  clicking a mark jumps to that match.
- **VIEW-13** A fenced block under the pointer offers its language and a Copy
  button. Copy writes the text as drawn — escapes removed — not the source
  bytes. A fence a diagram was drawn in place of offers Copy PNG as well, which
  puts the picture itself on the clipboard.
- **VIEW-14** A ```diff block reads as bands: added lines on one tint, removed
  on another, the rest plain.
- **VIEW-15** Terminal escapes in a pasted log are drawn as colour — the
  sixteen basic colours, the 256-colour cube and true colour — and never shown
  as text. Escapes that describe a terminal that is not there are dropped.
  Find and Copy see the text without them.
- **VIEW-16** Images from a file beside the document are shown, decoded at the
  size they are drawn and no larger. A paragraph that is nothing but an image
  shows it full width; an image inside a sentence is drawn on the line, at most
  a little taller than the text, and its alt text gives way to it. A remote
  address is not fetched; a picture that cannot be read leaves an empty frame
  where it belongs, so Find and the drawing agree on every character either
  way.
- **VIEW-17** A document can be compared against an older version of itself
  (File ▸ Compare…): blocks added since the baseline and blocks removed from it
  are marked in place, in one window with one scroll. The outline and find
  cover the removed text as well. Stop Comparing returns the plain document; an
  edit while comparing re-reads the baseline and compares again. The baseline
  choice lasts for the session only.
- **VIEW-18** The app carries its own icon, drawn from code and compiled as an
  asset catalog, so every size comes from one drawing.
- **VIEW-19** Quitting with documents open and relaunching brings those windows
  back, whatever the system's global "close windows when quitting" setting says.
- **VIEW-20** `<sup>` and `<sub>` are drawn smaller, above and below the
  baseline. The shift stays inside what the surrounding font's own ascent and
  descent allow, so a paragraph carrying markers keeps the leading of one that
  does not.
- **VIEW-21** A footnote reference is a raised, clickable label; clicking it
  scrolls to the note. The note itself is set smaller, indented, with its label
  standing beside its first line.
- **VIEW-22** A table written with HTML tags is drawn as a table, merged cells
  and all, by the same layout that draws a Markdown table. One that cannot be
  read as a grid is shown as source rather than as half a table.
- **VIEW-23** A `<details>` section shows a summary row with a triangle;
  clicking it folds the section away or brings it back. `<details open>` starts
  open, `<details>` starts closed — what the author wrote. A folded section's
  blocks are hidden, not dropped: find and copy still see them.
- **VIEW-24** A formula the parser understands is set with real glyphs — serif,
  variables in italic, fractions stacked over a rule, roots under a bar, scripts
  beside, accents on the letter's ink, matrices inside brackets grown to their
  height — at the size of the text around it, sitting on its baseline. A
  display formula writes the range of a sum above and below its sign; an inline
  one keeps it beside, so a paragraph does not grow around one formula. It
  occupies one placeholder character in find and copy, the way an inline picture
  does. A formula the parser does not understand keeps its source, and that
  source stays searchable.

- **VIEW-25** A diagram is drawn in place of its fence — boxes on ranks with
  arrows between them, subgraphs in titled frames, participants with messages,
  notes and framed blocks across them, a tree opening to the right of its root,
  periods across the page with what happened in each one under it, a line rising
  and falling over the steps of a journey, a row per task with its bar over the
  days it takes, a square cut in four with points scattered over it, bars and
  lines over named categories, commits along a lane per branch, a row of bit
  fields per word, a column of cards per board list, ribbons as thick as what
  they carry, nested rectangles each as big a share as its value, tiles on
  the grid their edges put them on, a closed shape per curve over a spoke per
  axis, or cells filling a grid of the width the author counted out — centred in
  the reading column, in the current theme's
  colours except where the diagram names its own, and with a colour per branch
  or section where the diagram's own meaning is carried by colour. A picture too
  wide for the column is drawn smaller rather than cut off. The block keeps the
  fence's own text, so find and copy still work on the diagram's source.
- **VIEW-27** Clicking a drawn diagram shows it large over the window, laid out
  again at that width rather than magnified. Clicking it again, clicking the
  enlarged picture, or pressing Escape puts it away.
- **VIEW-26** File ▸ Side by Side gives the baseline a column of its own: the
  older version on the left with what it lost, the current file on the right
  with what it gained. The two scroll together. Find, the outline and every
  command keep working on the document the window belongs to.

## QL — Quick Look

- **QL-1** Pressing Space on a Markdown file in Finder previews it with the
  same renderer the app uses.
- **QL-2** The preview resolves on the turn it is asked for: nothing is
  awaited, so it cannot hang on a spinner. A file it cannot read hands the
  error back, and macOS shows its own plain-text preview.
- **QL-3** The extension claims Markdown only, never plain text, and reads
  nothing from the app — it is sandboxed apart from it.

## PERF — The reason it exists

Measured on release builds over generated documents of realistic shape; the
numbers are recorded in `README.md` and reproduced by `deno task bench`.

- **PERF-1** Parsing is linear in file size and runs at hundreds of MB/s. A
  32 MB document parses in well under 100 ms.
- **PERF-2** The parse structure costs a bounded fraction of the file — under
  half — and the source is held once, as bytes. No second copy of the text.
- **PERF-3** Time to the first screenful does not grow with the document. Only
  blocks that are on screen, or about to be, are typeset.
- **PERF-4** Memory does not grow as the reader scrolls: laid-out blocks far
  from the viewport are released.
- **PERF-5** Scrolling to any point in the document is O(log n) in the number
  of blocks, including before the document has been measured.
- **PERF-6** Find runs off the main thread and reports its first matches before
  it has finished, without building an index or a second copy of the text.

## UI — Behaviour under the hood

- **UI-1** Opening a document must not block the windows already open beyond
  the parse itself.
- **UI-2** Replacing an estimated block height with a measured one must not
  move the text under the reader's eyes.
- **UI-3** A file named on the command line opens without the open panel
  appearing; a path that does not exist is reported and skipped, never turned
  into a modal alert.

## BUILD — How it is kept honest

- **BUILD-1** One command, `deno task check`, is the gate: format, lint,
  type-check, build, comment scan, web-engine scan, format lint, tests.
- **BUILD-2** The web-engine scan fails the build if `WebKit`, `WKWebView`,
  `JavaScriptCore` or HTML loading appears in the sources. PROD-1 is enforced,
  not trusted.
- **BUILD-3** Every command is a `deno task`. New commands become tasks, not
  shell scripts.
- **BUILD-4** `deno task dist` produces an unsigned `.app` at
  `.build/Markio2.app`. Signing, packaging and upload happen outside this
  repository, and nothing in it refers to how.
- **BUILD-5** Rendering can be verified without a screen: the app draws its own
  window to a PNG (`--capture=<path>`, with `--capture-hover=<x>,<y>` for the
  controls that only appear under the pointer and `--capture-click=<x>,<y>` for
  what only a click reveals, and `--compare=<path>` with `--side-by-side` for a
  comparison), and the bench harness renders a document offscreen — with an
  optional baseline, so a comparison can be checked the same way.
