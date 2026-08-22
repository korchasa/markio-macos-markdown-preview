# Parity sweep against the web implementation

The predecessor rendered through `WKWebView` with markdown-it, Mermaid and
KaTeX vendored inside it. This app replaced it on 2026-08-11 with a byte-level
parser and CoreText. Small conveniences were reported missing after the switch,
so this is a systematic sweep rather than a list of complaints.

The old tree is read-only and has no remote — it is the sole copy of that
history. Nothing here writes to it.

## Status — 2026-08-22: the five gaps are closed, the manual checks are not

Everything under "Genuinely missing" below shipped in `5bcfd3a`: `Close All`
(⌥⌘W), the standard Edit items present and greyed out on a read-only document,
`Compare…` back on ⇧⌘C, window tabs refused outright (`tabbingMode =
.disallowed`), and `Side by Side` moved back under View beside the Table of
Contents. `MenuTests` covers the shape of the menu, so a later edit cannot
quietly drop an item again.

Still open, and open on purpose:

- **"To check on a running build"** is a list of things code cannot answer. They
  need the app open in front of a person, and an accessibility pass for the menu
  items.
- **The corpus comparison** — one shared set of documents through both
  renderers, differences read by eye — has not been made. It is the remaining
  work on markdown coverage, and it needs the old tree, which is read-only.

## Where the old behaviour is written down

Four sources, each catching a class the others miss. Together they are the
inventory; none of them alone is.

- **Nine acceptance checklists**, 75 checkable items: menu (15), Quick Look
  (13), one-window-per-document (11), compare (9), local links (7), open (6),
  session restore (6), appearance (5), icon (3). Hand-written for manual
  verification, so they carry the small behaviour no requirement mentions.
- **77 test names.** Each is an assertion about behaviour. Mapped against this
  app's 307 tests by meaning, not by name.
- **The SRS and 24 task files.** What was intended, and — more useful — why a
  behaviour was shaped the way it was.
- **Two code surfaces.** The old app split its features: menu items and key
  equivalents in Swift, and roughly a dozen handlers that lived only in the web
  layer (zoom `+`/`-`/`0`, arrows, Escape, copy-on-`c`, the copy button on code
  blocks). The second half never appeared in a menu and is invisible if you
  read only the Swift.

A fifth source cannot be read at all: a running build. Menu enablement,
drag-and-drop, recents and restoration are decided at runtime, and code
inspection cannot tell an item that is absent from one that is present but
never enabled.

## Present, verified in code

- `Copy File Path` — `MainMenu.swift:89`, implemented at
  `DocumentWindowController.swift:730`: absolute path, plain string, no
  `file://`, no trailing newline, pasteboard untouched when the document has no
  URL. Matches the old checklist item exactly. Landed 2026-08-08 in the first
  native commit, so it has never been absent from this app.
- `Close` on ⌘W — `MainMenu.swift:95`.
- Find, Find Next, Find Previous on ⌘F/⌘G/⇧⌘G, with the match counter
  (`FindBar.swift:15`) and the match overview strip (`FindOverview.swift`).
- Compare, Side by Side, Stop Comparing, with `Stop Comparing` disabled unless
  a comparison is running (`validateMenuItem`, `DocumentWindowController.swift:748`)
  and the side-by-side state reflected as a checkmark.
- Table of Contents sidebar with the current section tracked while scrolling
  (`OutlineSidebar.swift:63`).
- Column width, wider and narrower, persisted.
- Window title is the document's full path (`DocumentWindowController.swift:499`).
- Open panel on a launch with no prior session (`AppDelegate.swift:240`).
- Drag-and-drop of a file onto a window (`DocumentView.swift:582`).
- Scroll position saved on close and restored on open (`Preferences`).
- Live reload (`FileWatcher.swift`).
- Open Recent, wired through AppKit's own recents menu.
- Diagram zoom, pan and copy-as-PNG; the copy button on code blocks; the
  language badge from the fence info.
- Follows the system light/dark appearance.
- Quick Look extension.

## Genuinely missing

- **`Close All` (⌥⌘W).** The old File menu carried it next to `Close`; there is
  no equivalent here and no `closeAll` anywhere in the sources. With one window
  per document and no tabs, closing six windows is six ⌘W.
- **The standard Edit items.** The old Edit menu kept Undo, Redo, Cut, Paste
  and Delete present and greyed out on the read-only preview; this menu has
  only Copy, Select All and the three Find commands. Users read a missing item
  as a missing capability, and system features that walk the Edit menu see a
  menu that is not standard.
- **`Compare…` lost its ⇧⌘C shortcut.** It is in the menu, but only reachable
  by mouse.
- **Nothing disables window tabs.** The old build was explicitly checked
  against macOS "prefer tabs: always"; no `tabbingMode` is set here, so on a
  system configured that way documents can merge into tabs — which breaks the
  one-window-per-document rule the app is built on.
- **Side by Side moved from View to File.** Not a loss of function, but the old
  checklist expects it under View next to Table of Contents, and that is where
  a returning user will look.

## To check on a running build

Code cannot answer these; they need the app open and, for the menu items, an
accessibility pass like the one the old `menu.md` describes.

- Whether `Copy File Path` and `Close` are **enabled** when a document window is
  key. Both are routed through the responder chain, so a chain that does not
  reach `DocumentWindowController` leaves a visible item that does nothing.
  This is the likeliest explanation for the original report, since both
  commands demonstrably exist in the code.
- Menu order and separators: one separator between groups, no stray or
  duplicate items after opening File repeatedly.
- Opening a file that is already open focuses the existing window instead of
  making a second one.
- Recents survive a relaunch; windows and their scroll positions come back
  after ⌘Q.
- Local links: anchor within the document, `.md` link to a new window, anchor
  into an already-open document, external link to the browser, non-Markdown
  link doing nothing.
- Quick Look: rendered preview rather than plain text, tables and task lists,
  Mermaid as a diagram, KaTeX typeset, frontmatter box, links inert, non-UTF-8
  falling back to the system preview.

## Markdown coverage, the other half of parity

Menus are the visible half. The old app inherited markdown-it's syntax
coverage; this one parses the text itself, so gaps show up as syntax that
renders differently rather than as a command that is gone. The old test names
name the constructs that were guaranteed: GFM tables, task lists, frontmatter
as metadata, inline HTML sanitised, HTML tables, KaTeX math, ANSI escapes in
code, long tokens that must not break the layout, malformed input that must not
crash, and a large document that must not hang.

All have counterparts here (`HTMLTableTests`, `InlineParserTests`,
`MathTests`, `AnsiTextTests`, `MermaidTests`, `PlainTextParityTests`), so the
inventory is covered. What is not covered is agreement on the *result*: the two
implementations were never run over one corpus and compared. That comparison is
the remaining work in this area — one shared corpus, both renderers, differences
read by eye, since there is no oracle.

## Repeating this sweep

1. Read the nine checklists; each item is a yes/no question about behaviour.
2. Diff the two menu surfaces — old Swift key equivalents plus the web-layer
   handlers against `MainMenu.swift`.
3. Walk the 77 old test names and find the counterpart here by meaning.
4. Run the app and answer the runtime list above.

Three verdicts, not two: present, missing, or dropped on purpose. The old
build's web-engine machinery — vendored assets rendering from disk, the
"no network requests" guard, the menu surgery that removed AppKit's `New` item
from a SwiftUI menu — has no meaning here and should not be carried over.
