/**
 * `deno task check` — the verification gate: build, comment scan, format lint,
 * tests. Cheapest failure first, and nothing here writes to the working tree.
 */

import { checkTooling, fail, run, scanFiles, section } from "./lib.ts";
import { test } from "./test.ts";

/** Sources scanned for work markers. Vendored web assets are not Swift, so the
 * `.swift` filter excludes them on its own. */
const SWIFT_SOURCES = ["Sources", "Tests"];

/** Work markers, suppression comments and stray debug output. */
const MARKERS = /TODO|FIXME|HACK|XXX|swiftlint:disable|swift-format-ignore|debugPrint\(/;

const TOTAL = 5;

async function check(): Promise<void> {
  section(`[1/${TOTAL}] Tooling (deno fmt --check, lint, type-check)`);
  await checkTooling();

  section(`[2/${TOTAL}] Build (debug)`);
  await run("swift", { args: ["build"] });

  section(`[3/${TOTAL}] Comment scan (TODO/FIXME/HACK/XXX, suppressions, debugPrint)`);
  const hits = await scanFiles(SWIFT_SOURCES, [".swift"], MARKERS);
  if (hits.length > 0) {
    hits.forEach((hit) => console.log(hit));
    fail("found forbidden markers");
  }
  console.log("    clean");

  section(`[4/${TOTAL}] Format check (swift format lint)`);
  await run("swift", { args: ["format", "lint", "-s", "-r", ...SWIFT_SOURCES] });

  section(`[5/${TOTAL}] Tests`);
  await test();

  section("check: OK");
}

if (import.meta.main) await check();
