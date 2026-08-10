import AppKit
import XCTest

@testable import Markio2

/// Store screenshots have one acceptable size and no tolerance around it.
///
/// The size cannot come from the window as it happens to open, nor from the
/// display the machine happens to have: `bitmapImageRepForCachingDisplay`
/// multiplies the view's bounds by the screen's backing scale, so the same code
/// yields 1920×1680 on this laptop and something else on the next one. These
/// tests pin the two things that must not drift — the pixel count, and the fact
/// that it does not depend on the screen.
@MainActor
final class SnapshotTests: XCTestCase {
    private static let autosaveKey = "NSWindow Frame MarkioDocumentWindow"
    private var savedFrame: Any?

    override func setUp() {
        super.setUp()
        savedFrame = UserDefaults.standard.object(forKey: Self.autosaveKey)
        UserDefaults.standard.removeObject(forKey: Self.autosaveKey)
    }

    override func tearDown() {
        if let savedFrame {
            UserDefaults.standard.set(savedFrame, forKey: Self.autosaveKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.autosaveKey)
        }
        super.tearDown()
    }

    private func window() throws -> NSWindow {
        let document = MarkdownDocument()
        try document.read(
            from: Data("# One\n\nTwo paragraphs, so there is something to lay out.\n".utf8),
            ofType: "net.daringfireball.markdown")
        let controller = DocumentWindowController(document: document)
        return try XCTUnwrap(controller.window)
    }

    /// The one size the App Store accepts for a Mac screenshot.
    func testASnapshotIsExactlyTheStoreSize() throws {
        let rep = try Snapshot.image(of: try window(), size: Snapshot.storeSize)
        XCTAssertEqual(rep.pixelsWide, 2880)
        XCTAssertEqual(rep.pixelsHigh, 1800)
    }

    /// A window that opened at some other size is resized to order rather than
    /// photographed as found — otherwise the first shot of a run and the fifth
    /// come out different sizes.
    func testAWindowIsResizedToTheSizeAsked() throws {
        let window = try window()
        window.setContentSize(NSSize(width: 700, height: 500))
        let rep = try Snapshot.image(of: window, size: NSSize(width: 800, height: 600))
        XCTAssertEqual(rep.pixelsWide, 1600)
        XCTAssertEqual(rep.pixelsHigh, 1200)
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(content.frame.width, 800, accuracy: 1)
    }

    /// The bitmap carries its size in points as well as pixels, so anything
    /// reading it back sees a 2× image rather than a huge 1× one.
    func testTheBitmapKnowsItIsDrawnAtTwice() throws {
        let rep = try Snapshot.image(of: try window(), size: Snapshot.storeSize)
        XCTAssertEqual(rep.size.width, Snapshot.storeSize.width, accuracy: 0.5)
        XCTAssertEqual(rep.size.height, Snapshot.storeSize.height, accuracy: 0.5)
    }

    /// The drawing has to cover the whole bitmap, not sit in a corner of it.
    ///
    /// A bitmap context maps one unit to one pixel whatever the rep's size in
    /// points says, so drawing a 1440×900 view into a 2880×1800 buffer without
    /// scaling the transform first fills a quarter of it and leaves the rest
    /// untouched — transparent, and white once it is encoded. The picture is
    /// the right size and useless. Corners are the cheapest place to see it:
    /// an untouched pixel has an alpha of zero.
    func testTheDrawingCoversTheWholeBitmap() throws {
        let rep = try Snapshot.image(of: try window(), size: Snapshot.storeSize)
        let corners = [
            (10, 10),
            (rep.pixelsWide - 10, 10),
            (10, rep.pixelsHigh - 10),
            (rep.pixelsWide - 10, rep.pixelsHigh - 10),
        ]
        for (x, y) in corners {
            let colour = try XCTUnwrap(rep.colorAt(x: x, y: y), "no pixel at \(x),\(y)")
            XCTAssertEqual(
                colour.alphaComponent, 1, accuracy: 0.01,
                "the pixel at \(x),\(y) was never drawn into")
        }
    }

    /// A shot plan is read from beside the document it describes. A missing or
    /// malformed plan stops the run: a store screenshot silently skipped is
    /// worse than one that never got made.
    func testAPlanIsReadFromBesideItsDocument() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = directory.appendingPathComponent("demo.md")
        try Data("# One\n".utf8).write(to: document)
        try Data(
            """
            {"shots": [{"file": "01-light.png", "appearance": "light"}]}
            """.utf8
        ).write(to: directory.appendingPathComponent("demo.snapshot.json"))

        let plan = try Snapshot.Plan.beside(document)
        XCTAssertEqual(plan.shots.count, 1)
        XCTAssertEqual(plan.shots[0].file, "01-light.png")
        XCTAssertEqual(plan.shots[0].appearance, .light)
    }

    func testAMissingPlanIsAnError() throws {
        let document = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).md")
        XCTAssertThrowsError(try Snapshot.Plan.beside(document))
    }
}
