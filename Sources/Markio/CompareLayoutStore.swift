import Foundation

/// Persists the compare layout choice (inline vs split columns) across
/// launches. A **global reading preference** (like the TOC visibility), not
/// per-window scene state. Backed by `UserDefaults`; a custom suite is
/// injectable for tests. [REF:fr:compare]
final class CompareLayoutStore {
    static let key = "compareSplitLayout"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether compare renders as side-by-side columns. Defaults to inline —
    /// the annotated single document is the calmer reading view.
    var split: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}
