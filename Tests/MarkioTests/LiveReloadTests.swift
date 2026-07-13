import XCTest

@testable import Markio

/// End-to-end live reload: editing the open file on disk updates the rendered
/// preview, exercising FileWatcher → DocumentModel.reload → WebView render.
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

        let initial = try FileLoader.load(file)
        let model = DocumentModel()
        await model.start(text: initial, url: file)

        // Initial content renders (also acts as a barrier: the watcher is armed).
        try await waitForContent(model, contains: "Alpha marker")

        // External edit (atomic save, like most editors) must refresh the view.
        try "# Beta marker\n".write(to: file, atomically: true, encoding: .utf8)
        try await waitForContent(model, contains: "Beta marker")
    }

    /// Re-rendering the same document must keep the reader's scroll position.
    /// Mermaid docs are the regression trigger: during re-render the SVG is
    /// momentarily replaced by its short source text, WebKit clamps the window
    /// scroll to the shrunken document, and without an explicit restore the
    /// view jumps up by the diagram height. [REF:fr:live-reload]
    func testRerenderPreservesScrollPosition() async throws {
        let controller = try await makeLoadedPreview()
        // A zero-size frame collapses SVG heights to ~0, hiding the clamp —
        // use a real viewport so the diagram actually contributes height.
        controller.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        let chain = (1...40).map { "n\($0)[Node \($0)]" }.joined(separator: " --> ")
        let filler = (1...300).map { "Paragraph \($0) lorem ipsum dolor sit amet." }
            .joined(separator: "\n\n")
        let doc = "```mermaid\nflowchart TD\n" + chain + "\n```\n\n" + filler

        await controller.render(doc)
        let height = try await count(controller, "document.documentElement.scrollHeight")
        XCTAssertGreaterThan(height, 1000, "document must be tall enough to scroll")

        let target = height - 700
        _ = try await controller.evaluate("window.scrollTo(0, \(target))")
        let scrolled = try await count(controller, "window.scrollY")
        XCTAssertEqual(scrolled, target, "precondition: scroll must reach the target")

        // Same render path reloadFromDisk takes on an external file change.
        await controller.render(doc)
        let after = try await count(controller, "window.scrollY")
        XCTAssertEqual(after, target, "re-render must preserve the scroll position")
    }

    private func waitForContent(
        _ model: DocumentModel, contains needle: String, timeout: TimeInterval = 6
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
