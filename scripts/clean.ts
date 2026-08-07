/** `deno task clean` — remove build artifacts. */

import { run, section } from "./lib.ts";

section("swift package clean");
await run("swift", { args: ["package", "clean"] });
await Deno.remove(".build", { recursive: true }).catch(() => {});
console.log("clean: removed .build");
