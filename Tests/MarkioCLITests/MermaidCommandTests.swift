import CoreGraphics
import ImageIO
import MarkioRender
import XCTest

@testable import markio_cli

/// One Mermaid source in, one PNG out, and an exit status that says which of
/// the ways it can end this was.
@MainActor
final class MermaidCommandTests: XCTestCase {
    private let source = """
        flowchart TD
            A[One] --> B[Two]
            B --> C[Three]
        """

    /// A subgraph left open is not a diagram in any Mermaid, which keeps this
    /// refused however many constructs the layout learns.
    private let refused = "flowchart TD\n subgraph a\n A --> B\n"

    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("markio-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// What a run left behind, with the test standing in for the terminal.
    private struct Outcome {
        var status: Int32
        var output = Data()
        var complaints: [String] = []
    }

    private func run(_ arguments: String..., typed: String = "") -> Outcome {
        final class Terminal {
            var output = Data()
            var complaints: [String] = []
        }
        let terminal = Terminal()
        let status = Tool.run(
            arguments: arguments,
            io: IO(
                read: { Data(typed.utf8) },
                write: { terminal.output.append($0) },
                complain: { terminal.complaints.append($0) }))
        return Outcome(status: status, output: terminal.output, complaints: terminal.complaints)
    }

    private func file(_ name: String, holding text: String? = nil) throws -> String {
        let url = folder.appendingPathComponent(name)
        if let text { try Data(text.utf8).write(to: url) }
        return url.path
    }

    private func picture(_ data: Data) throws -> (image: CGImage, dotsPerInch: Double?) {
        let read = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(read) as String?, "public.png")
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(read, 0, nil) as? [CFString: Any])
        return (
            try XCTUnwrap(CGImageSourceCreateImageAtIndex(read, 0, nil)),
            properties[kCGImagePropertyDPIWidth] as? Double
        )
    }

    private func picture(at path: String) throws -> (image: CGImage, dotsPerInch: Double?) {
        try picture(Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func testAFileIsDrawnToAPNGAtTwoPixelsPerPoint() throws {
        let input = try file("flow.mmd", holding: source)
        let output = try file("flow.png")

        let outcome = run("mermaid", input, "-o", output)
        XCTAssertEqual(outcome.status, 0)
        XCTAssertEqual(outcome.complaints, [])

        // The picture the app writes when a reader opens a diagram on its own:
        // its natural size, and dense enough for a Retina screen, with the file
        // saying so.
        let natural = try XCTUnwrap(
            DocumentRenderer.diagram(
                source: source, theme: Theme(isDark: false),
                width: DocumentRenderer.naturalWidth, scale: 1))
        let written = try picture(at: output)
        // Within a pixel: a size in points is rarely whole, and each density
        // rounds it for itself.
        XCTAssertEqual(Double(written.image.width), Double(natural.width * 2), accuracy: 1)
        XCTAssertEqual(Double(written.image.height), Double(natural.height * 2), accuracy: 1)
        XCTAssertEqual(written.dotsPerInch, 144)

        // Standard output is free when the picture went to a file, so it says
        // what was written — the size is what a caller checks first.
        let said = String(decoding: outcome.output, as: UTF8.self)
        XCTAssertEqual(
            said, "wrote \(output) — \(written.image.width)×\(written.image.height)\n")
    }

    func testStandardStreamsCarryTheSourceAndNothingButThePicture() throws {
        let outcome = run("mermaid", "-", "-o", "-", typed: source)
        XCTAssertEqual(outcome.status, 0)
        XCTAssertEqual(outcome.complaints, [])
        // A line of text ahead of the picture would make it no picture at all.
        XCTAssertEqual(Array(outcome.output.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertGreaterThan(try picture(outcome.output).image.width, 0)
    }

    func testAScaleIsThePixelsInEachPoint() throws {
        let input = try file("flow.mmd", holding: source)
        let plain = try file("plain.png")
        let single = try file("single.png")
        XCTAssertEqual(run("mermaid", input, "-o", plain).status, 0)
        XCTAssertEqual(run("mermaid", input, "-o", single, "--scale", "1").status, 0)

        let two = try picture(at: plain)
        let one = try picture(at: single)
        XCTAssertEqual(Double(one.image.width * 2), Double(two.image.width), accuracy: 1)
        // The file says how dense it is, so both open at the same size.
        XCTAssertEqual(one.dotsPerInch, 72)
        XCTAssertEqual(two.dotsPerInch, 144)
    }

    func testTheSourceNamesItsOwnColours() throws {
        let plain = try file("plain.png")
        let themed = try file("themed.png")
        XCTAssertEqual(
            run("mermaid", try file("plain.mmd", holding: source), "-o", plain).status, 0)
        let directive = "%%{init: {\"theme\": \"dark\"}}%%\n"
        XCTAssertEqual(
            run("mermaid", try file("themed.mmd", holding: directive + source), "-o", themed)
                .status, 0)

        // Same layout, other palette: the size holds and the pixels do not.
        XCTAssertEqual(try picture(at: themed).image.width, try picture(at: plain).image.width)
        XCTAssertNotEqual(
            try Data(contentsOf: URL(fileURLWithPath: themed)),
            try Data(contentsOf: URL(fileURLWithPath: plain)))
    }

    func testAWidthIsWhereTheDiagramStopsGrowing() throws {
        // Wide enough that its own size is past the limit asked for below.
        let wide = """
            sequenceDiagram
                participant A as A participant with a long name
                participant B as Another participant with a long name
                participant C as A third participant with a long name
                A->>B: a message with enough words to need real room
                B->>C: and another message just as wordy as the first
            """
        let input = try file("wide.mmd", holding: wide)
        let natural = try file("natural.png")
        let narrow = try file("narrow.png")
        XCTAssertEqual(run("mermaid", input, "-o", natural, "--scale", "1").status, 0)
        XCTAssertEqual(
            run("mermaid", input, "-o", narrow, "--scale", "1", "--width", "520").status, 0)
        XCTAssertLessThan(try picture(at: narrow).image.width, try picture(at: natural).image.width)
        XCTAssertLessThanOrEqual(try picture(at: narrow).image.width, 520)
    }

    func testARefusedSourceExitsThreeAndWritesNothing() throws {
        let input = try file("open.mmd", holding: refused)
        let output = try file("open.png")

        let outcome = run("mermaid", input, "-o", output)
        XCTAssertEqual(outcome.status, 3)
        XCTAssertEqual(outcome.output, Data())
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
        XCTAssertEqual(outcome.complaints.count, 1)
        XCTAssertTrue(try XCTUnwrap(outcome.complaints.first).contains("refused"))
    }

    func testAMissingInputExitsOne() throws {
        let input = try file("absent.mmd")
        let output = try file("absent.png")

        let outcome = run("mermaid", input, "-o", output)
        XCTAssertEqual(outcome.status, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
        XCTAssertTrue(try XCTUnwrap(outcome.complaints.first).contains(input))
    }

    func testAnOutputThatCannotBeWrittenExitsOne() throws {
        let input = try file("flow.mmd", holding: source)
        let output = try file("no-such-folder/flow.png")

        let outcome = run("mermaid", input, "-o", output)
        XCTAssertEqual(outcome.status, 1)
        XCTAssertEqual(outcome.output, Data())
        XCTAssertTrue(try XCTUnwrap(outcome.complaints.first).contains(output))
    }

    func testACommandLineThatDoesNotParseExitsTwoWithTheUsage() {
        let outcome = run("mermaid", "in.mmd")
        XCTAssertEqual(outcome.status, 2)
        XCTAssertEqual(outcome.output, Data())
        XCTAssertEqual(outcome.complaints.first, "markio: no output named — add -o <output.png>")
        XCTAssertEqual(outcome.complaints.last, Arguments.usage)
    }

    func testHelpIsTheUsageOnStandardOutput() {
        let outcome = run("--help")
        XCTAssertEqual(outcome.status, 0)
        XCTAssertEqual(String(decoding: outcome.output, as: UTF8.self), Arguments.usage + "\n")
        XCTAssertEqual(outcome.complaints, [])
    }

    /// The program as it is built, through real pipes: the one path the tests
    /// above cannot take, because they are the terminal themselves.
    func testTheBuiltProgramDrawsFromStandardInputToStandardOutput() throws {
        let bundle = try XCTUnwrap(
            Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") })
        let program = bundle.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("markio-cli")

        let process = Process()
        process.executableURL = program
        process.arguments = ["mermaid", "-", "-o", "-"]
        let typed = Pipe()
        let shown = Pipe()
        let complained = Pipe()
        process.standardInput = typed
        process.standardOutput = shown
        process.standardError = complained
        try process.run()
        typed.fileHandleForWriting.write(Data(source.utf8))
        try typed.fileHandleForWriting.close()
        let output = shown.fileHandleForReading.readDataToEndOfFile()
        let complaints = complained.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: complaints, as: UTF8.self), "")
        XCTAssertEqual(try picture(output).dotsPerInch, 144)
    }
}
