import Foundation

/// What the web view should do with a navigation request.
enum NavigationDecision: Equatable {
    /// Local bundle navigation (initial template load, in-document anchors).
    case allowInPage
    /// Web/mail/tel link → hand to the OS, never navigate the preview.
    case openExternally
    /// Anything else is refused (read-only viewer stays on its own document).
    case block
}

/// Pure decision used by the web view's navigation delegate, so the link rules
/// are unit-testable without constructing a real `WKNavigationAction`.
/// Keeps the `WKWebView` confined to bundled content. [REF:fr:offline]
enum LinkPolicy {
    static func decide(for url: URL) -> NavigationDecision {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto", "tel":
            return .openExternally
        case "file":
            return .allowInPage
        default:
            return .block
        }
    }
}
