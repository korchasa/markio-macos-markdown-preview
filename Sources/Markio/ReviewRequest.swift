import Foundation

/// Whether a document opening is the one to ask macOS for a rating on (UI-4).
///
/// All of its state lives in `defaults`, so an opening costs one read and one
/// write and nothing is held between calls. Apple caps how often the sheet
/// actually appears; this decides only when the app asks.
struct ReviewRequest {
    static let threshold = 3
    static let openingsKey = "reviewRequestOpenings"
    static let versionKey = "reviewRequestVersion"

    private let defaults: UserDefaults
    private let version: String
    /// Neither key existed when this launch first counted, so it is the
    /// app's first launch — or the first since this record was introduced,
    /// which is no worse a moment to hold back. Asking there would ask someone
    /// who has only just met the app.
    private let firstLaunch: Bool

    init(defaults: UserDefaults, version: String) {
        self.defaults = defaults
        self.version = version
        firstLaunch =
            defaults.object(forKey: Self.openingsKey) == nil
            && defaults.object(forKey: Self.versionKey) == nil
    }

    /// Count one opening, and say whether to ask now.
    ///
    /// The first launch keeps counting past the threshold rather than
    /// stopping at it, so the first opening of a later launch is the one that
    /// asks.
    func recordOpening() -> Bool {
        guard defaults.string(forKey: Self.versionKey) != version else { return false }
        let openings = defaults.integer(forKey: Self.openingsKey) + 1
        guard openings >= Self.threshold, !firstLaunch else {
            defaults.set(openings, forKey: Self.openingsKey)
            return false
        }
        defaults.set(0, forKey: Self.openingsKey)
        defaults.set(version, forKey: Self.versionKey)
        return true
    }
}
