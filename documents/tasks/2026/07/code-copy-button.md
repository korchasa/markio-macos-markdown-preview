---
date: 2026-07-14
status: done
implements:
  - FR-CODE-COPY
tags: [daily-use, wave1]
related_tasks:
  - [daily-use-feature-backlog](daily-use-feature-backlog.md)
---
# Copy button on code blocks

## Goal

Backlog item 3 (Tier 1): hovering a fenced code block shows a Copy button (raw
code text → clipboard) and a language badge (from the fence info string).
Copying a command / snippet is the single most frequent reader action in
technical Markdown; without it Markio loses daily use to Meva/MarkFlow.

## Overview

### Context

- Backlog: `documents/tasks/2026/07/daily-use-feature-backlog.md` item 3 (do not edit it).
- Items 1 (live-reload scroll) and 2 (TOC sidebar) already shipped on `feature/daily-use-wave1`.
- Render pipeline: markdown-it `highlight` callback in `Sources/Markio/Resources/template.html`
  emits `<pre class="hljs"><code>…` for fenced blocks (mermaid → `pre.mermaid`,
  frontmatter → `pre.hljs.markio-frontmatter`). Output passes DOMPurify before
  `innerHTML` ([REF:fr:inline-html]); `ALLOW_DATA_ATTR` is DOMPurify's default,
  so `data-*` survives the gate.
- Bridge today: native→web via `callAsyncJavaScript`; web→native exactly one
  read-only handler `markioTOC` ([REF:fr:toc]). SRS §4 Sec / §5 Proto state
  "exactly one page→native message handler" — a second handler obliges updating
  both statements.
- Sandbox lesson ([REF:sds:webview-host]): in the App Sandbox the WebContent
  process is confined; in-page `navigator.clipboard.writeText` is gated on
  user-activation/permission plumbing WKWebView does not expose — the reliable
  clipboard write on this platform is native `NSPasteboard`.

### Current State

- `template.html`: `render()` → sanitize → `innerHTML` → `rebuildTOC()` →
  `mermaid.run()` → scroll restore. Post-render DOM walks already exist
  (`rebuildTOC`). Find (`collectTextNodes`) walks ALL text under `#content`,
  skipping script/style/svg/katex — any injected UI text (button label, badge)
  would become searchable unless skipped.
- `PreviewController.swift`: registers `markioTOC` through weak
  `ScriptMessageProxy`; callback `onCurrentSectionChange`.
- No copy UI, no badge, no pasteboard code anywhere in the app.

### Constraints

- Read-only viewer; native first; minimalism (no settings, no toolbar buttons).
- Offline: no new vendored dependencies — hand-rolled JS/CSS in `template.html`.
- Web view owns content rendering only; OS integration (clipboard) belongs to
  the native shell.
- Fenced code blocks only (per backlog wording). Mermaid blocks (item 10 owns
  diagram copy) and the frontmatter box are excluded. Indented (4-space) code
  blocks: deferred (see Follow-ups).
- Copy payload = raw code text (no hljs markup, no badge/button text, no find
  `<mark>` artifacts — `textContent` of `<code>` is markup-free by construction).
- English-only "Copy" label in v1 (web-side content UI; system localization
  does not reach it).

### Affected Surface

Scout (`surface-scout`) verbatim output:

