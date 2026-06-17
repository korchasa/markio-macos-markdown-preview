# Manual checklist — FR-OPEN (open Markdown file)

Reviewer: maintainer. Run `make dev` (or a release `.app`) and verify each:

- [ ] `make dev ARGS="documents/checklists/open.md"` renders this file on launch.
- [ ] ⌘O opens the panel; selecting a `.md` renders it; non-md files are filtered out.
- [ ] Drag a `.md` onto the window → it renders; dragging a non-md is ignored.
- [ ] Finder "Open With ▸ Markview" (release build) / `open -a Markview file.md` opens it.
- [ ] File ▸ Open Recent lists previously opened documents.
- [ ] Window title shows the file name.
