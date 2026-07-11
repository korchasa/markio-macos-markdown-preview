---
date: 2026-07-12
status: done
implements:
  - FR-MATH
tags:
  - rendering
  - vendor
---
# Add LaTeX Math Support (KaTeX)

## Goal

Render inline (`$…$`) and block (`$$…$$`) LaTeX math in previewed Markdown, so
technical/scientific notes read faithfully instead of showing raw TeX source.
Fills the last major GFM-adjacent rendering gap after GFM/Mermaid/highlight.

## Overview

### Context

Markio renders Markdown in a confined `WKWebView` via a vendored, offline JS
pipeline (`template.html`: markdown-it → mermaid.run() DOM post-process →
highlight.js). Math was explicitly NOT supported (render-suite fixture §16:
"no plugin — literal text"). KaTeX 0.16.11 is already vendored under
`Sources/Markio/Resources/vendor/katex/`:
- `katex.min.js` — global `katex` with `katex.renderToString(tex, opts)`.
- `katex.css` — self-contained: all fonts inlined as `data:font/woff2;base64`
  URLs, zero external references (verified: no non-`data:` `url()` in the CSS).

This matters because the app now loads the shell via
`ResourceLocator.selfContainedHTML()` (inlines every `vendor/` `<link>`/`<script src>`
into the document, `loadHTMLString(baseURL: nil)`). A relative KaTeX `<link>`/`<script>`
added to `template.html` is auto-inlined by that machinery; the data-URI fonts
mean KaTeX renders correctly with no base URL.

Constraints from AGENTS.md: native-first, minimalism, offline/private (no CDN,
no network at runtime), document-before-code.

External refs: KaTeX 0.16.11 dist (`katex.min.js` + `katex.css`, already vendored).

### Current State

- `template.html` — markdown-it configured `html:false`; `render(markdown)`
  does `el.innerHTML = md.render(...)` then `mermaid.run()` over `pre.mermaid`.
  No math handling; `$…$` passes through as literal escaped text.
- `vendor/katex/` — `katex.min.js` + `katex.css` present, UNTRACKED, not
  referenced by `template.html`.
