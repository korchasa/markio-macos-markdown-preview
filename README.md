# Markio 2

A native macOS Markdown viewer with no web view, no HTML and no JavaScript.

Every glyph on screen is typeset by CoreText from a parser that reads the
file's bytes directly. Nothing is converted to HTML on the way, so there is no
browser engine to start, no document object model to build, and no second copy
of the text living inside a renderer. The point of that is what it buys on
large files: an 8 MB document opens as fast as an 8 KB one, and scrolling
through a 32 MB one measures the same as scrolling through a short note.

Markio 2 reads. It never writes a file it opens.

## What it renders

- CommonMark blocks: ATX and setext headings, paragraphs, nested block quotes,
  bullet and ordered lists (tight and loose, nested), fenced and indented code,
  thematic breaks
- GitHub extensions: tables with per-column alignment, task lists,
  strikethrough, autolinks
- YAML front matter, shown as a highlighted metadata block
- Inline: emphasis, strong, code spans, links (inline, reference, autolink),
  entities, hard and soft breaks
- The inline HTML that carries meaning — `<b>`, `<em>`, `<kbd>`, `<mark>`,
  `<u>`, `<del>`, `<code>`, `<br>` and their synonyms — mapped straight to text
  styles. There is no HTML engine; anything else is dropped rather than shown
- Inline math kept as its source in a distinct style
- Syntax highlighting for Swift, Python, Go, Rust, shell, SQL, JSON, YAML and
  the C family, in light and dark

Not yet: images are marked but not decoded, and there are no diagrams.

## Reading it

- **⌘O** open, **⌘W** close, **⌘⇧C** copy the document's path
- **⌘F** find, **⌘G** / **⌘⇧G** next and previous match
- **⌥⌘S** the table of contents — the heading tree, click to jump
- **⌘+** / **⌘−** reading column width, also on the slider in the bottom bar
- Select text with the mouse, **⌘A** select all, **⌘C** copy
- Click a link to open it; light and dark follow the system
- Edit the file in another app and the view reloads where you were reading

## Building it

Needs Deno 2 and a Swift 6.3 toolchain.

```bash
deno task check
```

That is the gate: format, lint, type-check, build, a scan for TODO markers, a
scan that fails if WebKit or JavaScriptCore ever appear in the sources, a
format lint, and the tests.

Other verbs:

- `deno task app` — build the `.app` bundle into `.build/Markio2.app`
- `deno task dev <file.md>` — build and open a document
- `deno task test` — the test suite alone
- `deno task bench` — parse cost and memory footprint at 1, 8 and 32 MB
- `deno task dist` — the unsigned bundle; signing and upload happen outside
  this repository

The app can draw its own window into a PNG, which is how rendering is checked
without a screen:

```bash
.build/Markio2.app/Contents/MacOS/Markio2 doc.md --capture=/tmp/shot.png
```

## What it costs

Release build, Apple silicon, generated documents of realistic shape:

- 1 MB — parse 1.9 ms (520 MB/s), 10 436 blocks, structure 0.4 MB, first
  viewport 0.4 ms
- 8 MB — parse 14.7 ms (545 MB/s), 84 725 blocks, structure 3.0 MB, first
  viewport 0.3 ms
- 32 MB — parse 69.3 ms (462 MB/s), 341 868 blocks, structure 12.2 MB, first
  viewport 0.3 ms

Peak resident memory across all three: 73.6 MB. The parse tree costs 38% of the
file it describes, and the time to the first screenful does not grow with the
document, because only the blocks on screen are ever typeset.

## Layout

- `Sources/MarkdownKit` — the parser. Pure Swift, no AppKit, byte-level
- `Sources/MarkioRender` — CoreText typesetting, the virtualized layout and the
  reading view
- `Sources/Markio2` — the app: documents, windows, menus, live reload
- `Sources/markio2-bench` — headless measurement and offscreen rendering
- `documents/` — requirements, design and per-task notes
