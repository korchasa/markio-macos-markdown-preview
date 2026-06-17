# Markview — standard command interface over SwiftPM.
# Verbs: check (build+scan+lint+test), test, dev, prod, fmt.
export NO_COLOR := 1

SWIFT_SOURCES := Sources Tests

.PHONY: check build scan fmt fmt-lint test dev prod clean

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

## prod — release build and run.
prod:
	swift build -c release
	swift run -c release Markview $(ARGS)

## clean — remove build artifacts.
clean:
	swift package clean
	rm -rf .build
