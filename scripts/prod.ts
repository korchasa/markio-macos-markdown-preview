/**
 * `deno task prod` — build the .app bundle and launch it, opening any files
 * given as arguments in the single running instance.
 */

import { run, section } from "./lib.ts";
import { app, APP_BUNDLE } from "./app.ts";

await app();

section("Launching");
await run("open", { args: ["-a", APP_BUNDLE, ...Deno.args] });
