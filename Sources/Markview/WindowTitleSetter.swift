import AppKit
import SwiftUI

/// Forces the host window's title text to the document's full path, overriding
/// the file name that `DocumentGroup` keeps re-applying.
///
/// `DocumentGroup` syncs the window title from the document's display name
/// asynchronously after window setup, so a one-shot assignment loses. We KVO the
/// window's `title` and re-assert the path on every change (guarded against
/// re-entrancy). The represented URL is cleared because, while set, AppKit shows
/// the file name regardless of `title` (this drops the proxy icon). [REF:fr:multidoc]
struct WindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> TitlePinningView {
        let view = TitlePinningView()
        view.desiredTitle = title
        return view
    }

    func updateNSView(_ nsView: TitlePinningView, context: Context) {
        nsView.desiredTitle = title
    }
}

/// Zero-size helper view that pins its window's title to `desiredTitle`.
final class TitlePinningView: NSView {
    var desiredTitle = "" {
        didSet { pin() }
    }

    private var observation: NSKeyValueObservation?
    private var isPinning = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            observation = nil
            return
        }
        if observation == nil {
            observation = window.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isPinning else { return }
                    self.pin()
                }
            }
        }
        pin()
    }

    private func pin() {
        guard !desiredTitle.isEmpty, let window else { return }
        guard window.title != desiredTitle || window.representedURL != nil else { return }
        isPinning = true
        window.representedURL = nil
        window.title = desiredTitle
        isPinning = false
    }
}
