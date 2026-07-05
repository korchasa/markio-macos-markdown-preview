import Foundation

/// Persists the reading-column width across launches and clamps it to a sane
/// range. The width is an **absolute character count** (CSS `ch` units), not a
/// pixel value and not a fraction of the window. Backed by `UserDefaults`; a
/// custom suite is injectable for tests. [REF:fr:line-width]
final class ContentWidthStore {
    /// New key: distinct from the legacy pixel key so old px values (e.g. 740)
    /// are not misread as character counts — a fresh install/upgrade falls back
    /// to `defaultWidth`.
    static let key = "contentWidthChars"
    static let defaultWidth = 80
    static let minWidth = 40
    static let maxWidth = 200
    /// Slider increment → the preset stops are 40, 60, …, 200.
    static let step = 20

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Current reading width in characters, always within `[minWidth, maxWidth]`
    /// and snapped to the nearest `step`.
    var width: Int {
        get {
            let stored = defaults.object(forKey: Self.key) as? Int ?? Self.defaultWidth
            return Self.clamp(stored)
        }
        set { defaults.set(Self.clamp(newValue), forKey: Self.key) }
    }

    /// Clamp to range and snap to the nearest preset step.
    static func clamp(_ value: Int) -> Int {
        let bounded = min(max(value, minWidth), maxWidth)
        let snapped = Int((Double(bounded - minWidth) / Double(step)).rounded()) * step + minWidth
        return min(max(snapped, minWidth), maxWidth)
    }
}
