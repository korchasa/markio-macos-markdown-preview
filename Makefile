# Markview — standard command interface over SwiftPM.
# Verbs: check (build+scan+lint+test), test, dev, prod, fmt.
export NO_COLOR := 1

SWIFT_SOURCES := Sources Tests

# .app packaging (built under .build, which is gitignored / clean-able).
APP_NAME := Markview
APP_BUNDLE := .build/$(APP_NAME).app
RELEASE_BIN := .build/release/$(APP_NAME)
RELEASE_RESBUNDLE := .build/release/$(APP_NAME)_$(APP_NAME).bundle

.PHONY: check build scan fmt fmt-lint test dev app prod clean

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
	swift run Markview $(ARGS)

## app — release build packaged as a proper Markview.app bundle.
## A bundle (with Info.plist + bundle id) makes macOS keep a single instance and
## route every open into it (window-per-document), unlike the raw dev binary.
app:
	swift build -c release
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"
	cp "$(RELEASE_BIN)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	# Resource bundle next to the binary AND in Resources so Bundle.module resolves it.
	cp -R "$(RELEASE_RESBUNDLE)" "$(APP_BUNDLE)/Contents/MacOS/"
	cp -R "$(RELEASE_RESBUNDLE)" "$(APP_BUNDLE)/Contents/Resources/"
	cp packaging/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@echo "app: built $(APP_BUNDLE)"

## prod — build the .app and launch it (single instance). Pass a file:
## make prod ARGS="path/to/file.md".
prod: app
	open -a "$(abspath $(APP_BUNDLE))" $(ARGS)

## clean — remove build artifacts.
clean:
	swift package clean
	rm -rf .build
