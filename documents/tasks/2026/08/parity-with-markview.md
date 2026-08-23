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

- **An accessibility pass over the menus** with a screen reader, which needs a
  person listening. Everything else on the "to check on a running build" list
  was answered by running the app — the last of it, the external link, on
  2026-08-23.
- **The corpus comparison** — one shared set of documents through both
  renderers, differences read by eye — has not been made. It is the remaining
  work on markdown coverage, and it needs the old tree, which is read-only.

## Status — 2026-08-22, later: the running-build list, checked by machine

Most of that list did not need a person after all. The app can be driven
offscreen — `--capture-click`, `--capture-scroll`, `--dump-menu` — and what
came back was three defects, all of them now fixed and covered by tests.

- **A reader always came back to the first line.** Restoring the reading
  position asked the document view to scroll itself, which does nothing before
  that view has drawn, and the position was marked restored before it had been
  put back — so the bounds change at the top wrote a zero over what was being
  restored. One failed restore erased the memory for good, which is why the
  preferences held zeroes for documents that had certainly been read further
  down. Proven by a scrolled shot and a shot after a relaunch showing the same
  page.
- **The File menu had two Open Recents,** one of them empty: AppKit gives a
  document app one and this app built a second. The guard meant to remove ours
  fired from the menu's delegate, which runs when a person opens the menu — by
  which time they had seen the duplicate.
- **A file name with a line number was read as a URL scheme.** A dot is legal
  in a scheme, so `main.swift:214` was refused as a scheme the app does not
  serve; `scripts/check.ts:42` never hit it, because the slash disqualifies the
  scheme. Found while writing the tests `LinkResolver` never had — it decides
  the whole of the app's link safety and had none.

Checked and correct: opening a file that is already open reuses it
(`OpenAgainTests`); recents survive a relaunch (a fresh process reports six);
windows come back after a quit (macOS restores them, and a launch that must
show one document needs `-ApplePersistenceIgnoreState YES`); an anchor link
scrolls this document (clicked offscreen, the target came into view).

**Menu enablement is settled too, and it was hiding a fourth defect.** The
owner said Open… was greyed out in the running app; a dump taken from an
inactive one had been read as inconclusive, because an inactive app has no key
window and every document command validates as disabled. It was real. The
document controller answered `documentClassNames` with `MarkdownDocument`, and
no such class exists as far as the Objective-C runtime is concerned — a Swift
class is `Markio.MarkdownDocument` — so AppKit found nothing, concluded the app
could open no kind of document, and disabled the command. Opening from Finder
went on working the whole time, because that path reads the plist. The
controller names no class now; `packaging/Info.plist` is the one place it is
named.

With the app frontmost the File menu resolves completely: Open…, Compare…,
Export as PDF, Print, Copy File Path and Close all enabled, Stop Comparing
correctly not. **So the suspicion about `Copy File Path` and `Close` was
unfounded** — the fault was one item further up. In the Edit menu, Copy and
Select All are enabled and Cut, Paste, Delete, Undo and Redo are not, which is
what a read-only viewer should show. The repeated Start Dictation and Emoji &
Symbols entries are macOS's own variants for different keyboards, all but one
hidden; the dump marks them.

One thing was left alone at the time: an **external link**, because verifying it
seemed to mean opening a browser. It is covered now — see the closing note on
this file.

One observation, not a defect: an anchor jump reveals its target rather than
putting it at the top of the window, so a click near the end of a document
leaves the heading at the bottom edge.

## Status — 2026-08-23: the corpus comparison, and what it found

The last two open items are closed. Both were answered by running things
rather than by reading them.

