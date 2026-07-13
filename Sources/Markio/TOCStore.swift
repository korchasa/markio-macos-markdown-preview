import Foundation

/// Persists the TOC sidebar's visibility across launches. A **global reading
/// preference** (like the line width), not per-window scene state: the reader
/// who wants an outline wants it for every long document. Backed by
/// `UserDefaults`; a custom suite is injectable for tests. [REF:fr:toc]
final class TOCStore {
    static let key = "tocSidebarVisible"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether the sidebar is shown. Defaults to hidden — short notes don't
    /// need an outline; the reader opts in once and keeps the choice.
    var visible: Bool {
        get { defaults.bool(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}
