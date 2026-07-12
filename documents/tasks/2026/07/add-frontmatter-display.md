---
date: 2026-07-12
status: done
implements:
  - FR-FRONTMATTER
tags:
  - rendering
  - frontmatter
---
# Convenient Frontmatter Display [ANC:task:2026-07-add-frontmatter-display]

## Goal

A leading YAML frontmatter block (`---` … `---` at the very top of a document)
must render as a clean, readable metadata block instead of the current broken
output. Today markdown-it has no frontmatter rule, so `---` on line 1 followed by
`key: value` lines and a closing `---` is parsed as a setext H2 heading plus a
thematic rule — the metadata is mangled and unreadable. Markdown authors (notes,
Hugo/Jekyll/Obsidian, this project's own task files) expect the frontmatter shown
as recognizable metadata, the way GitHub renders it.

## Overview

### Context

Markio renders Markdown in a confined offline `WKWebView` via a vendored
markdown-it pipeline (`Sources/Markio/Resources/template.html`). The pipeline
chains task-lists + a custom `mathPlugin` and uses highlight.js for fenced code.
`html:false` — raw inline HTML is dropped. No YAML parser is vendored, but
highlight.js already ships a YAML grammar (`grmr_yaml`).

Frontmatter is a document-start-only construct: the block is recognized only when
the file's first line is exactly `---` and a later line is exactly `---`. Content
after the closing fence is normal Markdown.

### Current State

- `template.html` builds `md = markdownit({...}).use(taskLists).use(mathPlugin)`.
  There is NO frontmatter rule → leading `---`/`key: value`/`---` renders as a
  setext heading + `<hr>`.
- Find (`collectTextNodes`) walks visible text nodes; any new frontmatter DOM
  (code block or table) is plain text/markup → find keeps working, KaTeX-style
  skips not needed.
- `RenderTests.swift` exercises the real pipeline via `makeLoadedPreview()` +
  `preview.render(md)` + `count(preview, "querySelectorAll(...).length")`.
- Fixture `test-fixtures/render-suite.md` starts with an H1, NOT frontmatter — a
  mid-document `---` block will NOT trigger the rule (doc-start-only), so the
  fixture can only demonstrate frontmatter if a block is added at its very top.

### Affected Surface

Independent scout (`flowai:surface-scout`) ran but returned only clarifying
questions, no surface enumeration (it received the verbatim one-line request per
protocol and judged it underspecified). Enumeration below is the planner's own.

- `Sources/Markio/Resources/template.html` (render pipeline) — covered-by Solution: add frontmatter rule + renderer + CSS.
- `Tests/MarkioTests/RenderTests.swift` — covered-by DoD: new `testFrontmatterRendersAsMetadata`.
- `documents/requirements.md` (SRS) — covered-by DoD: add FR-FRONTMATTER section.
- `documents/design.md` (SDS §3.6 vendor bundle, §5 logic) — covered-by Solution: document the new rule.
- `documents/index.md` — covered-by Solution: FR row.
- `README.md` — covered-by Solution: feature line.
- `test-fixtures/render-suite.md` — deferred — human choice (frontmatter is doc-start-only; adding a top block would change the fixture's leading H1).
- Find (`collectTextNodes` in template.html) — not affected — evidence: template.html:283-307 walks text nodes generically; frontmatter DOM (pre/table) needs no special skip, unlike `.katex`.
- `mathPlugin` / mermaid / highlight interaction — not affected — evidence: frontmatter rule matches only at line 0 before other block rules; body parsing unchanged.

## Definition of Done

- [x] FR-FRONTMATTER: a leading `---`…`---` YAML block renders as a distinct,
      readable metadata block (not a setext heading / `<hr>`); a `---` that is NOT
      at document start stays a normal thematic break; a document with no
      frontmatter is unchanged.
  - Test: `Tests/MarkioTests/RenderTests.swift::testFrontmatterRendersAsMetadata`
  - Evidence: `make test ARGS="--filter RenderTests"`
- [x] FR-FRONTMATTER: add the FR-FRONTMATTER section to SRS with `**Acceptance:**` filled.
  - Test: (doc) `documents/requirements.md` FR-FRONTMATTER section present
  - Evidence: `grep -q 'ANC:fr:frontmatter' documents/requirements.md`

## Solution

Variant A — highlight the leading frontmatter as a distinct YAML block. Zero new
dependency; reuses the vendored highlight.js YAML grammar.

Files:

1. `Sources/Markio/Resources/template.html`
   - Add `frontMatterPlugin(md)` near `mathPlugin`:
     - `frontMatter(state, startLine, endLine, silent)` block rule:
       - Bail unless `startLine === 0 && state.blkIndent === 0 && state.tShift[0] === 0`
         (document-start-only; never fires mid-document or inside a list/quote).
       - Opening line must be ≥3 chars and every char `-` (0x2D).
       - Scan forward for a closing line that is also entirely `-` (≥3), tShift 0.
       - No closing fence found → return false (fall through to normal parsing).
       - On match: `content = state.getLines(startLine+1, closeLine, 0, false)`,
         push `front_matter` token, `state.line = closeLine + 1`.
     - `md.block.ruler.before('table', 'front_matter', frontMatter, { alt: [...] })`
       so it runs before `hr`/`lheading` (which cause the current setext mangling).
     - `md.renderer.rules.front_matter`: highlight `content` via
       `hljs.highlight(content, { language: 'yaml', ignoreIllegals: true }).value`
       (fallback `escapeHtml` when hljs/grammar missing), wrap in
       `<pre class="hljs markio-frontmatter"><code>…</code></pre>`.
   - Chain `.use(frontMatterPlugin)` on the `md` instance.
   - CSS: `.markdown-body pre.markio-frontmatter` — subtle border + rounded corners
     + a small `::before` "frontmatter" caption so metadata is visually distinct
     from an author-written yaml code block. Colors scheme-neutral
     (semi-transparent grey border; hljs theme already themes the background).
2. `Tests/MarkioTests/RenderTests.swift` — `testFrontmatterRendersAsMetadata`
   (RED first): leading frontmatter → `pre.markio-frontmatter` ≥1 with hljs token
   spans, body `# Body` becomes `<h1>` (not swallowed); mid-document `---` block →
   0 frontmatter; plain `---` after a blank line → `<hr>`, 0 frontmatter; no
   frontmatter doc unchanged.
3. `documents/requirements.md` — FR-FRONTMATTER section (added in plan pass).
4. `documents/design.md` — §3.6 vendor bundle + §5 logic mention the rule.
5. `documents/index.md` — FR-FRONTMATTER row.
6. `README.md` — feature line.

Error handling: rule is best-effort — a document that opens with `---` but has no
closing fence simply falls through to today's behavior (no crash, no regression).
hljs failure falls back to escaped raw YAML.

Verification: `make test ARGS="--filter RenderTests"` then full `make check`.

## Follow-ups

- Surface cross-check (`surface-scout`) returned only clarifying questions, not a
  surface list — treated as degraded; planner enumeration used instead.
- Independent critique (`plan-critic`) returned only a transitional message, not a
  consolidated objection list — treated as degraded; planner self-critique used.
- Fixture `render-suite.md` frontmatter demonstration deferred (doc-start-only
  construct conflicts with the fixture's leading H1).
