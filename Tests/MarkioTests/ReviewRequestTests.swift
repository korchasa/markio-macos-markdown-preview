import XCTest

@testable import Markio

/// When the app asks macOS for a rating (UI-4).
///
/// Each test gets a defaults domain of its own, so neither the reader's record
/// nor another test's can decide the answer, and a clock of its own, so "today"
/// is whatever the test says it is. A new `ReviewRequest` over the same domain
/// is the next launch.
final class ReviewRequestTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func setUp() {
        suite = "ReviewRequestTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func request(version: String = "1.1") -> ReviewRequest {
        ReviewRequest(defaults: defaults, version: version, calendar: calendar) {
            [unowned self] in self.now
        }
    }

    private func nextDay() { now += 24 * 60 * 60 }

    /// A reader closing a window they have had open for a minute.
    private func closesAfterReading(_ request: ReviewRequest) -> Bool {
        request.asksOnClose(openFor: 60, terminating: false)
    }

    func testAsksAfterTheThirdOpeningAndNotBefore() {
        let first = request()
        first.recordOpening()
        nextDay()
        let later = request()
        later.recordOpening()
        XCTAssertFalse(closesAfterReading(later))
        later.recordOpening()
        XCTAssertTrue(closesAfterReading(later))
    }

    func testNeverAsksOnTheDayOfTheFirstOpening() {
        now = calendar.date(
            from: DateComponents(year: 2027, month: 3, day: 1, hour: 0, minute: 30))!
        let first = request()
        for _ in 0..<5 { first.recordOpening() }
        XCTAssertFalse(closesAfterReading(first))
        now += 23 * 60 * 60 - 1  // still the same calendar day
        XCTAssertFalse(closesAfterReading(request()))
        nextDay()
        XCTAssertTrue(closesAfterReading(request()))
    }

    func testTheFirstDayIsACalendarDayNotTwentyFourHours() {
        now = calendar.date(
            from: DateComponents(year: 2027, month: 3, day: 1, hour: 23, minute: 50))!
        let first = request()
        for _ in 0..<3 { first.recordOpening() }
        now += 20 * 60  // ten past midnight, twenty minutes later
        XCTAssertTrue(closesAfterReading(request()))
    }

    func testAWindowOpenUnderThirtySecondsDoesNotAsk() {
        let first = request()
        for _ in 0..<3 { first.recordOpening() }
        nextDay()
        let later = request()
        XCTAssertFalse(later.asksOnClose(openFor: 29.9, terminating: false))
        XCTAssertTrue(later.asksOnClose(openFor: 30, terminating: false))
    }

    func testQuittingDoesNotAsk() {
        let first = request()
        for _ in 0..<3 { first.recordOpening() }
        nextDay()
        XCTAssertFalse(request().asksOnClose(openFor: 600, terminating: true))
    }

    func testTheDecisionAloneDoesNotUseUpTheVersion() {
        let first = request()
        for _ in 0..<3 { first.recordOpening() }
        nextDay()
        let later = request()
        XCTAssertTrue(closesAfterReading(later))
        XCTAssertTrue(closesAfterReading(later))
    }

    func testAsksOncePerVersion() {
        let first = request()
        for _ in 0..<3 { first.recordOpening() }
        nextDay()
        let later = request()
        XCTAssertTrue(closesAfterReading(later))
        later.markAsked()
        for _ in 0..<10 { later.recordOpening() }
        nextDay()
        XCTAssertFalse(closesAfterReading(request()))
    }

    func testANewVersionNeedsThreeNewOpenings() {
        let old = request(version: "1.1")
        for _ in 0..<5 { old.recordOpening() }
        nextDay()
        XCTAssertTrue(closesAfterReading(old))
        old.markAsked()
        let new = request(version: "1.2")
        new.recordOpening()
        new.recordOpening()
        XCTAssertFalse(closesAfterReading(new))
        new.recordOpening()
        XCTAssertTrue(closesAfterReading(new))
    }

    /// A record kept before the first day was stored has openings and no day:
    /// the day it is first read is its first day.
    func testARecordWithoutAFirstDayStartsItOnTheFirstRead() {
        defaults.set(5, forKey: ReviewRequest.openingsKey)
        XCTAssertFalse(closesAfterReading(request()))
        XCTAssertEqual(defaults.object(forKey: ReviewRequest.firstDayKey) as? Date, now)
        nextDay()
        XCTAssertTrue(closesAfterReading(request()))
    }

    func testTheFirstDayIsKeptAcrossARequest() {
        let first = request()
        first.recordOpening()
        let day = now
        for _ in 0..<2 { first.recordOpening() }
        nextDay()
        let later = request()
        later.markAsked()
        later.recordOpening()
        XCTAssertEqual(defaults.object(forKey: ReviewRequest.firstDayKey) as? Date, day)
    }
}
