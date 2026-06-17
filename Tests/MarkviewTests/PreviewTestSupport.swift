import XCTest

@testable import Markview

extension XCTestCase {
    /// Create a `PreviewController` with `template.html` fully loaded.
    @MainActor
    func makeLoadedPreview() async -> PreviewController {
        let controller = PreviewController()
        await controller.loadTemplate()
        return controller
    }

    /// Evaluate JS that returns an integer count.
    @MainActor
    func count(_ controller: PreviewController, _ js: String) async throws -> Int {
        let value = try await controller.evaluate(js)
        return (value as? Int) ?? (value as? NSNumber)?.intValue ?? -1
    }
}
