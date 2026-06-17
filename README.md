# Markview

A native macOS app for **viewing** Markdown — nothing more. It renders GitHub
Flavored Markdown and Mermaid diagrams in a clean, minimal, offline reading
surface. The one on-screen reading control is **line width**.

## Features

- GitHub Flavored Markdown (tables, task lists, strikethrough, autolinks, code)
- Mermaid diagrams
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
make dev                       # launch (debug)
make dev ARGS="path/to.md"     # open a file on launch
make prod                      # release build + run
```

Open a document with ⌘O, drag-and-drop onto the window, or *Open With ▸ Markview*
from Finder.

## Develop

```sh
make check    # build + comment-scan + swift-format lint + tests
make test     # tests only (filter: make test ARGS="--filter RenderTests")
make fmt      # apply formatting
```

## Architecture

Native AppKit/SwiftUI shell hosting a single confined `WKWebView`. The shell
owns all OS integration (window, toolbar, menus, file handling, line-width
control); the web view only renders content via vendored JS/CSS
(`Sources/Markview/Resources/vendor`). See `documents/design.md`.

## Scope

Read-only previewer. No editing, export, plugins, or settings sprawl — by design.
