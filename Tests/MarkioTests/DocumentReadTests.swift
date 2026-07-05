import XCTest

@testable import Markio

/// `MarkdownDocument` read contract: decode UTF-8, fail fast on invalid bytes.
/// The document is the per-window unit DocumentGroup builds on. [REF:fr:multidoc]
final class DocumentReadTests: XCTestCase {
    func testDecodesUTF8() throws {
        let doc = try MarkdownDocument(data: Data("# Héllo — über".utf8))
        XCTAssertEqual(doc.text, "# Héllo — über")
    }

    func testRejectsInvalidUTF8() {
        // 0xFF is never valid in a UTF-8 stream → must throw, not render garbage.
        XCTAssertThrowsError(try MarkdownDocument(data: Data([0xFF, 0xFE, 0xFF])))
    }
}
