import AppKit
import XCTest

@testable import Markio

/// One window per document, however many times it is opened.
///
/// The old build's checklist has this as an item of its own, and it is not a
/// thing this app writes: `NSDocumentController` keys open documents by URL and
/// hands back the one it has. What a subclass can do is break it, so this is
/// here to say that this one does not.
@MainActor
final class OpenAgainTests: XCTestCase {
    func testOpeningAFileThatIsAlreadyOpenReusesIt() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("markio-open-again-\(UUID().uuidString).md")
        try Data("# Once\n\nAnd only once.\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let controller = MarkdownDocumentController()
        let first = try open(url, with: controller)
        XCTAssertFalse(first.alreadyOpen)
        let second = try open(url, with: controller)
        XCTAssertTrue(second.alreadyOpen)
        XCTAssertTrue(first.document === second.document)
        XCTAssertEqual(controller.documents.filter { $0.fileURL == url }.count, 1)
        first.document.close()
    }

    private func open(
        _ url: URL, with controller: NSDocumentController
    ) throws -> (document: NSDocument, alreadyOpen: Bool) {
        var result: (NSDocument, Bool)?
        var failure: Error?
        let opened = expectation(description: "opened")
        controller.openDocument(withContentsOf: url, display: false) { document, already, error in
            if let document { result = (document, already) }
            failure = error
            opened.fulfill()
        }
        wait(for: [opened], timeout: 5)
        if let failure { throw failure }
        return try XCTUnwrap(result)
    }
}
