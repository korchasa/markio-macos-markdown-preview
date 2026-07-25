import AppKit
import XCTest

@testable import Markio

/// FR-COMPARE: side-by-side compare — two document windows linked by the
/// `CompareCoordinator` mirror each other's scrolling by the same absolute
/// pixel distance (delta mirroring), each clamped within its own bounds, with
/// no feedback loop; a clamped peer re-engages the moment scrolling reverses;
/// unlinking or losing either side stops the mirroring.
final class CompareTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        suiteName = "markio-compare-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("markio-compare-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Open primitive for tests that link windows directly — must never fire.
    @MainActor
    private static func unusedOpen(
        _ url: URL, completion: @escaping @MainActor (URL?, Bool) -> Void
    ) {
        XCTFail("open primitive must not be called in direct-link tests")
        completion(nil, false)
    }

    /// A started document model over a real temp file, sized so the page has a
    /// scrollable viewport (offscreen web views need an explicit frame).
    @MainActor
    private func makeModel(
        coordinator: CompareCoordinator, file: String, paragraphs: Int
    ) async throws -> DocumentModel {
        let text = (1...paragraphs).map { "Paragraph \($0) — enough text to scroll." }
            .joined(separator: "\n\n")
        let url = tempDir.appendingPathComponent(file)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let model = DocumentModel(defaults: defaults, compareCoordinator: coordinator)
        model.preview.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        await model.start(text: text, url: url)
        return model
    }

    @MainActor
    private func scrollableMax(_ model: DocumentModel) async throws -> Double {
        let raw = try await model.preview.evaluate(
            "Math.max(0, document.documentElement.scrollHeight - window.innerHeight)")
        return (raw as? NSNumber)?.doubleValue ?? 0
    }

    @MainActor
    private func scrollY(_ model: DocumentModel) async throws -> Double {
        let raw = try await model.preview.evaluate("window.scrollY")
        return (raw as? NSNumber)?.doubleValue ?? -1
    }

    /// Poll until the model's scrollY is within `accuracy` of `expected`;
    /// returns the last observed value either way.
    @MainActor
    private func waitForScrollY(
        _ model: DocumentModel, toReach expected: Double, accuracy: Double = 2
    ) async throws -> Double {
        var last: Double = -1
        for _ in 0..<40 {
            last = try await scrollY(model)
            if abs(last - expected) <= accuracy { return last }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return last
    }

    /// Scrolling one linked preview moves the other by the same absolute pixel
    /// distance, in both directions (positions coincide while nothing clamps).
    @MainActor
    func testScrollMirrorsSameAbsoluteDistanceToLinkedPeer() async throws {
        let coordinator = CompareCoordinator(open: Self.unusedOpen)
        let a = try await makeModel(coordinator: coordinator, file: "a.md", paragraphs: 300)
        let b = try await makeModel(coordinator: coordinator, file: "b.md", paragraphs: 120)
        coordinator.link(a, b)

        let aMax = try await scrollableMax(a)
        let bMax = try await scrollableMax(b)
        XCTAssertGreaterThan(aMax, 0, "A must be scrollable")
        XCTAssertGreaterThan(bMax, 0, "B must be scrollable")
        XCTAssertNotEqual(
            aMax, bMax, accuracy: 10,
            "documents must differ in length so absolute ≠ proportional")

        // A down 300 px → B lands 300 px down (NOT at 300/aMax of its height).
        let step = min(300, bMax / 2).rounded()
        _ = try await a.preview.evaluate("window.scrollTo(0, \(step))")
        let bLanded = try await waitForScrollY(b, toReach: step)
        XCTAssertEqual(bLanded, step, accuracy: 2, "B follows A by the same distance")

        // And back: B up 100 px → A follows by 100 px. The link is symmetric.
        let back = step - 100
        _ = try await b.preview.evaluate("window.scrollTo(0, \(back))")
        let aLanded = try await waitForScrollY(a, toReach: back)
        XCTAssertEqual(aLanded, back, accuracy: 2, "A follows B by the same distance")
    }

    /// A peer stopped at its own end stays put while the longer document
    /// continues, and re-engages IMMEDIATELY on the first reverse scroll —
    /// position mapping would keep it pinned until the source came back below
    /// the peer's maximum.
    @MainActor
    func testClampedPeerPicksUpImmediatelyOnReverseScroll() async throws {
        let coordinator = CompareCoordinator(open: Self.unusedOpen)
        let a = try await makeModel(coordinator: coordinator, file: "a.md", paragraphs: 300)
        let b = try await makeModel(coordinator: coordinator, file: "b.md", paragraphs: 120)
        coordinator.link(a, b)

        let aMax = try await scrollableMax(a)
        let bMax = try await scrollableMax(b)
        XCTAssertGreaterThan(aMax, bMax + 200, "A must overshoot B by a clear margin")

        // Drive A to its bottom: B clamps at ITS bottom and stays.
        _ = try await a.preview.evaluate("window.scrollTo(0, \(aMax))")
        let bClamped = try await waitForScrollY(b, toReach: bMax)
        XCTAssertEqual(bClamped, bMax, accuracy: 2, "B clamps at its own end")

        // Reverse A by 150 px — far above B's max. B must move up 150 px NOW.
        _ = try await a.preview.evaluate("window.scrollTo(0, \(aMax - 150))")
        let bPicked = try await waitForScrollY(b, toReach: bMax - 150)
        XCTAssertEqual(
            bPicked, bMax - 150, accuracy: 2,
            "clamped peer must pick up on the first reverse scroll")
    }

    /// Linking seeds the peer to the initiator's absolute offset (clamped).
    @MainActor
    func testLinkSeedsPeerToInitiatorsAbsoluteOffset() async throws {
        let coordinator = CompareCoordinator(open: Self.unusedOpen)
        let a = try await makeModel(coordinator: coordinator, file: "a.md", paragraphs: 300)
        let b = try await makeModel(coordinator: coordinator, file: "b.md", paragraphs: 120)

        let bMax = try await scrollableMax(b)
        let seed = (bMax / 2).rounded()
        _ = try await a.preview.evaluate("window.scrollTo(0, \(seed))")
        try await Task.sleep(nanoseconds: 300_000_000)

        coordinator.link(a, b)
        let bLanded = try await waitForScrollY(b, toReach: seed)
        XCTAssertEqual(bLanded, seed, accuracy: 2, "link seeds B to A's absolute offset")
    }

    /// Applying a synced position must not re-emit a sync event that moves the
    /// source: after the peer lands, the source still sits exactly where the
    /// user put it.
    @MainActor
    func testNoFeedbackLoopBetweenLinkedPeers() async throws {
        let coordinator = CompareCoordinator(open: Self.unusedOpen)
        let a = try await makeModel(coordinator: coordinator, file: "a.md", paragraphs: 300)
        let b = try await makeModel(coordinator: coordinator, file: "b.md", paragraphs: 120)
        coordinator.link(a, b)

        let bMax = try await scrollableMax(b)
        let target = (bMax / 3).rounded()
        _ = try await a.preview.evaluate("window.scrollTo(0, \(target))")
        _ = try await waitForScrollY(b, toReach: target)

        // Let any echo settle, then verify neither side drifted.
        try await Task.sleep(nanoseconds: 500_000_000)
        let aY = try await scrollY(a)
        XCTAssertEqual(aY, target, accuracy: 1, "mirroring must not bounce back to the source")
        let bY = try await scrollY(b)
        XCTAssertEqual(bY, target, accuracy: 2, "peer stays at the mirrored position")
    }

    /// Unlinking stops the mirroring and clears the compared flag.
    @MainActor
    func testUnlinkStopsMirroring() async throws {
        let coordinator = CompareCoordinator(open: Self.unusedOpen)
        let a = try await makeModel(coordinator: coordinator, file: "a.md", paragraphs: 300)
        let b = try await makeModel(coordinator: coordinator, file: "b.md", paragraphs: 120)
        coordinator.link(a, b)
        XCTAssertTrue(coordinator.isCompared(a))
        XCTAssertTrue(coordinator.isCompared(b))

        let bMax = try await scrollableMax(b)
        let step = (bMax / 2).rounded()
        _ = try await a.preview.evaluate("window.scrollTo(0, \(step))")
        _ = try await waitForScrollY(b, toReach: step)

        coordinator.unlink(for: a)
        XCTAssertFalse(coordinator.isCompared(a))
        XCTAssertFalse(coordinator.isCompared(b))

        let bBefore = try await scrollY(b)
        _ = try await a.preview.evaluate("window.scrollTo(0, 0)")
        try await Task.sleep(nanoseconds: 600_000_000)
        let bAfter = try await scrollY(b)
        XCTAssertEqual(bAfter, bBefore, accuracy: 1, "unlinked peer no longer follows")
    }

    /// A deallocated peer drops the pair (weak references — closing a window
    /// never retains it and never closes the other one).
    @MainActor
    func testDeallocatedPeerDropsPair() async throws {
        let coordinator = CompareCoordinator(open: Self.unusedOpen)
        let a = try await makeModel(coordinator: coordinator, file: "a.md", paragraphs: 120)
        var b: DocumentModel? = try await makeModel(
            coordinator: coordinator, file: "b.md", paragraphs: 60)
        coordinator.link(a, b!)
        XCTAssertTrue(coordinator.isCompared(a))

        b = nil
        _ = try await a.preview.evaluate("window.scrollTo(0, 200)")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(coordinator.isCompared(a), "weak pair drops when a peer deallocates")
    }

    /// `beginCompare` for a not-yet-open document records a pending pair that
    /// completes when the new window's model attaches after its first render.
    @MainActor
    func testPendingPairCompletesOnAttach() async throws {
        let urlB = tempDir.appendingPathComponent("pending-b.md")
        let coordinator = CompareCoordinator(open: { _, completion in
            completion(urlB, false)
        })
        let a = try await makeModel(
            coordinator: coordinator, file: "pending-a.md", paragraphs: 60)
        coordinator.beginCompare(from: a)
        XCTAssertFalse(coordinator.isCompared(a), "pair is pending until the peer attaches")

        let b = try await makeModel(
            coordinator: coordinator, file: "pending-b.md", paragraphs: 60)
        XCTAssertTrue(coordinator.isCompared(a))
        XCTAssertTrue(coordinator.isCompared(b))
    }

    /// Picking the initiator's own document is a guarded no-op (FR-MULTIDOC
    /// means the same file never occupies two windows, so self-pairing is
    /// impossible by construction).
    @MainActor
    func testSelfCompareIsNoOp() async throws {
        var pickedURL: URL?
        let coordinator = CompareCoordinator(open: { url, completion in
            completion(pickedURL ?? url, true)
        })
        let a = try await makeModel(coordinator: coordinator, file: "self.md", paragraphs: 60)
        pickedURL = a.documentURL
        coordinator.beginCompare(from: a)
        XCTAssertFalse(coordinator.isCompared(a), "self-compare must be a no-op")
    }

    /// The tiling split covers the screen's visible frame exactly: two halves,
    /// no gap, no overlap, odd widths absorbed by the right half.
    func testTileFramesSplitScreenInHalves() {
        let screen = NSRect(x: 100, y: 50, width: 1601, height: 900)
        let frames = CompareCoordinator.tileFrames(in: screen)
        XCTAssertEqual(frames.left.minX, 100)
        XCTAssertEqual(frames.left.width, 800)
        XCTAssertEqual(frames.right.minX, 900)
        XCTAssertEqual(frames.right.width, 701 + 100)
        XCTAssertEqual(frames.left.height, 900)
        XCTAssertEqual(frames.right.height, 900)
        XCTAssertEqual(frames.right.maxX, screen.maxX)
        XCTAssertEqual(frames.left.maxX, frames.right.minX)
    }
}
