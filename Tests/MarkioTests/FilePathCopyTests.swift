import AppKit
import XCTest

@testable import Markio

/// Native clipboard acceptance for File ▸ Copy File Path. A uniquely named
/// pasteboard keeps the user's clipboard untouched. [REF:fr:menu]
@MainActor
final class FilePathCopyTests: XCTestCase {
    func testCopiesAbsoluteFilePathAsPlainText() {
        let pasteboard = makePasteboard()
        let fileURL = URL(fileURLWithPath: "/tmp/папка с пробелом/заметка.md")

        let copied = FilePathClipboard(pasteboard: pasteboard).copy(fileURL)

        XCTAssertTrue(copied)
        XCTAssertEqual(pasteboard.string(forType: .string), fileURL.path)
        XCTAssertTrue(fileURL.path.hasPrefix("/"))
        XCTAssertFalse(pasteboard.string(forType: .string)?.contains("file://") == true)
        XCTAssertFalse(pasteboard.string(forType: .string)?.contains("%20") == true)
        XCTAssertFalse(pasteboard.string(forType: .string)?.hasSuffix("\n") == true)
    }

    func testUnavailableFileLeavesPasteboardUntouched() {
        let pasteboard = makePasteboard()
        pasteboard.setString("sentinel", forType: .string)

        let copied = FilePathClipboard(pasteboard: pasteboard).copy(nil)

        XCTAssertFalse(copied)
        XCTAssertEqual(pasteboard.string(forType: .string), "sentinel")
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("dev.markio.tests.\(UUID().uuidString)"))
    }
}
