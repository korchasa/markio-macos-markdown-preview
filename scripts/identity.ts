/**
 * The bundle identity this app ships under, in one place.
 *
 * These strings are not free choices. The App Store record they belong to was
 * registered against `dev.markio.app`, the Quick Look extension against
 * `dev.markio.app.quicklook`, and the signing certificates and provisioning
 * profiles held outside this repository are issued for exactly those two. A
 * change here is a change to what the store will accept, so the gate compares
 * the packaging plists against this file and fails when they drift.
 *
 * The two kinds of name below read the same today and still mean different
 * things. One is the Swift product `swift build` writes into `.build/release`;
 * the other is what the bundle, its executable and the extension inside it are
 * called. `NSDocumentClass` is built from the first, because it names the Swift
 * module and not the file on disk — rename the bundle alone and documents stop
 * opening, with nothing to say why.
 */

import { fail, run } from "./lib.ts";

/** Swift product names — what `swift build` writes into `.build/release`. */
export const APP_PRODUCT = "Markio";
export const QL_PRODUCT = "MarkioQuickLook";

/** Bundle names — what a reader ends up with. */
export const APP_NAME = "Markio";
export const QL_NAME = "MarkioQuickLook";

export const APP_PLIST = "packaging/Info.plist";
export const QL_PLIST = "packaging/MarkioQuickLook-Info.plist";

/** Every plist key whose value the store depends on, and what it must be. */
const EXPECTED: Array<{ plist: string; keys: Record<string, string> }> = [
  {
    plist: APP_PLIST,
    keys: {
      CFBundleIdentifier: "dev.markio.app",
      CFBundleExecutable: APP_NAME,
      CFBundleName: APP_NAME,
      CFBundleDisplayName: APP_NAME,
      CFBundleShortVersionString: "1.0",
      CFBundleVersion: "8",
      // One declared locale, or AppKit renders its own standard menu items in
      // the system language beside ours, which ship untranslated English.
      CFBundleDevelopmentRegion: "en",
      // Nested inside the document-types array, and named after the Swift
      // module rather than the executable file.
      "CFBundleDocumentTypes.0.NSDocumentClass": `${APP_PRODUCT}.MarkdownDocument`,
    },
  },
  {
    plist: QL_PLIST,
    keys: {
      CFBundleIdentifier: "dev.markio.app.quicklook",
      CFBundleExecutable: QL_NAME,
      CFBundleName: "Markio Quick Look",
      CFBundleDisplayName: "Markio Quick Look",
      // An extension whose version disagrees with its host is rejected at
      // ingest, so these track the app's rather than living their own life.
      CFBundleShortVersionString: "1.0",
      CFBundleVersion: "8",
    },
  },
];

/** Read one key out of a plist. `-o -` keeps plutil from rewriting the file. */
async function readKey(plist: string, key: string): Promise<string> {
  const result = await run("plutil", {
    args: ["-extract", key, "raw", "-o", "-", "--", plist],
    capture: true,
    allowFailure: true,
  });
  if (result.code !== 0) return "";
  return result.stdout.trim();
}

/**
 * Compare every packaging plist against the identity above.
 *
 * Reports all mismatches before failing: one wrong key usually means several,
 * and finding them one gate run at a time is a waste of a release build.
 */
export async function verifyIdentity(): Promise<void> {
  const problems: string[] = [];
  for (const { plist, keys } of EXPECTED) {
    for (const [key, want] of Object.entries(keys)) {
      const got = await readKey(plist, key);
      if (got !== want) {
        problems.push(`${plist}: ${key} is ${got || "(absent)"}, expected ${want}`);
      }
    }
  }

  // CFBundleLocalizations is an array, so it is read as JSON rather than raw.
  const locales = await run("plutil", {
    args: ["-extract", "CFBundleLocalizations", "json", "-o", "-", "--", APP_PLIST],
    capture: true,
    allowFailure: true,
  });
  if (locales.code !== 0 || locales.stdout.trim() !== '["en"]') {
    problems.push(
      `${APP_PLIST}: CFBundleLocalizations is ${
        locales.code === 0 ? locales.stdout.trim() : "(absent)"
      }, expected ["en"]`,
    );
  }

  if (problems.length > 0) {
    problems.forEach((problem) => console.log(`    ${problem}`));
    fail("the packaging plists do not carry the store identity");
  }
  console.log("    clean");
}

if (import.meta.main) await verifyIdentity();
