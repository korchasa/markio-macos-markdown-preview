# Markio

A native macOS app for **viewing** Markdown — nothing more. It renders GitHub
Flavored Markdown and Mermaid diagrams in a clean, minimal, offline reading
surface. The one on-screen reading control is **line width**.

## Features

- GitHub Flavored Markdown (tables, task lists, strikethrough, autolinks, code)
- Mermaid diagrams
- LaTeX math formulas (inline `$…$` and block `$$…$$`, via KaTeX, offline)
- YAML frontmatter rendered as a highlighted metadata block
- Syntax highlighting (light/dark, follows system appearance)
- Live reload on external edits
- Adjustable reading width (toolbar slider), persisted across launches
- Fully offline — all rendering assets are vendored; the web view never touches
  the network

## Requirements

- macOS 14+
- Swift 6.3 toolchain (Xcode 16+)

## Run

```sh
make dev                       # launch raw debug binary (fast; each run = new process)
make dev ARGS="path/to.md"     # open a file on launch
make app                       # release build packaged as .build/Markio.app
make prod                      # build the .app and launch it (single instance)
make prod ARGS="path/to.md"    # …and open a file
```

`make prod` builds a real `Markio.app` bundle, so macOS keeps a **single
instance** and routes every open into it (one window per document), and Finder
"Open With ▸ Markio" works. The raw `make dev` binary has no bundle, so each
launch is a separate process — fine for quick debugging.

Open a document with ⌘O, drag-and-drop onto a window, or *Open With ▸ Markio*
from Finder. Each file opens in its own window (no tabs — one document = one
window); *File ▸ Open Recent* and state restoration are provided by the system.

## Develop

```sh
make check    # build + comment-scan + swift-format lint + tests
make test     # tests only (filter: make test ARGS="--filter RenderTests")
make fmt      # apply formatting
```

## Architecture

Native AppKit/SwiftUI document app (`DocumentGroup`): one window per file, each
hosting a confined `WKWebView`. The shell owns all OS integration (windows,
toolbar, menus, file handling, line-width control); the web view only renders
content via vendored JS/CSS (`Sources/Markio/Resources/vendor`). See
`documents/design.md`.

## Scope

Read-only previewer. No editing, export, plugins, or settings sprawl — by design.