- `ResourceLocator.selfContainedHTML()` inlines `vendor/` links+scripts
  (uncommitted, separate MAS-blank-preview fix — out of THIS task's scope).
- `RenderTests.swift` — pattern: `makeLoadedPreview()` → `render(md)` →
  `count(preview, "document.querySelectorAll(...).length")`.
- `OfflineTests::testNoNetworkRequests` — asserts `template.html` contains no
  `http://`/`https://`. KaTeX assets are relative → stays green.
- `test-fixtures/render-suite.md` §16 — declares math must stay literal; needs
  wording update once math renders.

### Constraints

- No network at runtime (offline FR). All KaTeX assets vendored + pinned.
- `securityLevel` parity with Mermaid ethos: KaTeX `trust:false`,
  `throwOnError:false` (malformed math never crashes render — NFR Reliability).
- Must not touch code blocks / inline code (`$` inside `` `code` `` stays literal).
- Find (`collectTextNodes`) already skips `svg`; KaTeX emits `.katex` spans with
  MathML + HTML — acceptable that rendered math is not plain-text searchable.
- Do NOT commit the pre-existing uncommitted MAS-fix changes
  (`PreviewController.swift`, `ResourceLocator.swift`, `packaging/*`) as part of
  this feature — separate concern (see Follow-ups / scope question).

### Affected Surface

Scout output (verbatim, unedited):

```
## Surface

- `documents/requirements.md` — add new FR-FORMULAS for inline/block LaTeX rendering — evidence: SRS has FR-GFM, FR-MERMAID, FR-HIGHLIGHT; formulas are a parallel rendering feature
- `documents/design.md` — document formula rendering component (KaTeX integration, appearance support) — evidence: SDS §3 describes markdown parser, Mermaid, highlight.js; formulas fit the same pattern
- `Sources/Markio/Resources/template.html` — inject KaTeX script/initialization, add formula parsing into markdown-it render flow, handle dark/light theming — evidence: template already loads markdown-it, mermaid, highlight.js via <script src="vendor/..."> tags and initializes them in the render() function
- `Sources/Markio/Resources/vendor/katex/` — KaTeX assets already present (katex.min.js, katex.css) — evidence: git status shows ?? Sources/Markio/Resources/vendor/katex/
- `Sources/Markio/ResourceLocator.swift` — selfContainedHTML() will auto-inline katex.css and katex.min.js via the existing inlineVendor() regex matching vendor/* patterns — evidence: function already inlines all <link rel="stylesheet" href="vendor/..."> and <script src="vendor/..."> tags
- `template.html` find logic (collectTextNodes(), search()) — skip formula content (may be SVG or data-attrributes) to avoid mangling MathML/KaTeX rendering, parallel to Mermaid SVG skip — evidence: line 158 already skips <svg> tags; formula output may use similar encapsulation
- `Tests/MarkioTests/RenderTests.swift` — add testFormulaInline() and testFormulaBlock() parallel to testMermaidFlowchartRenders() — evidence: same test class exercises markdown-it pipeline; needs parity for formula acceptance
- `test-fixtures/render-suite.md` — update line 10 (remove "No math plugin") and add LaTeX formula examples (inline $x^2$, block $$E=mc^2$$) — evidence: line 10 explicitly states "No math plugin (LaTeX shown literally)"
- `README.md` — add "Math formulas (LaTeX via KaTeX)" to features list (line 9-15) — evidence: features list covers GFM, Mermaid, highlighting; formulas are a user-visible feature
- `Sources/Markio/DocumentModel.swift` — when appearance changes via setDark(), may need to re-render formulas if KaTeX applies theme-specific colors — evidence: setDark() calls preview.setDark() which re-initializes Mermaid; formula re-theme path may differ
- `Sources/Markio/AGENTS.md` (module docs) — describe formula rendering responsibility if a new component added
- `Package.swift` — vendor/katex already in resources:[] via .copy("Resources/vendor") — evidence: line 19 covers entire vendor tree, no modification needed
- `PreviewController.swift` — may need new bridge method if KaTeX theme differs from Mermaid logic

## Could not rule out
- markdown-it-katex plugin vs plain KaTeX.render() / post-process all `$...$`
- KaTeX sync vs async (mermaid is async; render() may need to await)
- LaTeX delimiters ($...$, $$...$$) vs CommonMark math spec
- dark-mode formula color: KaTeX CSS override vs system color-scheme
```

Union (planner + scout), dispositions for SELECTED variant:

- `Sources/Markio/Resources/vendor/katex/` (katex.min.js, katex.css) — covered-by Solution step 1 (vendor assets, add to git).
- `Sources/Markio/Resources/template.html` — covered-by Solution steps 2+3 (KaTeX `<link>`/`<script>`, math post-process in `render()`, skip `.katex` in `collectTextNodes`).
- `Tests/MarkioTests/RenderTests.swift` — covered-by Solution step 4 (RED acceptance test `testMathRendersWithKatex`).
- `documents/requirements.md` — covered-by Solution step 5 (add FR-MATH + `[ANC:fr:math]`).
- `documents/design.md` — covered-by Solution step 6 (SDS vendor bundle + render pipeline update).
- `test-fixtures/render-suite.md` §16 — covered-by Solution step 7 (update wording + keep examples).
- `README.md` features list — covered-by Solution step 7 (add "Math (LaTeX via KaTeX)").
- `Tests/MarkioTests/OfflineTests.swift` — not affected — asserts only absence of `http(s)` in template; KaTeX refs relative (OfflineTests lines 10-14).
- `ResourceLocator.selfContainedHTML()` inliner — not affected — regex matches any `vendor/…` link/script generically (ResourceLocator diff, linkPattern/scriptPattern).
- `PreviewController.render()` bridge — not affected — calls `render(md)`; math post-process is internal to JS `render()`; KaTeX `renderToString`/auto-render are synchronous → no new await/bridge method.
- `Sources/Markio/DocumentModel.swift` / `PreviewController.setDark` — not affected — KaTeX 0.16 CSS uses `color: inherit`/`currentColor`; math inherits `CanvasText`, which already follows `color-scheme` live. No math re-render on appearance change.
- `Package.swift` — not affected — `.copy("Resources/vendor")` already ships the whole vendor tree (scout evidence line 19).
- `Sources/Markio/AGENTS.md` (module docs) — not affected — no new Swift component; math lives entirely in the vendored JS pipeline.

## Definition of Done

- [x] FR-MATH: inline `$…$` and block `$$…$$` LaTeX render as KaTeX (`.katex` DOM nodes), offline, malformed math renders best-effort without crashing.
  - Test: `Tests/MarkioTests/RenderTests.swift::testMathRendersWithKatex`
  - Evidence: `NO_COLOR=1 make test ARGS="--filter RenderTests/testMathRendersWithKatex"`
- [x] FR-MATH: add FR-MATH section to SRS with `**Acceptance:**` field filled + `[ANC:fr:math]`.
  - Test: (doc) — presence of `### 3.x FR-MATH … [ANC:fr:math]` in `documents/requirements.md`
  - Evidence: `NO_COLOR=1 grep -q 'ANC:fr:math' documents/requirements.md`
- [x] FR-MATH: offline contract preserved — no network URL introduced.
  - Test: `Tests/MarkioTests/OfflineTests.swift::testNoNetworkRequests`
  - Evidence: `NO_COLOR=1 make test ARGS="--filter OfflineTests/testNoNetworkRequests"`

## Solution

Variant B — parse-time markdown-it math rule + already-vendored
`katex.renderToString`. Synchronous (unlike Mermaid); no new fetch/dependency.

### Pre-step (scope 2C): commit the MAS-blank-preview fix separately FIRST

Before any formula work: verify baseline green (`make check`), then commit the
pre-existing, complete MAS fix as its OWN commit (not part of formula work),
with matching doc-sync so docs stop lying:
- Files: `PreviewController.swift`, `ResourceLocator.swift`,
  `packaging/Info.plist`, `packaging/Markio.entitlements`.
- Doc-sync: SDS §3.4 (WebViewHost) — `loadFileURL` → `selfContainedHTML()` +
  `loadHTMLString(baseURL:nil)`; SDS §3.6 (vendor) — inlined self-contained
  shell; record the `network.client`-entitlement rationale (WebContent process).
- Commit type: `fix(webview): render via self-contained HTML …` (separate SHA).

### Formula work

1. **Vendor assets** — `katex.min.js` + `katex.css` (0.16.11) already present
   under `vendor/katex/`; `git add` them in the formula commit. No auto-render
   file, no network fetch (Variant B renders at parse time).
2. **`template.html` — load KaTeX**: add `<link rel="stylesheet"
   href="vendor/katex/katex.css">` and `<script src="vendor/katex/katex.min.js">`
   to `<head>` (auto-inlined by `selfContainedHTML()`; relative → OfflineTests
   stays green).
3. **`template.html` — parse-time math rule**: embed a compact markdown-it plugin
   (`math_inline` for `$…$`, `math_block` for `$$…$$`), registered before the
   emphasis rules, and `.use()` it on `md`. Renderer → `katex.renderToString(tex,
   { throwOnError: false, trust: false, displayMode })`. Delimiter heuristic
   (standard): opening `$` not followed by space/digit-flanking rules; escaped
   `\$` ignored; `$` inside code spans never reaches the rule (separate token).
   Malformed math: `throwOnError:false` → KaTeX emits an error node; never throws
   (NFR Reliability). `trust:false` + `html:false` already set → no raw HTML/JS
   injection via `\href`/`\htmlClass`. **Money guard** (`isValidDelim`, standard
   markdown-it-katex): closing `$` must not be immediately followed by a digit,
   so `$5 and $10` stays literal text, not math.
4. **`template.html` — find skip**: in `collectTextNodes`, reject nodes whose
   ancestor carries class `katex` (parallel to the existing `svg` skip) so find
   never splices `<mark>` into KaTeX-rendered spans.
5. **RED test** `Tests/MarkioTests/RenderTests.swift::testMathRendersWithKatex`:
   render inline `$E = mc^2$` + block `$$\int_0^\infty e^{-x^2}\,dx$$`; assert
   `#content .katex` count ≥ 2 and `#content .katex-display` count ≥ 1 (block).
   Money guard: render `Pay $5 and $10` and assert `#content .katex` count == 0
   (stays literal). Then render malformed `$\frac{$` and assert `#content` still
   present (no crash).
6. **SRS** `documents/requirements.md`: add `### 3.12 FR-MATH: Render LaTeX math
   [ANC:fr:math]` (Desc/Scenario/Acceptance/Status=[x] after GREEN) + a
   `**Tasks:**` back-pointer to this task. Add FR-MATH to SDS §1 Rel-to-SRS ref
   list.
7. **SDS** `documents/design.md`: §3.6 vendor bundle — add KaTeX 0.16.11
   (katex.min.js + katex.css, fonts inlined data-URI) + the parse-time math rule;
   §5 Logic — extend render algo (md math rule → `katex.renderToString`). Add
   `render(markdown)` math note.
8. **Fixture + README**: `test-fixtures/render-suite.md` §16 + line 10 — reword
   "no plugin/literal" → "renders via KaTeX"; keep the example formulas.
   `README.md` features — add "Math formulas (LaTeX via KaTeX, offline)".
9. **CHECK**: `NO_COLOR=1 make check` exits 0 (build + comment-scan + swift-format
   lint + full test suite).

### Verification commands
- `NO_COLOR=1 make test ARGS="--filter RenderTests/testMathRendersWithKatex"`
- `NO_COLOR=1 make test ARGS="--filter OfflineTests/testNoNetworkRequests"`
- `NO_COLOR=1 grep -q 'ANC:fr:math' documents/requirements.md`
- `NO_COLOR=1 make check`

## Follow-ups

- Scope decision (user, 2C): the pre-existing MAS-blank-preview fix
  (`PreviewController.swift`, `ResourceLocator.swift`, `packaging/Info.plist`,
  `packaging/Markio.entitlements`) is committed SEPARATELY and FIRST, with its
  own doc-sync (SDS §3.4/§3.6), before the formula work — never folded into the
  formula commit.
- Independent critique (`plan-critic`) ran but returned no consolidated objection
  list (agent emitted only transitional text); its visible tool-work corroborated
  the plan's facts. Fell back to self-critique — sole applied finding: `$`-money
  guard (`isValidDelim`, no-digit-after-close) + a literal-`$5/$10` test assertion.
