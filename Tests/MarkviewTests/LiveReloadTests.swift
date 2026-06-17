import XCTest

@testable import Markview

/// End-to-end live reload: editing the open file on disk updates the rendered
/// preview, exercising FileWatcher → AppModel.reload → WebView render.
/// [REF:fr:live-reload]
@MainActor
final class LiveReloadTests: XCTestCase {
    func testPreviewUpdatesWhenFileChanges() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("doc.md")
        try "# Alpha marker\n".write(to: file, atomically: true, encoding: .utf8)

        let model = AppModel()
        await model.bootstrap()
        model.open(file)

        // Initial content renders (also acts as a barrier: the watcher is armed).
        try await waitForContent(model, contains: "Alpha marker")

        // External edit (atomic save, like most editors) must refresh the view.
        try "# Beta marker\n".write(to: file, atomically: true, encoding: .utf8)
        try await waitForContent(model, contains: "Beta marker")
    }

    private func waitForContent(
        _ model: AppModel, contains needle: String, timeout: TimeInterval = 6
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text =
                (try? await model.preview.evaluate(
                    "document.getElementById('content').innerText")) as? String
            if let text, text.contains(needle) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("preview did not contain \"\(needle)\" within \(timeout)s")
    }
}
