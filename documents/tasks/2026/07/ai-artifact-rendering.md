---
date: 2026-07-14
status: done
implements:
  - FR-AI-ARTIFACTS
tags: [rendering, engine, backlog-item-8]
related_tasks:
  - [code-copy-button](code-copy-button.md)
  - [find-upgrades](find-upgrades.md)
  - [quicklook-extension](quicklook-extension.md)
---
# AI-artifact rendering (ANSI colors, diff backgrounds, long-token wrap) [ANC:task:2026-07-ai-artifact-rendering]

## Goal

Deepen the "native reader for agent output" positioning (backlog item 8, 4.3(a)
differentiation): the artifacts AI agents actually emit into Markdown — colored
terminal logs, diffs, long paths/tokens — render cleanly instead of as raw
`\x1b[31m` garbage, flat monochrome diffs, and layout-breaking overflow.

## Overview

### Context

- Backlog: `daily-use-feature-backlog.md` item 8 (Tier 2). Items 1–7 already
  shipped on `feature/daily-use-wave1`. Backlog file itself must NOT be edited.
- All rendering lives in the shared engine (`MarkioEngine` target since the
  Quick Look feature): `Sources/MarkioEngine/Resources/template.html` (markdown-it
  config + highlight callback + post-render passes + inline CSS) and
  `Resources/vendor/*`. Both render surfaces (app `PreviewController`, Quick Look
  `QuickLookRenderHost`) load the same self-contained document via
  `ResourceLocator.selfContainedHTML()` — one change serves both.
- Offline constraint: no network, vendored assets only. Task explicitly prefers
  a small hand-rolled ANSI-SGR-subset parser over vendoring a library, with the
  supported subset documented honestly.
- Empirical findings (verified on HEAD `bbf6d71`):
  - Vendored highlight.js 11.10.0 common bundle DOES include the `diff` grammar
    (`grmr_diff`, aliases `patch`): `addition`/`deletion` spans match `^\+`/`^-`
    to end-of-line (newline NOT inside the span). The github themes already
    color them (light: `#22863a` on `#f0fff4` / dark: `#aff5b4` on `#033a16`)
    but the background hugs the text, not the full line.
  - `github-markdown.min.css` sets `word-wrap:break-word` on `.markdown-body`
    but `word-wrap:normal` + `overflow:auto` on `pre` (scroll, GitHub-style).
    Long unbroken tokens in table cells and autolinks can still stretch the
    layout; inline `<code>` relies on the generic break-word.
  - The render output passes DOMPurify (`USE_PROFILES {html, mathMl}`,
    `FORBID_TAGS ['style']`) BEFORE DOM insertion — any ANSI-generated markup
    must survive that gate (class attributes survive; inline `style`
    attributes are allowed by DOMPurify default but must be test-verified).

### Current State

- `template.html` highlight callback: `mermaid` → `pre.mermaid`; known hljs
  language → highlighted `pre.hljs` (+ `data-lang`); otherwise escaped text in
  `pre.hljs`. ANSI escapes render as literal `[31m…` garbage (the ESC byte is
  invisible; the remainder pollutes the text).
- ```` ```diff ```` fences highlight via hljs `diff` grammar: green/red text
  with a text-hugging background — no full-width line backgrounds.
- `decorateCodeBlocks()` wraps each `pre.hljs:not(.markio-frontmatter)` for the
  hover Copy UI; the delegated copy click posts `code.textContent` (markup-free
  by construction) to `markioCopy`.
- Find (`collectTextNodes` + two-phase search) walks text nodes under
  `#content`, tolerating matches that cross inline spans (hljs tokens) — new
  ANSI spans are structurally identical to hljs token spans.

### Constraints

- Offline; no new external dependency unless truly needed (prefer hand-rolled
  SGR-subset parser). No network, no CDN.
- Engine-only change (template.html CSS/JS); no native shell surface, no new
  message handlers, no settings.
- Priority order: nativeness > minimalism > UX. Read-only viewer scope.
- `make check` green before review; TDD (acceptance tests in
  `Tests/MarkioTests/RenderTests.swift` first).
- Copy button semantics ([REF:fr:code-copy | FR-CODE-COPY]) and find
  ([REF:fr:find | FR-FIND]) must keep working on ANSI/diff blocks.
