import Foundation

/// Whether closing a document window is the moment to ask macOS for a rating
/// (UI-4).
///
/// Openings are counted when a reader opens a document; the question is asked
/// when they close one they have read, because that is the end of something
/// they came to do rather than the start of it. All of the state lives in
/// `defaults`, so nothing is held between calls. Apple caps how often the sheet
/// actually appears; this decides only when the app asks.
struct ReviewRequest {
    static let threshold = 3
    /// Less than this and the window was a glance — a wrong file, a check of
    /// one line — not a read worth asking about.
    static let minimumReading: TimeInterval = 30
    static let openingsKey = "reviewRequestOpenings"
    static let versionKey = "reviewRequestVersion"
    static let firstDayKey = "reviewRequestFirstDay"

    private let defaults: UserDefaults
    private let version: String
    private let calendar: Calendar
    private let now: () -> Date

    init(
        defaults: UserDefaults, version: String, calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.version = version
        self.calendar = calendar
        self.now = now
    }

    /// Count one opening. Costs the same two reads and one write it always
    /// has; the first opening ever also stores its day.
    func recordOpening() {
        guard defaults.string(forKey: Self.versionKey) != version else { return }
        let openings = defaults.object(forKey: Self.openingsKey) as? Int
        if openings == nil, defaults.object(forKey: Self.firstDayKey) == nil {
            defaults.set(now(), forKey: Self.firstDayKey)
        }
        defaults.set((openings ?? 0) + 1, forKey: Self.openingsKey)
    }

    /// Whether closing a window that was open for `openFor` seconds asks now.
    ///
    /// Says yes again until `markAsked()` runs, so the version is spent only
    /// by a request that was actually made. A quit closes windows too, and
    /// asking someone who is leaving the app is asking at the worst moment.
    func asksOnClose(openFor: TimeInterval, terminating: Bool) -> Bool {
        guard !terminating, openFor >= Self.minimumReading else { return false }
        guard defaults.string(forKey: Self.versionKey) != version,
            defaults.integer(forKey: Self.openingsKey) >= Self.threshold
        else { return false }
        return !isFirstDay()
    }

    /// Spend this version's request and start counting for the next one.
    func markAsked() {
        defaults.set(0, forKey: Self.openingsKey)
        defaults.set(version, forKey: Self.versionKey)
    }

    /// Someone who met the app today has not used it yet, whatever they have
    /// opened. A record kept before the day was stored has none, and the day
    /// it is first read becomes its first day.
    private func isFirstDay() -> Bool {
        guard let first = defaults.object(forKey: Self.firstDayKey) as? Date else {
            defaults.set(now(), forKey: Self.firstDayKey)
            return true
        }
        return calendar.isDate(now(), inSameDayAs: first)
    }
}
