import MarkioEngine
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

    /// Fired on the main actor with the current heading id whenever the page's
    /// scroll-spy reports a section change. [REF:fr:toc]
    var onCurrentSectionChange: ((String) -> Void)?

    /// Fired on the main actor with the raw code text after a copy-button click
    /// landed on the pasteboard (test/UI hook). [REF:fr:code-copy]
    var onCodeCopied: ((String) -> Void)?

    /// Fired on the main actor with the page's debounced scroll position so
    /// the owner can persist the reading place. [REF:fr:session-restore]
    var onScrollPositionChange: ((Double) -> Void)?

    /// Fired on the main actor with the raw href of a clicked relative
    /// Markdown link; resolution and opening are the owner's (native) job.
    /// [REF:fr:local-links]
    var onLinkActivated: ((String) -> Void)?

    /// Fired on the main actor with the page's live scroll FRACTION (0…1 of
    /// its scrollable height) while compare sync is enabled — the mirroring
    /// channel for side-by-side reading. [REF:fr:compare]
    var onSyncScroll: ((Double) -> Void)?

    /// Retained separately because the user-content controller holds its
    /// handlers strongly — registering `self` directly would cycle
    /// webView → configuration → handler → controller. [REF:fr:toc]
    private let tocMessageProxy = ScriptMessageProxy()
    private let copyMessageProxy = ScriptMessageProxy()
    private let scrollMessageProxy = ScriptMessageProxy()
    private let linkMessageProxy = ScriptMessageProxy()
    private let syncScrollMessageProxy = ScriptMessageProxy()

    /// Destination for copy-button writes. Injected so tests use a private,
    /// uniquely named pasteboard instead of the user's clipboard. [REF:fr:code-copy]
    private let pasteboard: NSPasteboard

    /// Builds the confined `WKWebView`: two one-way page→native message
    /// handlers — the read-only `markioTOC` scroll-spy channel (current heading
    /// id) and the `markioCopy` copy channel (raw code text → pasteboard) —
    /// wired to `self` as navigation delegate so every navigation is gated by
    /// `decidePolicyFor` (only the initial `file:` load and in-page file links
    /// are allowed; web links open externally).
    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        config.userContentController.add(tocMessageProxy, name: "markioTOC")
        config.userContentController.add(copyMessageProxy, name: "markioCopy")
        config.userContentController.add(scrollMessageProxy, name: "markioScroll")
        config.userContentController.add(linkMessageProxy, name: "markioLink")
        config.userContentController.add(syncScrollMessageProxy, name: "markioSyncScroll")
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        tocMessageProxy.onMessage = { [weak self] message in
            self?.handleTOCMessage(message)
        }
        copyMessageProxy.onMessage = { [weak self] message in
            self?.handleCopyMessage(message)
        }
        scrollMessageProxy.onMessage = { [weak self] message in
            self?.handleScrollMessage(message)
        }
        linkMessageProxy.onMessage = { [weak self] message in
            self?.handleLinkMessage(message)
        }
        syncScrollMessageProxy.onMessage = { [weak self] message in
            self?.handleSyncScrollMessage(message)
        }
    }

    /// Load `template.html`, scoping read access to the vendored bundle only.
    /// Throws if the navigation fails (`didFail`/`didFailProvisionalNavigation`)
    /// so a failed shell load is distinguishable from success — the caller must
    /// not proceed to `render` on a page that never loaded.
    func loadTemplate() async throws {
        let html = try ResourceLocator.selfContainedHTML()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            // Self-contained document, no `file:` base: the shell carries its own
            // inlined CSS/JS, so WebKit needs no subresource reads. (The MAS blank
            // preview was ultimately the missing `network.client` entitlement that
            // blocked WKWebView's WebContent process from launching at all — see
            // packaging/Markio.entitlements; this validated load path stays.)
            // [REF:sds:webview-host] [REF:fr:offline]
            webView.loadHTMLString(html, baseURL: nil)
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

    /// Scroll the page to a saved reading position; returns the applied
    /// (browser-clamped) value, or `nil` if the bridge call failed (logged) —
    /// the same best-effort contract as `setContentWidth`. [REF:fr:session-restore]
    @discardableResult
    func setScrollY(_ y: Double) async -> Double? {
        do {
            let raw = try await webView.callAsyncJavaScript(
                "return setScrollY(y);",
                arguments: ["y": y],
                contentWorld: .page
            )
            return (raw as? NSNumber)?.doubleValue
        } catch {
            Log.preview.error("setScrollY(\(y)) failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Compare sync [REF:fr:compare]

    /// Toggle the page's live scroll-fraction reporting (the compare
    /// mirroring channel). Best-effort; failure is logged, not swallowed.
    func setCompareSync(_ enabled: Bool) async {
        do {
            _ = try await webView.callAsyncJavaScript(
                "return setCompareSync(e);",
                arguments: ["e": enabled],
                contentWorld: .page
            )
        } catch {
            Log.preview.error("setCompareSync(\(enabled)) failed: \(error.localizedDescription)")
        }
    }

    /// Scroll the page to a fraction (0…1) of its own scrollable height;
    /// returns the applied fraction, or `nil` if the bridge call failed
    /// (logged) — the same best-effort contract as `setScrollY`.
    @discardableResult
    func setScrollFraction(_ fraction: Double) async -> Double? {
        do {
            let raw = try await webView.callAsyncJavaScript(
                "return setScrollFraction(f);",
                arguments: ["f": fraction],
                contentWorld: .page
            )
            return (raw as? NSNumber)?.doubleValue
        } catch {
            Log.preview.error(
                "setScrollFraction(\(fraction)) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The page's current scroll fraction (0…1), or `nil` on bridge failure
    /// (logged) — used to seed a freshly linked compare peer.
    func scrollFraction() async -> Double? {
        do {
            let raw = try await webView.callAsyncJavaScript(
                "return getScrollFraction();", arguments: [:], contentWorld: .page)
            return (raw as? NSNumber)?.doubleValue
        } catch {
            Log.preview.error("scrollFraction failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Find [REF:fr:find]

    /// Case-insensitive search over the rendered content; highlights every
    /// match, makes the first current, and returns the totals. [REF:fr:find]
    @discardableResult
    func search(_ query: String) async -> FindResult {
        await callFind("return search(q);", ["q": query])
    }

    /// Move to the next match (wraps around). [REF:fr:find]
    @discardableResult
    func findNext() async -> FindResult {
        await callFind("return findNext();", [:])
    }

    /// Move to the previous match (wraps around). [REF:fr:find]
    @discardableResult
    func findPrev() async -> FindResult {
        await callFind("return findPrev();", [:])
    }

    /// Remove all find highlights, restoring the original DOM text. [REF:fr:find]
    func clearSearch() async {
        _ = await callFind("return clearSearch();", [:])
    }

    /// Invoke a find entrypoint and decode its `{count, current}` payload.
    /// Best-effort: a bridge failure logs and yields an empty result.
    private func callFind(_ javaScript: String, _ arguments: [String: Any]) async -> FindResult {
        do {
            let raw = try await webView.callAsyncJavaScript(
                javaScript, arguments: arguments, contentWorld: .page)
            guard let dict = raw as? [String: Any] else { return .empty }
            return FindResult(
                count: (dict["count"] as? NSNumber)?.intValue ?? 0,
                current: (dict["current"] as? NSNumber)?.intValue ?? 0)
        } catch {
            Log.preview.error("find failed: \(error.localizedDescription)")
            return .empty
        }
    }

    // MARK: - Table of contents [REF:fr:toc]

    /// The document's heading tree in document order. Best-effort: a bridge
    /// failure logs and yields an empty outline.
    func outline() async -> [TOCItem] {
        do {
            let raw = try await webView.callAsyncJavaScript(
                "return getOutline();", arguments: [:], contentWorld: .page)
            guard let items = raw as? [[String: Any]] else { return [] }
            return items.compactMap { dict in
                guard
                    let level = (dict["level"] as? NSNumber)?.intValue,
                    let text = dict["text"] as? String,
                    let id = dict["id"] as? String
                else { return nil }
                return TOCItem(level: level, text: text, id: id)
            }
        } catch {
            Log.preview.error("outline failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Scroll the heading with `id` to the top of the viewport. Returns whether
    /// the heading existed; a bridge failure logs and reports `false`.
    @discardableResult
    func scrollToHeading(_ id: String) async -> Bool {
        do {
            let raw = try await webView.callAsyncJavaScript(
                "return scrollToHeading(id);", arguments: ["id": id], contentWorld: .page)
            return (raw as? Bool) ?? (raw as? NSNumber)?.boolValue ?? false
        } catch {
            Log.preview.error("scrollToHeading(\(id)) failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Id of the section currently at the viewport top, or `nil` when the
    /// document has no headings (or the bridge call failed — logged).
    func currentSection() async -> String? {
        do {
            let raw = try await webView.callAsyncJavaScript(
                "return getCurrentSection();", arguments: [:], contentWorld: .page)
            guard let id = raw as? String, !id.isEmpty else { return nil }
            return id
        } catch {
            Log.preview.error("currentSection failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Validate and forward a scroll-spy push. Anything but a non-empty string
    /// payload is dropped.
    private func handleTOCMessage(_ message: WKScriptMessage) {
        guard message.name == "markioTOC", let id = message.body as? String, !id.isEmpty
        else { return }
        onCurrentSectionChange?(id)
    }

    /// Validate a copy-button push and write the raw code text to the
    /// pasteboard. Anything but a non-empty string payload is dropped;
    /// a failed write is logged, never thrown (best-effort per NFR
    /// Reliability). [REF:fr:code-copy]
    private func handleCopyMessage(_ message: WKScriptMessage) {
        guard message.name == "markioCopy", let code = message.body as? String, !code.isEmpty
        else { return }
        pasteboard.clearContents()
        if !pasteboard.setString(code, forType: .string) {
            Log.preview.error("pasteboard write failed for copied code block")
            return
        }
        onCodeCopied?(code)
    }

    /// Validate a scroll-position push: a non-empty string parseable as a
    /// non-negative finite number; anything else is dropped. [REF:fr:session-restore]
    private func handleScrollMessage(_ message: WKScriptMessage) {
        guard
            message.name == "markioScroll",
            let text = message.body as? String,
            let y = Double(text),
            y.isFinite, y >= 0
        else { return }
        onScrollPositionChange?(y)
    }

    /// Validate a link-click push: the raw href as a non-empty string;
    /// anything else is dropped. The href is untrusted page data — the owner
    /// runs it through `LocalLinkResolver` (default-deny) before acting.
    /// [REF:fr:local-links]
    private func handleLinkMessage(_ message: WKScriptMessage) {
        guard message.name == "markioLink", let href = message.body as? String, !href.isEmpty
        else { return }
        onLinkActivated?(href)
    }

    /// Validate a live sync-scroll push: a non-empty string parseable as a
    /// finite fraction in 0…1; anything else is dropped. [REF:fr:compare]
    private func handleSyncScrollMessage(_ message: WKScriptMessage) {
        guard
            message.name == "markioSyncScroll",
            let text = message.body as? String,
            let fraction = Double(text),
            fraction.isFinite, fraction >= 0, fraction <= 1
        else { return }
        onSyncScroll?(fraction)
    }

    /// Test/diagnostic hook: evaluate JS in the page world.
    func evaluate(_ javaScript: String) async throws -> Any? {
        try await webView.evaluateJavaScript(javaScript)
    }
}

/// One entry of the document's heading tree: `level` 1–6, the heading's text,
/// and its GitHub-style slug id (deduplicated, so usable as `Identifiable`).
/// [REF:fr:toc]
struct TOCItem: Equatable, Identifiable {
    let level: Int
    let text: String
    let id: String
}

/// Weak-forwarding `WKScriptMessageHandler`: the user-content controller
/// retains its handlers strongly, so the web-view owner must not register
/// itself. [REF:fr:toc]
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    var onMessage: ((WKScriptMessage) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        onMessage?(message)
    }
}

/// Totals from a find operation: how many matches exist and the 1-based index
/// of the current one (`0` when there are none). [REF:fr:find]
struct FindResult: Equatable {
    let count: Int
    let current: Int
    static let empty = FindResult(count: 0, current: 0)

    /// "N of M" reading for the find bar counter (e.g. "3 of 17"). [REF:fr:find]
    var counterText: String { "\(current) of \(count)" }
}

extension PreviewController: WKNavigationDelegate {
    /// Template finished loading → mark the shell ready and resume `loadTemplate`.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishInitialLoad = true
        resumeLoad(.success(()))
    }

    /// Committed navigation failed → resume `loadTemplate` with the error.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Log.preview.error("navigation: didFail: \(error.localizedDescription)")
        resumeLoad(.failure(error))
    }

    /// Provisional navigation (before commit) failed → resume with the error.
    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Log.preview.error("navigation: didFailProvisional: \(error.localizedDescription)")
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
