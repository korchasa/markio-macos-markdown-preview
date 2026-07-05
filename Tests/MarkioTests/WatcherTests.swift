import XCTest

@testable import Markio

/// External edits trigger a reload callback. [REF:fr:live-reload]
final class WatcherTests: XCTestCase {
    func testReloadsOnFileChange() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("note.md")
        try "first".write(to: file, atomically: true, encoding: .utf8)

        let changed = expectation(description: "watcher fired on file change")
        changed.assertForOverFulfill = false

        let watcher = FileWatcher(url: file) { changed.fulfill() }
        watcher.start()
        defer { watcher.stop() }

        // Give the source time to arm, then modify the file.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            try? "second".write(to: file, atomically: false, encoding: .utf8)
        }

        wait(for: [changed], timeout: 5.0)
    }
}
