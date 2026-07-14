import AppKit
import UniformTypeIdentifiers

/// A window that can receive a cross-file anchor jump: the document it shows
/// and the ability to scroll it to a heading. [REF:fr:local-links]
@MainActor
protocol LocalLinkTarget: AnyObject {
    var documentURL: URL? { get }
    func navigate(toAnchor anchor: String)
}

/// App-wide coordinator for local link navigation: resolves clicked hrefs,
/// opens the target document (one window per document), and hands the anchor
/// to whichever window ends up showing the file — a freshly opened window
/// consumes it after its first render, an already-open window is scrolled
/// directly (it never re-renders). Pending anchors are in-memory only,
/// consume-once; nothing is persisted. [REF:fr:local-links]
@MainActor
final class LocalLinkNavigator {
    /// Open primitive: open `URL`, then report `(openedURL, alreadyOpen)`;
    /// `nil` URL means the open did not happen (denied, cancelled, failed).
    /// Injected so unit tests drive the pending/registry logic without AppKit UI.
    typealias Open = @MainActor (URL, @escaping @MainActor (URL?, Bool) -> Void) -> Void

    static let shared = LocalLinkNavigator()

    private let open: Open
    private var pendingAnchors: [String: String] = [:]
    private var targets: [WeakTarget] = []

    init(open: @escaping Open = LocalLinkNavigator.systemOpen) {
        self.open = open
    }

    /// Register a window as an anchor-jump target. Held weakly; dead entries
    /// are pruned on every lookup.
    func attach(_ target: LocalLinkTarget) {
        prune()
        guard !targets.contains(where: { $0.value === target }) else { return }
        targets.append(WeakTarget(target))
    }

    /// Follow a clicked href from the document at `documentURL`. Unresolvable
    /// hrefs are a silent no-op (default-deny — the click stays dead).
    func follow(href: String, from documentURL: URL) {
        guard let link = LocalLinkResolver.resolve(href: href, documentURL: documentURL) else {
            return
        }
        if let anchor = link.anchor {
            pendingAnchors[key(link.fileURL)] = anchor
        }
        open(link.fileURL) { [weak self] openedURL, alreadyOpen in
            guard let self else { return }
            guard let openedURL else {
                // Denied/cancelled/failed: drop the anchor so it cannot fire
                // on an unrelated future open of the same path.
                self.pendingAnchors[self.key(link.fileURL)] = nil
                return
            }
            // The powerbox panel lets the user pick a different file than the
            // link target; the anchor belongs to the link target only.
            if self.key(openedURL) != self.key(link.fileURL) {
                self.pendingAnchors[self.key(link.fileURL)] = nil
            }
            if alreadyOpen {
                self.deliverPendingAnchor(for: openedURL)
            }
            // Fresh window: its DocumentModel consumes the anchor after the
            // first render (DocumentModel.start).
        }
    }

    /// Hand a pending anchor to the caller (the window that now shows `url`).
    /// Consume-once: a second call returns `nil`.
    func consumePendingAnchor(for url: URL) -> String? {
        pendingAnchors.removeValue(forKey: key(url))
    }

    private func deliverPendingAnchor(for url: URL) {
        guard let anchor = consumePendingAnchor(for: url) else { return }
        prune()
        let path = key(url)
        guard
            let target = targets.first(where: { box in
                guard let targetURL = box.value?.documentURL else { return false }
                return key(targetURL) == path
            })?.value
        else { return }
        target.navigate(toAnchor: anchor)
    }

    private func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func prune() {
        targets.removeAll { $0.value == nil }
    }

    private struct WeakTarget {
        weak var value: LocalLinkTarget?
        init(_ value: LocalLinkTarget) { self.value = value }
    }

    // MARK: - Production open flow (sandbox-honest) [REF:fr:local-links]

    /// Open a linked document. Readable targets (previously user-selected,
    /// recents, unsandboxed dev runs) open directly through the shared
    /// `NSDocumentController` — the same path as command-line opens. A target
    /// the sandbox denies (or that does not exist — indistinguishable inside
    /// the sandbox) gets a powerbox `NSOpenPanel` pre-pointed at it: the
    /// user's one "Open" click IS the access grant. Cancel is a no-op. No
    /// entitlement additions, no bookmark persistence.
    private static func systemOpen(
        _ url: URL, completion: @escaping @MainActor (URL?, Bool) -> Void
    ) {
        if FileManager.default.isReadableFile(atPath: url.path) {
            openViaController(url, completion: completion)
            return
        }
        let panel = NSOpenPanel()
        panel.message = "Markio needs your permission to open the linked file."
        panel.prompt = "Open"
        panel.directoryURL = url
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md"), .plainText]
            .compactMap { $0 }
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let picked = panel.url else {
                    completion(nil, false)
                    return
                }
                openViaController(picked, completion: completion)
            }
        }
    }

    private static func openViaController(
        _ url: URL, completion: @escaping @MainActor (URL?, Bool) -> Void
    ) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) {
            _, alreadyOpen, error in
            MainActor.assumeIsolated {
                if let error {
                    Log.app.error(
                        "link open failed for \(url.path): \(error.localizedDescription)")
                    completion(nil, false)
                    return
                }
                completion(url, alreadyOpen)
            }
        }
    }
}
