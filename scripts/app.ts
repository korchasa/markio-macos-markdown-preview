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

const QL_NAME = "Markio2QuickLook";
const QL_BIN = `.build/release/${QL_NAME}`;
export const QL_APPEX = `${APP_BUNDLE}/Contents/PlugIns/${QL_NAME}.appex`;

export async function app(): Promise<void> {
  section("Building (release)");
  await run("swift", { args: ["build", "-c", "release"] });

  section(`Assembling ${APP_BUNDLE}`);
  await Deno.remove(APP_BUNDLE, { recursive: true }).catch(() => {});
  await Deno.mkdir(`${APP_BUNDLE}/Contents/MacOS`, { recursive: true });
  await Deno.mkdir(`${APP_BUNDLE}/Contents/Resources`, { recursive: true });
  await Deno.copyFile(RELEASE_BIN, `${APP_BUNDLE}/Contents/MacOS/${APP_NAME}`);
  await Deno.copyFile("packaging/Info.plist", `${APP_BUNDLE}/Contents/Info.plist`);

  // Quick Look preview extension: a hand-assembled .appex, no Xcode involved.
  // The binary is linked with `_NSExtensionMain` as its entry point (see
  // Package.swift) and carries no resources — the renderer is compiled in.
  section(`Assembling ${QL_APPEX}`);
  await Deno.mkdir(`${QL_APPEX}/Contents/MacOS`, { recursive: true });
  await Deno.copyFile(QL_BIN, `${QL_APPEX}/Contents/MacOS/${QL_NAME}`);
  await Deno.copyFile(`packaging/${QL_NAME}-Info.plist`, `${QL_APPEX}/Contents/Info.plist`);
  // Ad-hoc sign the extension only. pluginkit refuses to load an unsigned or
  // unsandboxed extension even locally; the host app stays unsigned here, and
  // everything is re-signed outside this repository, nested bundle first.
  await run("codesign", {
    args: [
      "--force",
      "--sign",
      "-",
      "--entitlements",
      `packaging/${QL_NAME}.entitlements`,
      QL_APPEX,
    ],
  });

  section(`app: built ${APP_BUNDLE}`);
}

if (import.meta.main) await app();
