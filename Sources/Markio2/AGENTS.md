# Markio2

The app: documents, windows, menus, preferences, live reload. Wiring only —
anything expensive belongs in MarkioRender or MarkdownKit.

## Rules

- `NSApplication` is driven from `main.swift` rather than `NSApplicationMain`,
  so the menu bar exists before launch completes. Keep it that way.
- The document is **read-only**: no write path, never dirty, never prompts.
- Preferences hold user choices only (reading width, sidebar visibility, scroll
  position per file). Nothing derived and nothing about a document's content.
- A file named on the command line is collected in
  `applicationWillFinishLaunching`, because AppKit asks about opening an
  untitled document before `applicationDidFinishLaunching` runs.

## Where the bodies are buried

- **Swift 6 isolation and `NSDocument`.** Its members are main-actor isolated.
  Opting into `canConcurrentlyReadDocuments` moves construction to a background
  operation queue and traps with `SIGTRAP` before any window shows. The parse
  result lives behind a lock because `read(from:)` is declared nonisolated —
  that is the only reason.
- **Window sizing.** Every edge in the window layout is pinned to a neighbour,
  so the content's fitting size is nearly zero and AppKit collapses the window
  to its title bar. The scroll view's minimum and preferred size constraints
  are what give the window a size; do not remove them as "redundant".
- **`autoresizingMask = [.width]` on the document view** is what lets the
  reading column centre itself.
- **Live reload re-arms after every event**: an atomic save replaces the vnode,
  so the old watch points at a file nobody will write to again.
- **A launch argument's value is not a document.** `-Flag Value` makes AppKit
  present a modal error that blocks the run loop forever; non-existent paths
  are reported and skipped for exactly that reason.

## Debug affordance

`--capture=<path>` draws the visible window into a PNG and quits. It draws the
view hierarchy, so it needs no screen recording permission and works with the
window behind another app. Use it to check rendering instead of asking someone
to look.
