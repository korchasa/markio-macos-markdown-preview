---
date: 2026-10-02
status: to do
implements: [VIEW-25]
tags: [mermaid, layout, flowchart, class-diagram, er-diagram]
related_tasks: []
---

# Replace the ranked layout with the ELK Layered pipeline, written from the papers

## Goal

Make Markio's flowcharts, state machines, class and entity diagrams as clean as
ELK Layered draws them: no line through a box, no line over another line's
words, no line wandering around half the picture to reach a box one rank away.
The owner looked at nine layout engines over nine graphs and picked ELK Layered
with text order kept, right-angled lines with rounded corners and edge labels
wrapped at 12 characters (2026-10-02). The current layout is the reason the
diagrams in `second-brain/documents/tasks/unify-news-collectors.md` look tangled.

## Overview

### Context

A comparison bench (outside this repository, in a scratch directory of the
session that built it) laid out nine graphs — the five diagrams of the task
file above, a hand-written TCP state machine, Graphviz's `fsm.gv` and
`unix.gv`, and the Petersen graph — with 31 algorithms and counted the same
defects for each: edge crossings outside boxes, edges through a foreign box,
labels touched by a box, by another label or by a foreign edge, and overlapping
boxes; plus *detour*, an edge's length over the straight distance between its
ends, averaged over edges and taken for the worst edge.

The winner, ELK Layered with these options:

- `considerModelOrder.strategy = NODES_AND_EDGES`, `cycleBreaking = MODEL_ORDER`
- `crossingMinimization.thoroughness = 60`, `nodePlacement.favorStraightEdges = true`
- `edgeRouting = ORTHOGONAL`, `edgeLabels.placement = CENTER`, labels are
  layout dummies
- corners rounded with a 12-point arc when drawn
- every edge label broken at spaces into lines of at most 12 characters before
  the layout

scored, summed over the nine graphs: 5 defects, mean detour 1.16, worst detour
2.05, and 0.85 of the area of the same layout with one-line labels. Markio's
current layout was not measured by the same code yet — its pictures were
judged by eye.

ELK itself cannot be used: it is Java or JavaScript, and PROD-1 and BUILD-2
forbid any JavaScript runtime. Translating ELK's source would make those files
EPL-2.0, a second licence beside PolyForm Noncommercial. The owner chose
(2026-10-02) to write the same stages in Swift from the published papers,
replacing the old algorithm stage by stage, with the bench's metrics as the
gate.

Papers the stages come from:

- Sugiyama, Tagawa, Toda 1981 — the layered framework.
- Gansner, Koutsofios, North, Vo 1993, "A technique for drawing directed
  graphs" — network simplex layering.
- Eades, Kelly 1986 / Jünger, Mutzel 1997 — layer-sweep crossing minimisation
  with the barycenter heuristic.
- Brandes, Köpf 2001, "Fast and simple horizontal coordinate assignment".
- Sander 2004, "Layout of directed hypergraphs with orthogonal hyperedges" —
  orthogonal routing between layers with routing slots.
- Schulze, Spönemann, von Hanxleden 2014, "Drawing layered graphs with port
  constraints" — the model-order variants ELK uses.

### Current State

All in `Sources/MarkioRender/MermaidLayout.swift`:

- `ranks(count:edges:)` (longest path after `withoutBackEdges`) puts units
  on ranks; inside a rank the order is the order of the source text, centred
  against the widest rank. There is no crossing minimisation and no coordinate
  assignment beyond centring.
- `placed(chart:…)` lays a flowchart out container by container; a subgraph is
  laid out first and then placed as one unit of its parent. Box diagrams go
  through `ranked(sizes:links:…)` and `walled(…)` for namespaces.
- Lines are not routed by the layout. `connection(…)` joins two rectangles
  directly, and boxes in the way are handled by `laneChoice`, `lanes`,
  `spread`, `bow` — lanes beside obstacles, cubic sweeps, bows for skipped
  ranks. Edge words are placed afterwards by `edge(…)`, sliding along the line
  until they find room; their size never reaches the ranking except as the
  height of the rank gap.
