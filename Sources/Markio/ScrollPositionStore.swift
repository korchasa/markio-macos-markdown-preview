import Foundation

/// Persists each document's last scroll position across launches, keyed by
/// file path. A bounded map: beyond `maxEntries` the least-recently-written
/// entry is evicted, so the defaults never grow with every file ever opened.
/// Backed by `UserDefaults`; a custom suite is injectable for tests.
/// [REF:fr:session-restore]
final class ScrollPositionStore {
    static let key = "scrollPositions"
    static let maxEntries = 200

    private static let yField = "y"
    private static let seqField = "seq"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Last saved scroll position for `url`, or `nil` when unknown (including
    /// a corrupt stored value — the viewer must open regardless).
    func position(for url: URL) -> Double? {
        entries()[url.path]?[Self.yField]
    }

    /// Save the scroll position for `url`, evicting the oldest entries when
    /// the map exceeds `maxEntries`. Recency is a monotonic sequence number,
    /// not a timestamp — same-second writes keep a deterministic order.
    func setPosition(_ y: Double, for url: URL) {
        var map = entries()
        let nextSeq = (map.values.compactMap { $0[Self.seqField] }.max() ?? 0) + 1
        map[url.path] = [Self.yField: y, Self.seqField: nextSeq]
        while map.count > Self.maxEntries {
            guard
                let oldest = map.min(by: {
                    ($0.value[Self.seqField] ?? 0) < ($1.value[Self.seqField] ?? 0)
                })
            else { break }
            map.removeValue(forKey: oldest.key)
        }
        defaults.set(map, forKey: Self.key)
    }

    /// Decode the stored map best-effort: anything malformed reads as empty.
    private func entries() -> [String: [String: Double]] {
        defaults.dictionary(forKey: Self.key) as? [String: [String: Double]] ?? [:]
    }
}
