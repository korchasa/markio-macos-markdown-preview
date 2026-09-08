import MarkioRender
import XCTest

@testable import Markio

/// The map marks where the open boxes are, so a long report shows at a glance
/// which stretch still has work in it.
@MainActor
final class DocumentMapStripTests: XCTestCase {
    func testOpenTasksAreMarked() {
        let strip = DocumentMapStrip(theme: Theme(isDark: false))
        XCTAssertEqual(strip.openTaskLines, [])
        strip.setOpenTasks(lines: [3, 40, 41])
        XCTAssertEqual(strip.openTaskLines, [3, 40, 41])
        strip.setOpenTasks(lines: [])
        XCTAssertEqual(strip.openTaskLines, [])
    }
}
