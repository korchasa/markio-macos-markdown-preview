/**
 * `deno task bench` — run the performance harness on generated documents.
 *
 * Release build only: a debug Swift binary is slow enough to make the numbers
 * meaningless. Extra arguments are passed through to the harness.
 */

import { run, section } from "./lib.ts";

section("Building (release)");
await run("swift", { args: ["build", "-c", "release", "--product", "markio-bench"] });

section("Running benchmarks");
await run(".build/release/markio-bench", { args: Deno.args });
