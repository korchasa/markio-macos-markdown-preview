---
date: 2026-08-08
status: todo
implements:
  - NFR-SCALE
tags: [performance, render, webview, markdown-it]
---
# A 1.2 MB document takes two minutes to render [ANC:task:2026-08-large-document-render-time]

## Goal

Make a multi-megabyte document render in a time a person will wait for, and keep
it there. Today the viewer opens such a file, and nothing appears for about two
minutes.

## Overview

### Context

`RenderTests.testRendersLargeDocumentWithoutHanging` renders 30 000 repetitions
of a heading plus a paragraph — about 1.2 MB — through the real pipeline
(markdown-it + highlight.js + Mermaid) inside `WKWebView`. It passes. It also
accounts for **118 of the 197 seconds** of `deno task check`, which is what
brought it to attention: the gate was slow because the product is slow, not
because the test is written badly.

Measured 2026-08-07 on this machine, same test, only `count:` varied (each
number includes roughly 5 s of build and launch overhead):

- 2 000 repetitions, ~78 KB — 6.8 s
- 8 000 repetitions, ~312 KB — 9.2 s
- 30 000 repetitions, ~1.2 MB — 128 s

Net of overhead that is 1.8 s → 4.2 s → 123 s. Between the last two the input
grows 3.75× and the time grows about 29×. So the cost is not linear in document
size, and somewhere past a few hundred kilobytes it turns sharply. A file twice
as large again would not take four minutes; it would take much longer.

This is the `NFR-SCALE` line in the SRS — "each handles large docs (multi-MB)
without freezing the UI" — met only in the narrow sense that the UI thread is
not blocked. Nothing is on screen either.

### Current State

Not diagnosed. The measurement above says *how bad* and *that it is
super-linear*; it does not say which stage is responsible. The render is one
`callAsyncJavaScript("return await render(md)")` call, so from the Swift side it
is opaque — the whole markdown-it parse, the highlight pass, the Mermaid scan
and the DOM insertion happen behind that single await.

Where the time goes is the first thing to find out. Plausible stages, none of
them confirmed:

- markdown-it parsing itself
- the highlight.js pass over every code block (this document has none, which
  makes it an interesting control)
- one DOM insertion of a very large fragment, and layout for tens of thousands
  of nodes
- the Mermaid scan walking the whole tree
- anything in the pipeline that is quadratic in node count

The test now carries a 180 s budget (added 2026-08-08), so a regression or a
hang fails instead of silently costing minutes. The budget sits above today's
cost rather than at it, and should come down as this task lands.

## Definition of Done

- [ ] The stages of `render()` are measured on the 1.2 MB document, and the log
      says which one holds the time. NFR-SCALE. Evidence: per-stage timings
      recorded here.
- [ ] The super-linear behaviour is explained, not just reduced — a fix that
      makes 1.2 MB fast while leaving the curve intact only moves the wall.
      NFR-SCALE.
- [ ] 1.2 MB renders in a time chosen once the cause is known, and the test's
      budget is lowered to just above it. NFR-SCALE. Evidence:
      `deno task test --filter testRendersLargeDocumentWithoutHanging`.
- [ ] The measurement table above is extended past 1.2 MB, so the curve is
      known rather than extrapolated. NFR-SCALE.

## Solution

Not chosen — the cause is unknown. Deliberately not guessing at one here: the
numbers above are the whole of what is established, and a plan built on a
suspected stage would be a plan built on nothing.
