import MarkdownKit
import MarkioRender
import Quartz
import os

/// Principal class of the Quick Look preview extension: draws a Markdown file
/// with the same renderer the app uses when the reader presses Space in Finder.
///
/// The whole preview is synchronous. There is no web view to boot, no template
/// to load and nothing to wait for — parsing is a few milliseconds even for a
/// large file, and only the blocks that fit in the panel are ever laid out. The
/// completion handler therefore reports success or failure immediately, which
/// is the difference between this and a preview that can hang on a spinner.
///
/// The `@objc` name is pinned: `NSExtensionPrincipalClass` in
/// `packaging/MarkioQuickLook-Info.plist` names it verbatim.
@objc(PreviewViewController)
// `@preconcurrency`: the SDK protocol carries no actor annotation, but Quick
// Look calls it on the main thread and `NSViewController` is main-actor bound.
final class PreviewViewController: NSViewController, @preconcurrency QLPreviewingController {
    /// A preview that fails silently is indistinguishable from an empty file,
    /// so every refusal says why in the log.
    private static let log = Logger(subsystem: "dev.markio.two", category: "quicklook")

    /// Files above this are previewed by their first megabyte.
    ///
    /// Not a performance limit — the renderer handles far more — but a courtesy
    /// one: Quick Look runs on a keypress, and reading 200 MB off a slow disk
    /// to show one panel of text is work nobody asked for.
    private static let previewByteLimit = 1 * 1_024 * 1_024

    private let scrollView = NSScrollView()

    override func loadView() {
        // Quick Look sizes this; the scroll view fills whatever it gets.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
    }

    func preparePreviewOfFile(
        at url: URL,
        completionHandler handler: @escaping (Error?) -> Void
    ) {
        do {
            let bytes = try MarkdownFileReader.read(url, limit: Self.previewByteLimit)
            let theme = Theme(isDark: view.effectiveAppearance.isDark)
            let layout = DocumentLayout(
                document: Document(bytes: bytes),
                theme: theme,
                // A fixed width, not the app's: the extension is sandboxed apart
                // from the app and has no business reading its preferences.
                columnWidth: theme.columnWidth(characters: 80),
                baseURL: url
            )
            install(DocumentView(layout: layout), background: theme.palette.background)
            Self.log.info("preview: \(bytes.count) bytes, \(layout.blockCount) blocks")
            handler(nil)
        } catch {
            Self.log.error("preview failed: \(error.localizedDescription)")
            // Handing the error back lets macOS fall back to its own plain-text
            // preview instead of leaving an empty panel on screen.
            handler(error)
        }
    }

    private func install(_ documentView: DocumentView, background: CGColor) {
        documentView.autoresizingMask = [.width]
        // A preview panel is for reading, not for editing or following links,
        // so the view gets no callbacks at all.
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(cgColor: background) ?? .textBackgroundColor
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.width, .height]
        if scrollView.superview == nil { view.addSubview(scrollView) }
    }

}

extension NSAppearance {
    fileprivate var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
