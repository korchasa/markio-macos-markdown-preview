---
date: 2026-07-14
status: in progress
implements:
  - FR-QUICKLOOK
tags: [quicklook, packaging, rendering]
---
# Quick Look preview extension (.appex) built without Xcode [ANC:task:2026-07-quicklook-extension]

## Goal

Pressing Space on a `.md` file in Finder shows the document rendered by Markio's
own engine (GFM, Mermaid, KaTeX) — capabilities system Quick Look lacks. The
preview sells the app before it is opened (backlog item 7, Tier 2
differentiation for the 4.3(a) resubmission story).

## Overview

### Context

- Backlog: `documents/tasks/2026/07/daily-use-feature-backlog.md` item 7 (read-only reference).
- The app is assembled by a hand-rolled `Makefile` (SwiftPM release binary +
  manual `.app` bundle + `actool`), NOT an Xcode project. A Quick Look preview
  extension is an `.appex` bundle embedded at `Contents/PlugIns/` of the host app.
- Feasibility investigation (2026-07-14, web):
  - JS inside a QL extension **works** when the extension is *view-based*
    (`QLPreviewingController` + own `WKWebView`): proven by shipping projects
    csv-quick-look (WKWebView + JS injection), jtbandes/quicklookjs (generic
    web-preview appex), johnoscott/MermaidViewer (bundles mermaid.js in the
    extension). The *data-based* API (`QLPreviewReply` HTML) does NOT execute
    JS — unsuitable for Mermaid.
  - Known WKWebView-in-QL limitations (sbarex/QLTest): network entitlement is
    ignored (irrelevant — Markio is offline by design); external links open
    inside the preview (we block all post-load navigations); a dark-mode CSS
    `@media` bug in fullscreen (irrelevant — Markio switches theme via explicit
    `setDark`, not media queries).
  - Building the `.appex` without Xcode: compile the extension binary as a
    SwiftPM `executableTarget` with linker entry point `_NSExtensionMain`
    (`-Xlinker -e -Xlinker _NSExtensionMain` — exactly what Xcode passes for
    app-extension products; the symbol lives in Foundation), hand-assemble
    `Contents/Info.plist` (`CFBundlePackageType=XPC!`,
    `NSExtensionPointIdentifier=com.apple.quicklook.preview`,
    `NSExtensionPrincipalClass`, `QLSupportedContentTypes`) + `Contents/MacOS/`
    binary + `Contents/Resources/`.
  - Loading locally: extension processes must be sandboxed and signed to be
    launched by `pluginkit`; the documented non-Xcode practice (quicklookjs) is
    an **ad-hoc** `codesign --sign - --force --entitlements …` of the `.appex`.
    Distribution signing stays in app-store-factory; the factory re-signs
    (`--force`) over the ad-hoc seal. The host app itself stays unsigned in
    this repo, as today.
