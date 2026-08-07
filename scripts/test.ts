/**
 * `deno task test [args...]` — run the suite, or a filtered subset:
 *
 *   deno task test
 *   deno task test --filter RendererTests
 */

import { run, section } from "./lib.ts";

export async function test(args: string[] = []): Promise<void> {
  section(["swift test", ...args].join(" "));
  await run("swift", { args: ["test", ...args] });
}

if (import.meta.main) await test(Deno.args);
