import XCTest

@testable import Markio

/// What a clicked link means, which is the whole of the app's link safety.
///
/// The old build's checklist had seven items for local links and none of them
/// was covered here: the decision was made in one place and tested nowhere.
final class LinkResolverTests: XCTestCase {
    private var folder = URL(fileURLWithPath: "/tmp")
    private var document = URL(fileURLWithPath: "/tmp/doc.md")

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("markio-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        document = folder.appendingPathComponent("doc.md")
        try Data("# Doc\n".utf8).write(to: document)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func resolve(_ destination: String) -> LinkResolver.Target? {
        LinkResolver.resolve(destination: destination, relativeTo: document)
    }

    func testAnAnchorStaysInThisDocument() {
        guard case .anchor(let slug) = resolve("#the-plan") else {
            return XCTFail("expected an anchor")
        }
        XCTAssertEqual(slug, "the-plan")
        // Percent-encoded headings are the common case in generated documents.
        guard case .anchor(let encoded) = resolve("#%D0%BF%D0%BB%D0%B0%D0%BD") else {
            return XCTFail("expected an anchor")
        }
        XCTAssertEqual(encoded, "план")
    }

    func testAMarkdownNeighbourOpensAsADocument() throws {
        try Data("# Notes\n".utf8).write(to: folder.appendingPathComponent("notes.md"))
        guard case .document(let url, let anchor) = resolve("notes.md") else {
            return XCTFail("expected a document")
        }
        XCTAssertEqual(url.lastPathComponent, "notes.md")
        XCTAssertNil(anchor)
    }

    /// The one that needs two things at once: open that document, then jump.
    func testALinkIntoAnotherDocumentCarriesItsAnchor() {
        guard case .document(let url, let anchor) = resolve("notes.md#results") else {
            return XCTFail("expected a document")
        }
        XCTAssertEqual(url.lastPathComponent, "notes.md")
        XCTAssertEqual(anchor, "results")
    }

    func testAnythingWithASchemeGoesToTheSystem() {
        guard case .external(let url) = resolve("https://example.com/a?b=1") else {
            return XCTFail("expected an external link")
        }
        XCTAssertEqual(url.absoluteString, "https://example.com/a?b=1")
        guard case .external = resolve("mailto:someone@example.com") else {
            return XCTFail("mail is the system's")
        }
        // A protocol-relative link is a web link written by a page, not a path.
        guard case .external(let assumed) = resolve("//example.com/x") else {
            return XCTFail("expected an external link")
        }
        XCTAssertEqual(assumed.scheme, "https")
    }

    func testASchemeTheAppDoesNotServeIsRefused() {
        // `file:` above all: it would be a way around the relative-path rule.
        XCTAssertNil(resolve("file:///etc/passwd"))
        XCTAssertNil(resolve("javascript:alert(1)"))
        XCTAssertNil(resolve("markio://internal"))
    }

    func testASourceFileBesideTheDocumentOpensInAnEditor() throws {
        let source = folder.appendingPathComponent("main.swift")
        try Data("let x = 1\n".utf8).write(to: source)
        guard case .file(let url, let line) = resolve("main.swift:214") else {
            return XCTFail("expected a file")
        }
        XCTAssertEqual(url.lastPathComponent, "main.swift")
        XCTAssertEqual(line, 214)
        guard case .file(_, let none) = resolve("main.swift") else {
            return XCTFail("expected a file")
        }
        XCTAssertNil(none)
    }

    /// The safety argument, in three refusals.
    func testNothingOutsideTheDocumentsOwnFolderIsOpened() throws {
        // Absolute, however real.
        XCTAssertNil(resolve("/etc/hosts"))
        // Climbing out, even to a file that is there.
        let above = folder.deletingLastPathComponent().appendingPathComponent(
            "markio-outside-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: above)
        defer { try? FileManager.default.removeItem(at: above) }
        XCTAssertNil(resolve("../\(above.lastPathComponent)"))
        // A file that is not there at all.
        XCTAssertNil(resolve("missing.swift"))
        // A folder is not a file.
        XCTAssertNil(resolve("."))
    }

    /// A document that has never been saved has nothing to be relative to.
    func testAnUnsavedDocumentResolvesNoLocalPaths() {
        XCTAssertNil(LinkResolver.resolve(destination: "notes.md", relativeTo: nil))
        // An anchor still works: it needs no file at all.
        guard case .anchor = LinkResolver.resolve(destination: "#top", relativeTo: nil) else {
            return XCTFail("expected an anchor")
        }
    }

    func testWhatCountsAsAMarkdownFile() {
        for name in ["a.md", "b.MARKDOWN", "c.mdown", "d.mkd"] {
            XCTAssertTrue(LinkResolver.isMarkdown(URL(fileURLWithPath: "/tmp/\(name)")))
        }
        for name in ["a.txt", "b.markdownx", "c"] {
            XCTAssertFalse(LinkResolver.isMarkdown(URL(fileURLWithPath: "/tmp/\(name)")))
        }
    }
}