- Rendering engine reuse: the app renders via `template.html` + `vendor/`
  assets inlined by `ResourceLocator.selfContainedHTML()` and loaded with
  `loadHTMLString(baseURL: nil)` (the sandbox-proof path already validated on
  TestFlight). The extension uses the same self-contained document. Vendored
  assets total ~3.5 MB; the appex carries its own copy of the resource bundle
  (reading the host app's copy across the sandbox boundary is not guaranteed).

### Current State

- `Package.swift`: one executable target `Markio` (owns `Resources/template.html`
  + `Resources/vendor/`) + test target `MarkioTests` (imports `Markio`).
- `ResourceLocator` (Sources/Markio) resolves the SwiftPM resource bundle
  `Markio_Markio.bundle` across packaged/dev/test layouts and inlines vendor
  assets into one self-contained HTML string.
- `Makefile app` assembles `.build/Markio.app` (binary, resource bundle,
  `packaging/Info.plist`, actool icon). No `Contents/PlugIns/`, no signing.
- `packaging/Markio.entitlements` (app-sandbox, user-selected read-only,
  network.client) is applied by app-store-factory at signing time.
- No Quick Look integration of any kind; Space in Finder shows the system
  plain-text preview.

### Constraints

- Native-first; the web engine stays a content-rendering detail.
- Offline: no network from the extension (QL ignores the network entitlement
  anyway; the navigation delegate blocks everything post-load).
- No Xcode project; SwiftPM + Makefile only. No distribution signing in this
  repo (factory signs); ad-hoc signing of the `.appex` only, for local testing.
- Do not implement other backlog items; do not edit the backlog file.
- English artifacts; Conventional Commits; `make check` green.
- The extension is read-only render-only: no TOC push, no copy-to-pasteboard,
  no scroll persistence, no link opening (QL preview is ephemeral).

### Affected Surface

Independent scout output (verbatim):

```
- **Package.swift — targets** — needs a new `executableTarget` or `libraryTarget` for the Quick Look extension binary (separate from the main `Markio` executable); may need to decide on code sharing (library target vs. duplicate sources) — evidence: lines 9-24 show current executable-only structure.
- **Makefile — .appex build rules** — needs rules to compile the extension binary, create the `.appex` bundle directory structure at `.build/$(APP_NAME).app/Contents/PlugIns/MarkioQLExt.appex/Contents/MacOS/`, copy the binary in, and embed the extension's Info.plist and resources — evidence: lines 49-75 show the current `.app` assembly.
- **Makefile — `app` target update** — the existing `make app` rule must be modified to also assemble the `.appex`.
- **packaging/Info.plist (main app)** — needs to declare the embedded extension bundle ID in an `NSExtensionAttributes` or similar key so macOS knows which Quick Look provider to invoke; bundle IDs must be coordinated (child ID like `dev.markio.app.quicklook-extension`).
- **packaging/MarkioQLExt.entitlements (new)** — Quick Look extensions run in their own sandbox with constrained entitlements; this file would need to exist and be referenced at signing.
- **packaging/MarkioQLExt-Info.plist (new)** — the extension's own Info.plist: `NSExtensionPointIdentifier = com.apple.quicklook.preview`, principal class, supported UTTypes.
- **Sources/Markio/Resources/vendor/ (shared or copied)** — rendering assets must be accessible to the extension; either its own copy or shared; a QL extension may not be able to read the main app's resource bundle (sandboxing), so duplication is likely.
- **Sources/MarkioQLExt/ (new target directory)** — extension entry point, a `QLPreviewingController` or `QLPreviewProvider` subclass.
- **Sources/MarkioQLExt/QLRenderer.swift or similar (new)** — core rendering logic; likely reuses or duplicates ResourceLocator/PreviewController patterns; uncertain whether WKWebView is usable in a QL extension sandbox.
- **Sources/MarkioQLExt/Resources/template.html and vendor/ (new or symlinked)** — bundling orchestrated by the Makefile.
- **Tests/MarkioQLExtTests/ (new test target)** — unit/integration tests for the QL provider.
- **Tests/MarkioQLExtTests/QLRendererTests.swift (new)** — acceptance tests scoping what's reliably achievable in the QL sandbox.
- **documents/requirements.md (SRS)** — new FR section with runnable acceptance criteria.
- **documents/design.md (SDS)** — new § for the extension architecture: target, resource strategy, sandbox constraints, WKWebView feasibility or fallback.
- **documents/tasks/2026/07/quick-look-extension.md (new task file)** — persistent GODS record incl. investigation results and chosen variant.
- **Build system detection of .appex validity** — `make app` must fail clearly if the .appex assembly fails.
- **Finder/Preview.app integration verification** — manual checklist for registration + rendering in real Finder.
- **Sandbox entitlement negotiation** — decision checkpoint whether the unsigned repo build produces a working .appex at all (signing may be required even for dev builds).
- **LinkPolicy.swift — Quick Look branch** — QL preview should not open external links; LinkPolicy must be adapted or a QL-safe variant created.
- **ResourceLocator.swift — extension variant** — search logic is hard-wired to the main app layout; extension bundle layout differs.
- **MarkdownDocument.swift — QL compatibility check** — extension receives content differently; reuse trivially or create a QL struct.
- **PreviewController.swift — optional code sharing** — core render logic could be shared as a library target or duplicated with QL-specific adaptations.
- **Swift 6 concurrency (@MainActor, Sendable)** — extension must match the main app's strict-concurrency discipline.
- **App Store / MAS validation notes** — new bundle/entry point may trigger fresh MAS validation; factory signing coordination.
Could not rule out: swiftc/SPM producing a valid .appex in a hand-rolled Makefile; WKWebView + loadHTMLString viability in the QL sandbox; Mermaid/KaTeX feasibility; MAS eligibility without new entitlements; Makefile fragility.
```

Dispositions (union of scout list and planner enumeration):

- Package.swift: new extension target (+ sharing decision) — covered-by Solution (variant selection decides sharing shape)
- Makefile: appex compile + assembly inside `app` target, fail-fast steps — covered-by Solution step "Makefile appex assembly" and DoD item 2
- packaging/Info.plist (main app) — not affected — Apple's extension model discovers `.appex` bundles placed in `Contents/PlugIns/` via LaunchServices registration; the host Info.plist carries no extension declaration (verified against jtbandes/quicklookjs, which embeds its prebuilt appex into third-party apps without host-plist edits). Child bundle id (`dev.markio.app.quicklook`) lives in the appex's own Info.plist.
- packaging/MarkioQuickLook.entitlements (new) — covered-by Solution (app-sandbox entitlements; ad-hoc signed locally, factory re-signs)
- packaging appex Info.plist (new) — covered-by Solution
- vendor assets availability to the extension — covered-by Solution (appex carries its own copy of the resource bundle, ~3.5 MB; cross-bundle reads not guaranteed under the extension sandbox)
- New extension source dir + principal controller — covered-by Solution
- Extension render host (WKWebView) — covered-by Solution; feasibility evidenced by shipping WKWebView-based QL extensions (csv-quick-look, quicklookjs, MermaidViewer)
- Tests — covered-by DoD item 3; new `QuickLookTests` live in the existing `MarkioTests` target (test targets may depend on multiple targets; a separate test target adds no coverage). The full JS render path is already covered by `RenderTests` over the same engine assets.
- SRS / SDS / index / task file / checklist — covered-by DoD items 1 and 4
- Sandbox + signing checkpoint — covered-by Solution (ad-hoc `codesign --sign -` of the appex only; distribution signing stays in app-store-factory); loading verified via the manual checklist
- LinkPolicy.swift — not affected — the extension installs its own minimal navigation delegate that allows only the initial `loadHTMLString` navigation and cancels everything else; `LinkPolicy` (app semantics: open browser) is not reused and not modified
- ResourceLocator.swift — covered-by Solution step 2 (moved into the shared `MarkioEngine` library; bundle name becomes `Markio_MarkioEngine.bundle`; the appex carries the bundle in `Contents/Resources` where the existing `Bundle.main.resourceURL` search base resolves)
- MarkdownDocument.swift — not affected — the extension reads the previewed file itself (`String(contentsOf:encoding:)`, fail → QL system fallback); `MarkdownDocument` stays app-only (evidence: `Sources/Markio/MarkdownDocument.swift` is `FileDocument`/SwiftUI-bound)
- PreviewController.swift sharing — not affected — selected Variant B leaves `PreviewController` app-only; the extension ships its own ~60-line `QuickLookRenderHost` (loadTemplate/render/setDark only)
- Swift 6 concurrency — covered-by Solution (extension target compiled in the same package with `.swiftLanguageMode(.v6)`; controller is `@MainActor`)
- MAS validation of the new appex — deferred — human choice (App Store submission/factory concern outside this repo; noted in Follow-ups)

## Definition of Done

- [ ] FR-QUICKLOOK: Space on a `.md`/`.markdown` file in Finder shows the
  document rendered by Markio's engine — GFM, Mermaid diagrams, KaTeX math,
  frontmatter box, light/dark following the system.
  - Test: `manual — maintainer — documents/checklists/quicklook.md`
  - Evidence: checklist file exists and is walked on a locally built `.app`
    (`make app` → register → `qlmanage -p`): `test -f documents/checklists/quicklook.md`
- [x] FR-QUICKLOOK: `make app` assembles the `.appex` without Xcode —
  extension binary, Info.plist, resource bundle, ad-hoc-signed, embedded in
  `Contents/PlugIns/`.
  - Test: bundle-structure + registration verification (build product)
  - Evidence: `make app && test -x .build/Markio.app/Contents/PlugIns/MarkioQuickLook.appex/Contents/MacOS/MarkioQuickLook && test -d .build/Markio.app/Contents/PlugIns/MarkioQuickLook.appex/Contents/Resources/Markio_MarkioEngine.bundle && codesign --verify .build/Markio.app/Contents/PlugIns/MarkioQuickLook.appex && pluginkit -a .build/Markio.app/Contents/PlugIns/MarkioQuickLook.appex && pluginkit -m -p com.apple.quicklook.preview -v | grep -q dev.markio.app.quicklook`
- [x] FR-QUICKLOOK: extension file loading is unit-tested — UTF-8 Markdown
  decodes; non-UTF-8 fails cleanly (QL then falls back to the system preview).
  - Test: `Tests/MarkioTests/QuickLookTests.swift::testLoadsUTF8MarkdownAndRejectsBinary`
  - Evidence: `swift test --filter QuickLookTests`
- [x] FR-QUICKLOOK: SRS gains section FR-QUICKLOOK with `**Acceptance:**`
  filled; SDS gains the extension component section; index row added.
  - Test: docs review (part of review phase)
  - Evidence: `grep -q 'ANC:fr:quicklook' documents/requirements.md`
- [x] Baseline stays green (no regressions in existing suites).
  - Test: full suite
  - Evidence: `make check`

## Solution

Selected: **Variant B** — shared `MarkioEngine` library target; thin view-based
Quick Look extension; hand-assembled, ad-hoc-signed `.appex`.

1. **Extract `MarkioEngine` (behavior-preserving refactor; green baseline before
   and after).** Refactor acceptance: `make check` green BEFORE the move
   (baseline) and AFTER it; the direct locator acceptance is
   `Tests/MarkioTests/OfflineTests.swift::testVendoredAssetsRenderFromDisk`
   (resolves the renamed bundle, inlines vendor assets, renders). Layout
   coverage after the rename: test layout → `swift test`; packaged app layout →
   `make app` + `test -f` of the bundle inside `Contents/Resources`; appex
   layout → DoD item 2 evidence.
   - `Package.swift`: new library `.target(name: "MarkioEngine")` owning the
     resources (`.copy("Resources/template.html")`, `.copy("Resources/vendor")`);
     `Markio` drops its `resources:` and gains the dependency.
   - `git mv Sources/Markio/Resources Sources/MarkioEngine/Resources` and
     `git mv Sources/Markio/ResourceLocator.swift Sources/MarkioEngine/`.
   - `ResourceLocator` becomes `public`; `bundleName` →
     `"Markio_MarkioEngine.bundle"`. Search-base logic unchanged (it already
     covers packaged app, appex, dev, and test layouts).
   - Fix imports: `PreviewController.swift` + `Tests/MarkioTests/OfflineTests.swift`
     add `import MarkioEngine`.
   - `Makefile`: `RELEASE_RESBUNDLE` → `Markio_MarkioEngine.bundle`.
   - New `Sources/MarkioEngine/AGENTS.md` (module doc, listed in `exclude:`).
2. **RED → GREEN: extension input gate in the engine.**
   - RED: `Tests/MarkioTests/QuickLookTests.swift::testLoadsUTF8MarkdownAndRejectsBinary`
     — `MarkdownFileReader.read(url)` returns UTF-8 text; non-UTF-8 bytes throw
     (QL then falls back to the system preview; fail fast, consistent with
     `MarkdownDocument`).
   - GREEN: `Sources/MarkioEngine/MarkdownFileReader.swift` (public, `// FR-QUICKLOOK`).
3. **Extension target.**
   - `Package.swift`: `.executableTarget(name: "MarkioQuickLook",
     dependencies: ["MarkioEngine"], linkerSettings: [.linkedFramework("Quartz"),
     .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])])` —
     the Xcode app-extension entry point. SwiftPM aliases `_main` to
     `_<module>_main` for executable targets, so a stub `main.swift`
     (`fatalError`, never executed — LC_MAIN points at `_NSExtensionMain`)
     satisfies the link. Test target does NOT depend on this target (keeps the
     entry-point flag out of the test-bundle link).
   - `Sources/MarkioQuickLook/QuickLookRenderHost.swift`: minimal `@MainActor`
     WKWebView owner — `loadTemplate()` (self-contained HTML via
     `ResourceLocator`), `render(_:)`, `setDark(_:)`; own navigation delegate
     allows only the initial `loadHTMLString` navigation and cancels everything
     after (QL previews must never navigate; QLTest shows external links
     otherwise open in-preview).
   - `Sources/MarkioQuickLook/PreviewViewController.swift`:
     `@objc(PreviewViewController)` `NSViewController` + `QLPreviewingController`;
     `preparePreviewOfFile(at:completionHandler:)` → read via
     `MarkdownFileReader`, `loadTemplate`, `setDark(effectiveAppearance)`,
     `render`, then `completionHandler(nil)`; any error → `completionHandler(error)`.
   - `Sources/MarkioQuickLook/AGENTS.md` (module doc, excluded).
4. **Packaging artifacts.**
   - `packaging/MarkioQuickLook-Info.plist`: `CFBundlePackageType=XPC!`,
     `CFBundleIdentifier=dev.markio.app.quicklook`, `CFBundleExecutable`,
     versions mirroring the app, `LSMinimumSystemVersion 14.0`,
     `NSExtension { NSExtensionPointIdentifier=com.apple.quicklook.preview,
     NSExtensionPrincipalClass=PreviewViewController, NSExtensionAttributes {
     QLSupportedContentTypes=[net.daringfireball.markdown],
     QLSupportsSearchableItems=false } }`, plus a `UTImportedTypeDeclarations`
     entry for `net.daringfireball.markdown` (md/markdown extensions) so the
     UTI resolves on systems where no other app declares it.
   - `packaging/MarkioQuickLook.entitlements`: `com.apple.security.app-sandbox`
     + `com.apple.security.files.user-selected.read-only` (Xcode QL template
     set; extensions must be sandboxed to load). No `network.client` — QL
     ignores it (QLTest) and WKWebView-based QL extensions demonstrably run
     without it.
5. **Makefile appex assembly (inside `app`, fail-fast).** Exact steps, with
   `QL_APPEX := $(APP_BUNDLE)/Contents/PlugIns/MarkioQuickLook.appex`:
   - `mkdir -p "$(QL_APPEX)/Contents/MacOS" "$(QL_APPEX)/Contents/Resources"`
   - `cp .build/release/MarkioQuickLook "$(QL_APPEX)/Contents/MacOS/MarkioQuickLook"`
   - `cp -R .build/release/Markio_MarkioEngine.bundle "$(QL_APPEX)/Contents/Resources/"`
   - `cp packaging/MarkioQuickLook-Info.plist "$(QL_APPEX)/Contents/Info.plist"`
   - `codesign --force --sign - --entitlements packaging/MarkioQuickLook.entitlements "$(QL_APPEX)"`
     — ad-hoc, appex only (local-run necessity; the factory re-signs with
     `--force` for distribution; the host `.app` stays unsigned). Every step is
     a plain recipe line, so any failure aborts `make app` (fail-fast).
6. **Docs.**
   - SRS: new `FR-QUICKLOOK` section (`[ANC:fr:quicklook]`) with Acceptance =
     structure/evidence command + `manual — maintainer — documents/checklists/quicklook.md`;
     `**Tasks:**` back-pointer to this task.
   - SDS: new component §3.11 "Quick Look extension" + §3.6 bundle-name update
     + §2 subsystems + §7 packaging note (appex assembly + ad-hoc signing).
   - `documents/index.md`: FR-QUICKLOOK row. `documents/checklists/quicklook.md`
     with concrete steps: (1) `make app`; (2) register — `open` the app once or
     `pluginkit -a <appex>`; (3) `pluginkit -m … | grep dev.markio.app.quicklook`
     shows the extension; (4) `qlmanage -p test-fixtures/<doc>.md` renders via
     Markio (GFM table, Mermaid SVG present, KaTeX math typeset, frontmatter
     box); (5) Space in Finder shows the same; (6) dark/light follows system;
     (7) clicking links does nothing (no navigation); (8) principal class loads
     (no "cannot instantiate" in Console — guards the
     `@objc(PreviewViewController)` ↔ `NSExtensionPrincipalClass` name pin).
     Root `AGENTS.md` Documentation Map rows for the new source paths.
7. **Verification.**
   - `make check` (full suite, zero warnings).
   - `make app && test -x .build/Markio.app/Contents/PlugIns/MarkioQuickLook.appex/Contents/MacOS/MarkioQuickLook && codesign --verify <appex>`.
   - Registration smoke test inline: `pluginkit -a <appex>` then
     `pluginkit -m -p com.apple.quicklook.preview | grep dev.markio.app.quicklook`.
   - Real Finder Space behavior: manual checklist (GUI).
   - Findings from the implementation run (recorded in SDS + checklist):
     ExtensionFoundation crashes on hand-assembled appexes missing
     `CFBundleSupportedPlatforms`/`DT*`/`CFBundleInfoDictionaryVersion` keys;
     headless `qlmanage -p -o` cannot host view-based extensions (use GUI
     `qlmanage -p`/Finder); local activation may need
     `pluginkit -e use -i dev.markio.app.quicklook`; the extension process
     spawns and survives a full GUI preview with zero crash reports.

**Error handling:** every extension failure path resolves the QL completion
handler with the error → macOS falls back to the system plain-text preview;
nothing is swallowed (`os.Logger`, subsystem `dev.markio`). **Dependencies:**
none added — Quartz/WebKit are system frameworks; vendored assets unchanged.

## Follow-ups

- **MAS distribution signing of the nested `.appex` (factory repo, out of scope
  here):** the factory's signing lane must sign the embedded extension FIRST
  with its own bundle id (`dev.markio.app.quicklook`) + provisioning profile,
  then the host app (nested-code rule, like an iOS ShareExtension). Recorded
  per orchestrator instruction so it isn't lost.
- If the signed (factory) build shows a blank QL preview, revisit the omitted
  `network.client` entitlement for the appex (the app itself needed it for
  WebContent launch; QLTest reports QL ignores it — verify on a signed build).
- Possible future: Quick Look thumbnail extension (icon-view previews) reusing
  `MarkioEngine` — separate backlog decision.
- MAS validation/review implications of shipping a new extension bundle —
  deferred, human/App Store Connect concern.
