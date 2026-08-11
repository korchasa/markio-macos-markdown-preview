/**
 * `deno task dist` — produce the UNSIGNED .app bundle.
 *
 * Signing, packaging and upload happen outside this repository; the App Sandbox
 * is declared in packaging/Markio.entitlements and applied at signing time.
 * The output path is part of that contract and must stay `.build/Markio.app`.
 */

import { section } from "./lib.ts";
import { app, APP_BUNDLE } from "./app.ts";

await app();
section(`dist: unsigned bundle ready at ${APP_BUNDLE} — sign outside this repo`);
