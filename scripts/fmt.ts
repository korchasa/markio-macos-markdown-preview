/**
 * `deno task fmt` — apply formatting in place to both languages: the Swift
 * sources and the TypeScript task scripts. `check` verifies the same two
 * without writing.
 */

import { run, section } from "./lib.ts";

section("swift format");
await run("swift", { args: ["format", "format", "-i", "-r", "Sources", "Tests"] });

section("deno fmt");
await run("deno", { args: ["fmt"] });
