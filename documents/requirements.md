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
  `tt`, `var`, and `br`/`wbr` — becomes that style. Every other tag is dropped
  with its content kept. There is no HTML parser beyond this mapping.
- **PARSE-6** Inline math (`$…$`) is preserved as its source text in a
  distinct style. It is not typeset as mathematics.
- **PARSE-7** Malformed UTF-8 is displayed, not rejected: a viewer must show
  whatever it was handed.
- **PARSE-8** Parsing never depends on the theme, the window, or AppKit.

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
  window to a PNG (`--capture=<path>`), and the bench harness renders a
  document offscreen.
