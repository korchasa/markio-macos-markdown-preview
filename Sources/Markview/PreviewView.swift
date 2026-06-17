import SwiftUI
import WebKit

/// Hosts the model's `WKWebView` inside SwiftUI. The web view is owned by the
/// `PreviewController`; content updates flow through the model, not through
/// `updateNSView`. [REF:sds:webview-host]
struct PreviewView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
