# MarkioEngine

Shared rendering engine, extracted so the app and the Quick Look extension use
exactly one copy of the vendored web bundle and its loading logic.

## Responsibility

- Own the offline rendering assets: `Resources/template.html` + `Resources/vendor/`
  (markdown-it, mermaid, highlight.js, KaTeX, DOMPurify, github-markdown-css).
- `ResourceLocator` — resolve the SwiftPM resource bundle
  (`Markio_MarkioEngine.bundle`) across every shipped layout (packaged `.app`,
  embedded `.appex`, `swift run`, `swift test`) and inline the vendor assets
  into one self-contained HTML document (`selfContainedHTML()`), the
  sandbox-proof `loadHTMLString(baseURL: nil)` path.
- `MarkdownFileReader` — the extension's input gate: strict UTF-8 file read,
  fail fast on non-UTF-8 (consistent with the app's `MarkdownDocument`).

## Key decisions

- No WKWebView code here: consumers (app `PreviewController`, extension
  `QuickLookRenderHost`) own their web views; the engine owns only assets and
  their resolution. Keeps the library AppKit-free.
- The custom locator (not `Bundle.module`) is deliberate — see the header
  comment in `ResourceLocator.swift`.
