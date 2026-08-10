/**
 * `deno task check` — the verification gate: build, comment scan, format lint,
 * tests. Cheapest failure first, and nothing here writes to the working tree.
 */

import { checkTooling, fail, run, scanFiles, section } from "./lib.ts";
import { test } from "./test.ts";

const SWIFT_SOURCES = ["Sources", "Tests"];

/** Work markers, suppression comments and stray debug output. */
const MARKERS = /TODO|FIXME|HACK|XXX|swiftlint:disable|swift-format-ignore|debugPrint\(/;

/**
 * Nothing in this project may render through a web engine — that is the whole
 * point of Markio 2. The gate fails if a source file so much as imports WebKit.
 */
const WEB_ENGINE = /import WebKit|WKWebView|JavaScriptCore|loadHTMLString/;

const TOTAL = 7;

async function check(): Promise<void> {
  section(`[1/${TOTAL}] Tooling (deno fmt --check, lint, type-check)`);
  await checkTooling();

  section(`[2/${TOTAL}] Build (debug)`);
  await run("swift", { args: ["build"] });

  // The release build is a different compile, not the same one made faster:
  // whole-module optimization lets the compiler see across files, and it
  // rejects captures the debug build accepts. Everything that reaches a reader
  // is built this way, so the gate has to build it this way too — this step
  // exists because a data-race error sat in `main` for days, invisible to a
  // gate that only ever built debug, and surfaced when a bundle was wanted.
  section(`[3/${TOTAL}] Build (release)`);
  await run("swift", { args: ["build", "-c", "release"] });

  section(`[4/${TOTAL}] Comment scan (TODO/FIXME/HACK/XXX, suppressions, debugPrint)`);
  const hits = await scanFiles(SWIFT_SOURCES, [".swift"], MARKERS);
  if (hits.length > 0) {
    hits.forEach((hit) => console.log(hit));
    fail("found forbidden markers");
  }
  console.log("    clean");

  section(`[5/${TOTAL}] No-web-engine scan (WebKit, JavaScriptCore, HTML loading)`);
  const web = await scanFiles(SWIFT_SOURCES, [".swift"], WEB_ENGINE);
  if (web.length > 0) {
    web.forEach((hit) => console.log(hit));
    fail("a web engine reference reached the sources");
  }
  console.log("    clean");

  section(`[6/${TOTAL}] Format check (swift format lint)`);
  await run("swift", { args: ["format", "lint", "-s", "-r", ...SWIFT_SOURCES] });

  section(`[7/${TOTAL}] Tests`);
  await test();

  section("check: OK");
}

if (import.meta.main) await check();
