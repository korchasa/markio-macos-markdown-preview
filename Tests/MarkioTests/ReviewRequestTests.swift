import XCTest

@testable import Markio

/// When the app asks macOS for a rating (UI-4).
///
/// Each test gets a defaults domain of its own, so neither the reader's record
/// nor another test's can decide the answer. A `ReviewRequest` is built once
/// per launch, so a new instance over the same domain is the next launch.
final class ReviewRequestTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "ReviewRequestTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    /// A record left by an earlier launch, so the launch under test is not the
    /// first one.
    private func launchedBefore() {
        _ = ReviewRequest(defaults: defaults, version: "1.1").recordOpening()
        defaults.set(0, forKey: ReviewRequest.openingsKey)
    }

    func testAsksOnTheThirdOpeningAndNotBefore() {
        launchedBefore()
        let request = ReviewRequest(defaults: defaults, version: "1.1")
        XCTAssertEqual(
            [request.recordOpening(), request.recordOpening(), request.recordOpening()],
            [false, false, true])
    }

    func testAsksOncePerVersion() {
        launchedBefore()
        let request = ReviewRequest(defaults: defaults, version: "1.1")
        for _ in 0..<3 { _ = request.recordOpening() }
        let later = ReviewRequest(defaults: defaults, version: "1.1")
        XCTAssertFalse((0..<10).contains { _ in later.recordOpening() })
    }

    func testANewVersionNeedsThreeNewOpenings() {
        launchedBefore()
        let old = ReviewRequest(defaults: defaults, version: "1.1")
        for _ in 0..<5 { _ = old.recordOpening() }
        let new = ReviewRequest(defaults: defaults, version: "1.2")
        XCTAssertEqual(
            [new.recordOpening(), new.recordOpening(), new.recordOpening()],
            [false, false, true])
    }

    func testTheFirstLaunchNeverAsks() {
        let first = ReviewRequest(defaults: defaults, version: "1.1")
        XCTAssertFalse((0..<5).contains { _ in first.recordOpening() })
        let second = ReviewRequest(defaults: defaults, version: "1.1")
        XCTAssertTrue(second.recordOpening())
    }
}
