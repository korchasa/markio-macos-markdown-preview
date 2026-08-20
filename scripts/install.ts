/**
 * `deno task install` — put a fresh build in /Applications as "Markio Dev".
 *
 * A copy in /Applications is how the app gets used the way a reader uses it:
 * launched from Spotlight, opening documents from Finder, previewing them in
 * Quick Look. What ships to the store is not that copy — it arrives signed from
 * outside this repository — so the two must be able to sit side by side. This
 * one is therefore renamed and given its own bundle ids: identical ids would
 * leave LaunchServices choosing between two apps with the same name and the
 * same identity, and it does not choose the one you just built.
 *
 * The packaging plists are never touched. Every rename here is made in the
 * copy under /Applications, which is why `deno task check`'s identity gate goes
 * on comparing the sources against `identity.ts` and reading the same answer.
 */

import { fail, run, section } from "./lib.ts";
import { app, APP_BUNDLE } from "./app.ts";
import { APP_NAME, QL_NAME } from "./identity.ts";

/** What the local copy is called and answers to. */
const DEV_NAME = `${APP_NAME} Dev`;
const DEV_ID = "dev.markio.app.dev";
const DEV_QL_ID = `${DEV_ID}.quicklook`;
const INSTALLED = `/Applications/${DEV_NAME}.app`;

/**
 * Replace one plist value, leaving the rest of the file — comments included —
 * exactly as it was. `PlistBuddy` rewrites the whole document to change one
 * line, and a bundle nobody can diff is a bundle nobody can check.
 */
async function setValue(plist: string, key: string, value: string): Promise<void> {
  const text = await Deno.readTextFile(plist);
  const pattern = new RegExp(`(<key>${key}</key>\\s*<string>)[^<]*(</string>)`);
  if (!pattern.test(text)) fail(`${plist} has no ${key} to set`);
  await Deno.writeTextFile(plist, text.replace(pattern, `$1${value}$2`));
}

/** The commit this build came from, so the About panel says which one it is. */
async function commit(): Promise<string> {
  const head = await run("git", {
    args: ["rev-parse", "--short", "HEAD"],
    capture: true,
    allowFailure: true,
  });
  if (head.code !== 0) return "unknown";
  const dirty = await run("git", {
    args: ["status", "--porcelain"],
    capture: true,
    allowFailure: true,
  });
  return head.stdout.trim() + (dirty.stdout.trim() === "" ? "" : "+");
}

export async function install(): Promise<void> {
  await app();

  section(`Installing ${INSTALLED}`);
  // A copy owned by root — an old bundle an installer put there — cannot be
  // replaced from here, and saying so is more use than a permission error
  // thrown from the middle of a copy.
  const existing = await Deno.stat(INSTALLED).catch(() => null);
  if (
    existing && !(await run("test", { args: ["-w", INSTALLED], allowFailure: true }).then(
      (r) => r.code === 0,
    ))
  ) {
    fail(`${INSTALLED} is not yours to replace — remove it with sudo and run this again`);
  }
  await Deno.remove(INSTALLED, { recursive: true }).catch(() => {});
  await run("cp", { args: ["-R", APP_BUNDLE, INSTALLED] });

  section("Naming it apart from the store build");
  const plist = `${INSTALLED}/Contents/Info.plist`;
  await setValue(plist, "CFBundleName", DEV_NAME);
  await setValue(plist, "CFBundleDisplayName", DEV_NAME);
  await setValue(plist, "CFBundleIdentifier", DEV_ID);
  await setValue(plist, "CFBundleShortVersionString", `1.0-dev ${await commit()}`);
  const appex = `${INSTALLED}/Contents/PlugIns/${QL_NAME}.appex/Contents/Info.plist`;
  await setValue(appex, "CFBundleIdentifier", DEV_QL_ID);
  await setValue(appex, "CFBundleName", `${DEV_NAME} Quick Look`);
  await setValue(appex, "CFBundleDisplayName", `${DEV_NAME} Quick Look`);
  // The extension was signed as it was assembled, and editing its plist breaks
  // that signature. pluginkit refuses to load an extension whose seal is
  // broken, so it is sealed again over the names it now carries.
  await run("codesign", {
    args: [
      "--force",
      "--sign",
      "-",
      "--entitlements",
      "packaging/MarkioQuickLook.entitlements",
      `${INSTALLED}/Contents/PlugIns/${QL_NAME}.appex`,
    ],
  });

  // LaunchServices reads a bundle when it is installed by an installer, and a
  // directory copied into place is not that: without this the Quick Look
  // extension is not offered and Finder goes on opening documents in whatever
  // it knew before.
  section("Registering it with LaunchServices");
  await run(
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
    { args: ["-f", INSTALLED] },
  );

  section(`install: ${INSTALLED} is this build`);
}

if (import.meta.main) await install();
