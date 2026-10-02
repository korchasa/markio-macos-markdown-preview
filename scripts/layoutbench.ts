/**
 * `deno task layoutbench` — count the faults in how Markio lays out graphs.
 *
 * Every `.mmd` in `test-fixtures/layout/` is drawn by the release bench
 * (`markio-bench layout`), which prints where the boxes, lines and words came
 * to rest; this counts, per graph and in total:
 *
 * - crossings: two lines crossing outside every box;
 * - through: a line passing over a box that is not one of its ends;
 * - label hits: a line's words over a box, over another line's words, or
 *   crossed by another line;
 * - overlaps: two boxes on top of each other;
 * - detour: a line's length over the straight distance between its ends,
 *   averaged over the lines that are not loops, and the worst of them.
 *
 * The definitions and tolerances are the ones the layout comparison of
 * 2026-10-02 used to pick the layered pipeline (see
 * `documents/tasks/2026/10/elk-layered-layout.md`), so the totals here can be
 * set beside its numbers. Pass fixture names to measure only those.
 */

import { fail, run, section } from "./lib.ts";

type Point = [number, number];
type Rect = { x: number; y: number; w: number; h: number };
type RawRect = [[number, number], [number, number]];
interface Line {
  points: Point[];
  label?: RawRect;
  ends: number[];
  loop: boolean;
}
interface Geometry {
  nodes: RawRect[];
  frames: RawRect[];
  lines: Line[];
}

const FIXTURES = "test-fixtures/layout";

const rect = ([[x, y], [w, h]]: RawRect): Rect => ({ x, y, w, h });
const shrink = (r: Rect, k: number): Rect => ({
  x: r.x + k,
  y: r.y + k,
  w: Math.max(0, r.w - 2 * k),
  h: Math.max(0, r.h - 2 * k),
});
const overlap = (a: Rect, b: Rect) =>
  a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
const inside = (p: Point, r: Rect, pad = 0) =>
  p[0] > r.x - pad && p[0] < r.x + r.w + pad && p[1] > r.y - pad && p[1] < r.y + r.h + pad;

function crossing(a: Point, b: Point, c: Point, d: Point): Point | null {
  const den = (b[0] - a[0]) * (d[1] - c[1]) - (b[1] - a[1]) * (d[0] - c[0]);
  if (Math.abs(den) < 1e-9) return null;
  const t = ((c[0] - a[0]) * (d[1] - c[1]) - (c[1] - a[1]) * (d[0] - c[0])) / den;
  const u = ((c[0] - a[0]) * (b[1] - a[1]) - (c[1] - a[1]) * (b[0] - a[0])) / den;
  return t >= 0 && t <= 1 && u >= 0 && u <= 1
    ? [a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])]
    : null;
}

function segmentHits(a: Point, b: Point, r: Rect): boolean {
  if (inside(a, r) || inside(b, r)) return true;
  const c: Point[] = [[r.x, r.y], [r.x + r.w, r.y], [r.x + r.w, r.y + r.h], [r.x, r.y + r.h]];
  return c.some((p, i) => crossing(a, b, p, c[(i + 1) % 4]) !== null);
}

const lineHits = (points: Point[], r: Rect) =>
  points.slice(1).some((p, k) => segmentHits(points[k], p, r));

export interface Score {
  crossings: number;
  through: number;
  labelHits: number;
  overlaps: number;
  detour: number;
  worst: number;
}

