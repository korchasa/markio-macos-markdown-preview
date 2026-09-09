import XCTest

@testable import Markio

/// Where a file goes when the system is asked to open it.
final class CodeEditorTests: XCTestCase {
    func testTheSystemHandlerIsNeverThisApp() {
        // Markio is the default app for Markdown, so "open elsewhere" has to
        // skip itself even when Launch Services lists it first.
        let own = URL(fileURLWithPath: "/Applications/Markio.app/")
        let other = URL(fileURLWithPath: "/Applications/TextEdit.app")
        XCTAssertEqual(
            CodeEditor.other(
                than: own, among: [URL(fileURLWithPath: "/Applications/Markio.app"), other]),
            other)
        XCTAssertNil(
            CodeEditor.other(than: own, among: [URL(fileURLWithPath: "/Applications/Markio.app")]))
        XCTAssertNil(CodeEditor.other(than: own, among: []))
    }
}