```
## Surface

- **Sources/Markio/Resources/template.html** — Primary implementation: modify markdown-it's `highlight` function to wrap code blocks with a container including a copy button (with `onclick` or data-click handler) and language badge label. Add CSS styling (position, visibility on hover, appearance) and JavaScript event handler to copy block text to clipboard (via `navigator.clipboard.writeText()` or via a new message handler) — evidence: lines 306–318 (highlight function), lines 11–71 (existing `<style>` tag for theming).

- **Sources/Markio/PreviewController.swift** — Web↔native bridge decision point: if copy uses JavaScript's Clipboard API, no native changes needed; if copy sends a message to native code for pasteboard access (pattern consistency with TOC's `markioTOC` handler — lines 21, 35–37, 224–231), add a new `WKScriptMessageHandler` for clipboard operations (e.g., `markioCopy`), register it via `userContentController.add()` (similar to line 31), and decode the message payload in a new handler method — evidence: PreviewController's existing `ScriptMessageProxy` pattern (lines 224–231) and `handleTOCMessage` (lines 200–204).

- **Tests/MarkioTests/RenderTests.swift** — Test new feature: add one test (`testCodeBlockShowsCopyButton`) to verify fenced code blocks render a copy button element, language badge visibility, and correct language label extraction from fence info string — evidence: existing test pattern (lines 49–66, `testCodeBlockHighlighted`; testing infrastructure in PreviewTestSupport.swift lines 14–19).

- **Tests/MarkioTests/PreviewTestSupport.swift** — Possibly add a helper to extract and verify code block metadata (language, copy button state) if tests require detailed inspection — evidence: existing helpers `makeLoadedPreview()` and `count()` (lines 8–19).

- **documents/requirements.md (SRS, §3 Functional Reqs)** — Add new FR-COPY-CODE (or FR-CODE-COPY): "Desc: Hovering over a fenced code block shows a copy button and language badge derived from the fence info string; clicking copy places the raw code text (no highlighting markup, no line numbers) on the clipboard. Acceptance: `Tests/MarkioTests/RenderTests.swift::testCodeBlockShowsCopyButton` (and optionally a manual acceptance checklist if copy-to-clipboard cannot be tested in a WKWebView sandbox). Status: [ ]" — evidence: SRS patterns (lines 25–113, e.g., FR-GFM, FR-FIND, FR-HIGHLIGHT).

- **documents/design.md (SDS, §3.6 Vendored web bundle)** — Document the copy-code implementation under [ANC:sds:vendor] (code-block wrapping, CSS, click handler, `markioCopy` if used) — evidence: SDS §3.6 (lines 96–103).

- **documents/design.md (SDS, §3.4 WebViewHost)** — If a native clipboard message handler is added: update the Interfaces section to list the new `markioCopy` handler alongside existing `markioTOC` — evidence: SDS line 74 describing the single existing message handler.

- **README.md** — Update the Features list (lines 7–22) to mention the copy button — evidence: existing feature list format.

- **Sources/Markio/PreviewController.swift — Possibly a new clipboard helper class or extension** — If native pasteboard access is used: create a small helper (e.g., `NSPasteboard.setString()`), called from the `markioCopy` message handler.

- **Makefile** — No changes expected.

- **Sources/Markio/Resources/template.html — Interaction with existing features** — Verify that: (1) the copy button does not break the Find feature (`collectTextNodes` may need to skip code-block UI elements — line 505); (2) live reload re-creates copy buttons on re-render (fine, no state); (3) TOC unaffected.

- **Sources/Markio/DocumentModel.swift** — No changes expected (message handlers owned by PreviewController).

- **Sources/Markio/ContentView.swift** — No changes expected (code-block UI is pure web-side).

- **Tests/MarkioTests/RenderTests.swift — NFR Reliability check** — malformed input with unclosed code fence must not break copy-button rendering (`testMalformedMarkdownDoesNotCrash` inputs, line 210).

- **Tests/MarkioTests/LiveReloadTests.swift** — re-render recreates the button DOM; no state retained — correct by construction.

- **Package.swift** — No changes needed (template.html already a copied resource).

## Could not rule out

- Clipboard API vs. native pasteboard handler choice (WKWebView sandbox restrictions undocumented in SDS).
- Code block raw-source extraction method (data-attribute vs textContent vs closure).
- Language badge extraction from extended info strings (`swift {linenos}`).
- Hover styling light/dark compat; button positioning under horizontal overflow.
- Line-number plugins (none vendored — assumption held).
```

Union dispositions (planner ∪ scout):

