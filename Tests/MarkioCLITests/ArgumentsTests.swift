import XCTest

@testable import markio_cli

/// The command line is read into a value before anything is drawn, so a
/// mistyped option is answered with the usage and not with half a picture.
final class ArgumentsTests: XCTestCase {
    private func options(_ arguments: String...) throws -> MermaidOptions {
        guard case .mermaid(let options) = try Arguments.parse(arguments) else {
            XCTFail("\(arguments) did not parse as a mermaid command")
            throw UsageError(message: "not a mermaid command")
        }
        return options
    }

    private func refusal(_ arguments: String...) -> String? {
        do {
            _ = try Arguments.parse(arguments)
            return nil
        } catch {
            return error.message
        }
    }

    func testAnInputAndAnOutputAreAllACommandNeeds() throws {
        XCTAssertEqual(
            try options("mermaid", "in.mmd", "-o", "out.png"),
            MermaidOptions(input: .file("in.mmd"), output: .file("out.png")))
        XCTAssertEqual(
            try options("mermaid", "in.mmd", "--output", "out.png"),
            MermaidOptions(input: .file("in.mmd"), output: .file("out.png")))
    }

    func testADashIsTheStandardStream() throws {
        XCTAssertEqual(
            try options("mermaid", "-", "-o", "-"),
            MermaidOptions(input: .standard, output: .standard))
    }

    func testOptionsMayComeInAnyOrder() throws {
        XCTAssertEqual(
            try options(
                "mermaid", "--scale", "3", "-o", "out.png", "in.mmd", "--width", "640"),
            MermaidOptions(
                input: .file("in.mmd"), output: .file("out.png"), width: 640, scale: 3))
    }

    func testHelpIsAskedForByName() throws {
        XCTAssertEqual(try Arguments.parse(["--help"]), .help)
        XCTAssertEqual(try Arguments.parse(["-h"]), .help)
        XCTAssertEqual(try Arguments.parse(["mermaid", "--help"]), .help)
    }

    func testTheUsageNamesEveryOption() {
        for word in ["markio mermaid", "-o", "--width", "--scale", "--help", "theme"] {
            XCTAssertTrue(Arguments.usage.contains(word), "the usage does not mention \(word)")
        }
    }

    func testWhatIsMissingIsNamed() {
        XCTAssertEqual(refusal(), "no command given")
        XCTAssertEqual(refusal("render", "in.mmd"), "unknown command: render")
        XCTAssertEqual(refusal("mermaid", "-o", "out.png"), "no input named")
        XCTAssertEqual(refusal("mermaid", "in.mmd"), "no output named — add -o <output.png>")
        XCTAssertEqual(refusal("mermaid", "in.mmd", "-o"), "-o needs a value")
        XCTAssertEqual(
            refusal("mermaid", "in.mmd", "-o", "a.png", "--width"), "--width needs a value")
    }

    func testWhatIsWrongIsNamed() {
        XCTAssertEqual(
            refusal("mermaid", "a.mmd", "b.mmd", "-o", "out.png"),
            "one input at a time: a.mmd, then b.mmd")
        XCTAssertEqual(
            refusal("mermaid", "in.mmd", "-o", "out.png", "--svg"), "unknown option: --svg")
        // Colours are the source's to name, so the command has no say in them.
        XCTAssertEqual(
            refusal("mermaid", "in.mmd", "-o", "out.png", "--dark"), "unknown option: --dark")
        XCTAssertEqual(
            refusal("mermaid", "in.mmd", "-o", "out.png", "--width", "wide"),
            "--width takes a number above zero, not wide")
        XCTAssertEqual(
            refusal("mermaid", "in.mmd", "-o", "out.png", "--scale", "0"),
            "--scale takes a number above zero, not 0")
        XCTAssertEqual(
            refusal("mermaid", "in.mmd", "-o", "out.png", "--scale", "-2"),
            "--scale takes a number above zero, not -2")
    }
}
