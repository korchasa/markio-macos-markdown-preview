import XCTest

@testable import MarkioRender

/// Terminal escapes in a pasted log.
final class AnsiTextTests: XCTestCase {
    private let escape = "\u{1B}"

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
    private func string(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    func testEscapesAreRemovedFromTheText() {
        let input = bytes("\(escape)[32mok\(escape)[0m done")
        XCTAssertEqual(string(AnsiText.strip(input)), "ok done")
    }

    func testColouredRunsCoverExactlyTheColouredText() {
        let input = bytes("plain \(escape)[31mred\(escape)[0m plain")
        let parsed = AnsiText.parse(input, palette: AnsiText.Palette(isDark: false))
        XCTAssertEqual(string(parsed.text), "plain red plain")
        XCTAssertEqual(parsed.spans.count, 1)
        let span = try? XCTUnwrap(parsed.spans.first)
        XCTAssertEqual(span?.start, 6)
        XCTAssertEqual(span?.end, 9)
        XCTAssertNotNil(span?.color)
    }

    func testBackgroundAndBoldAreCarried() {
        let input = bytes("\(escape)[1;44;97m INFO \(escape)[0m")
        let parsed = AnsiText.parse(input, palette: AnsiText.Palette(isDark: true))
        XCTAssertEqual(string(parsed.text), " INFO ")
        XCTAssertEqual(parsed.spans.count, 1)
        XCTAssertTrue(parsed.spans[0].bold)
        XCTAssertNotNil(parsed.spans[0].background)
    }

    func testExtendedColourForms() {
        for sequence in ["\(escape)[38;5;208m", "\(escape)[38;2;120;190;255m"] {
            let parsed = AnsiText.parse(
                bytes("\(sequence)x\(escape)[0m"),
                palette: AnsiText.Palette(isDark: false)
            )
            XCTAssertEqual(string(parsed.text), "x")
            XCTAssertEqual(parsed.spans.count, 1, "failed for \(sequence.dropFirst())")
            XCTAssertNotNil(parsed.spans.first?.color)
        }
    }

    func testSequencesThatAreNotColourAreStillRemoved() {
        // Cursor motion describes a terminal that is not there; printing it
        // would show as mojibake.
        let input = bytes("a\(escape)[2Kb\(escape)[1;1Hc")
        let parsed = AnsiText.parse(input, palette: AnsiText.Palette(isDark: false))
        XCTAssertEqual(string(parsed.text), "abc")
        XCTAssertTrue(parsed.spans.isEmpty)
    }

    func testATruncatedEscapeDoesNotLeak() {
        let input = bytes("done\(escape)[3")
        XCTAssertEqual(string(AnsiText.strip(input)), "done")
    }

    func testTextWithoutEscapesIsUntouched() {
        let input = bytes("nothing to see")
        XCTAssertFalse(AnsiText.containsEscapes(input))
        let parsed = AnsiText.parse(input, palette: AnsiText.Palette(isDark: false))
        XCTAssertEqual(parsed.text, input)
        XCTAssertTrue(parsed.spans.isEmpty)
    }
}