- Run `make fmt` before `make check` (long inline strings in RenderTests).

### Affected Surface

Scout output (verbatim):

```
## Surface

- **Template HTML rendering engine** — Core location where code blocks are highlighted and ANSI support must be added — `/Users/korchasa/www/business/markview/Sources/MarkioEngine/Resources/template.html` lines 371–387 (highlight callback), 429–481 (decorateCodeBlocks), 11–130 (CSS for code styling).
- **Highlight.js vendor library** — Provides syntax highlighting and already has diff language support; ANSI color support would need to be checked or added — `/Users/korchasa/www/business/markview/Sources/MarkioEngine/Resources/vendor/highlight/highlight.min.js`.
- **CSS rules for code blocks** — Currently in template.html inline `<style>`; requires new rules for diff colors (red/green lines) and ANSI color classes — `/Users/korchasa/www/business/markview/Sources/MarkioEngine/Resources/template.html` lines 65–93 (code-block wrapper and UI styling).
- **RenderTests.swift** — Existing test suite exercising markdown-it + highlight.js pipeline; new tests needed for ANSI rendering, diff styling, and long-path wrapping — `/Users/korchasa/www/business/markview/Tests/MarkioTests/RenderTests.swift` (all test functions depend on the highlight callback).
- **CodeCopyTests.swift** — Tests copy-button functionality on code blocks; must verify that copied raw code strips ANSI codes (if that is desired) — `/Users/korchasa/www/business/markview/Tests/MarkioTests/CodeCopyTests.swift` lines 20–43 (testCopyButtonCopiesRawCode).
- **PreviewController native↔web bridge** — Marshals render calls to the page; no changes anticipated unless ANSI processing happens natively before render — `/Users/korchasa/www/business/markview/Sources/Markio/PreviewController.swift` lines 97–107 (render method).
- **Quick Look extension rendering** — Uses the same MarkioEngine bundle (template.html + vendor assets); any code-highlighting changes automatically apply here — `/Users/korchasa/www/business/markview/Sources/MarkioQuickLook/QuickLookRenderHost.swift` (all rendering delegated to shared engine).
- **Find text-node collection** — Scans visible text nodes for search; ANSI escape sequences must not corrupt the text map or match logic — `/Users/korchasa/www/business/markview/Sources/MarkioEngine/Resources/template.html` lines 684–713 (collectTextNodes function, includes block-boundary and element-filter logic).
- **Find search and highlighting** — Wraps matches in `<mark>` elements; must not match ANSI sequences or diff markers themselves — `/Users/korchasa/www/business/markview/Sources/MarkioEngine/Resources/template.html` lines 743–776 (search function and match wrapping).
- **DOMPurify sanitization gate** — All rendered HTML passes through allowlist sanitization before DOM insertion; ANSI-as-HTML spans (if chosen) must survive the gate — `/Users/korchasa/www/business/markview/Sources/MarkioEngine/Resources/template.html` lines 158–171 (sanitizeHtml function, uses DOMPurify profiles html + mathMl).
- **Frontmatter YAML rendering** — Uses highlight.js yaml grammar; if YAML contains ANSI codes, they would be highlighted the same way — `/Users/korchasa/www/business/markview/Sources/MarkioEngine/Resources/template.html` lines 348–363 (frontMatterPlugin renderer rule).
- **Copy-button message handler** — Copies raw code text to pasteboard via `markioCopy` page→native handler; must strip ANSI sequences from the code before posting (if raw code should be ANSI-free) — `/Users/korchasa/www/business/markview/Sources/MarkioEngine/Resources/template.html` lines 464–481 (delegated click listener, posts code.textContent).
- **ResourceLocator asset bundling** — Inlines template.html and vendor/* into a self-contained document; any new ANSI library must be vendored and added to the inline pass — `/Users/korchasa/www/business/markview/Sources/MarkioEngine/ResourceLocator.swift` (self-contained HTML generation).
- **SRS functional requirements** — No FR for AI-artifact rendering exists yet; item 8 (ANSI codes, diff styling, path wrapping) must be added as a new FR with acceptance tests — `/Users/korchasa/www/business/markview/documents/requirements.md` section 3 (Functional Reqs).
- **SDS design documentation** — Component §3.6 (Vendored web bundle) describes template, highlight.js, and rendering rules; must document ANSI color handling and diff-block CSS after implementation — `/Users/korchasa/www/business/markview/documents/design.md` lines 111–119.
- **Markdown-it parser configuration** — Currently configured with `html:true` and a highlight callback; the callback is where language-specific logic (diff branch colors, ANSI translation) lives — `/Users/korchasa/www/business/markview/Sources/MarkioEngine/Resources/template.html` lines 366–389 (md config and highlight function).
- **App shell and Quick Look both render code blocks** — Two render targets (main app via DocumentModel → PreviewController; Quick Look via QuickLookRenderHost) use the same template and vendor pipeline; changes to template apply to both — Parallel implementations at `/Users/korchasa/www/business/markview/Sources/Markio/DocumentModel.swift` (calls PreviewController.render) and `/Users/korchasa/www/business/markview/Sources/MarkioQuickLook/QuickLookRenderHost.swift`.

## Could not rule out

- Whether highlight.js's diff language mode is enabled in the current build.
- Whether ANSI handling should live in the markdown-it highlight callback or a post-render pass; tag-based vs content-based detection.
- Whether copied code text should strip ANSI sequences or preserve them.
- Whether long-path wrapping is a CSS property or requires active line-breaking.
- Whether the Copy button should be skipped on ANSI/diff blocks.
```

