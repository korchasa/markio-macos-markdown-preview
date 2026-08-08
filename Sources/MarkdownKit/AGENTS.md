# MarkdownKit

The parser. Pure Swift: no AppKit, no fonts, no theme, no knowledge that a
screen exists. Everything downstream depends on that staying true.

## Rules

- Work on `[UInt8]` and `ByteRange`. `String` appears in exactly one place —
  `Document.content(of:)`, called per visible block. Anywhere else on the scan
  path it is a defect: grapheme-aware types allocate and normalize, and at
  32 MB that is the entire budget.
- Every delimiter Markdown cares about is ASCII, and ASCII bytes never occur
  inside a multi-byte UTF-8 sequence. That is why byte scanning is safe — keep
  it true by never comparing against a non-ASCII byte.
- `Block` is 24 bytes and `ByteRange` is two `Int32`. Adding a field to `Block`
  costs a fraction of every document. Justify it in the type's doc comment or
  find another place for the data.
- The block scan is one pass over lines; inline parsing is per block, on
  demand. Do not add a pass that walks the whole document.

## Where the bodies are buried

- **Indented code**: measure the indent with no cap, then branch on `>= 4`.
  Capping the measurement makes indented code invisible.
- **List frames always match** in the container phase, so anything that follows
  a list — a block quote, a new leaf — must close the dangling list first.
- **Loose lists**: a pending blank marks a list loose only where content really
  continues *that* list. A new list after a blank starts tight.
- **Dropping link syntax is done by byte offset**, not by token kind. Each
  token records where it was emitted from; kind-based dropping misses the
  tokenizations that do not map one-to-one onto the syntax, and the destination
  prints twice.
- **`unescaped()` works in byte space.** A character-based version corrupts
  multi-byte UTF-8.
- **`[^1]: text` is a footnote, and it has the shape of a link reference
  definition.** `ReferenceCollector` refuses labels starting with a caret; drop
  that guard and a one-word note is swallowed as a definition, line and all, so
  the note simply disappears from the document.
- **`<details>` is recognised before the HTML-block branch**, or the section
  becomes one raw-HTML block ending at a blank line and the reader is shown the
  source of their own text. Only the whole-line spellings are taken: a
  `<details>` inside a sentence is prose about HTML.
- **Whether `[^label]` is a reference is a fact about the document**, not about
  the block. The labels are handed to `InlineParser.parse`; a caller that
  forgets them gets literal brackets, which is also the right answer for a
  block with no document behind it.

## Tests

`Tests/MarkdownKitTests` dumps structure (`TreeDump`) and inline runs
(`InlineDump`) as text and compares. A new construct gets a dump test; a fixed
bug gets the input that broke it.
