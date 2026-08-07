/**
 * `deno task prod [file.md]` — build the .app bundle and launch it (single
 * instance, window per document).
 */

import { run, section } from "./lib.ts";
import { app, APP_BUNDLE } from "./app.ts";

await app();
section(`Launching ${APP_BUNDLE}`);
await run("open", { args: ["-a", `${Deno.cwd()}/${APP_BUNDLE}`, ...Deno.args] });
