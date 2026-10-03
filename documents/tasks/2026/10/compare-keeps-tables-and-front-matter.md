---
date: 2026-10-02
status: done
implements: [VIEW-17, VIEW-26, PARSE-3]
tags: [compare, tables, front-matter]
related_tasks: ["[reload-and-compare-keep-the-place](reload-and-compare-keep-the-place.md)"]
---

# A comparison breaks changed tables and front matter apart

## Goal

Show a changed table as a table, and changed front matter as one front-matter
block, in both the inline and the side-by-side comparison. A report rewritten by
an agent usually changes in exactly these places: a results table and the
status fields at its head. The comparison is meant to show those changes, and
right now that is where it falls apart.

## Overview

### Context

Found on 2026-10-02 while recording a store preview of the app, comparing three
versions of one report whose results table and front matter changed between
versions:

- In both comparison modes, the changed table rows are drawn on the red and
  green bands as raw text — `| Payments | 96 | 4.92 s | passed |` — outside the
  table, which stops at the last unchanged row.
- The inline comparison shows the front matter twice, with no bands on it.
- Side by side, each column's front matter has an empty line inside it, between
  the first field and the changed ones.

### Current State

`CompareEngine` diffs the two versions line by line and builds one source out of
both (`merge`), or two (`split`). `Builder.add` puts a blank line between runs of
different origin (`Sources/MarkioRender/CompareEngine.swift`), so that a removed
paragraph and the one that replaced it parse as two blocks. That is right for
paragraphs (`testTheOldAndNewTextOfAParagraphStayTwoBlocks`).

Inside a construct whose lines must stay together, the blank line ends the
construct. A table stops at the blank line and the changed rows that follow
parse as a paragraph. A front-matter block (PARSE-3) loses its closing fence, so
the parser no longer reads it as front matter. No test compares a table or front
matter.

### Constraints

- The engine stays line-based for prose. Word-level diff is out of scope.
- The parser, layout, find and outline keep working on ordinary Markdown and
  know nothing about comparison.
- Nothing is typeset until it is visible. Scanning the block structure of both
  versions is parsing, which a comparison already does for the merged source.

## Definition of Done

- [x] VIEW-17: a table whose rows changed is shown inline as the old table,
      marked removed, followed by the new table, marked added. Both are parsed as
      tables, and no `|` row is left as a paragraph.
  - Test: `Tests/MarkioRenderTests/CompareEngineTests.swift::testABlockThatOnlyReadsWholeIsComparedWhole`
    (the `.table` case, inline half)
  - Evidence: `swift test --filter CompareEngineTests/testABlockThatOnlyReadsWholeIsComparedWhole`
- [x] VIEW-26: side by side, each column holds its version of the table as one
      table, marked.
  - Test: the same test, `.table` case, `split` half
  - Evidence: `swift test --filter CompareEngineTests/testABlockThatOnlyReadsWholeIsComparedWhole`
- [x] PARSE-3, VIEW-17: a changed front-matter field leaves exactly one
      front-matter block on each side, marked, with no blank line inside it.
      Side by side, each column opens on its own front matter. Inline, the old
      copy stays front matter at the top and the new one follows it as a fenced
      `yaml` block, marked added: front matter exists only on a file's first
      line, so a second front-matter block cannot be expressed in one source.
  - Test: the same test, `.frontMatter` case;
    `CompareEngineTests.swift::testTheSecondFrontMatterIsFencedAsYAML`
  - Evidence: `swift test --filter CompareEngineTests`
- [x] Paragraph behaviour is unchanged: the existing `CompareEngineTests` pass as
      they are.
  - Evidence: `swift test --filter CompareEngineTests`
- [x] The whole gate passes.
  - Evidence: `deno task check` (2026-10-03, commit `5732b4a`; CI green on `be4c109`)

## Solution

1. Before building the result, scan both versions into block byte ranges with
   the block scanner the parser already uses, and keep the ranges of tables and
   front matter.
2. Widen every changed run of lines that touches such a block to the whole
   block, on both sides: the baseline's table becomes one removed run and the
   current table one added run, each complete with its header and delimiter row.
   The existing blank-line separation then falls between whole tables, where it
   belongs.
3. Front matter gets the same treatment, so each side keeps its fences.
4. Accept the cost knowingly: a one-cell change tints the whole table. Marking
   single rows inside one table would need marks in the table layout, which is a
   separate task if the whole-table tint turns out to be too coarse.
5. Add the three tests above using a small report with a results table and front
   matter, asserting on the parsed blocks of `merge` and `split`, not on pixels.

## Outcome

Implemented in `5732b4a` more broadly than planned: every block that only reads
whole — fenced and indented code, tables, HTML blocks, front matter, and a
paragraph holding a `$$` formula across lines — is one unit of the diff, taken
from the parser (`CompareEngine.units(of:lineCount:)`). Prose stays line by
line. See "Comparing versions" in `documents/design.md`.
