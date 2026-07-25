# Manual checklist — FR-COMPARE (inline-diff compare)

Run against a real bundle: `make app && open .build/Markio.app`.
Prepare two versions of one document: `v2.md` (open it) and `v1.md` — v2
should add a section, delete a paragraph, and keep most content unchanged.

1. Open `v2.md`. The File menu shows `Compare…` (enabled, ⇧⌘C) and
   `Stop Comparing` (disabled).
2. Pick `Compare…` → an open panel appears, pre-pointed at the document's
   folder, prompt button "Compare". Cancel → nothing happens.
3. Pick it again and choose `v1.md` → the SAME window now shows the diff:
   content added since v1 carries a green accent, paragraphs deleted since
   v1 appear at their original position as dimmed red blocks, unchanged
   content has no markers. No second window opens. Without switching
   windows, `Stop Comparing` is enabled right away.
4. TOC sidebar, ⌘F find, and the width slider work over the diff view
   (find matches text inside removed blocks too).
5. Edit `v2.md` externally (add a paragraph) → the diff view refreshes and
   the new paragraph is marked added.
6. While compared, check `File ▸ Compare Side by Side` → the same window
   splits into two aligned columns: v1 left with deleted blocks marked red,
   v2 right with added blocks marked green; unchanged sections sit at the
   same height opposite each other; one scroll moves both. Resize the
   window and move the width slider — alignment holds. Uncheck → the inline
   view returns. Quit and relaunch while the toggle is on → a new compare
   opens in split layout (persisted preference).
7. `File ▸ Stop Comparing` → the plain document view returns, no markers
   remain; `Stop Comparing` is disabled again right away.
8. Pick `Compare…` and choose `v2.md` itself → nothing happens (self-compare
   is a no-op).
9. Compare again, close the window, reopen `v2.md` → plain view (the
   baseline choice is session-only).