- `sankey` also calls `ranks`, and stays on it: a Sankey diagram is not part of
  this change.

`documents/design.md` § Diagrams describes all of the above in detail (from
"`MermaidLayout` places it" through "Joining two boxes"); it has to be
rewritten as the stages land.

### Constraints

- PROD-1 / BUILD-2: no JavaScript, no web engine. Pure Swift, CoreGraphics only.
- Written from the papers, not from ELK's source: no file of ELK may be read
  while writing this code, so the code stays under the repository's own licence.
- Nothing is typeset until visible: the layout runs only when a diagram is
  drawn, as now.
- `Sankey` keeps `ranks`; sequence, gantt, git graph, architecture, C4 and
  every other kind with its own geometry are out of scope.
- Subgraphs keep their meaning from the SDS: a frame encloses its own members
  and nothing else, `direction` inside a frame turns only that frame, an edge
  may end on a frame.
- Each stage leaves `deno task check` green and the app drawing every fixture;
  the old code is deleted only when nothing calls it.

## Definition of Done

- [x] VIEW-25: Markio can hand out the geometry it draws for a diagram, so it
  can be measured.
  - Test: `Tests/MarkioRenderTests/LayeredLayoutTests.swift` (the four geometry tests)
  - Evidence: `.build/release/markio-bench layout test-fixtures/layout/story.mmd`
    prints JSON with node rectangles, edge polylines and label rectangles
- [x] VIEW-25: `deno task layoutbench` measures the nine graphs with the same
  defect and detour definitions as the comparison bench, and prints a baseline
  for the old layout.
  - Evidence: `deno task layoutbench` (fixtures in `test-fixtures/layout/`)
- [ ] VIEW-25: ranks come from network simplex over the graph with cycles broken
  in text order; boxes in a rank are ordered by layer sweep with text order as
  the tie-break; edge labels are layout dummies, wrapped at 12 characters.
  - Test: `Tests/MarkioRenderTests/LayeredLayoutTests.swift`
  - Evidence: `deno task test`
- [ ] VIEW-25: coordinates come from Brandes–Köpf with straight edges preferred;
  edges are routed orthogonally between layers and drawn with 12-point rounded
  corners; the lane/bow/spread routing is deleted.
  - Test: `Tests/MarkioRenderTests/LayeredLayoutTests.swift`
  - Evidence: `grep -c -E 'func (laneChoice|lanes|bow|spread)\(' Sources/MarkioRender/MermaidLayout.swift` prints 0
- [ ] VIEW-25: flowcharts (with subgraphs, all four directions), state machines,
  class and entity diagrams use the new layout.
  - Evidence: `deno task layoutbench` — total defects over the nine graphs ≤ 5,
    mean detour ≤ 1.20, worst detour ≤ 2.5
- [ ] VIEW-25: every diagram fixture still draws, in light and dark, and the
  side-by-side page is regenerated.
  - Evidence: `.build/release/markio-bench diagram <each fixture> <png> 760 dark`
    exits 0; screenshots reviewed
- [ ] `documents/design.md` § Diagrams describes the new pipeline;
  `documents/requirements.md` VIEW-25 is true; `deno task check` passes.
  - Evidence: `deno task check`

## Solution

Stages, each its own commit, each with `deno task check` green and a
`deno task layoutbench` run recorded in this file.

1. **Measure first.** Add `markio-bench layout <file.mmd>` that prints the
   drawn geometry as JSON (boxes, frames, edge polylines after clipping, label
   plates). Add `scripts/layoutbench.ts` + `deno task layoutbench`: the nine
   graphs as `.mmd` fixtures in `test-fixtures/layout/` (the two `.gv` graphs
   and Petersen converted to Mermaid once and committed), the defect and detour
   counters ported from the bench, a summary per graph and in total. Record the
   old layout's baseline here.
