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
}
