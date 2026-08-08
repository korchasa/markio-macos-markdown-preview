import AppKit

/// The three things a reader is allowed to change, and where they are kept.
///
/// Reading width, outline visibility and each document's scroll position. No
/// settings window: everything here is reachable from a control that is already
/// on screen or from the View menu.
enum Preferences {
    private static let widthKey = "readingWidthCharacters"
    private static let outlineKey = "outlineVisible"
    private static let positionsKey = "scrollPositions"

    static let widthRange = 50...140
    static let widthStep = 10

    static var readingWidth: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: widthKey)
            return stored == 0 ? 84 : clampWidth(stored)
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

    static func setScrollPosition(_ y: CGFloat, for url: URL) {
        var stored =
            UserDefaults.standard.dictionary(forKey: positionsKey) as? [String: [String: Double]]
            ?? [:]
        let sequence = (stored.values.compactMap { $0["seq"] }.max() ?? 0) + 1
        stored[url.path] = ["y": Double(y), "seq": sequence]
        if stored.count > positionLimit {
            let oldest = stored.sorted { ($0.value["seq"] ?? 0) < ($1.value["seq"] ?? 0) }
            for entry in oldest.prefix(stored.count - positionLimit) {
                stored.removeValue(forKey: entry.key)
            }
        }
        UserDefaults.standard.set(stored, forKey: positionsKey)
    }
}
