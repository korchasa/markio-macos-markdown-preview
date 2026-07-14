import XCTest

@testable import Markio

/// FR-LOCAL-LINKS: links inside rendered documents are useful — `#anchor`
/// links scroll the current document, relative `.md` links are handed to the
/// native side (new window per document), `other.md#section` does both.
/// External and unknown links are never hijacked by the page.
@MainActor
final class LinkTests: XCTestCase {
    private let doc = URL(fileURLWithPath: "/repo/docs/readme.md")

    // MARK: - Resolver (pure grammar)

    func testLocalLinkResolverResolvesRelativeAndRejectsOthers() {
        // Sibling file, no anchor.
        XCTAssertEqual(
            LocalLinkResolver.resolve(href: "other.md", documentURL: doc),
            LocalLink(fileURL: URL(fileURLWithPath: "/repo/docs/other.md"), anchor: nil))
        // Nested path with an anchor.
        XCTAssertEqual(
            LocalLinkResolver.resolve(href: "sub/guide.markdown#setup", documentURL: doc),
            LocalLink(
                fileURL: URL(fileURLWithPath: "/repo/docs/sub/guide.markdown"), anchor: "setup"))
        // Parent traversal — repo docs use it.
        XCTAssertEqual(
            LocalLinkResolver.resolve(href: "../up.md", documentURL: doc),
            LocalLink(fileURL: URL(fileURLWithPath: "/repo/up.md"), anchor: nil))
        // Percent-encoded path and anchor decode.
        XCTAssertEqual(
            LocalLinkResolver.resolve(href: "my%20doc.md#%D1%80%D0%B0%D0%B7", documentURL: doc),
            LocalLink(fileURL: URL(fileURLWithPath: "/repo/docs/my doc.md"), anchor: "раз"))
        // Uppercase extension is still Markdown.
        XCTAssertEqual(
            LocalLinkResolver.resolve(href: "NOTES.MD", documentURL: doc)?.fileURL,
            URL(fileURLWithPath: "/repo/docs/NOTES.MD"))
        // Empty trailing fragment → no anchor.
        XCTAssertEqual(
            LocalLinkResolver.resolve(href: "other.md#", documentURL: doc),
            LocalLink(fileURL: URL(fileURLWithPath: "/repo/docs/other.md"), anchor: nil))

        // Default-deny: everything below stays a dead click.
        XCTAssertNil(
            LocalLinkResolver.resolve(href: "#section", documentURL: doc),
            "in-document anchors are page-side, not a file open")
        XCTAssertNil(LocalLinkResolver.resolve(href: "", documentURL: doc))
        XCTAssertNil(LocalLinkResolver.resolve(href: "https://example.com/x.md", documentURL: doc))
        XCTAssertNil(LocalLinkResolver.resolve(href: "mailto:a@b.com", documentURL: doc))
        XCTAssertNil(
            LocalLinkResolver.resolve(href: "//example.com/x.md", documentURL: doc),
            "protocol-relative is not local")
        XCTAssertNil(
            LocalLinkResolver.resolve(href: "/abs/path.md", documentURL: doc),
            "absolute paths have no defined base for a viewer")
        XCTAssertNil(LocalLinkResolver.resolve(href: "other.txt", documentURL: doc))
        XCTAssertNil(LocalLinkResolver.resolve(href: "archive.md.zip", documentURL: doc))
        XCTAssertNil(
            LocalLinkResolver.resolve(href: "%zz.md", documentURL: doc),
            "malformed percent-encoding is rejected")
    }

    // MARK: - Page-side click interception

    func testAnchorLinkClickScrollsToHeading() async throws {
        let preview = try await makeLoadedPreview()
        preview.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let filler = String(repeating: "filler paragraph\n\n", count: 200)
        await preview.render("[jump](#target)\n\n" + filler + "\n# Target\n")

        let before = try await count(preview, "Math.round(window.scrollY)")
        XCTAssertEqual(before, 0, "page starts at the top")

        _ = try await preview.evaluate(
            "document.querySelector('#content a[href=\"#target\"]').click(); true")
        // scrollToHeading is synchronous scrollIntoView; read back the offset.
        let after = try await count(preview, "Math.round(window.scrollY)")
        XCTAssertGreaterThan(after, 0, "anchor click must scroll to the heading")

        let current = await preview.currentSection()
        XCTAssertEqual(current, "target", "the heading is the current section after the jump")
    }

