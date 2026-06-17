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

        let store = ContentWidthStore(defaults: defaults)
        store.width = 900
        XCTAssertEqual(ContentWidthStore(defaults: defaults).width, 900, "Width must persist")

        // Clamping guards out-of-range values.
        store.width = 99_999
        XCTAssertEqual(
            ContentWidthStore(defaults: defaults).width, ContentWidthStore.maxWidth,
            "Width must clamp to max")

        // Reflow: setting the width updates the live CSS custom property.
        let preview = await makeLoadedPreview()
        await preview.setContentWidth(900)
        let applied = try await preview.evaluate("getContentWidth()") as? String
        XCTAssertEqual(applied, "900px", "--content-width should reflect the applied width")
    }
}
