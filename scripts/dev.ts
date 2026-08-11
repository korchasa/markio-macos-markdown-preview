/**
 * `deno task dev` — build and launch the raw debug binary.
 *
 * No .app bundle, so every run is a separate process: fast to iterate, but the
 * system menu bar and single-instance document routing are degraded. Use
 * `deno task prod` when those matter.
 */

import { run, section } from "./lib.ts";

section("Building (debug)");
await run("swift", { args: ["build"] });

section("Launching");
await run(".build/debug/Markio", { args: Deno.args });
