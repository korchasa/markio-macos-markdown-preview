import AppKit
import XCTest

@testable import Markio
@testable import MarkioRender

/// The document window itself: how big it opens, and what a drag on its edge is
/// allowed to do to it.
@MainActor
final class DocumentWindowTests: XCTestCase {
    /// Where `windowFrameAutosaveName` keeps the size of the last window.
    private static let autosaveKey = "NSWindow Frame MarkioDocumentWindow"
    private var savedFrame: Any?

    /// Each test opens its window at the size the code chooses, not at the size
    /// the test before it dragged one to — and puts back whatever was there, so
    /// a test run never decides how wide the app opens afterwards.
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

    private func controller() throws -> DocumentWindowController {
        let document = MarkdownDocument()
        try document.read(
            from: Data("# One\n\nTwo paragraphs, so there is something to lay out.\n".utf8),
            ofType: "net.daringfireball.markdown")
        return DocumentWindowController(document: document)
    }

    /// The scroller holding the document, found the way the app's own capture
    /// harness finds it: the one whose document view is the document.
    private func documentScroller(in view: NSView) -> NSScrollView? {
        if let scroller = view as? NSScrollView, scroller.documentView is DocumentView,
            !scroller.isHidden
        {
            return scroller
        }
        for child in view.subviews {
            if let found = documentScroller(in: child) { return found }
        }
        return nil
    }

    /// Coming back to a document opens it where it was left.
    ///
    /// The restore has two parts and both were wrong at once: the scroll went
    /// through the document view, which does nothing before it has drawn, and
    /// the position was saved again the moment the window appeared — at the top
    /// — so one failed restore erased the memory for good.
    func testAReaderComesBackToWhereTheyLeftTheDocument() throws {
        let url = URL(fileURLWithPath: "/tmp/markio-restore-\(UUID().uuidString).md")
        let text = (0..<300)
            .map { "Paragraph \($0), long enough to take a line of its own." }
            .joined(separator: "\n\n")
        let document = MarkdownDocument()
        try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        document.fileURL = url
        Preferences.setScrollPosition(1500, for: url)

        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)

