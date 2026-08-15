import AppKit
import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// What the document tells the system about itself.
@MainActor
final class DocumentAccessibilityTests: XCTestCase {
    /// The view inside a scroll view, the way the app builds it.
    ///
    /// This is not ceremony. On its own the view grows to the height of the
    /// whole document, so `visibleRect` becomes the whole document and every
    /// block counts as on screen — the first version of these tests published
    /// all 800 blocks of a long file and looked like a defect in the view. What
    /// bounds the visible rectangle is the clip view, and the app always has
    /// one.
    private func view(text: String, height: CGFloat = 600) -> DocumentView {
        let layout = DocumentLayout(
            document: Document(text: text), theme: Theme(isDark: false), columnWidth: 520)
        let view = DocumentView(layout: layout)
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: height))
        scrollView.documentView = view
        view.frame = CGRect(x: 0, y: 0, width: 600, height: height)
        scrollView.layoutSubtreeIfNeeded()
        // Nothing is laid out until it is about to be drawn, so a view that has
        // never been through a draw pass has no boxes to publish.
        view.viewWillDraw()
        return view
    }

    func testTheTextOnScreenIsPublishedToTheSystem() throws {
        let view = view(
            text: """
                # Refactor report

                I read 214 files and changed 18 of them.
                """)

        let children = try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
        let spoken = children.compactMap { $0.accessibilityValue() as? String }

        XCTAssertTrue(
            spoken.contains { $0.contains("Refactor report") },
            "the heading on screen is not in the accessibility tree: \(spoken)")
        XCTAssertTrue(
            spoken.contains { $0.contains("214 files") },
            "the paragraph on screen is not in the accessibility tree: \(spoken)")
    }

    func testAViewThatDrawsIsNotAnEmptyRectangle() throws {
        let view = view(text: "# Title\n\nBody.")
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .group)
    }

    func testBlocksWithNothingToReadAreLeftOut() throws {
        // A thematic break draws a line and says nothing. An element for it
        // would make VoiceOver stop on a rule and read out silence.
        let view = view(text: "# Title\n\n---\n\nBody.")
        let children = try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertFalse(
            children.contains { ($0.accessibilityValue() as? String ?? "").isEmpty },
            "an element with no text reached the accessibility tree")
    }

    func testOnlyWhatIsOnScreenIsPublished() throws {
        // The whole point of the renderer is that length costs nothing, and an
        // accessibility tree built from the entire document would undo it.
        let long = (1...400).map { "## Section \($0)\n\nSome text in section \($0).\n" }
            .joined()
        let view = view(text: long, height: 300)

        let children = try XCTUnwrap(view.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertLessThan(
            children.count, 100,
            "the accessibility tree walked far past the screen: \(children.count) elements")
        XCTAssertFalse(children.isEmpty, "nothing was published at all")
    }
}