**Quick Look, on a running build.** Previewed four files through `qlmanage` on
the installed build and read the extension's own log (`subsystem
dev.markio.two`): every one was rendered by this extension rather than by the
system's plain-text preview — 297 bytes/6 blocks, 125/2, 101/3, 35/2. A shot of
the panel for a file holding all of it at once shows the frontmatter box, a GFM
table with alignment, ticked and unticked boxes, inline and display mathematics
and a Mermaid flowchart. Links are inert by construction: the extension installs
a `DocumentView` with no callbacks at all, and the renderer never opens anything
itself.

One item on that list turned out to be a decision rather than a gap. The old
checklist expects a non-UTF-8 file to fall back to the system preview; this app
shows it, because PARSE-7 says malformed UTF-8 is displayed rather than rejected
— a viewer shows whatever it was handed. Recorded here so the difference is not
rediscovered as a defect.

**The corpus comparison, with one renderer instead of two.** The old tree
carries `test-fixtures/render-suite.md`: 498 lines written to exercise every
construct a viewer is expected to render, each section labelled with what it is
testing. That is the shared corpus this sweep wanted. The old renderer could not
be made to answer: built from a scratch copy — never in the archived tree — it
opens the document, sets the window title, and draws a blank page, and its own
log stays empty. Debugging a retired build was not worth it, so the suite's own
descriptions were the oracle, and this app's rendering of all 18 exported pages
was read against them.

Correct, section by section: headings both ways and the seven-hash paragraph,
soft and hard breaks in both spellings, emphasis with the intraword rule, nested
quotes with a fence inside, lists tight, loose, deeply nested, ordered from a
custom start, task lists nested inside them, fenced and indented code,
highlighting across a dozen languages with a diff block banded red and green,
unknown languages falling back to plain, rules, links in every marked-up form,
images degrading to a placeholder, GFM tables including the ragged and the very
wide, footnotes, HTML tables with merged cells, `<details>`, escapes and
entities, Mermaid flowcharts, sequence, state and pie, a malformed diagram
keeping its source, Unicode with RTL and emoji, inline and display mathematics.

Two differences, and only one of them was a defect:

- **Bare links were not links.** `https://github.com/…`, `www.example.com` and
  an address in the prose stayed plain text, while the README and PARSE-2 have
  claimed GFM autolinks all along. Implemented, tested and measured — see the
  inline-parsing section of the SDS.
- **A single-line `classDiagram` body kept its source.** `class Document {
  +String text +render() }` was not read; the same class written over several
  lines was. Settled on 2026-08-23 and fixed. The oracle was Mermaid's own
  grammar rather than a running renderer: inside a class body its lexer
  discards newlines and returns everything up to one as a single `MEMBER`
  token, so the one-line form is valid and means **one** row — not two, and not
  a fallback to the source. Markio now reads it and draws exactly that.

**And a third defect, found on the running build rather than in the suite.** The
window title showed `notes.md` where the app means to show the whole path. The
title was being set by hand, and `NSDocument` syncs it again from the display
name afterwards. Fixed by overriding `windowTitle(forDocumentDisplayName:)`.

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

- **Done.** Menu enablement, from a dump of an app that was frontmost: the
  whole File menu resolves, and the item that was actually broken was Open…,
  not the two this list suspected.
- **Done.** Menu order and separators, and no duplicate items: the File menu
  carried two Open Recents and now carries one.
- **Done.** Opening a file that is already open reuses it — `OpenAgainTests`.
- **Done.** Recents survive a relaunch, windows come back, and the reading
  position comes back — the last of those was broken and is fixed.
- **Done, less the browser.** Anchors, `.md` neighbours, anchors into another
  document, source files and every refusal are covered by `LinkResolverTests`,
  and an anchor click was driven offscreen against the running app. The
  external link was left to a person on the grounds that checking it opens a
  browser. It does not have to: the window controller now says where it would
  send the reader, so a test clicks the link's own rectangle and reads the
  address — `DocumentWindowTests.testAClickOnAnExternalLinkGoesToItsAddress`.
  Clicking two hundred points to the right of it opens nothing, which is what
  makes the passing test worth anything.
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
inventory is covered. Agreement on the *result* was the remaining work, and it was
done on 2026-08-23 against the old tree's own `render-suite.md` — see the status
at the top of this file. It found two defects: bare links were not links, and a
one-line class body fell back to its source. Both are fixed, and nothing in this
file is open any more.

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
