import AppKit
import UniformTypeIdentifiers

/// A window that can take part in a side-by-side compare pair: the document it
/// shows, its host window (for tiling), and the scroll-mirroring operations.
/// [REF:fr:compare]
@MainActor
protocol CompareTarget: AnyObject {
    var documentURL: URL? { get }
    var hostWindow: NSWindow? { get }
    func setCompareSyncEnabled(_ enabled: Bool)
    func applyScrollFraction(_ fraction: Double)
    func currentScrollFraction() async -> Double?
}

/// App-wide coordinator for side-by-side compare: pairs two document windows,
/// mirrors scrolling between them at the same fraction of each document's own
/// scrollable height, and tiles the pair left/right. Windows stay symmetric,
/// independent peers — pairs are held weakly, so closing (deallocating) either
/// side just drops the pair and never touches the other window. Pairs are
/// session-only; nothing is persisted. [REF:fr:compare]
@MainActor
final class CompareCoordinator {
    /// Open primitive: let the user pick the second document (powerbox panel —
    /// the "Open" click IS the sandbox grant, same as local links), open it via
    /// the shared `NSDocumentController`, then report `(pickedURL, alreadyOpen)`;
    /// `nil` URL means cancelled/failed. Injected so unit tests drive the
    /// pending/registry logic without AppKit UI.
    typealias Open = @MainActor (URL, @escaping @MainActor (URL?, Bool) -> Void) -> Void

    static let shared = CompareCoordinator()

    private let open: Open
    private var targets: [WeakTarget] = []
    private var pairs: [(WeakTarget, WeakTarget)] = []
    /// One pending pair at a time: the document path we are waiting for and the
    /// window that initiated the compare. Completed by `attach`, replaced by
    /// the next `beginCompare`.
    private var pendingPeer: (path: String, source: WeakTarget)?
    /// Re-entrancy guard: a mirrored apply must never synchronously re-drive
    /// the source (the page's one-shot suppression handles the async echo).
    private var applying = false

    init(open: @escaping Open = CompareCoordinator.systemOpen) {
        self.open = open
    }

    /// Register a window as a potential compare peer (weak; dead entries are
    /// pruned on every lookup). Called after the window's first render, so a
    /// pending pair completes only once the new page is scrollable.
    func attach(_ target: CompareTarget) {
        prune()
        if !targets.contains(where: { $0.value === target }) {
            targets.append(WeakTarget(target))
        }
        guard
            let pending = pendingPeer,
            let url = target.documentURL, key(url) == pending.path,
            let source = pending.source.value, source !== target
        else { return }
        pendingPeer = nil
        link(source, target)
    }

    /// Whether the window is currently half of a live pair.
    func isCompared(_ target: CompareTarget) -> Bool {
        peer(of: target) != nil
    }

    /// Start a compare from the focused window: pick the second file, then
    /// link directly (already open) or park a pending pair until the fresh
    /// window attaches. Picking the initiator's own document is a no-op —
    /// FR-MULTIDOC means one file never occupies two windows, so self-pairing
    /// is impossible by construction.
    func beginCompare(from source: CompareTarget) {
        guard let sourceURL = source.documentURL else { return }
        open(sourceURL) { [weak self, weak source] picked, _ in
            guard let self, let source, let picked else { return }
            guard self.key(picked) != self.key(sourceURL) else { return }
            self.prune()
            if let existing = self.target(for: picked) {
                self.link(source, existing)
            } else {
                // The fresh window's `attach` (after its first render)
                // completes the pair — see `attach`.
                self.pendingPeer = (self.key(picked), WeakTarget(source))
            }
        }
    }

    /// Pair two windows: enable live mirroring on both, seed the peer from the
    /// initiator's current position, and tile the pair left/right. A window is
    /// in at most one pair — linking replaces any pair either side was in.
    func link(_ a: CompareTarget, _ b: CompareTarget) {
        guard a !== b else { return }
        unlink(for: a)
        unlink(for: b)
        pairs.append((WeakTarget(a), WeakTarget(b)))
        a.setCompareSyncEnabled(true)
        b.setCompareSyncEnabled(true)
        Task { [weak a, weak b] in
            guard let a, let b, let fraction = await a.currentScrollFraction() else { return }
            b.applyScrollFraction(fraction)
        }
        tile(a, b)
    }

