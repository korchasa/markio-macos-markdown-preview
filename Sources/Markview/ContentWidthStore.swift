import Foundation

/// Persists the reading-column width across launches and clamps it to a sane
/// range. Backed by `UserDefaults`; a custom suite is injectable for tests.
/// [REF:fr:line-width]
final class ContentWidthStore {
    static let key = "contentWidth"
    static let defaultWidth = 740
    static let minWidth = 480
    static let maxWidth = 1200

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Current width in CSS pixels, always within `[minWidth, maxWidth]`.
    var width: Int {
        get {
            let stored = defaults.object(forKey: Self.key) as? Int ?? Self.defaultWidth
            return Self.clamp(stored)
        }
        set { defaults.set(Self.clamp(newValue), forKey: Self.key) }
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, minWidth), maxWidth)
    }
}
