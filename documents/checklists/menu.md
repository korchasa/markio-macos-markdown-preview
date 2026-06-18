# Manual checklist — FR-MENU (read-only menu surface)

Verifies the trimmed, localized menu. Run against a real app bundle — `.commands`
has no effect on the bare `make dev` binary.

## Setup

- `make app`
- `open .build/Markview.app --args <some>.md`

## File menu (Файл)

- [ ] Shows only `Open…` (`Открыть…`) and `Open Recent` (`Открытие недавних`).
- [ ] No `New`, `Save`, `Save As…`, `Duplicate`, `Rename…`, `Move To…`, `Revert To`, `Share`.
- [ ] No inactive/blank `NSMenuItem` placeholder and no stray separators.
- [ ] (Accepted trade-off) `Close`/`Close All` absent — close the window with the red traffic-light button.

## Edit menu (Правка)

- [ ] Standard Edit menu, left intact: Undo/Redo/Cut/Copy/Paste/Delete/Select All.
- [ ] On the (non-editable) preview, the inapplicable items (Cut, Paste, Delete, Undo…) are greyed out; `Copy`/`Select All` work on a text selection.

## Localization

- [ ] With macOS set to Russian, all standard menu titles render in Russian (Файл, Правка, Вид, Окно, Справка; Открыть…, Скопировать, …).

## Unchanged

- [ ] App (`Markview`), `View`, `Window`, `Help` menus are stock.

## Optional automated snapshot

```sh
osascript -e 'tell application "System Events" to tell process "Markview" \
  to get name of menu items of menu 1 of menu bar item 3 of menu bar 1'
# Russian system → Открыть…, Открытие недавних
```