2. **A pure layered core.** New file `Sources/MarkioRender/LayeredLayout.swift`:
   input = node sizes, edges (from, to, label size), direction, spacing; output
   = node origins, edge polylines, label rectangles. No CoreText, no theme —
   unit-testable on small graphs.
   - Cycle breaking: an edge pointing from a later node to an earlier one in
     text order is reversed (model order), not chosen by a DFS.
   - Layering: network simplex (Gansner et al.) on the acyclic graph; edge
     weight 1, minimum length 1, label dummies give a labelled edge length 2.
   - Long edges and labels: dummy nodes per crossed layer; a label is a dummy
     of the label's size in the middle layer of its edge.
   - Crossing minimisation: layer sweep, barycenter, both directions, several
     random-free passes (thoroughness as a fixed pass count); ties and the
     initial order follow text order.
   - Coordinates: Brandes–Köpf, four alignments, balanced; straight edges
     preferred by taking the alignment whose dummy chains are straight.
   - Routing: per gap between layers, every edge segment that has to change its
     across-coordinate gets a routing slot; slots are assigned so that crossing
     segments are minimised (Sander's ordering), giving vertical–horizontal–
     vertical runs. Self-loops leave and re-enter one side, as now.
3. **Wire flowcharts in.** `placed(chart:…)` calls the core per container
   instead of `ranks` + centring; a frame stays a unit sized by what it holds.
   Edges whose ends are in the same container take the core's route. Edges
   across frames are routed at the lowest common container between the unit
   rectangles, then continued orthogonally inside each frame to the real box —
   the risky part; if it turns out wrong, stop and report rather than patch.
   `edge(…)` takes a ready route and a label rectangle instead of computing
   them; the route is drawn with 12-point rounded corners, end marks unchanged.
4. **Wire box diagrams in.** `ranked(…)` and `walled(…)` use the core the same
   way; end marks (crow's feet, triangles, diamonds) stay as they are.
5. **Delete the old routing.** `laneChoice`, `lanes`, `spread`, `bow`, the
   three-tenths hold, the label hunt in `edge(…)`; `ranks`/`withoutBackEdges`
   stay only for `sankey`.
6. **Docs and pictures.** Rewrite `documents/design.md` § Diagrams for the
   pipeline; check VIEW-25's wording; regenerate
   `documents/mermaid-side-by-side.md` pictures; walk every fixture in light and
   dark.

Risks to watch:

- Text measured by CoreText differs from the bench's fixed-width estimate, so
  Markio's numbers will not equal the bench's; the gate is the bench's ELK
  totals, not a pixel match.
- ELK's own refinements beyond the papers are unknown; a graph that stays worse
  than ELK after stage 3 is reported with its picture, not tuned blindly.
- Frames: ELK lays compound graphs out hierarchically; the recursive unit
  approach kept here may route cross-frame edges worse. The bench has no
  subgraph graph — add one from `test-fixtures` to the nine before stage 3.

## Log

### Stage 1 — baseline of the old layout (2026-10-02)

`deno task layoutbench` on the ranked layout with lanes and bows:

```
graph           cross  through  labels  overlap  faults  detour  worst
er                 13        2      15        0      30    1.14   1.49
fsm                 5        0       8        0      13    1.03   1.07
operations          1        0       0        0       1    1.01   1.02
petersen            2        0       0        0       2    1.03   1.12
publication         8        0       2        0      10    1.04   1.11
source              0        0       4        0       4    1.02   1.06
story               6        0       7        0      13    1.03   1.12
tcp                 6        1       6        0      13    1.09   1.57
unix               24       26       0        0      50    1.14   2.32
total                                               136    1.06   2.32
```

The old layout's low detour is the direct lines: they are short because they
run straight through whatever is in the way, which is what the 136 faults
count. The gate for the new pipeline is the comparison's ELK result: 5 faults,
mean detour 1.16, worst 2.05.
