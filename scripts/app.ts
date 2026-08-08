/**
 * `deno task app` — release build packaged as a proper Markio2.app bundle.
 *
 * A bundle (Info.plist + bundle id) is what makes macOS keep a single instance
 * and route every open into it, one window per document. `prod` and `dist`
 * build on this.
 */

import { run, section } from "./lib.ts";

export const APP_NAME = "Markio2";
export const APP_BUNDLE = `.build/${APP_NAME}.app`;
const RELEASE_BIN = `.build/release/${APP_NAME}`;

export async function app(): Promise<void> {
  section("Building (release)");
  await run("swift", { args: ["build", "-c", "release"] });

  section(`Assembling ${APP_BUNDLE}`);
  await Deno.remove(APP_BUNDLE, { recursive: true }).catch(() => {});
  await Deno.mkdir(`${APP_BUNDLE}/Contents/MacOS`, { recursive: true });
  await Deno.mkdir(`${APP_BUNDLE}/Contents/Resources`, { recursive: true });
  await Deno.copyFile(RELEASE_BIN, `${APP_BUNDLE}/Contents/MacOS/${APP_NAME}`);
  await Deno.copyFile("packaging/Info.plist", `${APP_BUNDLE}/Contents/Info.plist`);

  section(`app: built ${APP_BUNDLE}`);
}

if (import.meta.main) await app();
