/**
 * `deno task check` — the verification gate: build, comment scan, format lint,
 * tests. Cheapest failure first, and nothing here writes to the working tree.
 */

import { checkTooling, fail, run, scanFiles, section } from "./lib.ts";
import { APP_PLIST, QL_PLIST, verifyIdentity } from "./identity.ts";
import { test } from "./test.ts";

const SWIFT_SOURCES = ["Sources", "Tests"];

/** Work markers, suppression comments and stray debug output. */
const MARKERS = /TODO|FIXME|HACK|XXX|swiftlint:disable|swift-format-ignore|debugPrint\(/;

/**
 * The two files whose subject is the markers themselves.
 *
 * The bottom bar counts a document's open questions, and an open question is a
 * `TODO` or a `FIXME` in the text it is reading — so the words appear there as
 * data and as the documentation of what the number means, never as work left
 * undone. Named one by one rather than matched by a pattern, so a marker
 * anywhere else still fails the gate.
 */
const MARKERS_ALLOWED = [
  "Sources/MarkioRender/DocumentSummary.swift",
  "Tests/MarkioRenderTests/DocumentSummaryTests.swift",
];

/**
 * Nothing in this project may render through a web engine — that is the whole
 * point of Markio. The gate fails if a source file so much as imports WebKit.
 */
const WEB_ENGINE = /import WebKit|WKWebView|JavaScriptCore|loadHTMLString/;

/**
 * A save panel is a sandbox capability, not just a class.
 *
 * AppKit refuses to display an `NSSavePanel` to an app that holds only
 * `com.apple.security.files.user-selected.read-only`: the panel never appears,
 * the command looks dead, and nothing in the app says why. The refusal is
 * invisible outside the sandbox, so a local build — which used to be
 * linker-signed with no entitlements at all — showed the panel happily. App
 * Review found it instead, and rejected 1.0 under Guideline 2.1(a) on
 * 2026-09-13 because Export as PDF did nothing.
 */
const SAVE_PANEL = /NSSavePanel/;
const SAVE_PANEL_ENTITLEMENT = "com.apple.security.files.user-selected.read-write";
const APP_ENTITLEMENTS = "packaging/Markio.entitlements";

/**
 * A comment in a packaging plist ships in the bundle.
 *
 * `scripts/app.ts` copies these files into the bundle byte for byte, so an
 * `<!-- -->` in the source is one in the app App Store ingest reads. Apple
 * Developer Support asked on 2026-09-19 (case 102964427402) for them to go.
 * What they used to explain is in packaging/README.md.
 */
const PLIST_COMMENT = "<!--";
const PACKAGING_PLISTS = [APP_PLIST, QL_PLIST];

const TOTAL = 10;

async function check(): Promise<void> {
  section(`[1/${TOTAL}] Tooling (deno fmt --check, lint, type-check)`);
  await checkTooling();

  // A few plutil reads, so it costs nothing and comes before the builds. What
  // it guards is expensive to get wrong: a drifted bundle id or version is
  // only noticed when signing fails or App Store ingest rejects the upload,
  // both of them a full build away from here.
  section(`[2/${TOTAL}] Store identity (packaging plists match identity.ts)`);
  await verifyIdentity();

  section(`[3/${TOTAL}] Packaging plists (no XML comments)`);
  const commented: string[] = [];
  for (const plist of PACKAGING_PLISTS) {
    if ((await Deno.readTextFile(plist)).includes(PLIST_COMMENT)) commented.push(plist);
  }
  if (commented.length > 0) {
    commented.forEach((plist) => console.log(`    ${plist}`));
    fail(
      "a packaging plist carries an XML comment — it would ship in the bundle; " +
        "move the reason to packaging/README.md",
    );
  }
  console.log("    clean");

  section(`[4/${TOTAL}] Build (debug)`);
  await run("swift", { args: ["build"] });

  // The release build is a different compile, not the same one made faster:
  // whole-module optimization lets the compiler see across files, and it
  // rejects captures the debug build accepts. Everything that reaches a reader
  // is built this way, so the gate has to build it this way too — this step
  // exists because a data-race error sat in `main` for days, invisible to a
  // gate that only ever built debug, and surfaced when a bundle was wanted.
  section(`[5/${TOTAL}] Build (release)`);
  await run("swift", { args: ["build", "-c", "release"] });

  section(`[6/${TOTAL}] Comment scan (TODO/FIXME/HACK/XXX, suppressions, debugPrint)`);
  const hits = (await scanFiles(SWIFT_SOURCES, [".swift"], MARKERS))
    .filter((hit) => !MARKERS_ALLOWED.some((path) => hit.startsWith(`${path}:`)));
  if (hits.length > 0) {
    hits.forEach((hit) => console.log(hit));
    fail("found forbidden markers");
  }
  console.log("    clean");

  section(`[7/${TOTAL}] No-web-engine scan (WebKit, JavaScriptCore, HTML loading)`);
  const web = await scanFiles(SWIFT_SOURCES, [".swift"], WEB_ENGINE);
  if (web.length > 0) {
    web.forEach((hit) => console.log(hit));
    fail("a web engine reference reached the sources");
  }
  console.log("    clean");

  section(`[8/${TOTAL}] Save-panel entitlement (code and sandbox agree)`);
  const panels = await scanFiles(SWIFT_SOURCES, [".swift"], SAVE_PANEL);
  if (panels.length > 0) {
    const entitlements = await Deno.readTextFile(APP_ENTITLEMENTS);
    if (!entitlements.includes(SAVE_PANEL_ENTITLEMENT)) {
      panels.forEach((hit) => console.log(hit));
      fail(
        `a save panel is used but ${APP_ENTITLEMENTS} lacks ${SAVE_PANEL_ENTITLEMENT} — ` +
          "AppKit will refuse to display the panel in the sandbox",
      );
    }
  }
  console.log("    clean");

  section(`[9/${TOTAL}] Format check (swift format lint)`);
  await run("swift", { args: ["format", "lint", "-s", "-r", ...SWIFT_SOURCES] });

  section(`[10/${TOTAL}] Tests`);
  await test();

  section("check: OK");
}

if (import.meta.main) await check();
