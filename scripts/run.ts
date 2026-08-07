/**
 * `deno task run [file.md]` — the manual-QA loop in one step: rebuild the
 * bundle, restart the app, and re-register the Quick Look appex (a rebuild
 * DROPS its pluginkit registration; see AGENTS.md "Quick Look dev loop").
 */

import { run, section } from "./lib.ts";
import { app, APP_BUNDLE, APP_NAME, QL_APPEX } from "./app.ts";

await app();

section(`Quitting ${APP_NAME}`);
await run("osascript", {
  args: ["-e", `quit app "${APP_NAME}"`],
  allowFailure: true,
  capture: true,
});
// Quit is asynchronous — `open` racing the dying process fails with
// LaunchServices -600 (procNotFound). Wait for the process to actually exit
// (state restoration can take over a second), bounded at ~6 s.
for (let attempt = 0; attempt < 20; attempt++) {
  const alive = await run("pgrep", {
    args: ["-qx", APP_NAME],
    allowFailure: true,
    capture: true,
  });
  if (alive.code !== 0) break;
  await new Promise((resolve) => setTimeout(resolve, 300));
}

section("Re-registering the Quick Look extension");
await run("pluginkit", { args: ["-a", QL_APPEX] });

section(`Launching ${APP_BUNDLE}`);
await run("open", { args: ["-a", `${Deno.cwd()}/${APP_BUNDLE}`, ...Deno.args] });
