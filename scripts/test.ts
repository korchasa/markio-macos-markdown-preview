/**
 * `deno task test` — the Swift test suite. Extra arguments are passed straight
 * to `swift test`, so `deno task test --filter BlockScannerTests` works.
 */

import { run, section } from "./lib.ts";

export async function test(args: string[] = []): Promise<void> {
  await run("swift", { args: ["test", ...args] });
}

if (import.meta.main) {
  section("Tests");
  await test(Deno.args);
}
