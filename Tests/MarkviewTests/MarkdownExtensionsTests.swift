import XCTest

@testable import Markview

/// Guards the single source of truth for recognized Markdown extensions: the
/// runtime list, the `URL` predicate, and the Info.plist declaration must agree
/// so the three copies cannot silently drift. [REF:fr:open]
final class MarkdownExtensionsTests: XCTestCase {
    func testURLPredicateDerivesFromCanonicalList() {
        XCTAssertEqual(MarkdownDocument.extensions, ["md", "markdown"])
        XCTAssertTrue(URL(fileURLWithPath: "/tmp/a.md").isMarkdown)
        XCTAssertTrue(URL(fileURLWithPath: "/tmp/a.MARKDOWN").isMarkdown, "case-insensitive")
        XCTAssertFalse(URL(fileURLWithPath: "/tmp/a.txt").isMarkdown)
    }

    func testInfoPlistExtensionsMatchCanonicalList() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MarkviewTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
        let plistURL = root.appendingPathComponent("packaging/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist =
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let docTypes = plist?["CFBundleDocumentTypes"] as? [[String: Any]]
        let plistExtensions = docTypes?.first?["CFBundleTypeExtensions"] as? [String]
        XCTAssertEqual(
            plistExtensions, MarkdownDocument.extensions,
            "Info.plist CFBundleTypeExtensions must stay in sync with MarkdownDocument.extensions")
    }
}
