import XCTest

@testable import Markio

/// FR-SESSION-RESTORE: per-document scroll position survives closing and
/// reopening a document — the store round-trips positions (bounded), and the
/// page → `markioScroll` → store → `setScrollY` chain restores the reader's
/// place on the next open.
final class SessionRestoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "markio-session-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// The store persists a position per file path, overwrites on update, and
    /// evicts the oldest entry beyond its cap (a bounded map, not a leak).
    func testScrollPositionRoundTrip() {
        let store = ScrollPositionStore(defaults: defaults)
        let a = URL(fileURLWithPath: "/tmp/a.md")
        let b = URL(fileURLWithPath: "/tmp/b.md")

        XCTAssertNil(store.position(for: a), "unknown document has no position")

        store.setPosition(420, for: a)
        store.setPosition(77, for: b)
        XCTAssertEqual(store.position(for: a), 420)
        XCTAssertEqual(store.position(for: b), 77)

        store.setPosition(500, for: a)
        XCTAssertEqual(store.position(for: a), 500, "update overwrites")

        // Reopening the same suite (a fresh store) still sees the values —
        // the map lives in UserDefaults, not in memory.
        let reopened = ScrollPositionStore(defaults: defaults)
        XCTAssertEqual(reopened.position(for: a), 500)

        // Fill past the cap: the oldest entry (a, refreshed above, then b,
        // then fillers) must be evicted first.
        for i in 0..<ScrollPositionStore.maxEntries {
            store.setPosition(Double(i), for: URL(fileURLWithPath: "/tmp/fill-\(i).md"))
        }
        XCTAssertNil(store.position(for: a), "oldest entry evicted at the cap")
        XCTAssertNotNil(
            store.position(
                for: URL(fileURLWithPath: "/tmp/fill-\(ScrollPositionStore.maxEntries - 1).md")),
            "newest entry survives")
    }

    /// End-to-end: scrolling a document persists its position (via the page's
    /// debounced `markioScroll` post); a second "session" over the same
    /// defaults suite reopens the document at that position.
    @MainActor
    func testScrollSavedOnScrollAndRestoredOnOpen() async throws {
        let markdown = (1...150).map { "Paragraph \($0) — enough text to scroll." }
            .joined(separator: "\n\n")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("markio-session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("doc.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)

        // Session 1: open, scroll, and wait for the debounced save to land.
        let first = DocumentModel(defaults: defaults)
        first.preview.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        await first.start(text: markdown, url: url)
        _ = try await first.preview.evaluate("window.scrollTo(0, 600)")
        let store = ScrollPositionStore(defaults: defaults)
        var saved: Double?
        for _ in 0..<40 where saved == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            saved = store.position(for: url)
        }
        XCTAssertEqual(saved ?? -1, 600, accuracy: 1, "scroll must persist via markioScroll")

        // Session 2: a fresh model over the same suite restores the position.
        let second = DocumentModel(defaults: defaults)
        second.preview.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        await second.start(text: markdown, url: url)
        let restored = try await count(second.preview, "window.scrollY")
        XCTAssertEqual(Double(restored), 600, accuracy: 1, "reopen restores the reading position")
    }
}
