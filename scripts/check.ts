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

const TOTAL = 6;

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

  section(`[4/${TOTAL}] No-web-engine scan (WebKit, JavaScriptCore, HTML loading)`);
  const web = await scanFiles(SWIFT_SOURCES, [".swift"], WEB_ENGINE);
  if (web.length > 0) {
    web.forEach((hit) => console.log(hit));
    fail("a web engine reference reached the sources");
  }
  console.log("    clean");

  section(`[5/${TOTAL}] Format check (swift format lint)`);
  await run("swift", { args: ["format", "lint", "-s", "-r", ...SWIFT_SOURCES] });

  section(`[6/${TOTAL}] Tests`);
  await test();

  section("check: OK");
}

if (import.meta.main) await check();
