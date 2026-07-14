import MarkioEngine
import Quartz
import WebKit
import os

/// Principal class of the Quick Look preview extension: renders a Markdown
/// file with Markio's engine when the user presses Space in Finder. Any
/// failure resolves the completion handler with the error, so macOS falls
/// back to its own plain-text preview instead of showing an empty panel.
/// The `@objc` name is pinned because `NSExtensionPrincipalClass` in
/// packaging/MarkioQuickLook-Info.plist references it verbatim.
/// [REF:fr:quicklook]
@objc(PreviewViewController)
// `@preconcurrency`: the SDK protocol is not actor-annotated, but Quick Look
// invokes it on the main thread; the class is main-actor-isolated via
// NSViewController.
final class PreviewViewController: NSViewController, @preconcurrency QLPreviewingController {
    private var host: QuickLookRenderHost?
    // Step breadcrumbs: a hung preview shows as an infinite spinner with no
    // error anywhere — the last logged step is the only way to locate the hang.
    private static let log = Logger(subsystem: "dev.markio", category: "quicklook")

    override func loadView() {
        // Plain container sized by Quick Look; the web view fills it once the
        // preview is prepared.
        view = NSView()
    }

    func preparePreviewOfFile(
        at url: URL,
        completionHandler handler: @escaping (Error?) -> Void
    ) {
        Task { @MainActor in
            do {
                let markdown = try MarkdownFileReader.read(url)
                Self.log.info("preview: read \(markdown.count) chars")
                let host = QuickLookRenderHost()
                self.host = host
                host.webView.frame = view.bounds
                host.webView.autoresizingMask = [.width, .height]
                view.addSubview(host.webView)
                try await host.loadTemplate()
                Self.log.info("preview: template loaded")
                let dark =
                    view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                await host.setDark(dark)
                Self.log.info("preview: appearance set (dark=\(dark))")
                try await host.render(markdown)
                Self.log.info("preview: rendered, completing")
                handler(nil)
            } catch {
                Self.log.error("preview: failed: \(error.localizedDescription)")
                handler(error)
            }
        }
    }
}
