import MarkioEngine
import WebKit
import os

/// Minimal `WKWebView` owner for the Quick Look preview: load the
/// self-contained shell, push Markdown, follow appearance. Unlike the app's
/// `PreviewController` it registers no message handlers and opens nothing —
/// after the initial `loadHTMLString` navigation every navigation is
/// cancelled, because a Quick Look preview must never navigate (external
/// links would otherwise open inside the preview panel). [REF:fr:quicklook]
@MainActor
final class QuickLookRenderHost: NSObject {
    let webView: WKWebView

    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var didFinishInitialLoad = false
    private static let log = Logger(subsystem: "dev.markio", category: "quicklook")

    override init() {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        webView.navigationDelegate = self
    }

    /// Load the self-contained shell (vendored assets inlined app-side; no
    /// `file:` subresource reads — the same sandbox-proof path the app uses).
    /// Throws if the navigation fails, so the caller can hand the error to
    /// Quick Look and let the system preview take over.
    func loadTemplate() async throws {
        let html = try ResourceLocator.selfContainedHTML()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    /// Render Markdown; awaits the page (including Mermaid) settling. Throws
    /// on bridge failure — in Quick Look a failed render should surface to the
    /// completion handler (system fallback), not show an empty panel.
    func render(_ markdown: String) async throws {
        _ = try await webView.callAsyncJavaScript(
            "return await render(md);",
            arguments: ["md": markdown],
            contentWorld: .page
        )
    }

    /// Inform the page of the current appearance so Mermaid and the theme CSS
    /// match the system. Best-effort; failure is logged, not thrown — a
    /// wrongly-themed preview beats no preview.
    func setDark(_ dark: Bool) async {
        do {
            _ = try await webView.callAsyncJavaScript(
                "return await setDark(d);",
                arguments: ["d": dark],
                contentWorld: .page
            )
        } catch {
            Self.log.error("setDark(\(dark)) failed: \(error.localizedDescription)")
        }
    }
}

extension QuickLookRenderHost: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishInitialLoad = true
        resumeLoad(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.log.error("navigation: didFail: \(error.localizedDescription)")
        resumeLoad(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Self.log.error("navigation: didFailProvisional: \(error.localizedDescription)")
        resumeLoad(.failure(error))
    }

    /// Allow only the initial shell load; cancel everything after it.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(didFinishInitialLoad ? .cancel : .allow)
    }

    /// Resume the pending `loadTemplate` continuation exactly once.
    private func resumeLoad(_ result: Result<Void, Error>) {
        loadContinuation?.resume(with: result)
        loadContinuation = nil
    }
}
