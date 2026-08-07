/**
 * `deno task dev [file.md]` — run the app straight from the debug build,
 * without packaging it as a bundle.
 */

import { run, section } from "./lib.ts";
import { APP_NAME } from "./app.ts";

section(["swift run", APP_NAME, ...Deno.args].join(" "));
await run("swift", { args: ["run", APP_NAME, ...Deno.args] });