        let root = try XCTUnwrap(controller.window?.contentView)
        let scroller = try XCTUnwrap(documentScroller(in: root))
        // Straight away: the scroll goes through the clip view, which needs no
        // drawn document view. Asking the document view to scroll itself does
        // nothing at all before it has drawn, and that is what left every
        // reader at the first line.
        XCTAssertEqual(scroller.contentView.bounds.minY, 1500, accuracy: 1)
        // The second half of the restore lands on the next turn of the run
        // loop, once the blocks it scrolled onto have been measured.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(scroller.contentView.bounds.minY, 1500, accuracy: 1)
        // And the position it restored is still the position it remembers.
        XCTAssertEqual(try XCTUnwrap(Preferences.scrollPosition(for: url)), 1500, accuracy: 1)
    }

    // MARK: - Holding the place across a swap

    /// A long report whose blocks differ in height and in text, so a block can
    /// be told apart from its neighbours and a position inside it means something.
    private func report(_ count: Int = 300) -> String {
        (0..<count).map { index in
            index % 10 == 0
                ? "## Section \(index)"
                : "Paragraph \(index). "
                    + String(repeating: "Words that wrap onto another line. ", count: index % 4 + 2)
        }.joined(separator: "\n\n") + "\n"
    }

    private struct Opened {
        let document: MarkdownDocument
        let controller: DocumentWindowController
        let window: NSWindow
        let view: DocumentView
    }

    /// The report in a window of the size the defect was found in, scrolled
    /// to the middle and drawn there.
    private func openScrolled(_ text: String) throws -> Opened {
        let document = MarkdownDocument()
        try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        let controller = DocumentWindowController(document: document)
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 760), display: true)
        window.layoutIfNeeded()
        let scroller = try XCTUnwrap(documentScroller(in: try XCTUnwrap(window.contentView)))
        let view = try XCTUnwrap(scroller.documentView as? DocumentView)
        view.viewWillDraw()
        scroller.contentView.scroll(to: NSPoint(x: 0, y: 2537))
        scroller.reflectScrolledClipView(scroller.contentView)
        view.viewWillDraw()
        return Opened(document: document, controller: controller, window: window, view: view)
    }

    /// The block at the top of the view, by its source text, and how far down
    /// into it the top of the view sits.
    private func top(of opened: Opened) throws -> (text: String, into: CGFloat) {
        let view = opened.view
        let clip = try XCTUnwrap(view.enclosingScrollView).contentView
        view.viewWillDraw()
        let y = clip.bounds.minY - view.verticalPadding
        let ordinal = view.layout.index(atOffset: y)
        let document = view.layout.document
        let text = document.text(document.sourceRange(of: document.leaves[ordinal]))
        return (text, y - view.layout.offset(of: ordinal))
    }

    /// What the file watcher does when another process writes the file.
    private func rewrite(_ opened: Opened, to text: String) throws {
        try opened.document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        opened.controller.documentDidReload()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    /// An agent appends to the report below the reader; the reader's line does
    /// not move. It used to jump up by a quarter of the window plus however far
    /// into its block the reader had scrolled.
    func testAReloadKeepsTheReaderOnTheSameLine() throws {
        let opened = try openScrolled(report())
        let before = try top(of: opened)
        XCTAssertGreaterThan(before.into, 1, "the reader is inside a block, not on its edge")

        try rewrite(opened, to: report() + "\nOne more paragraph at the end.\n")

        let after = try top(of: opened)
        XCTAssertEqual(after.text, before.text)
        XCTAssertEqual(after.into, before.into, accuracy: 1)
        opened.window.close()
    }

    /// A report rewritten every few seconds walked the reader towards its
    /// beginning, one jump per rewrite.
    func testRepeatedReloadsDoNotDrift() throws {
        let opened = try openScrolled(report())
        let before = try top(of: opened)
        var text = report()
        for round in 1...3 {
            text += "\nAppended in round \(round).\n"
            try rewrite(opened, to: text)
            let after = try top(of: opened)
            XCTAssertEqual(after.text, before.text, "round \(round)")
            XCTAssertEqual(after.into, before.into, accuracy: 1, "round \(round)")
        }
        opened.window.close()
    }

    /// Blocks added above the reader push the block they were reading further
    /// down the file; the view goes with it rather than staying on its old
    /// number.
    func testTextAddedAboveDoesNotMoveTheReader() throws {
        let opened = try openScrolled(report())
        let before = try top(of: opened)
        let added = (1...5).map { "Inserted paragraph \($0) at the top." }.joined(separator: "\n\n")

        try rewrite(opened, to: added + "\n\n" + report())

        let after = try top(of: opened)
        XCTAssertEqual(after.text, before.text)
        XCTAssertEqual(after.into, before.into, accuracy: 1)
        opened.window.close()
    }

    /// Starting a comparison puts the removed text back above the reader,
    /// switching to side by side narrows the column, and stopping takes the
    /// removed text away again. Through all three the reader stays on the
    /// block they were reading.
    func testComparingKeepsTheReaderInPlace() throws {
        let opened = try openScrolled(report())
        let before = try top(of: opened)
        let baseline = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).md")
        let removed = (1...5).map { "Removed paragraph \($0) of the old version." }
            .joined(separator: "\n\n")
        try Data((removed + "\n\n" + report()).utf8).write(to: baseline)
        defer { try? FileManager.default.removeItem(at: baseline) }

        opened.controller.compare(with: baseline, sideBySide: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(try top(of: opened).text, before.text, "inline")

        opened.controller.toggleSideBySide(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(try top(of: opened).text, before.text, "side by side")

        opened.controller.stopComparing(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(try top(of: opened).text, before.text, "stopped")
        opened.window.close()
    }

    /// The map has a lane of its own: the scroller to the right of it, the text
    /// to the left, and neither underneath it.
    ///
    /// Both halves were wrong at once. The strip was pinned to the trailing
    /// edge of the scroll view, where the scroller draws, so it covered the
    /// scroller; and the reading area was told about the strip through
    /// `contentInsets`, which shifts what can be scrolled to without narrowing
    /// the document view — so a document wide enough ran its text under the map.
    func testTheMapTakesALaneOfItsOwnBesideTheScroller() throws {
        let text = (0..<300)
            .map { "Paragraph \($0), long enough to take a line of its own." }
            .joined(separator: "\n\n")
        let document = MarkdownDocument()
        try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        let root = try XCTUnwrap(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()

        let scroller = try XCTUnwrap(documentScroller(in: root))
        let map = try XCTUnwrap(mapStrip(in: root))
        let documentView = try XCTUnwrap(scroller.documentView)
        XCTAssertFalse(map.isHidden, "a document this long is what the map is for")

        let mapFrame = map.convert(map.bounds, to: root)
        let scrollFrame = scroller.convert(scroller.bounds, to: root)
        let textFrame = documentView.convert(documentView.bounds, to: root)

        // A scroller's width of clear space between the map and the edge.
        XCTAssertEqual(
            scrollFrame.maxX - mapFrame.maxX, DocumentWindowController.scrollerLane, accuracy: 1)
        // And the text stops where the map starts, however wide the window is.
        XCTAssertLessThanOrEqual(textFrame.maxX, mapFrame.minX + 1)
        XCTAssertGreaterThan(textFrame.width, 100, "the reading area is still the bulk of it")
    }

    /// The window says which file it is showing, in full.
    ///
    /// Two documents called `notes.md` in different folders are one window
    /// title apart, and the app sets the title to the path for exactly that
    /// reason. Setting `window.title` by hand was not enough: `NSDocument`
    /// syncs the title from the display name afterwards, and the running app
    /// showed the bare file name.
    func testTheWindowTitleIsTheWholePath() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("markio-title-\(UUID().uuidString)")
            .appendingPathComponent("notes.md")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# Notes\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let document = MarkdownDocument()
        try document.read(from: Data(contentsOf: url), ofType: "net.daringfireball.markdown")
        document.fileURL = url
        let controller = DocumentWindowController(document: document)
        document.addWindowController(controller)
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.title, url.path)

        // And it survives the sync AppKit runs on its own — which is the half
        // that was missing.
        controller.synchronizeWindowTitleWithDocumentName()
        XCTAssertEqual(window.title, url.path)
    }

    /// The widest reading column a reader can ask for still stops at the map.
    ///
    /// The column was fitted to the clip view, which runs on underneath the
    /// strip, so a wide column reached past the map's left edge and was cut off
    /// there — from a reader's chair, text running onto the map.
    func testTheWidestColumnStillStopsAtTheMap() throws {
        let saved = UserDefaults.standard.object(forKey: "readingWidthCharacters")
        UserDefaults.standard.set(
            Preferences.widthRange.upperBound, forKey: "readingWidthCharacters")
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: "readingWidthCharacters")
            } else {
                UserDefaults.standard.removeObject(forKey: "readingWidthCharacters")
            }
        }

        let text = (0..<300)
            .map { "Paragraph \($0), long enough to take a line of its own." }
            .joined(separator: "\n\n")
        let document = MarkdownDocument()
        try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        let root = try XCTUnwrap(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()

        let map = try XCTUnwrap(mapStrip(in: root))
        XCTAssertFalse(map.isHidden, "a document this long is what the map is for")
        let scroller = try XCTUnwrap(documentScroller(in: root))
        let page = try XCTUnwrap(scroller.documentView as? DocumentView)
        // The column, where it is drawn, ends inside the page — and the page
        // ends where the map begins, which the test above holds to.
        XCTAssertLessThanOrEqual(page.contentX + page.layout.columnWidth, page.frame.width + 1)
    }

    /// The find bar ends where the map begins.
    ///
    /// Both were pinned to the scroll view's trailing edge and nothing kept
    /// them apart, so with matches on the map — which is exactly when the bar
    /// is open — the count and the arrows sat over the strip, its marks running
    /// through the digits.
    func testTheFindBarStaysLeftOfTheMap() throws {
        let text = (0..<300)
            .map { "Paragraph \($0) mentions the ledger, long enough to take a line." }
            .joined(separator: "\n\n")
        let document = MarkdownDocument()
        try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        let controller = DocumentWindowController(document: document)
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: 900), display: true)
        controller.showFind(nil)
        controller.find("ledger")
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()

        let map = try XCTUnwrap(mapStrip(in: root))
        let bar = try XCTUnwrap(findBar(in: root))
        XCTAssertFalse(map.isHidden, "matches put the map on screen")
        XCTAssertFalse(bar.isHidden)
        let mapFrame = map.convert(map.bounds, to: root)
        let barFrame = bar.convert(bar.bounds, to: root)
        XCTAssertLessThanOrEqual(barFrame.maxX, mapFrame.minX)
        window.close()
    }

    private func findBar(in view: NSView) -> FindBar? {
        if let bar = view as? FindBar { return bar }
        for child in view.subviews {
            if let found = findBar(in: child) { return found }
        }
        return nil
    }

    private func mapStrip(in view: NSView) -> DocumentMapStrip? {
        if let strip = view as? DocumentMapStrip { return strip }
        for child in view.subviews {
            if let found = mapStrip(in: child) { return found }
        }
        return nil
    }

    private func window() throws -> NSWindow {
        try XCTUnwrap(try controller().window)
    }

    /// A drag on a window edge reaches the layout as a size constraint at
    /// `dragThatCanResizeWindow`, which is priority 510. Anything the window's
    /// own content asks for above that outranks the drag, and the window stops
    /// moving — which is exactly what two `.defaultHigh` size preferences did.
    func testADragOnTheEdgeOutranksThePreferredSize() throws {
        let window = try window()
        let content = try XCTUnwrap(window.contentView)
        window.layoutIfNeeded()
        // The preference has to be a preference: the window opens larger than
        // the sizes dragged to below, or the test would prove nothing.
        XCTAssertGreaterThan(content.frame.width, 700)
        XCTAssertGreaterThan(content.frame.height, 500)

        let narrower = content.widthAnchor.constraint(equalToConstant: 700)
        narrower.priority = NSLayoutConstraint.Priority(510)
        narrower.isActive = true
        window.layoutIfNeeded()
        XCTAssertEqual(content.frame.width, 700, accuracy: 1)

        let shorter = content.heightAnchor.constraint(equalToConstant: 500)
        shorter.priority = NSLayoutConstraint.Priority(510)
        shorter.isActive = true
        window.layoutIfNeeded()
        XCTAssertEqual(content.frame.height, 500, accuracy: 1)
    }

    /// Nothing else in the window asks for a size, so the preference is what the
    /// first window opens at — a lower priority must not cost it that.
    func testTheFirstWindowOpensAtTheReadingSize() throws {
        let window = try window()
        let content = try XCTUnwrap(window.contentView)
        window.layoutIfNeeded()
        // 810 of reading area and the 30-point bottom bar.
        XCTAssertEqual(content.frame.height, 840, accuracy: 1)
    }

    /// Putting the baseline in a column of its own must not shrink the window.
    ///
    /// The divider between the two columns is a separator box, and a separator
    /// box that has no frame yet reports an intrinsic height of one point and
    /// holds it at 750 — above the window's own size preference at 250. So the
    /// window used to be fitted to that one point and fell to the required
    /// floor: 200 points of reading area over the 30-point bottom bar, a title
    /// bar above a sliver, below even the window's declared minimum of 320. The
    /// store's comparison screenshot came out of that — two columns of content
    /// along the bottom of an empty page.
    func testSideBySideDoesNotCollapseTheWindow() throws {
        let controller = try controller()
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        window.layoutIfNeeded()
        let before = content.frame.height
        XCTAssertGreaterThan(before, 500, "the window has to start tall to prove anything")

        let baseline = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).md")
        try Data("# One\n\nOne paragraph, so the two versions differ.\n".utf8).write(to: baseline)
        defer { try? FileManager.default.removeItem(at: baseline) }

        controller.compare(with: baseline, sideBySide: true)
        window.layoutIfNeeded()
        XCTAssertEqual(content.frame.height, before, accuracy: 1)
    }

    /// The two columns of a comparison are typeset at one width.
    ///
    /// The panes are equally wide, but the map and the scroller take their
    /// room from the right-hand one only. Each column was fitted to its own
    /// pane, so in a window too narrow for two full columns the right one was
    /// narrower, its lines broke elsewhere, and the shared text stood lower
    /// and lower on that side — while the scroll offset is copied one to one.
    func testTheTwoColumnsOfAComparisonAreOneWidth() throws {
        let text = (1...120).map { "Paragraph \($0), long enough to wrap at any width a pane has." }
            .joined(separator: "\n\n")
        let document = MarkdownDocument()
        try document.read(from: Data(text.utf8), ofType: "net.daringfireball.markdown")
        let controller = DocumentWindowController(document: document)
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 700), display: true)
        window.layoutIfNeeded()

        let baseline = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).md")
        try Data((text + "\n\nOne more paragraph in the old version.\n").utf8).write(to: baseline)
        defer { try? FileManager.default.removeItem(at: baseline) }
        let map = Preferences.mapVisible
        Preferences.mapVisible = true
        defer { Preferences.mapVisible = map }

        controller.compare(with: baseline, sideBySide: true)
        window.layoutIfNeeded()
        func views(in view: NSView) -> [DocumentView] {
            var found: [DocumentView] = []
            if let scroll = view as? NSScrollView, !scroll.isHidden,
                let inner = scroll.documentView as? DocumentView
            {
                inner.viewWillDraw()
                found.append(inner)
            }
            for child in view.subviews { found += views(in: child) }
            return found
        }
        let columns = views(in: try XCTUnwrap(window.contentView))
        XCTAssertEqual(columns.count, 2)
        // The window is narrow enough that a column has to give way, or the
        // test proves nothing.
        let preferred = Theme(isDark: false).columnWidth(characters: Preferences.readingWidth)
        XCTAssertLessThan(columns.map(\.layout.columnWidth).min() ?? 0, preferred)
        XCTAssertEqual(columns[0].layout.columnWidth, columns[1].layout.columnWidth, accuracy: 0.5)
        window.close()
    }

    /// A click on a link out of the document, from the click itself to the URL
    /// that would have been handed to the browser.
    ///
    /// This was the one item of the parity sweep left to a person, on the
    /// grounds that checking it opens a browser. It does not have to: the
    /// controller now says where it would send the reader, and the test reads
    /// that instead of watching a window appear.
    func testAClickOnAnExternalLinkGoesToItsAddress() throws {
        let document = MarkdownDocument()
        try document.read(
            from: Data("Read [the notes](https://example.com/notes) first.\n".utf8),
            ofType: "net.daringfireball.markdown")
        let controller = DocumentWindowController(document: document)
        var opened: [URL] = []
        controller.openExternal = { opened.append($0) }

        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        let scroller = try XCTUnwrap(documentScroller(in: try XCTUnwrap(window.contentView)))
        let view = try XCTUnwrap(scroller.documentView as? DocumentView)
        view.viewWillDraw()

        // The link's own rectangle, in the view's coordinates: a click anywhere
        // else proves nothing about links.
        let box = try XCTUnwrap(view.layout.box(at: 0))
        let region = try XCTUnwrap(box.links.first)
        let point = CGPoint(
            x: region.rect.midX + view.contentX,
            y: view.layout.offset(of: 0) + view.verticalPadding + region.rect.midY)
        let click = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        view.mouseDown(with: click)

        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/notes"])
    }
}
