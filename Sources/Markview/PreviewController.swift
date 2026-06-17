import WebKit

/// Owns the confined `WKWebView` and exposes the native↔web bridge: load the
/// shell, push Markdown source and reading width, follow appearance. Network is
/// blocked by the navigation delegate (only `file:` is allowed in-page; web
/// links open in the default browser). [REF:sds:webview-host] [REF:fr:offline]
@MainActor
final class PreviewController: NSObject {
    let webView: WKWebView

    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var didFinishInitialLoad = false

    override init() {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    /// Load `template.html`, scoping read access to the vendored bundle only.
    func loadTemplate() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loadContinuation = continuation
            webView.loadFileURL(
                ResourceLocator.templateURL,
                allowingReadAccessTo: ResourceLocator.resourcesRoot
            )
        }
    }

    /// Render Markdown; awaits the page (including Mermaid) settling.
    /// [REF:fr:gfm] [REF:fr:mermaid] [REF:fr:highlight]
    func render(_ markdown: String) async {
        _ = try? await webView.callAsyncJavaScript(
            "return await render(md);",
            arguments: ["md": markdown],
            contentWorld: .page
        )
    }

    /// Set the reading-column width (CSS px); returns the applied value.
    /// [REF:fr:line-width]
    @discardableResult
    func setContentWidth(_ pixels: Int) async -> String? {
        let result = try? await webView.callAsyncJavaScript(
            "return setContentWidth(px);",
            arguments: ["px": pixels],
            contentWorld: .page
        )
        return result as? String
    }

    /// Inform the page of the current appearance so Mermaid re-themes.
    /// [REF:fr:appearance]
    func setDark(_ dark: Bool) async {
        _ = try? await webView.callAsyncJavaScript(
            "return await setDark(d);",
            arguments: ["d": dark],
            contentWorld: .page
        )
    }

    /// Test/diagnostic hook: evaluate JS in the page world.
    func evaluate(_ javaScript: String) async throws -> Any? {
        try await webView.evaluateJavaScript(javaScript)
    }
}

extension PreviewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishInitialLoad = true
        resumeLoad()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resumeLoad()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        resumeLoad()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // The first navigation is our own template load.
        guard didFinishInitialLoad else {
            decisionHandler(.allow)
            return
        }
        switch LinkPolicy.decide(for: url) {
        case .allowInPage:
            decisionHandler(.allow)
        case .openExternally:
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
        case .block:
            decisionHandler(.cancel)
        }
    }

    private func resumeLoad() {
        loadContinuation?.resume()
        loadContinuation = nil
    }
}
