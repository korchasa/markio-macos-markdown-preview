# Manual checklist — FR-COMPARE (side-by-side compare)

Run against a real bundle: `make app && open .build/Markio.app`.
Prepare two Markdown files of clearly different lengths (e.g. `a.md` ~300
paragraphs, `b.md` ~120).

1. Open `a.md`. The Window menu shows `Compare Side by Side…` (enabled) and
   `Stop Comparing` (disabled).
2. Pick `Compare Side by Side…` → an open panel appears, pre-pointed at the
   document's folder, prompt button "Compare". Cancel → nothing happens.
3. Pick it again and choose `b.md` → `b.md` opens in its own window; the two
   windows tile left/right filling the screen's visible frame.
4. Scroll `a.md` with the trackpad — `b.md` follows live, landing at the same
   fraction of its own length (middle ↔ middle, end ↔ end). Scroll `b.md` —
   `a.md` follows back. No jitter, no runaway feedback.
5. Click a TOC entry / use ⌘F navigation in one window — the other follows
   (paired reading follows any navigation).
6. TOC sidebar, find bar, and the width slider still work independently in
   each window.
7. `Window ▸ Stop Comparing` → scrolling no longer mirrors; both windows stay
   open and fully functional.
8. Re-compare, then close `b.md`'s window → `a.md` stays open, mirroring is
   off, `Stop Comparing` is disabled again.
9. Compare with an ALREADY-OPEN document → no duplicate window: the existing
   window is used and tiled (one window per document).
