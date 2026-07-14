# Manual checklist — FR-QUICKLOOK (Quick Look preview extension)

Automated coverage: bundle structure, ad-hoc signature, pluginkit registration,
UTF-8 input gate (see SRS FR-QUICKLOOK Acceptance). This checklist covers what
only eyes on a real Quick Look panel can verify.

Setup:

1. `make app`
2. Register: `open .build/Markio.app` once (or
   `pluginkit -a "$PWD/.build/Markio.app/Contents/PlugIns/MarkioQuickLook.appex"`).
3. If the extension does not activate, elect it:
   `pluginkit -e use -i dev.markio.app.quicklook`, and confirm
   `pluginkit -m -v -i dev.markio.app.quicklook` shows a `+` prefix.
4. NOTE: headless `qlmanage -p -o <dir>` CANNOT host view-based extensions
   (crashes in ExtensionFoundation: "Unable to load host extension context
   class") — always test via GUI `qlmanage -p <file>` or Finder.

Checks (use `test-fixtures/render-suite.md`):

- [ ] `qlmanage -p test-fixtures/render-suite.md` shows the Markio-rendered
      document (not the system plain-text preview).
- [ ] Space on the file in Finder shows the same rendered preview.
- [ ] GFM table is laid out as a table; task-list checkboxes render.
- [ ] Mermaid block renders as an SVG diagram, not code.
- [ ] KaTeX math is typeset; frontmatter shows as the captioned YAML box.
- [ ] Dark/light: preview theme matches the system appearance.
- [ ] Clicking any link inside the preview does nothing (no navigation, no
      browser).
- [ ] A non-UTF-8 `.md` file falls back to the system preview (no blank panel).
- [ ] Console shows no "cannot instantiate" / principal-class errors for
      `dev.markio.app.quicklook` (guards the `@objc(PreviewViewController)` ↔
      `NSExtensionPrincipalClass` name pin).
