---
date: 2026-09-15
status: done
implements: [VIEW-32]
tags: [sandbox, entitlements, pdf, print, app-review]
related_tasks: []
---

# Export as PDF did nothing in the sandbox, and the local build could not see it

## Goal

Make Export as PDF and Print work in the shipped, sandboxed app, and make the
local build fail the same way the shipped one would, so this class of defect
cannot reach App Review again.

## Overview

### What happened

App Review rejected Markio 1.0 (build 11) on 2026-09-13 under **Guideline
2.1(a) — Performance: App Completeness**. The message: *"We were unable to use
the core feature, Export as PDF.., because the tab does not respond when clicked
and unable to verify feature."* The attached screenshot shows the File menu open
with **Export as PDF… enabled and highlighted** over a `.txt` document, so the
command was reaching its target — it simply did nothing.

### The cause

`packaging/Markio.entitlements` declared `files.user-selected.read-only`, and
`DocumentWindowController.exportPDF` puts up an `NSSavePanel`. AppKit will not
display a save panel to an app holding read-only access. The system log says so
in one line, captured here while reproducing it:

```
[com.apple.AppKit:OpenSavePanels] Unable to display save panel: your app has the
User Selected File Read entitlement but it needs User Selected File Read/Write
to display save panels.
```

Print is the same path (`PrintableDocument`), so "Save as PDF" from the print
panel was dead for the same reason.

### Why nobody here saw it

Local builds were linker-signed ad-hoc with **no entitlements at all**, so they
ran outside the sandbox entirely — `codesign -d --entitlements` on the installed
"Markio Dev" returned nothing. Outside the sandbox the save panel always opens.
The same blind spot had already cost VIEW-16 (pictures beside a document drew an
empty frame on the Mac App Store and nowhere else); that time the conclusion was
written down and the tooling was left as it was.

Reproduced on this machine by signing the same binary two ways: ad-hoc with the
real entitlements — the menu click produced nothing, and the log line above;
ad-hoc with no entitlements — the save panel appeared normally.

## Definition of Done

- [x] The sandboxed app can display the save panel (the AppKit refusal is gone
      from the log, and the panel appears).
- [x] `deno task app` signs the bundle with the app's real entitlements, and so
      does the dev copy in `/Applications`.
- [x] `deno task dist` still produces the unsigned bundle signing outside this
      repository expects.
- [x] `deno task check` fails when a source file uses `NSSavePanel` while the
      entitlements do not carry the write capability (red probe run).
- [x] `deno task check` green.

## Solution

**Entitlements.** `files.user-selected.read-only` →
`files.user-selected.read-write`. Write access reaches only the file the reader
names in the panel; nothing else about what the app touches changes.

**Local signing.** `app()` takes `signHost` (default true) and signs the bundle
ad-hoc with `packaging/Markio.entitlements`, nested bundle first; `install.ts`
signs the installed copy the same way after rewriting its bundle id. `dist.ts`
passes `signHost: false`, so the artifact leaving this repository stays
unsigned.

**Gate.** A new `check` step scans the sources for `NSSavePanel` and fails if
the entitlements lack `com.apple.security.files.user-selected.read-write`.
