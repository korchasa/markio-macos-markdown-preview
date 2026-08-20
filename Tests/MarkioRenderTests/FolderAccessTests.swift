import AppKit
import XCTest

@testable import MarkioRender

/// The grants that let a sandboxed build read what sits beside a document.
@MainActor
final class FolderAccessTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "FolderAccessTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.standardizedFileURL
    }

    func testNothingIsGrantedUntilSomebodyGrantsIt() throws {
        let access = FolderAccess(defaults: defaults)
        let folder = try temporaryFolder()
        XCTAssertFalse(access.covers(folder.appendingPathComponent("pic.png")))
        XCTAssertTrue(access.granted.isEmpty)
    }

    /// A grant is on the folder, so everything under it is readable — a picture
    /// beside the document and one in a subfolder alike.
    func testAGrantCoversWhatIsInsideIt() throws {
        let access = FolderAccess(defaults: defaults)
        let folder = try temporaryFolder()
        XCTAssertTrue(access.remember(folder))
        XCTAssertTrue(access.covers(folder.appendingPathComponent("pic.png")))
        XCTAssertTrue(access.covers(folder.appendingPathComponent("images/deep/pic.png")))
        // The folder itself is not something inside it, and neither is its
        // neighbour — a grant that leaked upwards would be the whole disk.
        XCTAssertFalse(access.covers(folder))
        XCTAssertFalse(access.covers(folder.deletingLastPathComponent()))
        // A folder whose name merely starts the same way is a different folder.
        XCTAssertFalse(
            access.covers(
                folder.deletingLastPathComponent()
                    .appendingPathComponent(folder.lastPathComponent + "-other/pic.png")))
    }

    /// The panel hands back the path the reader saw, and the document arrives
    /// with its symlinks resolved: `/tmp/notes` and `/private/tmp/notes` are
    /// one folder, and a grant on either covers the other.
    func testAFolderIsTheSameFolderWhicheverWayItIsSpelt() throws {
        let access = FolderAccess(defaults: defaults)
        // `/tmp` is a symlink to `/private/tmp`, so these two spellings are the
        // real pair a panel and a document arrive with — this is what the
        // sandboxed probe produced — and not a contrived one.
        let asThePanelGivesIt = URL(fileURLWithPath: "/tmp/folder-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: asThePanelGivesIt, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: asThePanelGivesIt) }
        let asTheDocumentArrives = URL(fileURLWithPath: "/private" + asThePanelGivesIt.path)
        XCTAssertNotEqual(asThePanelGivesIt.path, asTheDocumentArrives.path)
        XCTAssertTrue(access.remember(asThePanelGivesIt))
        XCTAssertTrue(access.covers(asTheDocumentArrives.appendingPathComponent("pic.png")))
    }

    /// The grant is kept as a bookmark, which is the whole point of asking once
    /// rather than every morning.
    func testAGrantSurvivesTheAppThatMadeIt() throws {
        let folder = try temporaryFolder()
        XCTAssertTrue(FolderAccess(defaults: defaults).remember(folder))
        let later = FolderAccess(defaults: defaults)
        XCTAssertTrue(later.covers(folder.appendingPathComponent("pic.png")))
    }

    /// A file that cannot be read is a question for the reader — once per
    /// folder, however many pictures a document has in it.
    func testAnUnreadableFileAsksForItsFolderOnce() throws {
        let access = FolderAccess(defaults: defaults)
        let folder = try temporaryFolder()
        var asked: [URL] = []
        access.onNeedsGrant = { asked.append($0) }
        access.noteUnreadable(folder.appendingPathComponent("one.png"))
        access.noteUnreadable(folder.appendingPathComponent("two.png"))
        XCTAssertEqual(asked, [folder])
    }

    /// Inside a granted folder, a file that will not decode is a broken file
    /// and not a locked one: asking for the folder again would be a panel the
    /// reader has already answered.
    func testAFileInsideAGrantedFolderIsNeverAskedAbout() throws {
        let access = FolderAccess(defaults: defaults)
        let folder = try temporaryFolder()
        XCTAssertTrue(access.remember(folder))
        var asked: [URL] = []
        access.onNeedsGrant = { asked.append($0) }
        access.noteUnreadable(folder.appendingPathComponent("truncated.png"))
        XCTAssertTrue(asked.isEmpty)
    }
}
