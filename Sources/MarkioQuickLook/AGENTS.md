# MarkioQuickLook

Quick Look preview extension: Space on a `.md`/`.markdown` file in Finder
renders it with Markio's engine (GFM, Mermaid, KaTeX) — capabilities the
system preview lacks.

## Responsibility

- `PreviewViewController` — `QLPreviewingController` principal class; reads the
  previewed file (strict UTF-8 via `MarkdownFileReader`), errors fall back to
  the system preview.
- `QuickLookRenderHost` — minimal WKWebView owner: `loadTemplate` / `render` /
  `setDark` only. No message handlers, no link opening; every post-load
  navigation is cancelled.

## Key decisions

- **View-based, not data-based**: the data-based Quick Look API
  (`QLPreviewReply` HTML) does not execute JavaScript, which Mermaid requires.
  A view-based controller hosting its own WKWebView runs the full engine.
- **No main entry point**: the binary links with entry `_NSExtensionMain`
  (Foundation) via linker flags in `Package.swift` — how Xcode links app
  extensions. The `.appex` bundle is assembled and ad-hoc signed by `make app`
  (see Makefile); distribution signing happens in app-store-factory.
- The appex carries its own copy of `Markio_MarkioEngine.bundle` — reading the
  host app's copy across the extension sandbox boundary is not guaranteed.
