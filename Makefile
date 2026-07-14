# Markio — standard command interface over SwiftPM.
# Verbs: check (build+scan+lint+test), test, dev, prod, fmt.
export NO_COLOR := 1

SWIFT_SOURCES := Sources Tests

# .app packaging (built under .build, which is gitignored / clean-able).
APP_NAME := Markio
APP_BUNDLE := .build/$(APP_NAME).app
RELEASE_BIN := .build/release/$(APP_NAME)
# SwiftPM resource bundle of the shared MarkioEngine target (<pkg>_<target>).
RELEASE_RESBUNDLE := .build/release/$(APP_NAME)_MarkioEngine.bundle

# Quick Look preview extension (.appex embedded under Contents/PlugIns).
QL_NAME := MarkioQuickLook
QL_BIN := .build/release/$(QL_NAME)
QL_APPEX := $(APP_BUNDLE)/Contents/PlugIns/$(QL_NAME).appex

.PHONY: check build scan fmt fmt-lint test dev app run dist prod clean

## check — comprehensive verification: build, comment-scan, format lint, tests.
check: build scan fmt-lint test
	@echo "check: OK"

## build — compile the package (debug).
build:
	swift build

## scan — fail on leftover work markers / suppression comments in Swift sources.
## Vendored web assets and this Makefile are excluded (third-party / self-match).
scan:
	@echo "scan: comment markers"
	@! grep -RInE --include='*.swift' \
		'(TODO|FIXME|HACK|XXX|swiftlint:disable|swift-format-ignore|debugPrint\()' \
		$(SWIFT_SOURCES) \
		|| (echo "scan: found forbidden markers" && exit 1)
	@echo "scan: OK"

## fmt — apply formatting in place.
fmt:
	swift format format -i -r $(SWIFT_SOURCES)

## fmt-lint — verify formatting without modifying files.
fmt-lint:
	swift format lint -s -r $(SWIFT_SOURCES)

## test — run the full test suite, or a filtered subset via ARGS.
test:
	swift test $(ARGS)

## dev — run the app (debug). Pass a file: make dev ARGS="path/to/file.md".
dev:
	swift run Markio $(ARGS)

## run — manual-QA loop in one step: rebuild the bundle, restart the app, and
## re-register the Quick Look appex (a rebuild DROPS its pluginkit registration;
## see AGENTS.md "Quick Look dev loop"). Pass a file: make run ARGS="doc.md".
run: app
	# Quit is asynchronous — without the pause `open` races the dying process
	# and fails with LaunchServices -600 (procNotFound).
	-osascript -e 'quit app "$(APP_NAME)"' 2>/dev/null; sleep 1
	pluginkit -a "$(QL_APPEX)"
	open -a "$(CURDIR)/$(APP_BUNDLE)" $(ARGS)

## app — release build packaged as a proper Markio.app bundle.
## A bundle (with Info.plist + bundle id) makes macOS keep a single instance and
## route every open into it (window-per-document), unlike the raw dev binary.
app:
	swift build -c release
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	cp "$(RELEASE_BIN)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	# Resource bundle goes in Contents/Resources only; ResourceLocator finds it
	# there via Bundle.main.resourceURL (NOT SwiftPM's Bundle.module, whose
	# accessor looks beside Bundle.main.bundleURL and crashed the packaged app).
	# (A .bundle under Contents/MacOS/ breaks codesign: "bundle format
	# unrecognized" — that dir is for Mach-O executables only.)
	cp -R "$(RELEASE_RESBUNDLE)" "$(APP_BUNDLE)/Contents/Resources/"
	cp packaging/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	# Compile the app icon as an asset catalog (Assets.car + AppIcon.icns).
	# App Store validation (ITMS-90546) rejects bundles with only a loose .icns.
	xcrun actool packaging/Assets.xcassets \
		--compile "$(APP_BUNDLE)/Contents/Resources" \
		--platform macosx --minimum-deployment-target 14.0 \
		--app-icon AppIcon \
		--output-partial-info-plist .build/assetcatalog-info.plist >/dev/null
	# Drop the loose AppIcon.icns actool also emits (capped at 256×256). The
	# App Store icon must come from Assets.car (1024×1024) via CFBundleIconName;
	# leaving the .icns lets ingest pick the low-res file instead.
	rm -f "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	# Quick Look preview extension: hand-assembled .appex (no Xcode). The
	# extension binary links with entry _NSExtensionMain (see Package.swift);
	# it carries its own copy of the engine resource bundle — reading the
	# host app's copy across the extension sandbox boundary is not
	# guaranteed. [REF:fr:quicklook]
	mkdir -p "$(QL_APPEX)/Contents/MacOS" "$(QL_APPEX)/Contents/Resources"
	cp "$(QL_BIN)" "$(QL_APPEX)/Contents/MacOS/$(QL_NAME)"
	cp -R "$(RELEASE_RESBUNDLE)" "$(QL_APPEX)/Contents/Resources/"
	cp packaging/$(QL_NAME)-Info.plist "$(QL_APPEX)/Contents/Info.plist"
	# Ad-hoc sign the .appex ONLY (extensions must be signed + sandboxed for
	# pluginkit to load them, even locally). The host .app stays unsigned in
	# this repo; app-store-factory re-signs everything (nested extension
	# first) with real identities for distribution.
	codesign --force --sign - \
		--entitlements packaging/$(QL_NAME).entitlements "$(QL_APPEX)"
	@echo "app: built $(APP_BUNDLE)"

## dist — produce the UNSIGNED .app bundle for the App Store. Signing and .pkg
## packaging are done by app-store-factory (the App Sandbox is declared in
## packaging/Markio.entitlements, applied by the factory at signing time).
dist: app
	@echo "dist: unsigned bundle ready at $(APP_BUNDLE) — sign via app-store-factory"

## prod — build the .app and launch it (single instance). Pass a file:
## make prod ARGS="path/to/file.md".
prod: app
	open -a "$(abspath $(APP_BUNDLE))" $(ARGS)

## clean — remove build artifacts.
clean:
	swift package clean
	rm -rf .build
