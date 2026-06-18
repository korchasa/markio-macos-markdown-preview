import XCTest

@testable import Markview

/// Offline contract: the shell references no external URLs and the navigation
/// guard keeps the web view confined to bundled content. [REF:fr:offline]
final class OfflineTests: XCTestCase {
    func testNoNetworkRequests() throws {
        // (1) The HTML shell loads only relative (vendored) assets — no http(s).
        let html = try String(contentsOf: ResourceLocator.templateURL, encoding: .utf8)
        XCTAssertFalse(
            html.contains("http://") || html.contains("https://"),
            "template.html must not reference any network URL")

        // (2) The navigation guard externalizes web links and refuses unknown
        //     schemes, so the preview never fetches over the network itself.
        XCTAssertEqual(LinkPolicy.decide(for: URL(string: "https://example.com")!), .openExternally)
        XCTAssertEqual(LinkPolicy.decide(for: URL(string: "http://example.com")!), .openExternally)
        XCTAssertEqual(LinkPolicy.decide(for: URL(string: "mailto:a@b.com")!), .openExternally)
        XCTAssertEqual(LinkPolicy.decide(for: URL(fileURLWithPath: "/tmp/x.html")), .allowInPage)
        XCTAssertEqual(LinkPolicy.decide(for: URL(string: "ftp://example.com")!), .block)
    }

    /// End-to-end: the shell + vendored JS/CSS load and render purely from disk.
    /// WKWebView's network stack can't be intercepted by `URLProtocol`, so rather
    /// than spy on a guaranteed-absent request, this proves the offline pipeline
    /// works — markdown-it and mermaid resolve from the bundle and produce DOM.
    @MainActor
    func testVendoredAssetsRenderFromDisk() async throws {
        let preview = try await makeLoadedPreview()
        await preview.render("# Title\n\n```mermaid\nflowchart LR\n  A-->B\n```")

        let mdLoaded = try await count(preview, "window.markdownit ? 1 : 0")
        XCTAssertEqual(mdLoaded, 1, "Vendored markdown-it must load from disk")

        let svgs = try await count(
            preview, "document.querySelectorAll('#content pre.mermaid svg').length")
        XCTAssertGreaterThanOrEqual(svgs, 1, "Vendored mermaid must render offline from disk")
    }
}
