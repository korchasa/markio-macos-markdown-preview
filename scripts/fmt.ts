/**
 * `deno task fmt` — apply formatting to the Swift sources and the task scripts.
 */

import { run, section } from "./lib.ts";

section("Formatting Swift sources");
await run("swift", { args: ["format", "-i", "-r", "Sources", "Tests"] });

section("Formatting task scripts");
await run("deno", { args: ["fmt"] });

section("fmt: OK");
