# Manual checklist — FR-LOCAL-LINKS (local link navigation)

Run on a real bundle: `make app && open .build/Markio.app` (dev binary is
unsandboxed — the grant flow only shows on a sandboxed/signed build; on the
dev build steps 3–4 open silently, which is the documented degradation).

Fixture: a folder with `a.md` (contains `[b](b.md)`, `[sec](b.md#target)`,
`[top](#intro)`, `[txt](notes.txt)`, `[web](https://example.com)`, heading
`# Intro`), `b.md` (tall content + heading `# Target`), `notes.txt`.

1. [ ] Open `a.md` via ⌘O. Click `[top](#intro)` → the window scrolls to
       "Intro"; no new window, no navigation.
2. [ ] Click `[web](https://example.com)` → default browser opens; the
       preview stays on `a.md`.
3. [ ] Click `[b](b.md)` (sandboxed build, `b.md` never opened before) → an
       Open panel appears pre-pointed at `b.md` with the permission message;
       "Open" → `b.md` appears in a NEW window; the `a.md` window is
       unchanged. Cancel instead → nothing happens.
4. [ ] Quit, relaunch, reopen `a.md`, click `[b](b.md)` again → `b.md` opens
       silently (recents access is system-managed) or after one grant,
       depending on OS recents state — no crash, no blank window either way.
5. [ ] Click `[sec](b.md#target)` while `b.md` is CLOSED → `b.md` opens
       scrolled to "Target" (not the saved reading position).
6. [ ] Click `[sec](b.md#target)` while `b.md` is already OPEN → the existing
       `b.md` window scrolls to "Target"; no duplicate window.
7. [ ] Click `[txt](notes.txt)` → dead click: no window, no navigation.
