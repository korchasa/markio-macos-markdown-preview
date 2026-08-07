/**
 * `deno task app` — release build packaged as a proper Markio.app bundle.
 *
 * A bundle (with Info.plist and a bundle id) makes macOS keep a single instance
 * and route every open into it (window-per-document), unlike the raw dev
 * binary. `prod`, `run` and `dist` all build on this.
 */

import { run, section } from "./lib.ts";

export const APP_NAME = "Markio";
export const APP_BUNDLE = `.build/${APP_NAME}.app`;
const RELEASE_BIN = `.build/release/${APP_NAME}`;
/** SwiftPM resource bundle of the shared MarkioEngine target (<pkg>_<target>). */
const RELEASE_RESBUNDLE = `.build/release/${APP_NAME}_MarkioEngine.bundle`;

const QL_NAME = "MarkioQuickLook";
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
  // The resource bundle goes in Contents/Resources only; ResourceLocator finds
  // it there via Bundle.main.resourceURL (NOT SwiftPM's Bundle.module, whose
  // accessor looks beside Bundle.main.bundleURL and crashed the packaged app).
  // A .bundle under Contents/MacOS/ also breaks codesign ("bundle format
  // unrecognized" — that directory is for Mach-O executables only).
  await run("cp", { args: ["-R", RELEASE_RESBUNDLE, `${APP_BUNDLE}/Contents/Resources/`] });
  await Deno.copyFile("packaging/Info.plist", `${APP_BUNDLE}/Contents/Info.plist`);

  // Compile the app icon as an asset catalog (Assets.car). App Store validation
  // (ITMS-90546) rejects bundles carrying only a loose .icns, and the .icns
  // actool also emits is capped at 256×256 — leaving it in place lets ingest
  // pick it over the catalog's 1024×1024, blanking the store listing icon.
  section("Compiling asset catalog (Assets.car)");
  await run("xcrun", {
    args: [
      "actool",
      "packaging/Assets.xcassets",
      "--compile",
      `${APP_BUNDLE}/Contents/Resources`,
      "--platform",
      "macosx",
      "--minimum-deployment-target",
      "14.0",
      "--app-icon",
      "AppIcon",
      "--output-partial-info-plist",
      ".build/assetcatalog-info.plist",
    ],
    capture: true,
  });
  await Deno.remove(`${APP_BUNDLE}/Contents/Resources/AppIcon.icns`).catch(() => {});

  // Quick Look preview extension: hand-assembled .appex (no Xcode). The
  // extension binary links with entry _NSExtensionMain (see Package.swift); it
  // carries its own copy of the engine resource bundle — reading the host app's
  // copy across the extension sandbox boundary is not guaranteed.
  // [REF:fr:quicklook]
  section(`Assembling ${QL_APPEX}`);
  await Deno.mkdir(`${QL_APPEX}/Contents/MacOS`, { recursive: true });
  await Deno.mkdir(`${QL_APPEX}/Contents/Resources`, { recursive: true });
  await Deno.copyFile(QL_BIN, `${QL_APPEX}/Contents/MacOS/${QL_NAME}`);
  await run("cp", { args: ["-R", RELEASE_RESBUNDLE, `${QL_APPEX}/Contents/Resources/`] });
  await Deno.copyFile(`packaging/${QL_NAME}-Info.plist`, `${QL_APPEX}/Contents/Info.plist`);
  // Ad-hoc sign the .appex ONLY (extensions must be signed and sandboxed for
  // pluginkit to load them, even locally). The host .app stays unsigned here;
  // everything is re-signed outside this repo, nested extension first.
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