export function score(g: Geometry): Score {
  const boxes = g.nodes.map(rect);
  const lines = g.lines.map((l) => ({ ...l, plate: l.label ? rect(l.label) : null }));
  let crossings = 0, through = 0, labelHits = 0, overlaps = 0;
  for (let i = 0; i < lines.length; i++) {
    for (let j = i + 1; j < lines.length; j++) {
      // One crossing per place: a line that touches another at a bend shares
      // a point between two of its segments, and that is still one crossing.
      const found: Point[] = [];
      const A = lines[i].points, B = lines[j].points;
      for (let a = 1; a < A.length; a++) {
        for (let b = 1; b < B.length; b++) {
          const p = crossing(A[a - 1], A[a], B[b - 1], B[b]);
          if (!p || boxes.some((r) => inside(p, r, 6))) continue;
          if (!found.some((q) => Math.hypot(q[0] - p[0], q[1] - p[1]) < 4)) found.push(p);
        }
      }
      crossings += found.length;
    }
  }
  for (const line of lines) {
    boxes.forEach((box, index) => {
      if (!line.ends.includes(index) && lineHits(line.points, shrink(box, 3))) through++;
    });
  }
  lines.forEach((line, i) => {
    if (!line.plate) return;
    const plate = shrink(line.plate, 1.5);
    labelHits += boxes.filter((b) => overlap(plate, b)).length;
    for (let j = i + 1; j < lines.length; j++) {
      const other = lines[j].plate;
      if (other && overlap(plate, shrink(other, 1.5))) labelHits++;
    }
    lines.forEach((other, j) => {
      if (j !== i && lineHits(other.points, shrink(line.plate!, 2))) labelHits++;
    });
  });
  for (let i = 0; i < boxes.length; i++) {
    for (let j = i + 1; j < boxes.length; j++) {
      if (overlap(shrink(boxes[i], 1), shrink(boxes[j], 1))) overlaps++;
    }
  }
  const ratios = lines.filter((l) => !l.loop && l.points.length >= 2).map(({ points }) => {
    let length = 0;
    for (let k = 1; k < points.length; k++) {
      length += Math.hypot(points[k][0] - points[k - 1][0], points[k][1] - points[k - 1][1]);
    }
    const last = points[points.length - 1];
    const chord = Math.hypot(last[0] - points[0][0], last[1] - points[0][1]);
    return chord > 1 ? length / chord : 1;
  });
  const detour = ratios.length ? ratios.reduce((a, b) => a + b, 0) / ratios.length : 1;
  return { crossings, through, labelHits, overlaps, detour, worst: Math.max(1, ...ratios) };
}

if (import.meta.main) {
  section("Building (release)");
  await run("swift", { args: ["build", "-c", "release", "--product", "markio-bench"] });

  const wanted = new Set(Deno.args);
  const names: string[] = [];
  for await (const entry of Deno.readDir(FIXTURES)) {
    const name = entry.name.replace(/\.mmd$/, "");
    if (entry.isFile && entry.name.endsWith(".mmd") && (!wanted.size || wanted.has(name))) {
      names.push(name);
    }
  }
  names.sort();
  for (const name of wanted) if (!names.includes(name)) fail(`no fixture ${name}.mmd`);

  section("Measuring");
  const pad = (s: string | number, n: number) => String(s).padStart(n);
  console.log(
    `${"graph".padEnd(14)}${pad("cross", 7)}${pad("through", 9)}${pad("labels", 8)}` +
      `${pad("overlap", 9)}${pad("faults", 8)}${pad("detour", 8)}${pad("worst", 7)}`,
  );
  let total = 0, detours = 0, worst = 1;
  for (const name of names) {
    const out = await run(".build/release/markio-bench", {
      args: ["layout", `${FIXTURES}/${name}.mmd`],
      capture: true,
    });
    const s = score(JSON.parse(out.stdout) as Geometry);
    const faults = s.crossings + s.through + s.labelHits + s.overlaps;
    total += faults;
    detours += s.detour;
    worst = Math.max(worst, s.worst);
    console.log(
      `${name.padEnd(14)}${pad(s.crossings, 7)}${pad(s.through, 9)}${pad(s.labelHits, 8)}` +
        `${pad(s.overlaps, 9)}${pad(faults, 8)}${pad(s.detour.toFixed(2), 8)}` +
        `${pad(s.worst.toFixed(2), 7)}`,
    );
  }
  console.log(
    `${"total".padEnd(14)}${pad("", 33)}${pad(total, 8)}` +
      `${pad((detours / names.length).toFixed(2), 8)}${pad(worst.toFixed(2), 7)}`,
  );
}
