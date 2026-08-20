import AppKit

/// The few things a reader is allowed to change, and where they are kept.
///
/// Reading width, outline visibility, and each document's scroll position and
/// zoom. No settings window: everything here is reachable from a control that
/// is already on screen or from the View menu.
enum Preferences {
    private static let widthKey = "readingWidthCharacters"
    private static let outlineKey = "outlineVisible"
    private static let positionsKey = "scrollPositions"

    /// The sizes zooming steps through, as multiples of the reading size.
    ///
    /// Steps rather than a factor applied over and over: a reader who zooms in
    /// four times and out four times has to land back where they started, and
    /// repeated multiplication by 1.1 does not.
    static let zoomSteps: [CGFloat] = [
        0.7, 0.8, 0.9, 1.0, 1.1, 1.25, 1.4, 1.6, 1.8, 2.0, 2.4, 2.8,
    ]

    /// The step at or below `zoom`, moved by `steps` places.
    static func zoom(_ zoom: CGFloat, steppedBy steps: Int) -> CGFloat {
        let nearest =
            zoomSteps.enumerated().min {
                abs($0.element - zoom) < abs($1.element - zoom)
            }?.offset ?? zoomSteps.firstIndex(of: 1) ?? 0
        let moved = min(max(nearest + steps, 0), zoomSteps.count - 1)
        return zoomSteps[moved]
    }

    static func clampZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, zoomSteps.first ?? 1), zoomSteps.last ?? 1)
    }

    static let widthRange = 50...140
    static let widthStep = 10

    /// The width a reader who has never touched the slider reads at.
    static let defaultWidth = 84

    /// Held for the length of a `--snapshot` run, and never written down.
    ///
    /// A store picture has to come out the same on every machine, and the
    /// width a snapshot draws at is the same one the reader sets with the
    /// slider — so a session that left the slider at 130 shipped 130 to the
    /// App Store, wide frames and all. Pinning it here rather than assigning
    /// to `readingWidth` is what keeps the reader's own choice.
    @MainActor static var pinnedWidth: Int?

    @MainActor static var readingWidth: Int {
        get {
            if let pinnedWidth { return clampWidth(pinnedWidth) }
            let stored = UserDefaults.standard.integer(forKey: widthKey)
            return stored == 0 ? defaultWidth : clampWidth(stored)
        }
        set { UserDefaults.standard.set(clampWidth(newValue), forKey: widthKey) }
    }

    static func clampWidth(_ value: Int) -> Int {
        let snapped = (value / widthStep) * widthStep
        return min(max(snapped, widthRange.lowerBound), widthRange.upperBound)
    }

    static var outlineVisible: Bool {
        get { UserDefaults.standard.bool(forKey: outlineKey) }
        set { UserDefaults.standard.set(newValue, forKey: outlineKey) }
    }

    // MARK: - Scroll positions

    /// Remember where each document was left, bounded so the list cannot grow
    /// without limit. Eviction is by write order, which is a good enough proxy
    /// for "least recently read" and needs no extra bookkeeping.
    private static let positionLimit = 200

    static func scrollPosition(for url: URL) -> CGFloat? {
        let stored =
            UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: [String: Double]]
        guard let entry = stored?[url.path], let y = entry["y"] else { return nil }
        return CGFloat(y)
    }

    /// A window's zoom is kept with its scroll position, because it is the same
    /// kind of fact: where this document was left and how it was being read.
    static func zoom(for url: URL) -> CGFloat? {
        let stored =
            UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: [String: Double]]
        guard let entry = stored?[url.path], let zoom = entry["zoom"] else { return nil }
        return clampZoom(CGFloat(zoom))
    }

    static func setZoom(_ zoom: CGFloat?, for url: URL) {
        var stored =
            UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: [String: Double]]
            ?? [:]
        var entry = stored[url.path] ?? [:]
        if let zoom {
            entry["zoom"] = Double(clampZoom(zoom))
        } else {
            entry.removeValue(forKey: "zoom")
        }
        entry["seq"] = (stored.values.compactMap { $0["seq"] }.max() ?? 0) + 1
        stored[url.path] = entry
        UserDefaults.standard.set(evicted(stored), forKey: positionsKey)
    }

    static func setScrollPosition(_ y: CGFloat, for url: URL) {
        var stored =
            UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: [String: Double]]
            ?? [:]
        let sequence = (stored.values.compactMap { $0["seq"] }.max() ?? 0) + 1
        var entry = stored[url.path] ?? [:]
        entry["y"] = Double(y)
        entry["seq"] = sequence
        stored[url.path] = entry
        UserDefaults.standard.set(evicted(stored), forKey: positionsKey)
    }

    private static func evicted(_ stored: [String: [String: Double]]) -> [String: [String: Double]]
    {
        guard stored.count > positionLimit else { return stored }
        var stored = stored
        let oldest = stored.sorted { ($0.value["seq"] ?? 0) < ($1.value["seq"] ?? 0) }
        for entry in oldest.prefix(stored.count - positionLimit) {
            stored.removeValue(forKey: entry.key)
        }
        return stored
    }
}