- `Sources/Markio/Resources/template.html` (highlight callback, post-render wrap pass, CSS, click handler) — covered-by Solution steps 1–3
- `Sources/Markio/PreviewController.swift` (`markioCopy` handler + pasteboard write) — covered-by Solution step 4
- Find interplay: button label + badge text must never match a search — covered-by Solution step 3 (skip `.markio-code-ui` in `collectTextNodes`) and DoD item 4
- Live reload: wrap pass runs inside `render()` next to `rebuildTOC()` → buttons recreated every render — covered-by Solution step 2
- Mermaid (`pre.mermaid`) and frontmatter (`pre.markio-frontmatter`) exclusion — covered-by Solution step 2 and DoD item 3
- Unclosed-fence malformed input — covered-by Solution step 5 (extend `testMalformedMarkdownDoesNotCrash` inputs)
- `documents/requirements.md` (new FR section + "exactly one handler" statements in §4/§5) — covered-by Solution step 6
- `documents/design.md` (§3.4 WebViewHost bridge, §3.6 vendor rule) — covered-by Solution step 6
- `README.md` feature list — covered-by Solution step 6
- `Tests/MarkioTests/CodeCopyTests.swift` (new suite; scout proposed RenderTests — a dedicated suite matches the FindTests/TOCTests precedent) — covered-by Solution step 5
- `Sources/Markio/DocumentModel.swift`, `ContentView.swift`, `Makefile`, `Package.swift`, `PreviewTestSupport.swift` — not affected — scout inspected: handlers live in PreviewController; template.html already a bundled resource; existing helpers suffice
- Indented (4-space) code blocks — deferred — human choice (backlog wording says "fenced"; cheap to add later on the same wrap pass)
- Localization of the "Copy" label; accessibility (VoiceOver/keyboard) of the web-side button — deferred — human choice (v1 minimalism)

## Definition of Done

- [x] FR-CODE-COPY: a fenced code block renders hover-revealed Copy UI; clicking it delivers the block's raw code text (exactly the fence content) to the native pasteboard path
  - Test: `Tests/MarkioTests/CodeCopyTests.swift::testCopyButtonCopiesRawCode`
  - Evidence: `make test ARGS="--filter CodeCopyTests"`
