# Markio2QuickLook — Finder's preview panel

The Quick Look preview extension. It parses the file with `MarkdownKit` and
draws it with `MarkioRender` — the same two modules the app uses — inside a
scroll view that Quick Look sizes.

## What makes this one simple

Everything hard about a Quick Look extension in a web-based viewer is absent
here. There is no template to load, no web view to boot, no navigation to await:
`preparePreviewOfFile` parses, builds a layout, installs a view, and calls the
completion handler on the same turn. A preview cannot hang waiting for something
that never arrives, because it waits for nothing.

That is also why `packaging/Markio2QuickLook.entitlements` carries no
`com.apple.security.network.client`. A sandboxed `WKWebView` needs it or its
WebContent helper never launches and Finder spins forever; a CoreText renderer
does not.

## Rules

- The `@objc` class name `PreviewViewController` is referenced verbatim by
  `NSExtensionPrincipalClass` in `packaging/Markio2QuickLook-Info.plist`.
  Renaming the class without the plist gives a preview that silently never
  loads.
- `main.swift` is never executed. The entry point is `_NSExtensionMain`, set by
  the linker flags in `Package.swift`; SwiftPM merely wants an entry symbol.
- Read nothing from the app: the extension is sandboxed apart from it, so the
  reading width is a constant here rather than the reader's preference.
- Only `net.daringfireball.markdown` is claimed. Taking over `public.plain-text`
  would put this in front of every `.txt` preview on the machine.
- Failures go back through the completion handler. macOS then shows its own
  plain-text preview, which beats an empty panel.
