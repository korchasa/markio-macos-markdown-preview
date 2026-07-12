---
date: "2026-07-12"
status: done
implements:
  - FR-INLINE-HTML
tags:
  - rendering
  - security
  - vendor
related_tasks:
  - 2026/07/add-math-support.md
  - 2026/07/add-frontmatter-display.md
---
# Render Inline HTML via Sanitizer + Tag Allowlist [ANC:task:2026-07-render-inline-html-sanitized]

## Goal

Raw inline HTML in Markdown documents (e.g. `<table>` with `rowspan`/`colspan`
that plain GFM tables cannot express) must render as HTML, the way GitHub
renders it, instead of showing up as escaped literal text. The user's trigger
document is `support-matrix.md` (an ai-ide-sync doc): a generated migration
matrix built as one raw `<table>` — today Markio shows the whole tag soup as
text. Safety is preserved by sanitizing the HTML through a tag/attribute
allowlist before it reaches the DOM ("санитайзер + список тегов" — the
user-selected direction over rewriting documents as GFM tables).

## Overview

### Context

- Markio renders Markdown in a confined offline `WKWebView` via a vendored
  pipeline in `Sources/Markio/Resources/template.html`: markdown-it 14.1.0 →
  `#content.innerHTML` → `mermaid.run()` → (highlight done at parse time).
