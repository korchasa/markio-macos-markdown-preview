import AppKit
import XCTest

@testable import Markio

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

    /// Not one pixel of a store picture may be transparent.
    ///
    /// The corners above are the cheap version of this and they passed while
    /// the set shipped with a hole in it: the outline sidebar is drawn as a
    /// material by the window server, which an offscreen context has none of,
    /// so its background never arrived and only its text did. On white it read
    /// as a sidebar; on black it read as a black rectangle.
    func testNothingInAStorePictureIsTransparent() throws {
        let document = MarkdownDocument()
        try document.read(
            from: Data("# One\n\n## Two\n\nEnough headings for an outline.\n".utf8),
            ofType: "net.daringfireball.markdown")
        let controller = DocumentWindowController(document: document)
        controller.setOutline(visible: true)
        let window = try XCTUnwrap(controller.window)
        let rep = try Snapshot.image(of: window, size: Snapshot.storeSize)
        XCTAssertEqual(rep.samplesPerPixel, 4, "the scan below reads the fourth byte")
        let data = try XCTUnwrap(rep.bitmapData)
        var clear = 0
        for row in 0..<rep.pixelsHigh {
            let start = row * rep.bytesPerRow
            for column in 0..<rep.pixelsWide where data[start + column * 4 + 3] != 255 {
                clear += 1
            }
        }
        XCTAssertEqual(clear, 0, "\(clear) pixels were never painted")
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

    /// The same document has to come out the same picture on any machine.
    ///
    /// The reading width is the reader's, kept in the defaults a snapshot run
    /// reads too, so the pictures used to be drawn at whatever the slider was
    /// last left at — a session that widened the column to 130 shipped 130 to
    /// the App Store. Two runs over one document, with two different widths
    /// stored, must therefore draw the same pixels.
    func testAStoredReadingWidthDoesNotReachTheStorePictures() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = directory.appendingPathComponent("demo.md")
        let text = """
            # Wide enough

            A paragraph long enough that the column it is broken into changes \
            where the words fall.
            """
        try Data(text.utf8).write(to: document)
        try Data(
            """
            {"shots": [{"file": "01-light.png", "appearance": "light"}]}
            """.utf8
        ).write(to: directory.appendingPathComponent("demo.snapshot.json"))

        let saved = UserDefaults.standard.object(forKey: "readingWidthCharacters")
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: "readingWidthCharacters")
            } else {
                UserDefaults.standard.removeObject(forKey: "readingWidthCharacters")
            }
        }

        func shoot(storedWidth: Int) throws -> Data {
            UserDefaults.standard.set(storedWidth, forKey: "readingWidthCharacters")
            let out = directory.appendingPathComponent("out-\(storedWidth)")
            let markdown = MarkdownDocument()
            try markdown.read(
                from: Data(contentsOf: document), ofType: "net.daringfireball.markdown")
            let controller = DocumentWindowController(document: markdown)
            defer { controller.window?.close() }
            try Snapshot.run(document: document, into: out, using: controller)
            return try Data(contentsOf: out.appendingPathComponent("01-light.png"))
        }

        XCTAssertEqual(try shoot(storedWidth: 60), try shoot(storedWidth: 130))
    }

    /// Where the document was last left must not reach the store pictures.
    ///
    /// The same trap as the reading width, one turn of the run loop later:
    /// opening a document schedules the restore of its remembered position,
    /// and that scroll lands in the middle of the first shot. The picture then
    /// shows wherever the run before it finished — the set shipped on
    /// 2026-08-24 had its first shot two thirds of the way down the document.
    func testARememberedPositionDoesNotReachTheStorePictures() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = directory.appendingPathComponent("demo.md")
        let text = (1...40).map { "Paragraph \($0), long enough to take a line of its own.\n" }
            .joined(separator: "\n")
        try Data("# Long\n\n\(text)".utf8).write(to: document)

        let saved = Preferences.remembersPosition
        defer { Preferences.remembersPosition = saved }
        Preferences.setScrollPosition(4000, for: document)

        Preferences.remembersPosition = false
        let markdown = try MarkdownDocument(
            contentsOf: document, ofType: "net.daringfireball.markdown")
        let controller = DocumentWindowController(document: markdown)
        defer { controller.window?.close() }
        // A window with real geometry, or the scroll has nowhere to go: the
        // restore clamps to the room below the fold, and in a window that was
        // never laid out that room is zero and any position looks obeyed.
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 600))
        // Showing the window is what asks for the restore, so a test that only
        // builds a controller never reaches the code it is about.
        controller.showWindow(nil)
        window.layoutIfNeeded()
        // The restore is scheduled on the next turn of the run loop, so give it
        // one before asking: the guard has to hold across that turn, not only
        // at the moment the document opens.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(controller.scrollOffsetForTesting, 0)
    }

    func testAMissingPlanIsAnError() throws {
        let document = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).md")
        XCTAssertThrowsError(try Snapshot.Plan.beside(document))
    }
}