Dispositions (union of scout list and own enumeration):

- template.html highlight callback + CSS + decorateCodeBlocks — covered-by Solution (primary change site)
- Vendored highlight.js — not affected — `grmr_diff` grammar confirmed present in the common bundle (grep `grmr_diff:` in `vendor/highlight/highlight.min.js`); no ANSI grammar needed (hand-rolled parser)
- RenderTests.swift — covered-by DoD acceptance tests
- CodeCopyTests.swift / copy semantics on ANSI blocks — covered-by Solution (copy behavior decided at variant selection; regression covered by existing `CodeCopyTests` run in `make check`)
- PreviewController bridge — not affected — ANSI processing is page-side; no new messages, no signature change (`Sources/Markio/PreviewController.swift` untouched)
- Quick Look render host — covered-by shared engine (same `template.html`); no appex-side change (`Sources/MarkioQuickLook/*` untouched)
- Find (collectTextNodes/search) — covered-by DoD (find-over-ANSI-spans acceptance assertion); ANSI spans are inline spans exactly like hljs token spans, which two-phase search already crosses
- DOMPurify gate — covered-by DoD (test asserts ANSI spans + attributes survive sanitize)
- Frontmatter renderer — not affected — frontmatter box keeps the plain YAML path (ESC in frontmatter YAML out of scope; escaped text renders as before)
- markioCopy handler (native side) — not affected — payload stays a plain string (`PreviewController` validation unchanged)
- ResourceLocator inlining — not affected — no new vendor file in the selected approach (hand-rolled parser lives inside template.html); would change only under Variant C
- SRS — covered-by DoD item "add FR-AI-ARTIFACTS section"
- SDS §3.6 — covered-by DoD item "SDS documents the ANSI subset + diff CSS + wrap rules"
- documents/index.md — covered-by plan step 5b (row added)
- Makefile / build — not affected — no target changes; tests run under existing `make check`

## Definition of Done

- [x] FR-AI-ARTIFACTS (a): ANSI SGR color/style sequences inside fenced code
  blocks render as colored/styled spans; no raw escape residue (`[31m`…)
  visible in the rendered text; non-SGR escape sequences are stripped; a
  truecolor (`38;2;r;g;b`) span with an inline `style` attribute explicitly
  survives the DOMPurify gate (silent truecolor failure is the risk).
  - Test: `Tests/MarkioTests/RenderTests.swift::testANSIEscapesRenderAsColors`
  - Evidence: `make test ARGS="--filter RenderTests"`
