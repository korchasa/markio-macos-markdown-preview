import XCTest

@testable import Markview

/// Line-width persistence (UserDefaults) and live reflow (CSS var). [REF:fr:line-width]
@MainActor
final class LineWidthTests: XCTestCase {
    func testWidthPersistsAndReflows() async throws {
        // Persistence: a fresh store on the same suite reads the saved value.
        let suite = "dev.markview.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // An in-range, on-step character count persists verbatim.
        let store = ContentWidthStore(defaults: defaults)
        store.width = 120
        XCTAssertEqual(ContentWidthStore(defaults: defaults).width, 120, "Width must persist")

        // Clamping guards out-of-range values.
        store.width = 99_999
        XCTAssertEqual(
            ContentWidthStore(defaults: defaults).width, ContentWidthStore.maxWidth,
            "Width must clamp to max")

        // Off-step values snap to the nearest preset (70 → 80).
        store.width = 70
        XCTAssertEqual(
            ContentWidthStore(defaults: defaults).width, 80, "Width must snap to nearest step")

        // Reflow: setting the width updates the live CSS custom property in `ch`.
        let preview = await makeLoadedPreview()
        await preview.setContentWidth(120)
        let applied = try await preview.evaluate("getContentWidth()") as? String
        XCTAssertEqual(applied, "120ch", "--content-width should reflect the applied width in ch")
    }
}