- Root cause of the reported behavior: `template.html` initializes
  `markdownit({ html: false, ... })` — markdown-it escapes every raw HTML tag
  into text. This was a deliberate v1 safety choice (SDS §3.6: "markdown-it
  runs with `html:false` (read-only viewer drops raw inline HTML)").
- GitHub's reference behavior: raw HTML passes through a sanitizer with an
  element/attribute allowlist (`table`, `tr`, `td`, `th`, `rowspan`,
  `colspan`, `details`, `summary`, `img`, `kbd`, `sub`, `sup`, …; scripts,
  styles, event handlers, `javascript:` URLs stripped).
- The page is loaded via `ResourceLocator.selfContainedHTML()` +
  `loadHTMLString(baseURL: nil)`; any new vendored `<script src>` in
  `template.html` is auto-inlined by that machinery (same path KaTeX used).
- mermaid.min.js bundles DOMPurify 3.2.4 internally but does NOT expose it as
  a global — it cannot be reused from `template.html` (verified by grep: no
  `window.DOMPurify` export in the UMD bundle).
- KaTeX output is produced at markdown-it parse time, so the HTML string
  handed to the sanitizer already contains KaTeX spans (with `style`/`class`
  attributes) and MathML (`<math>`, `<semantics>`, `<annotation>`, …), plus
  hljs `<span class="hljs-…">` tokens and `<pre class="mermaid">` blocks.
  The sanitizer MUST NOT strip these — allowlist and config must cover them,
  or sanitize only the raw-HTML tokens.
- Security model context (SRS §4 Sec, SDS §6): no network (navigation
  delegate blocks all web loads), JS bridge is native→web only, `WKWebView`
  sees only the bundled shell. Injection blast radius is low but non-zero;
  "fail fast, fail clearly" and NFR Reliability (malformed input never
  crashes) still apply.

### Current State

- `Sources/Markio/Resources/template.html:283-301` — `markdownit({ html:
  false, … })` + task-lists + `mathPlugin` + `frontMatterPlugin`.
- `render(markdown)` (template.html:315-328) assigns `md.render(...)` output
  straight to `el.innerHTML`, then runs mermaid over `pre.mermaid` nodes.
- `Tests/MarkioTests/RenderTests.swift::testMalformedMarkdownDoesNotCrash`
  feeds `"<script>alert(1)</script> & <unclosed"` and only asserts the
  surface survives — with `html:false` the script arrives as text. After the
  change this input must be *sanitized away*, not executed.
- Vendored assets are pinned and committed under
  `Sources/Markio/Resources/vendor/` (SDS §3.6 lists exact versions).
- No sanitizer exists anywhere in the codebase today.

### Constraints

- Offline/private: no CDN, no network — any sanitizer must be vendored,
  pinned, and committed like every other asset (AGENTS.md "Offline & private").
- Sanitization MUST happen **before** the HTML reaches the live DOM:
  `innerHTML` assignment does not execute `<script>` but DOES fire
  `<img onerror>` and similar — sanitize-in-place-after-insert is not safe.
- Must not break existing render features: GFM, task lists, mermaid
  (`pre.mermaid` + post-render SVG), hljs token spans, KaTeX HTML+MathML,
  frontmatter box, find-in-page `<mark>` splicing.
- Minimalism (AGENTS.md): the change stays inside the content-rendering web
  layer; no app-shell/native changes, no settings, no per-document toggles.
- Document-before-code: new FR section in SRS + SDS §3.6/§5 update precede
  implementation.

### Affected Surface

Scout output (verbatim, `surface-scout`):

````text
## Surface

- **template.html, line 284** — markdown-it инициализация с `html: false` отключает обработку raw HTML. Изменение этого флага на `html: true` потребует добавления санитайзера/списка разрешённых тегов — evidence: `var md = window.markdownit({ html: false, ... })`

- **escapeHtml функция, template.html lines 86-88** — функция для экранирования HTML, используется в math/frontmatter/mermaid/code блоках. При включении `html: true` может потребоваться усиленная санитизация или белый список тегов — evidence: `function escapeHtml(s) { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }`

- **KaTeX конфигурация, template.html lines 94-104** — используют `trust: false` чтобы блокировать HTML-инъекции в math. При изменении политики HTML может потребоваться пересмотреть этот параметр — evidence: comments на lines 92-93, `trust: false` на line 98

- **Mermaid конфигурация, template.html lines 303-310** — используют `securityLevel: 'strict'` для безопасности. При включении HTML потребуется согласовать с этой политикой — evidence: line 307

- **markdown-it-task-lists использование, template.html line 300** — плагин для task-листов, может генерировать HTML. Потребуется проверить совместимость с политикой HTML — evidence: `.use(window.markdownitTaskLists, { enabled: false })`

- **RenderTests.swift, line 141** — тест `testMalformedMarkdownDoesNotCrash` проверяет что `<script>alert(1)</script>` не выполняется. При включении HTML придётся переписать этот тест или добавить параллельный для санитизации — evidence: `"<script>alert(1)</script> & <unclosed"` в inputs массиве

- **render-suite.md, lines 230-344** — fixture документ, раздел "Raw HTML (viewer runs with html:false — must be escaped/inert)" содержит примеры raw HTML которые должны быть экранированы. Потребуется обновить комментарии и возможно добавить новые примеры для санитизированного HTML — evidence: `## 12. Raw HTML (viewer runs with html:false — must be escaped/inert)` и примеры `<div>`, `<script>`, `<img onerror=...>`

- **OfflineTests.swift** — проверяет что нет сетевых запросов. При включении HTML потребуется убедиться что санитайзер/parser не делают сетевых запросов — evidence: path `/Users/korchasa/www/business/markview/Tests/MarkioTests/OfflineTests.swift`

- **design.md, lines 93-95** — документация описывает что `markdown-it runs with html:false (read-only viewer drops raw inline HTML)`. Потребуется обновить эту документацию при изменении политики — evidence: section "Deps (pinned, committed)" в SDS § 3.6

- **requirements.md, FR-GFM** — описывает требование на рендеринг GFM таблиц (Markdown таблицы, не raw HTML). Потребуется проверить не требуется ли добавить новое требование на обработку raw HTML — evidence: `### 3.2 FR-GFM: Render GitHub Flavored Markdown [ANC:fr:gfm]`

- **add-math-support.md, lines 44 и 159** — в задаче документируется что `template.html configured html:false` и `trust:false + html:false already set → no raw HTML/JS`. Потребуется обновить или создать новую задачу если меняется политика — evidence: task file в `documents/tasks/2026/07/`

- **add-frontmatter-display.md, line 29** — упоминает что `html:false — raw inline HTML is dropped`. Потребуется обновить при изменении политики — evidence: task file в `documents/tasks/2026/07/`

- **implement-markview-app.md, line 94** — ранняя задача упоминает `markdown-it configured html:false (read-only viewer drops raw inline HTML` — evidence: task file в `documents/tasks/2026/06/`

- **PreviewController.swift, line 41** — загружает template.html и вызывает `render()`. При изменении конфигурации markdown-it потребуется убедиться что shell загружается корректно — evidence: `webView.loadHTMLString(html, baseURL: nil)`

- **ResourceLocator.swift, lines 69-86** — читает template.html и инлайнит vendor assets. При добавлении нового санитайзера потребуется убедиться что он включён в vendor или inline — evidence: `selfContainedHTML()` функция

- **DocumentModel.swift, lines 39-46** — управляет рендерингом документов через `preview.render(text)` — evidence: `.start(text:url:)` и `render()` вызовы

- **LinkPolicy.swift** — управляет политикой навигации (какие ссылки разрешены). При включении HTML потребуется согласовать политику ссылок в HTML элементах — evidence: path `/Users/korchasa/www/business/markview/Sources/Markio/LinkPolicy.swift`

- **MarkdownDocument.swift** — загружает и хранит Markdown текст — evidence: path `/Users/korchasa/www/business/markview/Sources/Markio/MarkdownDocument.swift`

- **markdown-it.min.js в vendor** — основной парсер, конфигурируется в template.html. Потребуется убедиться что версия поддерживает нужные опции санитизации или потребуется добавить плагин санитайзера — evidence: `/Users/korchasa/www/business/markview/Sources/Markio/Resources/vendor/markdown-it/markdown-it.min.js`

## Not examined (budget)

- Минифицированные JS файлы в vendor (highlight.js, mermaid.js) — не читались полностью для поиска упоминаний политики HTML
- Все остальные тесты в `Tests/MarkioTests/` — проверены только RenderTests и OfflineTests на предмет HTML
- История коммитов и ветвления — не проверялась

## Could not rule out

- Возможны упоминания в комментариях/документации вне основных файлов, которые не были найдены
- Плагины для markdown-it в vendor могут иметь собственные опции безопасности, которые потребуют изменений
- Может потребоваться добавление нового санитайзера (например, внешней библиотеки), что повлечёт обновление Package.swift и инструкций по сборке
- CSS стили (github-markdown.min.css и другие) могут содержать селекторы по raw HTML элементам, потребуется проверка
````

Union dispositions:

- `template.html:284` `html:false` root cause — covered-by DoD item 1 (flag flips + sanitizer; Solution details after variant selection)
- Sanitizer insertion point (`render()` before `innerHTML`, template.html:315-328) — covered-by DoD items 1–2
- `escapeHtml` call sites (math/code/mermaid/frontmatter escaping, template.html:86-88) — not affected — those paths escape *generated* fragments and remain as-is; the `html:` flag governs only raw HTML in source Markdown
- KaTeX `trust:false` (template.html:98) — not affected — stays; math-level injection guard is independent of the document sanitizer
- Mermaid `securityLevel:'strict'` (template.html:307) — not affected — stays; mermaid input arrives escaped via the `highlight` hook (template.html:288-290)
- markdown-it-task-lists (template.html:300) — not affected — the plugin emits checkbox HTML through renderer rules, which the `html:` flag does not gate; covered anyway by existing `testGFMTableAndTaskList` in `make check` (DoD item 3)
- `RenderTests.swift::testMalformedMarkdownDoesNotCrash` (`<script>` input) — covered-by DoD item 2 (sanitization test supersedes the escape assumption; existing test must stay green)
- `test-fixtures/render-suite.md` §12 "Raw HTML … html:false" — covered-by Solution (fixture section update; wording + expected behavior change)
- `Tests/MarkioTests/OfflineTests.swift` — covered-by DoD item 3 (`make check` runs it; sanitizer is vendored/offline by Constraints)
- SDS §3.6 + §5 (`html:false` statements, design.md:93-95,103) — covered-by DoD item 4
- SRS: new FR-INLINE-HTML section (FR-GFM untouched) — covered-by DoD item 4
- Prior task files mentioning `html:false` (2026/07/add-math-support.md, 2026/07/add-frontmatter-display.md, 2026/06/implement-markview-app.md) — not affected — tasks are persistent canonical records of their moment (AGENTS.md Tasks rules); never retro-edited
- `PreviewController.swift:41` + `ResourceLocator.selfContainedHTML()` — not affected as code; a new vendored `<script src>` is auto-inlined by the existing machinery (same path KaTeX took); exercised by DoD items 1–3 tests
- `DocumentModel.swift`, `MarkdownDocument.swift` — not affected — content-agnostic text pass-through (DocumentModel.swift:39-46; UTF-8 decode only)
- `LinkPolicy.swift` — not affected — navigation delegate intercepts link *clicks* regardless of whether the `<a>` came from Markdown or raw HTML; sanitizer additionally strips `javascript:` URLs (DoD item 2)
- `vendor/markdown-it/markdown-it.min.js` — not affected — no parser change; `html:true` is a documented 14.x option, configuration lives in template.html
- `Package.swift` / build instructions (scout "could not rule out") — not affected — `.copy("Resources/vendor")` (Package.swift:19) copies the whole vendor directory; a new `vendor/dompurify/` subdirectory ships with zero manifest changes
- github-markdown-css selectors for raw HTML elements (scout "could not rule out") — not affected — the stylesheet is GitHub's own and already styles raw-HTML elements (`table`, `details`, `kbd`, …); visual check lands in the acceptance test's DOM assertions

## Definition of Done

- [x] FR-INLINE-HTML: raw HTML `<table>` with `rowspan`/`colspan` (support-matrix.md shape) renders as a real `<table>` element, not escaped text
  - Test: `Tests/MarkioTests/RenderTests.swift::testInlineHTMLTableRenders`
  - Evidence: `make test ARGS="--filter RenderTests"`
- [x] FR-INLINE-HTML: dangerous HTML never executes — `<script>`, event-handler attributes (`onerror`, `onclick`), `javascript:` URLs are stripped by the allowlist sanitizer before DOM insertion
  - Test: `Tests/MarkioTests/RenderTests.swift::testInlineHTMLSanitized`
  - Evidence: `make test ARGS="--filter RenderTests"`
- [x] FR-INLINE-HTML: existing pipeline features survive sanitization — mermaid SVG, hljs tokens, KaTeX (incl. MathML), frontmatter box still render (existing RenderTests stay green)
  - Test: `Tests/MarkioTests/RenderTests.swift` (full suite, existing tests)
  - Evidence: `make check`
- [x] FR-INLINE-HTML: add FR-INLINE-HTML section to SRS with `**Acceptance:**` field filled; update SDS §3.6 (vendor bundle, `html:` decision) and §5 (render algo)
  - Test: `manual — maintainer` (doc review; SALP validated by review flow)
  - Evidence: `grep -q "FR-INLINE-HTML" documents/requirements.md documents/design.md`

## Solution

Selected: **Variant 2 — vendor DOMPurify (pinned) + allowlist config**, over
(1) a hand-rolled DOMParser/TreeWalker sanitizer (no new dependency, but
hand-rolled sanitizers miss the mXSS class and must not break KaTeX
MathML/hljs spans — exactly where DIY filters fail) and (3) DOMPurify + CSP +
extended XSS suite (defense depth beyond the offline threat model; CSP inside
a `loadHTMLString(baseURL:nil)` shell with an inline script is fiddly).
Root cause addressed: `markdownit({html:false})` escapes raw HTML into text;
the fix flips the flag and replaces the blanket escape with a real sanitizer.

### Steps

1. **Vendor DOMPurify** — new file
   `Sources/Markio/Resources/vendor/dompurify/purify.min.js`, pinned
   **3.2.4** (the same version mermaid 11.6.0 bundles internally — known-good
   vintage; source: npm tarball `dompurify-3.2.4.tgz` → `dist/purify.min.js`,
   committed like every other vendored asset). No `Package.swift` change:
   `.copy("Resources/vendor")` ships the directory (Package.swift:19).
   `ResourceLocator.selfContainedHTML()` auto-inlines the new
   `<script src="vendor/dompurify/purify.min.js">` (same path KaTeX took).

2. **template.html — flip the flag, insert the sanitize gate**:
   - `<script src="vendor/dompurify/purify.min.js"></script>` in `<head>` —
     EXACTLY this form: `src` first, double quotes, no other attributes.
     `ResourceLocator.inlineVendor()`'s regex
     (`<script\s+src="(vendor/[^"]+)"\s*></script>`) silently skips any
     deviating tag and the sanitizer would be absent at runtime (the
     fail-fast throw in `sanitizeHtml` is the backstop that surfaces it).
   - `markdownit({ html: true, ... })` (line 284) + update its comment:
     raw HTML now passes through and is sanitized before DOM insertion.
   - New `sanitizeHtml(html)` beside `escapeHtml`:
     ```js
     // [REF:fr:inline-html] — allowlist gate between md.render() and the DOM.
     function sanitizeHtml(html) {
       if (!window.DOMPurify) throw new Error('DOMPurify asset missing');
       return window.DOMPurify.sanitize(html, {
         USE_PROFILES: { html: true, mathMl: true },  // KaTeX spans + MathML survive
         FORBID_TAGS: ['style']  // no document-wide CSS injection
       });
     }
     ```
     - `input` MUST stay allowed (DOMPurify default): task-list checkboxes
       are `<input class="task-list-item-checkbox">` — forbidding form tags
       wholesale would break `testGFMTableAndTaskList`.
     - Defaults already strip `<script>`, event-handler attributes,
       `javascript:`/unknown-protocol URLs; `colspan`/`rowspan`/`scope`/
       `class`/`style`-attr are in the default attribute allowlist (the "tag
       allowlist" the user chose = profiles + defaults + FORBID_TAGS).
     - Fail fast, no silent fallback: a missing DOMPurify global is a build
       defect → `render()` rejects loudly (bridge failures are logged by
       `PreviewController`), never renders unsanitized.
   - `render()` (line ~317): `el.innerHTML = sanitizeHtml(md.render(...))`.
   - `trust:false` (KaTeX) and `securityLevel:'strict'` (mermaid) stay.

3. **Tests (RED first)** — `Tests/MarkioTests/RenderTests.swift`:
   - `testInlineHTMLTableRenders` — render a raw `<table>` with
     `rowspan`/`colspan` `<th>` (support-matrix.md shape, incl. `<code>` in
     cells); assert `#content table` ≥ 1, `th[rowspan]` ≥ 1, and that
     `#content` textContent does NOT contain the literal string `<table>`.
   - `testInlineHTMLSanitized` — render
     `<script>window.__xss=1</script>`, `<img src="x" onerror="window.__xss=1">`,
     `<a href="javascript:alert(1)">x</a>`, `<style>body{display:none}</style>`;
     assert: no `#content script|style` nodes, no `[onerror]` attributes, no
     `a[href^="javascript:"]`, and `window.__xss` stays undefined (proves
     nothing executed, not merely that markup vanished).
   - `testMathRendersWithKatex` — extend with an explicit MathML-survival
     assertion: `#content .katex-mathml math` ≥ 1 (KaTeX's default
     `output: 'htmlAndMathml'` emits the MathML branch; the sanitizer's
     `mathMl` profile must preserve it, and DoD item 3 claims it — so the
     suite must assert it, not assume it).
   - Existing suite unchanged and green — especially
     `testMalformedMarkdownDoesNotCrash` (its `<script>alert(1)</script>`
     input is now *stripped*, not escaped — assertion already only checks
     survival) and `testGFMTableAndTaskList` (checkbox `<input>` survives).
   - Reminder (AGENTS.md Test Rules): run `make fmt` before `make check` —
     new DOM-query assertion strings will exceed the line-length limit.

4. **Fixture** — `test-fixtures/render-suite.md` §12: retitle from
   "html:false — must be escaped/inert" to sanitized-HTML semantics; keep the
   hostile samples (now expected: stripped, inert), add rendering samples:
   `rowspan`/`colspan` table, `<details><summary>`, `<kbd>`, `<sub>`/`<sup>`.

5. **Docs (before code, per AGENTS.md)**:
   - SRS: new section
     `### 3.14 FR-INLINE-HTML: Render sanitized inline HTML [ANC:fr:inline-html]`
     — Desc (raw HTML renders through DOMPurify
     allowlist; dangerous content stripped; GitHub-parity examples), Scenario
     (support-matrix-style `<table rowspan>` renders as a table; `<img
     onerror>` never fires), Acceptance (both tests above), Status `[ ]`,
     plus the `**Tasks:**` back-pointer to this task (deferred from plan
     phase — section did not exist yet).
   - SDS §3.6: add DOMPurify 3.2.4 to the pinned deps list; replace
     "markdown-it runs with `html:false` …" with the html:true + sanitize-gate
     decision (and why: GFM-parity for raw-HTML tables, user-chosen
     sanitizer+allowlist direction). SDS §5 Algos: render = … md parser
     (html:true) → **DOMPurify allowlist sanitize** → innerHTML → mermaid.
   - SRS §4 Sec: extend "no JS bridge…" sentence with the sanitizer gate.

6. **Verify**: `make fmt` → `make check` (build + comment-scan + lint + full
   tests) → `make test ARGS="--filter RenderTests"`. No menu/toolbar surface
   → no `make app` UI pass required.

### Error handling

- `DOMPurify.sanitize` never throws on malformed input (returns a cleaned
  string) → NFR Reliability holds for hostile/broken HTML.
- Missing sanitizer asset → `sanitizeHtml` throws → `render()` promise
  rejects → logged by `PreviewController` (`os.Logger`), page shows no
  unsanitized content. Fail fast, no silent fallback (AGENTS.md).

### Dependencies

- New vendored, pinned, committed: DOMPurify 3.2.4 (`purify.min.js`, ~22 KB,
  zero transitive deps). No SPM/package-manager dependency — a static asset
  like markdown-it/KaTeX/mermaid.

## Follow-ups

- Variant 3 extras deliberately not taken: CSP meta tag in the shell and an
  extended mXSS vector suite — revisit only if untrusted-file viewing becomes
  a first-class threat scenario (offline shell + native→web-only bridge keeps
  blast radius low today).
