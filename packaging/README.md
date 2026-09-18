# Packaging

What the two `Info.plist` files declare, and why each declaration is not a free
choice. The reasons live here because the plists themselves carry no comments.

## The plists carry no XML comments

Apple Developer Support wrote on 2026-09-19 (case 102964427402) that the app's
`Info.plist` contains XML comments and asked for them to be removed before the
next upload. The files are copied into the bundle byte for byte by
`scripts/app.ts`, so a comment in the source is a comment in the shipped app.
Keep the rationale in this file and the files themselves free of `<!-- -->`;
`deno task check` fails when a comment reappears.

## Info.plist (the app)

- **`CFBundleIdentifier` = `dev.markio.app`** — the identity the App Store
  record was registered under. The signing certificates and provisioning
  profiles held outside this repository are issued for this id and for
  `dev.markio.app.quicklook`, so changing either string leaves nothing able to
  sign the bundle. The Swift targets stay `Markio`: this is the second
  implementation of one product, not a second product. `scripts/identity.ts` is
  the gate that keeps them in step.
- **`CFBundleDevelopmentRegion` = `en` and one entry in
  `CFBundleLocalizations`** — English only. Our own menu items ship
  untranslated, so declaring more locales makes AppKit render *its* standard
  items in the system language beside ours: a menu bar in two languages at
  once. One declared locale keeps the whole interface in one.

## MarkioQuickLook-Info.plist (the Quick Look extension)

- **`CFBundleIdentifier` = `dev.markio.app.quicklook`** — registered as its own
  Bundle ID resource beside the host app's, and signed with its own Mac App
  Store profile before the app around it.
- **`CFBundlePackageType` = `XPC!`** — an app extension is an XPC service in
  bundle-format terms.
- **`CFBundleSupportedPlatforms`, `DTPlatformName`, `DTSDKName`** —
  ExtensionFoundation reads the platform when it builds the XPC connection for
  an extension request and traps on a missing key. A hand-assembled bundle does
  not get these from Xcode, so they are written out here.
- **`CFBundleShortVersionString` and `CFBundleVersion`** — an extension whose
  version disagrees with its host is rejected at ingest, so these track the
  app's rather than living their own life.
- **`NSExtensionPrincipalClass` = `PreviewViewController`** — the verbatim
  `@objc` name of the `QLPreviewingController` subclass.
- **`QLSupportedContentTypes` = `net.daringfireball.markdown` only** —
  deliberately not `public.plain-text`: the extension must never take over
  `.txt` previews.
- **`UTImportedTypeDeclarations`** — the Markdown type is not declared by the
  base system; importing it here makes `.md` and `.markdown` resolve to it even
  when no other app declares it. LaunchServices merges declarations across
  bundles.
