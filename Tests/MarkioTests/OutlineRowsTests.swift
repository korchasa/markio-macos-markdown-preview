import AppKit
import MarkdownKit
import MarkioRender
import XCTest

@testable import Markio

/// The outline lists the boxes under their headings, one line each, and a
/// ticked one reads as finished.
@MainActor
final class OutlineRowsTests: XCTestCase {
    private func heading(_ block: Int32, level: Int, _ text: String) -> Document.Heading {
        Document.Heading(block: block, level: level, text: text, slug: text.lowercased())
    }

    private func entry(_ ordinal: Int, section: Int, checked: Bool, _ title: String)
        -> DocumentSummary.TaskEntry
    {
        DocumentSummary.TaskEntry(
            ordinal: ordinal, section: section, isChecked: checked, title: title)
    }

    func testBoxesSitUnderTheirHeadingsInDocumentOrder() {
        let outline = OutlineSidebar()
        outline.setHeadings([heading(2, level: 1, "Plan"), heading(9, level: 2, "Checks")])
        outline.addTasks(
            [
                entry(0, section: -1, checked: false, "Before the first heading"),
                entry(3, section: 0, checked: true, "Write it"),
                entry(10, section: 1, checked: false, "Run it"),
            ], complete: true)

        XCTAssertEqual(
            outline.rows.map { outline.label(of: $0) },
            ["Before the first heading", "Plan", "Write it", "Checks", "Run it"])
        // The scroll follows sections, so a heading has to be found by its own
        // index whatever rows sit between them.
        XCTAssertEqual(outline.headingRows, [1, 3])
    }

    func testATickedBoxIsStruckAndAnOpenOneIsNot() {
        let done = OutlineSidebar.taskTitle(entry(0, section: 0, checked: true, "Done"))
        let open = OutlineSidebar.taskTitle(entry(1, section: 0, checked: false, "Open"))
        XCTAssertNotNil(done.attribute(.strikethroughStyle, at: 0, effectiveRange: nil))
        XCTAssertNil(open.attribute(.strikethroughStyle, at: 0, effectiveRange: nil))
    }

    func testANewDocumentForgetsTheOldBoxes() {
        let outline = OutlineSidebar()
        outline.setHeadings([heading(2, level: 1, "Plan")])
        outline.addTasks([entry(3, section: 0, checked: false, "Write it")], complete: true)
        outline.setHeadings([heading(1, level: 1, "Other")])
        XCTAssertEqual(outline.rows.map { outline.label(of: $0) }, ["Other"])
    }
}
