import WebKit

/// Owns the confined `WKWebView` and exposes the native↔web bridge: load the
/// shell, push Markdown source and reading width, follow appearance. Network is
/// blocked by the navigation delegate (only `file:` is allowed in-page; web
/// links open in the default browser). [REF:sds:webview-host] [REF:fr:offline]
@MainActor
final class PreviewController: NSObject {
    let webView: WKWebView

    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var didFinishInitialLoad = false

    /// Builds the confined `WKWebView`: a default configuration with no message
    /// handlers, wired to `self` as navigation delegate so every navigation is
    /// gated by `decidePolicyFor` (only the initial `file:` load and in-page
    /// file links are allowed; web links open externally).
    override init() {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    /// Load `template.html`, scoping read access to the vendored bundle only.
    /// Throws if the navigation fails (`didFail`/`didFailProvisionalNavigation`)
    /// so a failed shell load is distinguishable from success — the caller must
    /// not proceed to `render` on a page that never loaded.
    func loadTemplate() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.loadFileURL(
                ResourceLocator.templateURL,
                allowingReadAccessTo: ResourceLocator.resourcesRoot
            )
        }
    }

    /// Render Markdown; awaits the page (including Mermaid) settling. Best-effort
    /// by contract (a render failure must not crash the viewer), but the error is
    /// logged rather than swallowed silently. [REF:fr:gfm] [REF:fr:mermaid] [REF:fr:highlight]
    func render(_ markdown: String) async {
        do {
            _ = try await webView.callAsyncJavaScript(
                "return await render(md);",
                arguments: ["md": markdown],
                contentWorld: .page
            )
        } catch {
            Log.preview.error("render failed: \(error.localizedDescription)")
        }
    }

    /// Set the reading-column width in characters (CSS `ch`); returns the applied
    /// value (e.g. `"80ch"`), or `nil` if the JS call failed (logged). [REF:fr:line-width]
    @discardableResult
    func setContentWidth(_ chars: Int) async -> String? {
        do {
            let result = try await webView.callAsyncJavaScript(
                "return setContentWidth(chars);",
                arguments: ["chars": chars],
                contentWorld: .page
            )
            return result as? String
        } catch {
            Log.preview.error("setContentWidth(\(chars)) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Inform the page of the current appearance so Mermaid re-themes.
    /// Best-effort; failure is logged, not swallowed. [REF:fr:appearance]
    func setDark(_ dark: Bool) async {
        do {
            _ = try await webView.callAsyncJavaScript(
                "return await setDark(d);",
                arguments: ["d": dark],
                contentWorld: .page
            )
        } catch {
            Log.preview.error("setDark(\(dark)) failed: \(error.localizedDescription)")
        }
    }

    /// Test/diagnostic hook: evaluate JS in the page world.
    func evaluate(_ javaScript: String) async throws -> Any? {
        try await webView.evaluateJavaScript(javaScript)
    }
}

extension PreviewController: WKNavigationDelegate {
    /// Template finished loading → mark the shell ready and resume `loadTemplate`.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishInitialLoad = true
        resumeLoad(.success(()))
    }

    /// Committed navigation failed → resume `loadTemplate` with the error.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resumeLoad(.failure(error))
    }

    /// Provisional navigation (before commit) failed → resume with the error.
    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        resumeLoad(.failure(error))
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

    /// Resume the pending `loadTemplate` continuation exactly once, then clear it
    /// so a late callback cannot double-resume.
    private func resumeLoad(_ result: Result<Void, Error>) {
        loadContinuation?.resume(with: result)
        loadContinuation = nil
    }
}
