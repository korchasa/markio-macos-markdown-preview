# Manual checklist — FR-MULTIDOC (one window per document)

Reviewer: maintainer. Run `make dev` (or a release `.app`) and verify each.
Tip: inspect window titles via System Events AXTitle (`osascript -e 'tell application "System Events" to tell (first process whose name is "Markview") to get title of window 1'`) — `screencapture` needs Screen Recording permission and may be unavailable in headless/agent shells.



- [ ] With a document open, ⌘O → choose another `.md` → a **new window** appears; the first window is unchanged.
- [ ] Drag a `.md` onto an open window → it opens in a **new window** (does not replace the current one).
- [ ] Opening a file that is already open focuses its existing window (no duplicate).
- [ ] Each window's title bar shows that document's full path (no proxy icon — intentional trade-off).
- [ ] Each window's line-width slider adjusts only that window.
- [ ] Live reload affects only the window showing the edited file.
- [ ] File ▸ Open Recent lists previously opened documents.
- [ ] No window tabs: View menu has no "Show Tab Bar"; opening files never merges them into tabs (even with macOS "prefer tabs: always").
- [ ] Quit-then-relaunch state restoration works (system-provided).
- [ ] No Save / no "Edited" state — documents are read-only.
- [ ] Fresh launch with no prior windows shows the system Open panel (no welcome screen).
