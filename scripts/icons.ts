/**
 * `deno task icons` — redraw the app icon set from code.
 *
 * The icon is drawn by `markio-bench icon`, so every size comes from one
 * drawing and a change to it is a diff rather than a new pile of PNGs. Run this
 * after changing `Sources/markio-bench/Icon.swift`; `deno task app` compiles
 * whatever is in the catalog.
 */

import { run, section } from "./lib.ts";

const CATALOG = "packaging/Assets.xcassets/AppIcon.appiconset";

section("Building (debug)");
await run("swift", { args: ["build"] });

section(`Drawing ${CATALOG}`);
await run(".build/debug/markio-bench", { args: ["icon", CATALOG] });