- [x] FR-CODE-COPY: the badge shows the first word of the fence info string (` ```swift ` → `swift`); an untagged fence shows no badge but still gets a Copy button
  - Test: `Tests/MarkioTests/CodeCopyTests.swift::testLanguageBadgeFromFenceInfo`
  - Evidence: `make test ARGS="--filter CodeCopyTests"`
- [x] FR-CODE-COPY: Mermaid blocks and the frontmatter box get no copy UI
  - Test: `Tests/MarkioTests/CodeCopyTests.swift::testMermaidAndFrontmatterExcluded`
  - Evidence: `make test ARGS="--filter CodeCopyTests"`
- [x] FR-CODE-COPY: find never matches the Copy label or badge text
  - Test: `Tests/MarkioTests/CodeCopyTests.swift::testFindSkipsCopyUI`
  - Evidence: `make test ARGS="--filter CodeCopyTests"`
- [x] FR-CODE-COPY: SRS section added with filled `**Acceptance:**` (+ §4/§5 bridge statements updated); SDS §3.4/§3.6 updated; README feature list updated
  - Test: n/a (doc change)
  - Evidence: `grep -q "FR-CODE-COPY" documents/requirements.md && grep -q "markioCopy" documents/requirements.md && grep -q "markioCopy" documents/design.md && grep -qi "copy" README.md && ! grep -q "exactly one read-only page→native message handler" documents/requirements.md`

## Solution

Selected: **Variant B** — page renders the hover UI, native owns the clipboard
write via a second one-way message handler `markioCopy`.

1. **`template.html` — carry the fence language.** In the markdown-it
   `highlight` callback, add `data-lang="<lang>"` to the emitted
   `<pre class="hljs">` for tagged fences (first word of the info string is
   what markdown-it already passes as `lang`; HTML-entity escape it with the
   existing `escapeHtml()`). Untagged fences get
   no attribute. DOMPurify keeps `data-*` by default (`ALLOW_DATA_ATTR`), so
   the attribute survives the sanitize gate. Mermaid (`pre.mermaid`) and
   frontmatter (`pre.markio-frontmatter`) emit no attribute and are never
   decorated.
2. **`template.html` — post-render decoration pass.** New
   `decorateCodeBlocks()` called from `render()` next to `rebuildTOC()`: for
   each `#content pre.hljs:not(.markio-frontmatter)`, wrap it in
   `<div class="markio-codeblock">` (position:relative) and append
   `<div class="markio-code-ui">` holding an optional
   `<span class="markio-code-lang">` badge (from `data-lang`) and a
   `<button class="markio-copy">Copy</button>`. Buttons are re-created on every
   render (live reload safe, no state). One **delegated** click listener on
   `#content` (registered once) handles `.markio-copy` clicks: read the
   sibling `<code>`'s `textContent` (markup-free raw code by construction) and
   post it to `webkit.messageHandlers.markioCopy` (guarded no-op when the
   bridge is absent — headless test contexts); flip the button label to
   "Copied" for ~1.5 s as optimistic feedback. CSS: `.markio-code-ui` is
   `opacity:0`, revealed by `.markio-codeblock:hover` (and `:focus-within`);
   top-right, scheme-neutral colors matching the frontmatter box style.
3. **`template.html` — find isolation.** `collectTextNodes()` gains a skip for
   ancestors with class `markio-code-ui`, so "Copy"/badge text never matches a
   search (mirrors the existing katex/svg skips).
4. **`PreviewController.swift` — native pasteboard write.** Second
   `ScriptMessageProxy` registered as `markioCopy`; handler validates a
   non-empty string body, calls `pasteboard.clearContents()` +
   `setString(_:forType:.string)` on an injected `NSPasteboard` (new init
   parameter, default `.general` — tests pass `NSPasteboard(name:)` unique so
   `make check` never clobbers the user clipboard), then fires a new
   `onCodeCopied: ((String) -> Void)?` callback (test/UI hook). Doc comments
   updated: the bridge is now two one-way handlers.
5. **Tests — new suite `Tests/MarkioTests/CodeCopyTests.swift`** (dedicated
   suite per FindTests/TOCTests precedent), driving the real pipeline via
   `makeLoadedPreview()` with an injected unique pasteboard:
   - `testCopyButtonCopiesRawCode` — render a swift fence, synthetic
     `.markio-copy` click via `evaluate`, await `onCodeCopied` /
     poll pasteboard == exact fence content.
   - `testLanguageBadgeFromFenceInfo` — tagged fence shows `swift` badge;
     untagged fence has no badge but still a Copy button.
   - `testMermaidAndFrontmatterExcluded` — no `.markio-copy` inside mermaid
     or frontmatter markup.
   - `testFindSkipsCopyUI` — `search('Copy')` (and the badge text) yields 0
     matches on a doc whose content doesn't contain the word.
   - Extend `RenderTests.testMalformedMarkdownDoesNotCrash` inputs with an
     unclosed fence containing a fence-like body (reliability).
6. **Docs.** SRS: new `### 3.16 FR-CODE-COPY … [ANC:fr:code-copy]` (Desc,
   Scenario, Acceptance = CodeCopyTests, Tasks back-pointer to this task);
   update §4 Sec and §5 Proto from "exactly one message handler" to the
   two-handler wording (`markioTOC` scroll-spy + `markioCopy` copy channel,
   both one-way page→native, string payloads). SDS: §3.4 WebViewHost
   interfaces/decision (second proxy, injected pasteboard), §3.6 vendor rule
   (decoration pass, delegated click, find skip), §5 Logic (copy flow),
   §6 Sec note. README feature list: copy button + badge.
   `documents/index.md`: FR row (done at plan time).
7. **Verification.** `make fmt` (long inline JS strings in tests), then
   `make check` (build + comment-scan + format lint + full tests);
   `make test ARGS="--filter CodeCopyTests"` as the FR evidence command.

Error handling: the copy path is best-effort per NFR Reliability — a missing
bridge is a silent no-op in the page (guarded), a malformed message body is
dropped in the handler (mirrors `handleTOCMessage`), and pasteboard write
failures cannot throw (`setString` returns Bool; log via `Log.preview` on
`false`). No new dependencies.

## Follow-ups

- Indented (4-space) code blocks: extend the same wrap pass later if wanted (backlog item 3 wording covers fenced only).
- "Copy" label localization + web-side button accessibility (VoiceOver label, keyboard focus) — revisit with backlog item 15 (smart copy).
