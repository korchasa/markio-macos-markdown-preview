# Markio 2 — Rules

Read `documents/requirements.md` and `documents/design.md` before changing
anything. This file is the rulebook; it does not repeat them.

## Invariants

These are what the project is. Breaking one is not a trade-off to weigh — it
means the change is wrong.

- **No web engine.** No WebKit, no `WKWebView`, no JavaScript, no HTML in the
  rendering path. `deno task check` fails the build if any of them appears in
  the sources; do not weaken that scan.
- **The source is held once, as bytes.** MarkdownKit works on `[UInt8]` and
  byte ranges. Introducing a `String` on the scan path, or a second copy of the
  document text anywhere, is the one change that undoes the whole point.
- **Nothing is typeset until it is visible.** Any code that walks all blocks at
  open time — to measure, to index, to search — is a defect, however cheap it
  looks on a small file.
- **The app never writes a document it opens.**
- **Signing, packaging and upload happen outside this repository.** `deno task
  dist` produces an unsigned bundle at `.build/Markio2.app`; nothing here
  describes or performs a release, and no workflow uploads anything.

## Commands

Everything is a `deno task`. Add a task, never a shell script or a Makefile
target.

- `deno task check` — the gate: fmt, lint, type-check, build, comment scan,
  web-engine scan, swift-format lint, tests. Run it before you call anything
  done.
- `deno task test` — tests alone
- `deno task app` — build `.build/Markio2.app`
- `deno task dev <file.md>` — build and open a document
- `deno task bench` — parse cost and footprint at 1, 8 and 32 MB
- `deno task fmt` — format Swift and the task scripts
- `deno task dist` — the unsigned bundle
- `deno task clean`

## Verifying a change to rendering

Do not ask someone to look at the screen. Two paths draw through the same code:

```bash
.build/Markio2.app/Contents/MacOS/Markio2 doc.md --capture=/tmp/shot.png
.build/release/markio2-bench snapshot doc.md /tmp/shot.png 900 900 dark 1200
```

`--capture` draws the real window — scroll view, sidebar, bottom bar — and
quits. The bench `snapshot` renders a document offscreen at a given width,
height, appearance and scroll offset. Neither needs screen recording
permission; `screencapture` does, and does not have it.

Performance claims come from `deno task bench` on a **release** build. Do not
quote a debug number.

## Things that cost a session to learn

- **`NSDocument` and Swift 6 isolation.** `NSDocument`'s members are
  main-actor isolated. Opting into `canConcurrentlyReadDocuments` makes AppKit
  construct the document on a background operation queue, and the executor
  check traps with `SIGTRAP` before any window appears. The parse is fast
  enough that concurrent reading buys nothing; leave it off.
- **A window whose content is all pinned edges has a fitting size of nearly
  zero,** and AppKit sizes the window down to a bare title bar. The scroll
  view's floor and preference constraints are load-bearing.
- **A scroll view's document view does not track its width** unless you say so.
  Without `autoresizingMask = [.width]` the reading column has nothing to
  centre inside and sits against the left edge.
- **AppKit asks `applicationShouldOpenUntitledFile` before
  `applicationDidFinishLaunching`,** so a file named on the command line has to
  be known before then or a modal open panel races it.
- **A launch argument's value is not a document.** Passing `-Flag Value` to the
  binary makes AppKit's batched open present a modal error that blocks the run
  loop forever. Launch with a path only.
- **Reading a plist:** always `plutil -extract <key> raw -o - -- <file>`.
  Without `-o -` the value is written back into the file.

## Style

- Comments explain **why**, at the point where the reason is not visible. Do not
  narrate what the next line does.
- Fail fast and clearly: surface a bad state with a message, do not paper over
  it with a default. Do not add fallbacks nobody asked for.
- Match the surrounding code — naming, comment density, idiom.
- Documentation in English. Keep `README.md`, `documents/requirements.md` and
  `documents/design.md` true after every session; stale docs mislead the next
  one.
