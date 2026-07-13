# Daily-use feature backlog (post-4.3(a) differentiation)

Context: version 1.0 (build 7) was rejected 2026-07-13 under Guideline 4.3(a)
"Design — Spam" (crowded niche of similar Markdown viewers: Meva, Markdown Lens,
Clearly Markdown, MarkFlow, Read.md — all free, released late 2025 – 2026).
This backlog collects 20 daily-use feature ideas that stay within the current
direction (native, offline, viewer-only — NOT an editor), prioritized by
(daily value × 4.3(a) differentiation) / cost.

Competitor feature notes (from App Store descriptions, 2026-07-13):
- Meva: Mermaid, LaTeX, TOC, live reload, in-doc search, "reader for AI-generated docs" positioning.
- Markdown Lens: viewer, GFM, Mermaid, math, offline, export to Word/PDF/HTML, spell check.
- Clearly Markdown: editor+preview, Mermaid, math, frontmatter.
- MarkFlow: reader, TOC, folders, Mermaid, math, HTML.
- Read.md: reader (iOS+macOS), Mermaid, GFM, tap-to-zoom diagrams.
- Nobody claims inline HTML + frontmatter + fully-offline together (Markio's current core).

## Tier 1 — table stakes for a daily tool (do first)

1. **Live file reload** — re-render on disk change, preserve scroll position.
   Key 2026 scenario: watching Claude/Cursor write a document. Meva has it; without it we lose daily use.
2. **TOC sidebar** — heading tree, click-to-jump, current section highlighted on scroll.
   Meva/MarkFlow have it; long agent reports are unreadable without it.
3. **Copy button on code blocks** — hover → Copy (+ language badge).
   The single most frequent reader action in technical Markdown.
4. **Recent documents + window restore** — Open Recent menu; reopen last documents at last scroll positions on relaunch.
5. **Find upgrades** — highlight all matches, "3 of 17" counter, scrollbar minimap; search inside code blocks/tables. (⌘F exists — extend it.)

## Tier 2 — differentiation drivers (the 4.3(a) story)

6. **Local link navigation** — relative links to other .md files open them (new window, per the window-per-document concept); `#anchor` links scroll; Back returns. Dead clicks today; none of the five competitors claim it. Turns Markio into "a native reader for a repo's living documentation".
7. **Quick Look extension** — Space in Finder renders .md with our engine (Mermaid + KaTeX, which system Quick Look can't). Sells the app before it's opened.
8. **AI-artifact rendering** — ANSI color codes in code blocks (colored logs), diff blocks with green/red, long path wrapping. Deepens the "reader for agent output" positioning beyond Meva's.
9. **Side-by-side compare** — two .md files with synchronized scrolling (spec v1 vs v2, report before/after). Not a diff editor — parallel reading. No competitor has it.
10. **Mermaid zoom & copy** — click diagram → zoom/pan; "copy as PNG". Read.md has tap-to-zoom on iOS; desktop needs it more.

## Tier 3 — cheap daily quality-of-life

11. **Copy heading anchor** — hover a heading → copy `#anchor` / `file.md#anchor`.
12. **Reading stats in title bar** — word count, reading time ("12 min"), scroll progress %.
13. **Reliable local images** — relative paths, SVG, GIF; broken paths show an explicit placeholder with the path instead of nothing.
14. **Reading mode typography** — column width, font size, line height; persisted globally; auto light/dark follows the system.
15. **Smart copy** — "copy selection as Markdown" (source, not plain text); "copy table as CSV". Feeds text back into agent chats.

## Tier 4 — bigger bets / niche

16. **Section folding** — click a heading to collapse its section (like `<details>`).
17. **Checklist progress** — for docs with `- [ ]`: "7/12 done" in the toolbar, click jumps to next unchecked.
18. **Command palette ⌘K** — headings of current doc + recent files in one keyboard-first entry. (Overlaps 2 + 4 — build after them.)
19. **PDF export with full render** — print/PDF where Mermaid/KaTeX/tables look exactly like on screen. Markdown Lens's headline feature; watch WKWebView print quirks.
20. **Presentation mode** — full-screen, one section per slide (split on `##` or `---`), arrow keys. Niche but unique.

## Recommended first wave

Tier 1 complete (1–5) + **6 (local links)** + **7 (Quick Look)**: together they
make the "native reader for living repo documentation" story concrete for a
4.3(a) reply/resubmission, while 1–5 fix daily-use gaps against Meva/MarkFlow.