    func testRelativeMarkdownLinkPostsLinkMessage() async throws {
        let preview = try await makeLoadedPreview()
        var activated: String?
        let delivered = expectation(description: "markioLink delivered")
        preview.onLinkActivated = { href in
            activated = href
            delivered.fulfill()
        }
        await preview.render("[open](docs/other.md#setup)")

        _ = try await preview.evaluate("document.querySelector('#content a').click(); true")
        await fulfillment(of: [delivered], timeout: 5)

        XCTAssertEqual(
            activated, "docs/other.md#setup",
            "the page posts the raw href; resolution is native")
    }

    func testNonMarkdownAndExternalLinksNotHijacked() async throws {
        let preview = try await makeLoadedPreview()
        preview.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        var activations = 0
        preview.onLinkActivated = { _ in activations += 1 }
        // ftp: exercises the scheme'd branch without opening a real browser
        // (LinkPolicy blocks it at the navigation delegate).
        await preview.render("[text file](notes.txt)\n\n[remote](ftp://example.com/x.md)")

        _ = try await preview.evaluate(
            "document.querySelectorAll('#content a').forEach(function(a){a.click();}); true")
        // Give any stray message a beat to arrive before asserting silence.
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(activations, 0, "non-Markdown and scheme'd links never post markioLink")
        let stillThere = try await count(preview, "document.querySelectorAll('#content a').length")
        XCTAssertEqual(stillThere, 2, "the preview never navigated away from the document")
    }

    // MARK: - Cross-window anchor hand-off

    /// A fake window: records anchors it was asked to navigate to.
    @MainActor
    private final class TargetSpy: LocalLinkTarget {
        let documentURL: URL?
        var anchors: [String] = []
        init(url: URL?) { documentURL = url }
        func navigate(toAnchor anchor: String) { anchors.append(anchor) }
    }

    func testPendingAnchorStoreRoundTripAndConsumeOnce() {
        let navigator = LocalLinkNavigator(open: { url, completion in
            completion(url, false)  // fresh window: no live target yet
        })
        navigator.follow(href: "other.md#setup", from: doc)

        let target = URL(fileURLWithPath: "/repo/docs/other.md")
        XCTAssertEqual(
            navigator.consumePendingAnchor(for: target), "setup",
            "the anchor waits for the opened window")
        XCTAssertNil(
            navigator.consumePendingAnchor(for: target),
            "an anchor is consumed exactly once")
        XCTAssertNil(
            navigator.consumePendingAnchor(for: doc),
            "other documents have nothing pending")
    }

    func testFollowDeliversAnchorToAlreadyOpenTarget() {
        let target = TargetSpy(url: URL(fileURLWithPath: "/repo/docs/other.md"))
        let other = TargetSpy(url: URL(fileURLWithPath: "/repo/docs/unrelated.md"))
        let navigator = LocalLinkNavigator(open: { url, completion in
            completion(url, true)  // document already open: window never re-renders
        })
        navigator.attach(target)
        navigator.attach(other)

        navigator.follow(href: "other.md#setup", from: doc)

        XCTAssertEqual(target.anchors, ["setup"], "the open window scrolls immediately")
        XCTAssertEqual(other.anchors, [], "unrelated windows are untouched")
        XCTAssertNil(
            navigator.consumePendingAnchor(for: target.documentURL!),
            "a delivered anchor does not linger")
    }

    func testFollowIgnoresUnresolvableHrefs() {
        var opened: [URL] = []
        let navigator = LocalLinkNavigator(open: { url, completion in
            opened.append(url)
            completion(url, false)
        })
        navigator.follow(href: "https://example.com/x.md", from: doc)
        navigator.follow(href: "notes.txt", from: doc)
        XCTAssertTrue(opened.isEmpty, "unresolvable hrefs never reach the opener")
    }
}
