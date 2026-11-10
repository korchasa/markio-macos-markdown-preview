---
date: 2026-11-10
status: done
implements: [CLI-1, CLI-2, CLI-3]
tags: [cli, mermaid, png]
---

# Draw a Mermaid diagram to a PNG from a terminal

## Goal

Let a person or an agent turn one Mermaid source into a PNG with one command,
from any folder, using the renderer the app draws with. The usual tool for this
starts a browser to draw one picture; Markio already draws the same diagrams
with no web engine, and that ability is locked inside a window.

## Overview

### Context

The owner asked for console rendering of Mermaid to PNG on 2026-11-10. Three
homes for the command were weighed, and the owner chose a program of its own:

- **A mode of the app binary.** A sandboxed app cannot open a path named on its
  command line. A probe built with the app's entitlements confirmed it: reading
  standard input and writing standard output work, opening either path fails
  with a permission error. The mode would also be a store-visible feature that
  reaches readers only through review.
- **The bench harness as it is.** `markio-bench diagram` already draws one
  source, but it lives in `.build/release`, takes positional arguments and
  cannot read standard input.
- **A program of its own (chosen).** Outside the sandbox, so paths work, and
  outside the bundle, so the store build does not change. A mode of the app can
  be added later on top of the same code.

### Current State

- `DocumentRenderer.diagram(source:theme:width:scale:)` in
  `Sources/MarkioRender/DocumentRenderer.swift` parses, lays out, crops and
  draws one Mermaid source into a `CGImage`, and returns `nil` for a source the
  layout does not draw.
- `DocumentView.diagramFile(ordinal:)` is the app's "open this diagram in
  Preview": it draws at `DocumentRenderer.naturalWidth`, picks the density with
  `DocumentRenderer.density(for:)` and writes the PNG with its resolution
  recorded (`DocumentView.writePNG`).
- `Sources/markio-bench/Diagram.swift` is the harness command: fixed 2× scale,
  no resolution recorded, exit 3 on a refusal.
- `scripts/app.ts` builds the bundle and `scripts/install.ts` installs it as
  Markio Dev. Nothing installs a command.

### Constraints

- No web engine (PROD-1); the command uses the app's renderer and nothing else.
- No new dependency: arguments are parsed by hand, as the harness does.
- The store bundle does not change: the command is not copied into
  `.build/Markio.app`.
- Every command is a `deno task` (BUILD-3); the install rides on
  `deno task app`, it is not a new script.
- Two products named `Markio` and `markio` would be one file on a
  case-insensitive volume, so the Swift product is `markio-cli` and only the
  installed copy is called `markio`.

## Definition of Done

- [x] CLI-1: `markio mermaid <input> -o <output>` writes a PNG of the diagram,
      at the size and density the app writes when a diagram is opened on its
      own, with the resolution recorded in the file.
  - Test: `Tests/MarkioCLITests/MermaidCommandTests.swift::testAFileIsDrawnToAPNGAtTwoPixelsPerPoint`
  - Evidence: `swift test --filter MermaidCommandTests/testAFileIsDrawnToAPNGAtTwoPixelsPerPoint`
- [x] CLI-1: `-` reads the source from standard input and writes the picture to
      standard output, through the built program and real pipes.
  - Test: `Tests/MarkioCLITests/MermaidCommandTests.swift::testTheBuiltProgramDrawsFromStandardInputToStandardOutput`
  - Evidence: `swift test --filter MermaidCommandTests/testTheBuiltProgramDrawsFromStandardInputToStandardOutput`
- [x] CLI-1: `--width` and `--scale` change the wrap width and the density,
      and a theme the source names changes the colours.
  - Test: `Tests/MarkioCLITests/MermaidCommandTests.swift::testAWidthIsWhereTheDiagramStopsGrowing`,
    `::testAScaleIsThePixelsInEachPoint`, `::testTheSourceNamesItsOwnColours`
  - Evidence: `swift test --filter MermaidCommandTests`
- [x] CLI-2: a source the layout does not draw exits 3 and writes nothing; an
      unreadable input or an unwritable output exits 1; a command that does not
      parse exits 2 with the usage. Messages go to standard error.
  - Test: `Tests/MarkioCLITests/MermaidCommandTests.swift::testARefusedSourceExitsThreeAndWritesNothing`,
    `::testAMissingInputExitsOne`, `Tests/MarkioCLITests/ArgumentsTests.swift`
  - Evidence: `swift test --filter MarkioCLITests`
- [x] CLI-3: `deno task app` installs the command as `markio` on the search
      path, and `.build/Markio.app` does not contain it.
  - Evidence: `deno task app && markio mermaid test-fixtures/layout/<any>.mmd -o /tmp/x.png && ! find .build/Markio.app -name 'markio-cli'`
- [x] `deno task check` passes.
  - Evidence: `deno task check`

## Solution

1. `documents/requirements.md`: a `CLI` section with CLI-1 – CLI-3, and the
   Scope sentence widened to name the command. `documents/design.md`: the new
   target in "The shape of it" and a section of its own.
2. `MarkioRender`: a public `DocumentRenderer.png(_:density:)` that encodes a
   `CGImage` with its resolution recorded. `DocumentView.writePNG` calls it, so
   the app and the command share one encoder.
3. A new executable target `markio-cli` in `Sources/markio-cli`:
   - `Arguments.swift` — the command line as a value: `mermaid <input> -o
     <output> [--width <points>] [--scale <factor>]`, `--help`, and a usage
     error for anything else. No `--dark`: found while implementing that
     `Theme.forDiagrams` draws every diagram on a white page, so the option
     changed no pixel — in this command and in `markio-bench diagram` alike,
     whose `dark` argument has the same lack of effect. Colours stay with the
     source (PARSE-14).
   - `MermaidCommand.swift` — read the source, measure at one pixel per point
     (a `nil` here is the refusal, exit 3), choose the density, draw, encode,
     write. Input and output go through a small `IO` value so the tests can
     stand in for the standard streams.
   - `main.swift` — hand the arguments over and exit with the answer.
4. A test target `MarkioCLITests`: the arguments, the command against files in
   a temporary folder, and one run of the built program through real pipes.
5. `scripts/install.ts`: `installCommand()` copies `.build/release/markio-cli`
   to `~/.local/bin/markio`; `scripts/app.ts` calls it where it installs the
   dev copy, so `dist` leaves it alone.
6. `README.md`: how to get the command and how to call it.
7. Verify: `deno task check`, then `deno task app` and a real call from another
   folder, with the PNG looked at.
