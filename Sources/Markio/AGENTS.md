# Module: Markio (executable target)

Native AppKit/SwiftUI shell hosting one confined `WKWebView` per document. The
shell owns all OS integration; the web view owns only content rendering. See SDS
(`documents/design.md`) §3 for the authoritative component spec.

## Responsibility

- **App shell / OS integration** — `MarkioApp` (`DocumentGroup`, command-line
  open, window-tabbing opt-out), `MenuArtifactCleaner` (idempotently removes
  native New after SwiftUI updates File),
  `FileCommands` (ordered read-only File actions), `FindCommands` (Edit find
  actions), `WindowTitleSetter` (full-path title bar).
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
- **Find** — native find bar (`ContentView.findBar`) + app-level Find menu
  (`FindCommands` routed by the focused-object `DocumentModel`); the search/
  highlight engine lives in `template.html` (`search`/`findNext`/`findPrev`/
  `clearSearch`), bridged by `PreviewController` and driven by `DocumentModel`.
- **File path copy** — `ContentView` publishes its synchronous file URL through
  `FocusedValues.documentFileURL`; `FileCommands` adds File ▸ Copy File Path and
  `FilePathClipboard` writes the absolute path to native `NSPasteboard`.
- **Diagnostics** — `Log` (`os.Logger`, subsystem `dev.markio`): best-effort
  paths (JS bridge, file opens) log failures instead of swallowing them.

## Key decisions

- Hybrid rendering: shell fully native, web view confined to content. Network is
  blocked by `LinkPolicy` at the navigation delegate; assets are vendored offline
  under `Resources/vendor`.
- One `DocumentModel` per window — no shared singleton.
- One `FileCommands` owner defines File ordering; Edit keeps standard Copy and
  contains only the app's Find additions.
- SwiftUI owns commands, focused routing, Open, and Open Recent; AppKit only
  removes public `NSDocumentController.newDocument(_:)` after forwarding the
  original menu update. `AppDelegate` repairs SwiftUI delegate replacement
  before tracking through public launch/activation/update callbacks. Never use
  timers, input monitors, menu titles, indices, or private selectors.
- Layering: Foundation-only file/locator code never imports AppKit/WebKit/SwiftUI.

## UI verification (real app)

Menu/toolbar/window/HUD changes must be checked in a real `.app` (`make app` →
`open .build/Markio.app`), not `make dev` (degraded menu).

- **Do not drive the app via System Events / AX while the user is interacting
  with it.** `activate` + `AXRaise` + `keystroke`/clicks steal window focus and
  keyboard from the user's own testing. Prefer: build, relaunch, and let the
  user observe; run AX/keystroke probes only when the user is not using the app,
  or ask first.
- Screenshots via `screencapture` are blocked here (`could not create image from
  display` — no Screen Recording permission). Inspect the live UI via System
  Events AX instead.
- The bundle is English-only — query File/Edit by title after resolving the
  exact process ID and verifying its executable path.
- System Events `keystroke` is **corrupted by a non-US input source** (a
  Cyrillic layout turns `mermaid` into `mффmффd`). To set text reliably, `set
  value of <AXTextField>` directly — it also drives the SwiftUI binding, so live
  search/actions fire.
- SwiftUI controls are **nested in groups** — walk `entire contents of window`
  recursively; a flat `text fields of window 1` misses them.