- [x] FR-AI-ARTIFACTS (b): ```` ```diff ```` fenced blocks show full-width
  green/red line backgrounds for `+`/`-` lines (hunk headers styled as meta),
  in both light and dark appearance; on a horizontally scrolling block the
  background covers the full scrolled line width (span width ≥ the pre's
  scrollable content width), not just the visible viewport.
  - Test: `Tests/MarkioTests/RenderTests.swift::testDiffBlockLineBackgrounds`
  - Evidence: `make test ARGS="--filter RenderTests"`
- [x] FR-AI-ARTIFACTS (c): a long unbroken token (path/hash/URL) in prose,
  inline code, or a table cell never widens the layout beyond the content
  column (it wraps); code blocks keep scrolling horizontally (no layout break).
  - Test: `Tests/MarkioTests/RenderTests.swift::testLongTokensDoNotBreakLayout`
  - Evidence: `make test ARGS="--filter RenderTests"`
- [x] FR-AI-ARTIFACTS: find works over ANSI-rendered blocks — a query crossing
  ANSI span boundaries still matches (verifies the two-phase text map is not
  corrupted by ANSI spans); copy button present on ANSI/diff blocks and its
  payload (`code.textContent`) is escape-free.
  - Test: `Tests/MarkioTests/RenderTests.swift::testANSIBlocksKeepFindAndCopy`
  - Evidence: `make test ARGS="--filter RenderTests"`
- [x] Add FR-AI-ARTIFACTS section to SRS with `**Acceptance:**` filled, plus
  `[ANC:fr:ai-artifacts]` anchor, `**Tasks:**` back-pointer to this task, and
  SDS §3.6 updated (ANSI subset documented honestly, diff CSS, wrap rules).
  - Test: n/a (docs)
  - Evidence: `grep -q 'ANC:fr:ai-artifacts' documents/requirements.md`
- [x] Full project check green.
  - Test: whole suite
  - Evidence: `make check`

## Solution

Selected: **Variant B** — content-based ANSI detection + hand-rolled SGR-subset
parser; diff via CSS over existing hljs spans; wrapping via CSS. Copy on ANSI
blocks copies the visible text (escape codes stripped) — decision confirmed at
variant selection. All changes live in
`Sources/MarkioEngine/Resources/template.html` (shared engine → app + Quick
Look) and `Tests/MarkioTests/RenderTests.swift` + docs.

### Step 1 — RED: acceptance tests (RenderTests.swift)

- `testANSIEscapesRenderAsColors`: render a fence containing
  `\u{1B}[31mERROR\u{1B}[0m`, bold+color combo, a 256-color (`38;5;196`) and a
  truecolor (`38;2;255;0;0`) sequence, plus a non-SGR CSI (`\u{1B}[2K`) and an
  OSC title sequence. Assert: `pre.markio-ansi` present; a span with class
  `ansi-fg-1` exists; a span with inline `style` color survives sanitize;
  rendered `textContent` contains neither `\u{1B}` nor `[31m` nor `[2K`.
- `testDiffBlockLineBackgrounds`: render a ```` ```diff ```` fence with `+`/`-`
  /`@@` lines. Assert `.hljs-addition`/`.hljs-deletion` spans exist, computed
  `display == inline-block`, non-transparent `background-color`.
- `testLongTokensDoNotBreakLayout`: render a 300-char unbroken token in a
  paragraph, in inline code, in a table cell, and in a fenced code block.
  Assert `document.documentElement.scrollWidth <= window.innerWidth` (no
  horizontal page overflow) AND the `<pre>` still scrolls
  (`pre.scrollWidth > pre.clientWidth`) — code blocks scroll, never wrap.
- `testANSIBlocksKeepFindAndCopy`: on an ANSI block whose colored spans split
  a word (`\u{1B}[31mAB\u{1B}[32mCD\u{1B}[0m`), `search('abcd')` finds 1 match
  (two-phase search crosses span boundaries); `button.markio-copy` exists in
  the block wrapper; `code.textContent` is escape-free (copy payload = visible
  text by construction).

Run `make test ARGS="--filter RenderTests"` → the four MUST fail (missing
`markio-ansi` class etc.).

### Step 2 — GREEN: template.html

1. **ANSI branch in the markdown-it `highlight` callback** (before the hljs
   path, after the mermaid path): if `str` contains ESC (U+001B) followed by `[` → return
   `<pre class="hljs markio-ansi"[data-lang]><code>` + `renderAnsi(str)`.
   Rationale: agent logs are not a programming language — ANSI rendering
   replaces syntax highlight for such blocks regardless of tag. Marker comment
   `[REF:fr:ai-artifacts]`.
2. **`renderAnsi(str)`** — hand-rolled SGR-subset renderer. One regex scan
   over `ESC`-introduced sequences: CSI ESC + `[` + params + final byte (final byte `m`
   → SGR state update; any other final byte → strip), OSC
   ESC + `]` … BEL or ESC-backslash terminated → strip, other ESC + one char →
   strip. Text runs are `escapeHtml`-ed and wrapped in one `<span>` when state
   is non-default. **Supported SGR subset (documented in SDS):** `0` reset;
   `1` bold, `2` dim, `3` italic, `4` underline, `9` strikethrough; off codes
   `22/23/24/29`; fg `30–37`, `90–97`, default `39`; bg `40–47`, `100–107`,
   default `49`; 256-color `38;5;n` / `48;5;n`; truecolor `38;2;r;g;b` /
   `48;2;r;g;b`. Everything else (incl. inverse `7`, blink, cursor movement,
   erase, OSC) is ignored/stripped, never displayed raw. Named colors 0–15 →
   classes `ansi-fg-N`/`ansi-bg-N`; 256-cube/grayscale and truecolor → inline
   `style` (must survive DOMPurify — asserted by test).
3. **CSS**: (a) 16-color ANSI palette classes for light + dark (VS Code
   terminal palettes; dark override via `@media (prefers-color-scheme: dark)`,
   same mechanism as the hljs theme `<link media=…>`); style classes for
   bold/dim/italic/underline/strike. (b) Diff full-width line backgrounds:
   `pre.hljs code .hljs-addition, … .hljs-deletion { display: inline-block;
   min-width: 100%; box-sizing: border-box; }` — colors come from the existing
   hljs github themes (light `#f0fff4`/red pair, dark `#033a16`/…), so the
   backgrounds follow appearance for free; `min-width:100%` (not `width`)
   keeps the background covering horizontally scrolled long lines. (c) Wrap:
   `overflow-wrap: anywhere` on inline code, links, and table cells (NOT on
   `pre` — `white-space: pre` + `overflow: auto` keeps code scrolling).
   Targeted, because github-markdown-css's `word-wrap: break-word` does not
   shrink a table cell's min-content width; `anywhere` does.

### Step 3 — REFACTOR + docs

- SDS §3.6: add "ANSI rule" (detection, honest subset list, palette source,
  copy-visible-text semantics), "diff rule" (CSS-only, min-width:100%
  decision), "wrap rule" (targeted overflow-wrap:anywhere). Update §5 Algos
  render pipeline sentence.
- FR-AI-ARTIFACTS Desc: add the copy-visible-text sentence (Copy on ANSI
  blocks yields escape-free visible text — deliberate deviation from
  byte-exact fence content, decided at variant selection).
- Flip FR Status/DoD checkboxes only when tests pass.

### Step 4 — CHECK

`make fmt` (long inline test strings), then `make check` (build,
comment-scan, format lint, full suite). Zero warnings baseline.

### Error handling

Parser is total: any malformed/unterminated escape sequence consumes just the
ESC byte (stripped) and continues — render never throws (NFR Reliability).
Unknown SGR params are skipped without failing the whole sequence.

### Verification commands

- `make test ARGS="--filter RenderTests"` — acceptance
- `make check` — full gate
- `grep -n 'REF:fr:ai-artifacts' Sources/MarkioEngine/Resources/template.html` — code marker

## Follow-ups

- Plan-critic objections triaged 2026-07-14: all 6 applied (SRS acceptance
  completed to 4 tests; copy-visible-text + content-based-detection trade-off
  written into FR Desc; DoD strengthened: truecolor inline-style survival,
  scrolled-width diff background, find text-map integrity; SDS §3.6 must state
  the "tagged fence with ESC loses language highlighting" trade-off).
- Deferred (out of v1 scope, recorded at variant selection): SGR inverse (7),
  blink, OSC-8 hyperlinks, byte-exact copy of ANSI fences via data attribute
  (Variant C territory).
