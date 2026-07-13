# Manual checklist — FR-SESSION-RESTORE (recent documents + window restore)

Verifies Open Recent and reopen-at-relaunch. Run against a real app bundle —
`DocumentGroup`/AppKit state restoration and the recents list depend on bundle
identity, absent from the bare `make dev` binary.

NB: the local `make app` bundle is unsigned → no App Sandbox. Items below prove
the restoration mechanics; sandbox-specific access on reopen is re-verified on
a signed TestFlight build (system-managed for both recents and restoration —
no bookmark entitlement is expected).

## Setup

- `make app`
- `open .build/Markio.app test-fixtures/<a>.md` and a second document.

## Open Recent

- [ ] 1. `File ▸ Open Recent` lists both opened documents (most recent first).
- [ ] 2. Closing a document window, then picking it from `Open Recent`, reopens
  it — at the scroll position it was closed at.

## Reopen at relaunch

- [ ] 3. Scroll both documents away from the top; quit (⌘Q); relaunch
  (`open .build/Markio.app`) → the same document windows reopen (no Open
  panel), regardless of the system "Close windows when quitting an
  application" setting.
- [ ] 4. Each reopened document sits at its pre-quit scroll position.

## Regression guards

- [ ] 5. A fresh launch with no prior session (clear state:
  `defaults delete dev.markio.app` + relaunch) still shows the system Open
  panel — no crash, no phantom windows.
- [ ] 6. Live reload still preserves the reading position (edit the open file
  externally while scrolled down).
