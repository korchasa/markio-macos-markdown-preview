/**
 * `deno task app` — release build packaged as a proper Markio.app bundle, and
 * installed as the local "Markio Dev" copy.
 *
 * A bundle (Info.plist + bundle id) is what makes macOS keep a single instance
 * and route every open into it, one window per document. `prod` and `dist`
 * build on this.
 *
 * Two families of name meet here. `swift build` writes its products under the
 * target names — Markio, MarkioQuickLook — while what ships is named Markio.
 * Both come from `identity.ts` so the difference is stated once rather than
 * spelled out in string literals that can drift apart.
 */

import { run, section } from "./lib.ts";
import { APP_NAME, APP_PRODUCT, QL_NAME, QL_PLIST, QL_PRODUCT } from "./identity.ts";
import { installDevCopy } from "./install.ts";

export const APP_BUNDLE = `.build/${APP_NAME}.app`;
const RELEASE_BIN = `.build/release/${APP_PRODUCT}`;

const QL_BIN = `.build/release/${QL_PRODUCT}`;
export const QL_APPEX = `${APP_BUNDLE}/Contents/PlugIns/${QL_NAME}.appex`;

/**
 * `signHost: false` leaves the outer bundle unsigned — that is the `dist`
 * contract, where signing happens outside this repository. Every other caller
 * wants the signature: without it the binary is linker-signed, carries no
 * entitlements, and runs outside the sandbox the shipped app runs in.
 *
 * `installDev: false` skips the copy in /Applications, and `dist` needs that
 * too: the install quits the running dev copy first, a reader can refuse that
 * quit, and a refusal must not be able to fail the build that ships.
 */
export async function app(
  { signHost = true, installDev = true }: { signHost?: boolean; installDev?: boolean } = {},
): Promise<void> {
  section("Building (release)");
  await run("swift", { args: ["build", "-c", "release"] });

  section(`Assembling ${APP_BUNDLE}`);
  await Deno.remove(APP_BUNDLE, { recursive: true }).catch(() => {});
  await Deno.mkdir(`${APP_BUNDLE}/Contents/MacOS`, { recursive: true });
  await Deno.mkdir(`${APP_BUNDLE}/Contents/Resources`, { recursive: true });
  await Deno.copyFile(RELEASE_BIN, `${APP_BUNDLE}/Contents/MacOS/${APP_NAME}`);
  await Deno.copyFile("packaging/Info.plist", `${APP_BUNDLE}/Contents/Info.plist`);

  // The icon is compiled as an asset catalog and referenced by name
  // (`CFBundleIconName`). The loose AppIcon.icns actool also emits is deleted:
  // it caps at 256×256, and anything that prefers it over the catalog gets a
  // blurry icon at large sizes. Redraw the catalog with `deno task icons`.
  section("Compiling the asset catalog");
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

  // Quick Look preview extension: a hand-assembled .appex, no Xcode involved.
  // The binary is linked with `_NSExtensionMain` as its entry point (see
  // Package.swift) and carries no resources — the renderer is compiled in.
  section(`Assembling ${QL_APPEX}`);
  await Deno.mkdir(`${QL_APPEX}/Contents/MacOS`, { recursive: true });
  await Deno.copyFile(QL_BIN, `${QL_APPEX}/Contents/MacOS/${QL_NAME}`);
  await Deno.copyFile(QL_PLIST, `${QL_APPEX}/Contents/Info.plist`);
  // Ad-hoc sign the extension. pluginkit refuses to load an unsigned or
  // unsandboxed extension even locally; everything is re-signed outside this
  // repository, nested bundle first.
  await run("codesign", {
    args: [
      "--force",
      "--sign",
      "-",
      "--entitlements",
      `packaging/${QL_PRODUCT}.entitlements`,
      QL_APPEX,
    ],
  });

  // And the app itself, with the entitlements it ships with — the nested
  // bundle first, then the one containing it. A linker-signed binary carries
  // no entitlements at all, so a build left unsigned here runs outside the
  // sandbox and answers every sandbox question wrongly: a save panel that
  // AppKit would refuse in the store build opens locally, and nothing on this
  // machine can tell. That is how a dead Export as PDF reached App Review on
  // 2026-09-13. Re-signed outside this repository for distribution; this
  // signature only makes the local build behave like the shipped one.
  if (signHost) {
    section(`Signing ${APP_BUNDLE}`);
    await run("codesign", {
      args: [
        "--force",
        "--sign",
        "-",
        "--entitlements",
        "packaging/Markio.entitlements",
        APP_BUNDLE,
      ],
    });
  }

  // A build nobody can launch from Spotlight is half a build: the copy in
  // /Applications is refreshed here rather than by a verb somebody has to
  // remember, so what is installed is always what was last built.
  if (installDev) await installDevCopy(APP_BUNDLE);

  section(`app: built ${APP_BUNDLE}`);
}

if (import.meta.main) await app();