    /// Break the pair the window is in (if any); both sides stop mirroring.
    func unlink(for target: CompareTarget) {
        prune()
        guard
            let index = pairs.firstIndex(where: {
                $0.0.value === target || $0.1.value === target
            })
        else { return }
        let (x, y) = pairs.remove(at: index)
        x.value?.setCompareSyncEnabled(false)
        y.value?.setCompareSyncEnabled(false)
    }

    /// Live scroll fraction from one side of a pair → apply to the other.
    func scrollChanged(from source: CompareTarget, fraction: Double) {
        guard !applying, let peer = peer(of: source) else { return }
        applying = true
        peer.applyScrollFraction(fraction)
        applying = false
    }

    /// Split a screen's visible frame into two side-by-side halves; an odd
    /// point goes to the right half. Pure — unit-testable without windows.
    nonisolated static func tileFrames(in screen: NSRect) -> (left: NSRect, right: NSRect) {
        let half = (screen.width / 2).rounded(.down)
        let left = NSRect(x: screen.minX, y: screen.minY, width: half, height: screen.height)
        let right = NSRect(
            x: screen.minX + half, y: screen.minY,
            width: screen.width - half, height: screen.height)
        return (left, right)
    }

    // MARK: - Internals

    private func tile(_ a: CompareTarget, _ b: CompareTarget) {
        guard
            let windowA = a.hostWindow, let windowB = b.hostWindow,
            let screen = windowA.screen ?? NSScreen.main
        else { return }
        let frames = Self.tileFrames(in: screen.visibleFrame)
        windowA.setFrame(frames.left, display: true)
        windowB.setFrame(frames.right, display: true)
        windowB.makeKeyAndOrderFront(nil)
    }

    private func peer(of target: CompareTarget) -> CompareTarget? {
        prunePairs()
        for (x, y) in pairs {
            if x.value === target { return y.value }
            if y.value === target { return x.value }
        }
        return nil
    }

    private func target(for url: URL) -> CompareTarget? {
        let path = key(url)
        return targets.first { box in
            guard let targetURL = box.value?.documentURL else { return false }
            return key(targetURL) == path
        }?.value
    }

    /// Drop pairs with a dead side and stop mirroring on the survivor —
    /// closing one window leaves the other open, unlinked, and independent.
    private func prunePairs() {
        pairs.removeAll { pair in
            guard pair.0.value == nil || pair.1.value == nil else { return false }
            pair.0.value?.setCompareSyncEnabled(false)
            pair.1.value?.setCompareSyncEnabled(false)
            return true
        }
    }

    private func prune() {
        targets.removeAll { $0.value == nil }
        prunePairs()
    }

    private func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private struct WeakTarget {
        weak var value: CompareTarget?
        init(_ value: CompareTarget) { self.value = value }
    }

    // MARK: - Production open flow (sandbox-honest) [REF:fr:compare]

    /// Powerbox panel pre-pointed at the initiator's directory: the user's
    /// one "Compare" click grants sandbox access to the picked file, which
    /// then opens through the shared `NSDocumentController` — the same path
    /// as every other open, so window-per-document and Open Recent behave
    /// identically. Cancel is a no-op.
    private static func systemOpen(
        _ sourceURL: URL, completion: @escaping @MainActor (URL?, Bool) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.message = "Choose a document to compare side by side."
        panel.prompt = "Compare"
        panel.directoryURL = sourceURL.deletingLastPathComponent()
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
                NSDocumentController.shared.openDocument(withContentsOf: picked, display: true) {
                    _, alreadyOpen, error in
                    MainActor.assumeIsolated {
                        if let error {
                            Log.app.error(
                                "compare open failed for \(picked.path): \(error.localizedDescription)"
                            )
                            completion(nil, false)
                            return
                        }
                        completion(picked, alreadyOpen)
                    }
                }
            }
        }
    }
}
