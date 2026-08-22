import AppKit
import XCTest

@testable import Markio

/// One window per document, however many times it is opened.
///
/// The old build's checklist has this as an item of its own, and it is not a
/// thing this app writes: `NSDocumentController` keeps the documents it has
/// open and looks them up by URL, so a second open finds the first one and
/// brings its window forward. What a subclass can do is break that lookup, so
/// this is here to say that this one does not.
///
/// The lookup is what is tested rather than a full `openDocument` — under the
/// test runner there is no app bundle claiming the Markdown type, so AppKit
/// refuses to open the file at all ("xctest cannot open files in the Markdown
/// text file format"). The test passed alone and failed in a full run, which is
/// worse than not having it.
@MainActor
final class OpenAgainTests: XCTestCase {
    func testAFileThatIsAlreadyOpenIsFoundRatherThanOpenedAgain() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("markio-open-again-\(UUID().uuidString).md")
        try Data("# Once\n\nAnd only once.\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let controller = MarkdownDocumentController()
        let document = MarkdownDocument()
        try document.read(
            from: Data("# Once\n\nAnd only once.\n".utf8),
            ofType: "net.daringfireball.markdown")
        document.fileURL = url
        controller.addDocument(document)

        XCTAssertTrue(controller.document(for: url) === document)
        // The same file by another spelling of its path is the same file.
        XCTAssertTrue(
            controller.document(for: URL(fileURLWithPath: url.path)) === document)
        XCTAssertNil(controller.document(for: url.deletingLastPathComponent()))
        XCTAssertEqual(controller.documents.filter { $0.fileURL == url }.count, 1)
        controller.removeDocument(document)
    }
}
