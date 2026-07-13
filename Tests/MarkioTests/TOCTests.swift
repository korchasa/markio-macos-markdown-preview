import XCTest

@testable import Markio

/// Acceptance tests for the TOC sidebar: outline extraction, click-to-jump,
/// scroll-spy, visibility persistence, and consistency across live re-renders.
/// [REF:fr:toc]
@MainActor
final class TOCTests: XCTestCase {
    /// A document with duplicate titles and mixed levels: the outline must keep
    /// document order, expose levels, and dedup slug ids GitHub-style.
    func testOutlineExtractsHeadingTree() async throws {
        let controller = try await makeLoadedPreview()
        await controller.render(
            """
            # Alpha
            text
            ## Beta
            text
            ## Beta
            text
            ### Gamma Deep
            text
            # Omega End
            text
            """)

        let outline = await controller.outline()
        XCTAssertEqual(
            outline,
            [
                TOCItem(level: 1, text: "Alpha", id: "alpha"),
                TOCItem(level: 2, text: "Beta", id: "beta"),
                TOCItem(level: 2, text: "Beta", id: "beta-1"),
                TOCItem(level: 3, text: "Gamma Deep", id: "gamma-deep"),
                TOCItem(level: 1, text: "Omega End", id: "omega-end"),
            ])
    }

    /// Clicking a heading scrolls the preview so the heading sits at the top of
    /// the viewport.
    func testJumpScrollsToHeading() async throws {
        let controller = try await makeTallPreview()

        let jumped = await controller.scrollToHeading("omega-end")
        XCTAssertTrue(jumped, "known heading id must be found")

        let scrollY = try await count(controller, "window.scrollY")
        XCTAssertGreaterThan(scrollY, 0, "jump must actually scroll")
        let top = try await count(
            controller,
            "Math.round(document.getElementById('omega-end').getBoundingClientRect().top)")
        XCTAssertLessThanOrEqual(abs(top), 2, "heading must sit at the viewport top")

        let missing = await controller.scrollToHeading("no-such-heading")
        XCTAssertFalse(missing, "unknown id must report failure, not throw")
    }

    /// The current section follows the scroll position: the page computes it
    /// (pull) and pushes changes to native via the markioTOC message handler.
    func testCurrentSectionTracksScroll() async throws {
        let controller = try await makeTallPreview()

        let initial = await controller.currentSection()
        XCTAssertEqual(initial, "alpha", "at the top the first heading is current")

        var pushed: [String] = []
        controller.onCurrentSectionChange = { pushed.append($0) }

        _ = await controller.scrollToHeading("omega-end")
        let current = await controller.currentSection()
        XCTAssertEqual(current, "omega-end", "pull: current section follows the scroll")

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, pushed.last != "omega-end" {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(
            pushed.last, "omega-end",
            "push: the page must deliver the current section id to native")
    }

    /// Sidebar visibility is a global reading preference persisted across
    /// launches (UserDefaults), defaulting to hidden.
    func testSidebarVisibilityPersists() throws {
        let suiteName = "TOCTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(TOCStore(defaults: defaults).visible, "default is hidden")

        let store = TOCStore(defaults: defaults)
        store.visible = true
        XCTAssertTrue(
            TOCStore(defaults: defaults).visible,
            "a fresh store on the same suite must see the persisted choice")
    }

    /// After a live re-render the outline matches the NEW document and jumping
    /// keeps working — heading DOM nodes are re-created on every render.
    /// [REF:fr:live-reload]
    func testOutlineSurvivesRerender() async throws {
        let controller = try await makeTallPreview()
        let before = await controller.outline()
        XCTAssertEqual(before.first?.id, "alpha")

        // Enough content after the last heading that scrollIntoView can bring
        // it to the viewport top (a too-short tail clamps the scroll).
        let filler = (1...80).map { "Paragraph \($0) lorem ipsum dolor sit amet." }
            .joined(separator: "\n\n")
        await controller.render(
            "# Rewritten\n\n\(filler)\n\n## Fresh Section\n\n\(filler)\n")

        let after = await controller.outline()
        XCTAssertEqual(
            after,
            [
                TOCItem(level: 1, text: "Rewritten", id: "rewritten"),
                TOCItem(level: 2, text: "Fresh Section", id: "fresh-section"),
            ])

        let jumped = await controller.scrollToHeading("fresh-section")
        XCTAssertTrue(jumped, "jump must work against the re-created DOM nodes")
        let current = await controller.currentSection()
        XCTAssertEqual(current, "fresh-section")
    }

    /// End-to-end model path: an external file edit must refresh the model's
    /// published outline (FileWatcher → reloadFromDisk → refreshOutline), not
    /// just the page-side cache. [REF:fr:live-reload]
    func testModelOutlineRefreshesOnLiveReload() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("doc.md")
        try "# First Title\n".write(to: file, atomically: true, encoding: .utf8)

        let model = DocumentModel()
        await model.start(text: try FileLoader.load(file), url: file)
        XCTAssertEqual(model.outline.map(\.id), ["first-title"])

        try "# Second Title\n\n## Child\n".write(to: file, atomically: true, encoding: .utf8)
        // Generous deadline: under full-suite load the watcher→render→refresh
        // chain can take well over the interactive ~1 s.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, model.outline.map(\.id) != ["second-title", "child"] {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(
            model.outline.map(\.id), ["second-title", "child"],
            "outline must follow the document across a live reload")
    }

    /// A loaded preview with a real viewport and a document tall enough that
    /// every section can reach the viewport top.
    private func makeTallPreview() async throws -> PreviewController {
        let controller = try await makeLoadedPreview()
        controller.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let filler = { (n: Int) in
            (1...n).map { "Paragraph \($0) lorem ipsum dolor sit amet." }
                .joined(separator: "\n\n")
        }
        await controller.render(
            """
            # Alpha

            \(filler(40))

            ## Beta

            \(filler(40))

            # Omega End

            \(filler(60))
            """)
        return controller
    }
}
