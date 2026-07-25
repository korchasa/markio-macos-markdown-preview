import AppKit
import XCTest

@testable import Markio

/// FR-COMPARE: inline-diff compare — the open document renders in its own
/// window with blocks added since a picked baseline marked, removed runs
/// inserted as dimmed blocks, and unchanged content untouched; Stop Comparing
/// restores the plain render; self-compare is a no-op.
final class CompareTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        suiteName = "markio-compare-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("markio-compare-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// A started document model over a real temp file, with an injected
    /// baseline picker that returns `pick` (nil = cancelled).
    @MainActor
    private func makeModel(
        file: String, text: String, pick: URL?
    ) async throws -> DocumentModel {
        let url = tempDir.appendingPathComponent(file)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let model = DocumentModel(
            defaults: defaults,
            comparePick: { _, completion in completion(pick) }
        )
        model.preview.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        await model.start(text: text, url: url)
        return model
    }

    @MainActor
    private func writeBaseline(_ file: String, _ text: String) throws -> URL {
        let url = tempDir.appendingPathComponent(file)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @MainActor
    private func count(_ model: DocumentModel, selector: String) async throws -> Int {
        let raw = try await model.preview.evaluate(
            "document.querySelectorAll('\(selector)').length")
        return (raw as? NSNumber)?.intValue ?? -1
    }

    /// Poll until the model reports the expected compared state and the DOM
    /// predicate holds; compare rendering is asynchronous.
    @MainActor
    private func waitFor(
        _ predicate: @MainActor () async throws -> Bool
    ) async throws -> Bool {
        for _ in 0..<40 {
            if try await predicate() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return try await predicate()
    }

    /// A block present only in the current text carries the added marker;
    /// unchanged content stays unmarked.
    @MainActor
    func testDiffMarksAddedBlocks() async throws {
        let old = "# Title\n\nShared paragraph one.\n\nShared paragraph two.\n"
        let new =
            "# Title\n\nShared paragraph one.\n\nBrand new paragraph.\n\nShared paragraph two.\n"
        let baseline = try writeBaseline("v1.md", old)
        let model = try await makeModel(file: "v2.md", text: new, pick: baseline)

        model.startCompare()
        let marked = try await waitFor {
            try await self.count(model, selector: ".markio-diff-added") > 0
        }
        XCTAssertTrue(marked, "an added block must carry the added marker")
        XCTAssertTrue(model.isCompared)

        let markedText = try await model.preview.evaluate(
            "document.querySelector('.markio-diff-added').textContent")
        XCTAssertEqual(markedText as? String, "Brand new paragraph.")
        // Unchanged blocks carry no marker: exactly one added block.
        let addedCount = try await count(model, selector: ".markio-diff-added")
        XCTAssertEqual(addedCount, 1, "unchanged content must stay unmarked")
    }

    /// A run present only in the baseline is inserted as a removed block, at
    /// its original position, with its text rendered (findable content).
    @MainActor
    func testDiffInsertsRemovedBlocks() async throws {
        let old = "# Title\n\nDoomed paragraph.\n\nShared paragraph.\n"
        let new = "# Title\n\nShared paragraph.\n"
        let baseline = try writeBaseline("v1.md", old)
        let model = try await makeModel(file: "v2.md", text: new, pick: baseline)

        model.startCompare()
        let inserted = try await waitFor {
            try await self.count(model, selector: ".markio-diff-removed") > 0
        }
        XCTAssertTrue(inserted, "a removed run must be inserted into the view")

        let removedText = try await model.preview.evaluate(
            "document.querySelector('.markio-diff-removed').textContent")
        XCTAssertTrue(
            ((removedText as? String) ?? "").contains("Doomed paragraph."),
            "the removed run's rendered text must be present")
        // Position: the removed block precedes the shared paragraph.
        let order = try await model.preview.evaluate(
            """
            (function () {
              var removed = document.querySelector('.markio-diff-removed');
              var all = Array.prototype.slice.call(
                document.getElementById('content').children);
              var shared = all.filter(function (el) {
                return el.textContent.indexOf('Shared paragraph.') !== -1
                  && el !== removed;
              })[0];
              return all.indexOf(removed) < all.indexOf(shared);
            })()
            """)
        XCTAssertEqual(order as? Bool, true, "removed block sits at its original position")
    }

    /// Identical documents produce a clean view — no markers of either kind.
    @MainActor
    func testIdenticalDocumentsShowNoMarkers() async throws {
        let text = "# Title\n\nSame paragraph.\n"
        let baseline = try writeBaseline("v1.md", text)
        let model = try await makeModel(file: "v2.md", text: text, pick: baseline)

        model.startCompare()
        let compared = try await waitFor { model.isCompared }
        XCTAssertTrue(compared)
        try await Task.sleep(nanoseconds: 300_000_000)
        let added = try await count(model, selector: ".markio-diff-added")
        let removed = try await count(model, selector: ".markio-diff-removed")
        XCTAssertEqual(added, 0)
        XCTAssertEqual(removed, 0)
    }

    /// Stop Comparing restores the plain render: no markers, flag cleared.
    @MainActor
    func testStopComparingRestoresPlainRender() async throws {
        let old = "# Title\n\nGone.\n"
        let new = "# Title\n\nFresh.\n"
        let baseline = try writeBaseline("v1.md", old)
        let model = try await makeModel(file: "v2.md", text: new, pick: baseline)

        model.startCompare()
        _ = try await waitFor {
            try await self.count(model, selector: ".markio-diff-removed") > 0
        }

        model.stopCompare()
        let cleaned = try await waitFor {
            let added = try await self.count(model, selector: ".markio-diff-added")
            let removed = try await self.count(model, selector: ".markio-diff-removed")
            return added == 0 && removed == 0
        }
        XCTAssertTrue(cleaned, "plain render must carry no diff markers")
        XCTAssertFalse(model.isCompared)
        let body = try await model.preview.evaluate(
            "document.getElementById('content').textContent")
        XCTAssertTrue(((body as? String) ?? "").contains("Fresh."))
    }

    /// Split layout: baseline left with removed blocks marked, current right
    /// with added blocks marked, both full renders.
    @MainActor
    func testSplitLayoutShowsBothVersionsWithMarks() async throws {
        let old = "# Title\n\nDoomed paragraph.\n\nShared paragraph.\n"
        let new = "# Title\n\nShared paragraph.\n\nBrand new paragraph.\n"
        let baseline = try writeBaseline("v1.md", old)
        let model = try await makeModel(file: "v2.md", text: new, pick: baseline)
        model.setCompareSplit(true)

        model.startCompare()
        let split = try await waitFor {
            try await self.count(model, selector: ".markio-split") > 0
        }
        XCTAssertTrue(split, "split container must appear")

        let removedInOld = try await count(
            model, selector: ".markio-split-old .markio-diff-removed")
        XCTAssertEqual(removedInOld, 1, "removed block marked in the baseline column")
        let addedInNew = try await count(
            model, selector: ".markio-split-new .markio-diff-added")
        XCTAssertEqual(addedInNew, 1, "added block marked in the current column")
        // Full-fidelity renders: both columns carry the shared paragraph.
        let sharedCount = try await model.preview.evaluate(
            """
            Array.prototype.filter.call(
              document.querySelectorAll('.markio-split-col p'),
              function (p) { return p.textContent === 'Shared paragraph.'; }).length
            """)
        XCTAssertEqual((sharedCount as? NSNumber)?.intValue, 2)
    }

    /// Unchanged blocks after a change sit at the same vertical offset in
    /// both columns — the spacer alignment compensates differing heights.
    @MainActor
    func testSplitAlignsSharedBlocks() async throws {
        let longDeleted = (1...8).map { "Deleted line \($0) of a long removed paragraph." }
            .joined(separator: " ")
        let old = "# Title\n\n\(longDeleted)\n\nShared tail paragraph.\n"
        let new = "# Title\n\nShared tail paragraph.\n"
        let baseline = try writeBaseline("v1.md", old)
        let model = try await makeModel(file: "v2.md", text: new, pick: baseline)
        model.setCompareSplit(true)

        model.startCompare()
        _ = try await waitFor {
            try await self.count(model, selector: ".markio-split") > 0
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let offsets = try await model.preview.evaluate(
            """
            (function () {
              function top(sel) {
                var els = document.querySelectorAll(sel + ' p');
                for (var i = 0; i < els.length; i++) {
                  if (els[i].textContent === 'Shared tail paragraph.') {
                    return els[i].getBoundingClientRect().top;
                  }
                }
                return -1;
              }
              return [top('.markio-split-old'), top('.markio-split-new')];
            })()
            """)
        let pair = (offsets as? [NSNumber])?.map(\.doubleValue) ?? []
        XCTAssertEqual(pair.count, 2)
        XCTAssertGreaterThan(pair[0], 0)
        XCTAssertEqual(
            pair[0], pair[1], accuracy: 3,
            "shared blocks must sit at the same vertical offset")
    }

    /// The layout toggle re-renders the active compare live, both ways.
    @MainActor
    func testSplitToggleSwitchesLayoutLive() async throws {
        let old = "# Title\n\nGone.\n\nShared.\n"
        let new = "# Title\n\nShared.\n"
        let baseline = try writeBaseline("v1.md", old)
        let model = try await makeModel(file: "v2.md", text: new, pick: baseline)

        model.startCompare()
        _ = try await waitFor {
            try await self.count(model, selector: ".markio-diff-removed") > 0
        }

        model.setCompareSplit(true)
        let toSplit = try await waitFor {
            try await self.count(model, selector: ".markio-split") > 0
        }
        XCTAssertTrue(toSplit, "checking the toggle switches to columns")

        model.setCompareSplit(false)
        let backInline = try await waitFor {
            let split = try await self.count(model, selector: ".markio-split")
            let removed = try await self.count(model, selector: ".markio-diff-removed")
            return split == 0 && removed > 0
        }
        XCTAssertTrue(backInline, "unchecking returns the inline view")
    }

    /// The layout choice is a persisted global reading preference.
    @MainActor
    func testSplitPreferencePersists() {
        let store = CompareLayoutStore(defaults: defaults)
        XCTAssertFalse(store.split, "inline is the default")
        store.split = true
        XCTAssertTrue(CompareLayoutStore(defaults: defaults).split)
    }

    /// Picking the document's own file is a no-op.
    @MainActor
    func testSelfCompareIsNoOp() async throws {
        let text = "# Title\n\nBody.\n"
        let url = tempDir.appendingPathComponent("self.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let model = DocumentModel(
            defaults: defaults,
            comparePick: { _, completion in completion(url) }
        )
        model.preview.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        await model.start(text: text, url: url)

        model.startCompare()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(model.isCompared, "self-compare must be a no-op")
    }
}
