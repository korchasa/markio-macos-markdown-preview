/**
 * `deno task clean` — remove build artifacts.
 */

import { section } from "./lib.ts";

await Deno.remove(".build", { recursive: true }).catch(() => {});
section("clean: OK");
