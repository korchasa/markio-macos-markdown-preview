# Manual checklist — FR-MENU (ordered read-only menu)

Verifies File ordering, focused-document routing, and standard Edit preservation.
Run a real app bundle; the bare `make dev` binary has a degraded menu.

## Setup

- `make app`
- Record existing Markio process IDs, then run
  `open -n -a "$(pwd)/.build/Markio.app" --args <a>.md <b>.md`.
- Identify the new PID and verify `ps -p <pid> -o command=` starts with the
  workspace `.build/Markio.app/Contents/MacOS/Markio` path. Every accessibility
  query must explicitly iterate over `every application process` and compare
  each `unix id` with `<pid>`; `first process whose unix id is <pid>` can select
  another same-named process. Activate that exact process before opening File.

## File menu

- [ ] Visible groups appear exactly in this order: `Open…` / `Open Recent`;
      `Copy File Path` / `Compare Side by Side…` / `Stop Comparing`;
      `Close` / `Close All`.
- [ ] `Open Recent` opens after File updates and contains recent documents plus
      native `Clear Menu`; opening it never produces a disabled `NSMenuItem`.
- [ ] Exactly one separator lies between groups; no blank `NSMenuItem`, leading,
      trailing, or duplicate separator appears after opening File repeatedly.
- [ ] No `New`, `Save`, `Save As…`, `Duplicate`, `Rename…`, `Move To…`,
      `Revert To`, `Share`, `Import`, `Export`, `Page Setup`, or `Print`.
- [ ] `Close` uses ⌘W; `Close All` uses ⌥⌘W.
- [ ] `Copy File Path` has no shortcut.
- [ ] With one document focused, `Copy File Path` writes its exact absolute path:
      no `file://`, percent encoding, symlink resolution, or trailing newline.
- [ ] With two document windows, raising either window changes the copied path;
      closing it makes the remaining window the command target.
- [ ] `Close All` closes both document windows. With no document, `Copy File
      Path`, `Close`, and `Close All` stay visible but disabled and the clipboard
      remains unchanged.

## Edit menu

- [ ] Standard Undo/Redo/Cut/Copy/Paste/Delete/Select All items remain.
- [ ] On the (non-editable) preview, the inapplicable items (Cut, Paste, Delete, Undo…) are greyed out; `Copy`/`Select All` work on a text selection.
- [ ] `Copy File Path` is absent.
- [ ] Find…, Find Next, and Find Previous each appear exactly once with
      ⌘F/⌘G/⌘⇧G.

## Language

- [ ] The app bundle declares English only; custom titles (`Close`, `Close All`, `Copy File Path`, compare commands) are English.

## Unchanged

- [ ] FR-MENU does not change App (`Markio`), View, Window, or Help.

## Optional automated snapshot

Use `AXShowMenu` before reading items so SwiftUI updates the menu and runs
`MenuArtifactCleaner`. Resolve the application process by the verified PID,
never by `process "Markio"` or a `whose` filter. Assert relative indices instead
of comparing the whole platform-dependent menu: `Open… < Open Recent < Copy
File Path < Compare Side by Side… < Stop Comparing < Close < Close All`; assert
each named item occurs once and Edit contains no `Copy File Path`.
