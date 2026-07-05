# Module: Markio (executable target)

Native AppKit/SwiftUI shell hosting one confined `WKWebView` per document. The
shell owns all OS integration; the web view owns only content rendering. See SDS
(`documents/design.md`) §3 for the authoritative component spec.

## Responsibility

- **App shell / OS integration** — `MarkioApp` (`DocumentGroup`, command-line
  open, window-tabbing opt-out), `MenuArtifactCleaner` (trims the read-only menu),
  `WindowTitleSetter` (full-path title bar).
- **Document** — `MarkdownDocument` (read-only `FileDocument`, UTF-8 decode,
  canonical Markdown `extensions` + `URL.isMarkdown`).
- **Per-window state** — `DocumentModel` (owns preview/watcher/reading width,
  re-renders on appearance + live reload).
- **Render host** — `PreviewController` (native↔JS bridge over the `WKWebView`),
  `PreviewView` (SwiftUI wrapper), `LinkPolicy` (in-page vs external vs block),
  `ResourceLocator` (vendored bundle URLs).
- **File I/O** — `FileLoader` (off-main-thread read), `FileWatcher` (FSEvents
  live reload).
- **Reading width** — `ContentWidthStore` (persisted absolute char width),
  driven by the bottom-bar slider in `ContentView`.
- **Diagnostics** — `Log` (`os.Logger`, subsystem `dev.markio`): best-effort
  paths (JS bridge, file opens) log failures instead of swallowing them.

## Key decisions

- Hybrid rendering: shell fully native, web view confined to content. Network is
  blocked by `LinkPolicy` at the navigation delegate; assets are vendored offline
  under `Resources/vendor`.
- One `DocumentModel` per window — no shared singleton.
- Layering: Foundation-only file/locator code never imports AppKit/WebKit/SwiftUI.
