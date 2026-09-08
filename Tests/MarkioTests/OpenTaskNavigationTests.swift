import XCTest

@testable import Markio

/// From one open box to the next, and round again at the end.
@MainActor
final class OpenTaskNavigationTests: XCTestCase {
    private let open = [4, 9, 20]

    func testTheNextBoxIsTheFirstOneAfterThePosition() {
        XCTAssertEqual(DocumentWindowController.nextOpenTask(after: 0, in: open), 4)
        XCTAssertEqual(DocumentWindowController.nextOpenTask(after: 4, in: open), 9)
        XCTAssertEqual(DocumentWindowController.nextOpenTask(after: 10, in: open), 20)
    }

    func testTheLastBoxLeadsBackToTheFirst() {
        XCTAssertEqual(DocumentWindowController.nextOpenTask(after: 20, in: open), 4)
        XCTAssertEqual(DocumentWindowController.nextOpenTask(after: 500, in: open), 4)
    }

    func testThePreviousBoxMirrorsIt() {
        XCTAssertEqual(DocumentWindowController.previousOpenTask(before: 10, in: open), 9)
        XCTAssertEqual(DocumentWindowController.previousOpenTask(before: 9, in: open), 4)
        XCTAssertEqual(DocumentWindowController.previousOpenTask(before: 4, in: open), 20)
        XCTAssertEqual(DocumentWindowController.previousOpenTask(before: 0, in: open), 20)
    }

    /// The whole move, through a real window: the count finds the boxes, the
    /// shortcut's action steps to the first open one after the top, and the
    /// next press to the one after that.
    func testTheActionStepsThroughTheOpenBoxes() throws {
        let document = MarkdownDocument()
        try document.read(
            from: Data("- [x] Done\n- [ ] First\n- [ ] Second\n".utf8),
            ofType: "net.daringfireball.markdown")
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        let deadline = Date().addingTimeInterval(5)
        while controller.openTasks.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(controller.openTasks, [1, 2])

        controller.nextOpenTask(nil)
        XCTAssertEqual(controller.currentOpenTask, 1)
        controller.nextOpenTask(nil)
        XCTAssertEqual(controller.currentOpenTask, 2)
        controller.nextOpenTask(nil)
        XCTAssertEqual(controller.currentOpenTask, 1)
        controller.previousOpenTask(nil)
        XCTAssertEqual(controller.currentOpenTask, 2)
        controller.close()
    }

    func testNoOpenBoxesMeansNowhereToGo() {
        XCTAssertNil(DocumentWindowController.nextOpenTask(after: 0, in: []))
        XCTAssertNil(DocumentWindowController.previousOpenTask(before: 0, in: []))
    }
}
