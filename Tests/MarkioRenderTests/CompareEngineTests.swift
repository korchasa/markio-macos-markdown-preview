import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// Comparing a document with an older version of itself.
@MainActor
final class CompareEngineTests: XCTestCase {
    private func merge(_ current: String, _ baseline: String) -> CompareEngine.Result {
        CompareEngine.merge(current: Array(current.utf8), baseline: Array(baseline.utf8))
    }

    private func text(_ result: CompareEngine.Result) -> String {
        String(decoding: result.bytes, as: UTF8.self)
    }

    /// The mark on the block a piece of text starts in.
    private func mark(_ result: CompareEngine.Result, containing needle: String)
        -> CompareEngine.Mark?
    {
        let haystack = text(result)
        guard let range = haystack.range(of: needle) else { return nil }
        return result.mark(
            atByte: haystack.utf8.distance(
                from: haystack.utf8.startIndex,
                to: range.lowerBound.samePosition(in: haystack.utf8)!
            ))
    }

    func testIdenticalVersionsHaveNothingToShow() {
        let result = merge("# Title\n\nBody.\n", "# Title\n\nBody.\n")
        XCTAssertFalse(result.hasChanges)
        XCTAssertEqual(text(result), "# Title\n\nBody.\n")
    }

    func testNewTextIsMarkedAsAdded() {
        let result = merge("# Title\n\nOld.\n\nNew.\n", "# Title\n\nOld.\n")
        XCTAssertEqual(mark(result, containing: "New."), .added)
        XCTAssertNil(mark(result, containing: "Old."))
    }

    func testDeletedTextComesBackMarkedAsRemoved() {
        let result = merge("# Title\n\nKept.\n", "# Title\n\nGone.\n\nKept.\n")
        XCTAssertTrue(text(result).contains("Gone."), "removed text is shown, not dropped")
        XCTAssertEqual(mark(result, containing: "Gone."), .removed)
    }

    func testAChangedParagraphReadsAsOldThenNew() {
        let result = merge("Answer is 43.\n", "Answer is 42.\n")
        XCTAssertEqual(text(result), "Answer is 42.\n\nAnswer is 43.\n")
        XCTAssertEqual(mark(result, containing: "42"), .removed)
        XCTAssertEqual(mark(result, containing: "43"), .added)
    }

    func testNeighbouringLinesBecomeOneMark() {
        let result = merge("a\nb\nc\n", "a\n")
        XCTAssertEqual(result.marks.count, 1, "two added lines are one change")
        XCTAssertEqual(result.marks[0].mark, .added)
    }

    func testAWholesaleRewriteIsRemovedThenAdded() {
        let result = merge("Entirely different text.\n", "Nothing in common here.\n")
        XCTAssertEqual(text(result), "Nothing in common here.\n\nEntirely different text.\n")
        XCTAssertEqual(result.marks.map(\.mark), [.removed, .added])
    }

    func testAnUnterminatedLastLineIsNotAChange() {
        // The baseline ends without a newline and the current file has one more
        // line. Only the new line is a change; the missing terminator is not.
        let result = merge("one\ntwo", "one")
        XCTAssertEqual(text(result), "one\n\ntwo\n")
        XCTAssertEqual(mark(result, containing: "two"), .added)
        XCTAssertNil(mark(result, containing: "one"))
    }

    func testTheOldAndNewTextOfAParagraphStayTwoBlocks() {
        // Without a blank line between them the parser would read the two lines
        // as one paragraph, and the whole thing would take the mark of its first
        // byte — the old text and the new text tinted as a single removal.
        let result = merge("Answer is 43.\n", "Answer is 42.\n")
        let layout = DocumentLayout(
            document: Document(bytes: result.bytes),
            theme: Theme(isDark: false),
            columnWidth: 520
        )
        layout.comparison = result
        XCTAssertEqual(layout.blockCount, 2)
        XCTAssertEqual((0..<layout.blockCount).map { layout.mark(at: $0) }, [.removed, .added])
    }

    /// The layout is what the view asks, so the mark has to survive the trip
    /// through the parser and land on the right block.
    func testTheLayoutMarksTheBlockThatChanged() throws {
        let result = merge("# Title\n\nKept.\n\nAdded.\n", "# Title\n\nKept.\n")
        let layout = DocumentLayout(
            document: Document(bytes: result.bytes),
            theme: Theme(isDark: false),
            columnWidth: 520
        )
        layout.comparison = result
        let marks = (0..<layout.blockCount).map { layout.mark(at: $0) }
        XCTAssertEqual(marks, [nil, nil, .added])
    }

    /// Side by side needs the two versions apart: each column carries its own
    /// text and only its own marks, and what did not change is in both.
    func testSplitKeepsEachSideToItself() {
        let sides = CompareEngine.split(
            current: Array("# Title\n\nKept.\n\nAdded.\n".utf8),
            baseline: Array("# Title\n\nKept.\n\nGone.\n".utf8)
        )
        let left = String(decoding: sides.baseline.bytes, as: UTF8.self)
        let right = String(decoding: sides.current.bytes, as: UTF8.self)
        XCTAssertTrue(left.contains("Gone."), left)
        XCTAssertFalse(left.contains("Added."), left)
        XCTAssertTrue(right.contains("Added."), right)
        XCTAssertFalse(right.contains("Gone."), right)
        // The unchanged text is in both, which is what keeps the columns level.
        XCTAssertTrue(left.contains("Kept."))
        XCTAssertTrue(right.contains("Kept."))
        XCTAssertEqual(sides.baseline.marks.map(\.mark), [.removed])
        XCTAssertEqual(sides.current.marks.map(\.mark), [.added])
    }

    /// Two files that agree have two columns of the same text and no marks.
    func testSplitOfIdenticalVersions() {
        let text = Array("# Title\n\nBody.\n".utf8)
        let sides = CompareEngine.split(current: text, baseline: text)
        XCTAssertFalse(sides.hasChanges)
        XCTAssertEqual(sides.baseline.bytes, sides.current.bytes)
    }

    /// Each block of a compared source: what it parsed as, and its mark.
    private func blocks(_ result: CompareEngine.Result) -> [(BlockKind, CompareEngine.Mark?)] {
        let document = Document(bytes: result.bytes)
        let layout = DocumentLayout(
            document: document, theme: Theme(isDark: false), columnWidth: 520)
        layout.comparison = result
        return (0..<layout.blockCount).map { ordinal in
            (document.block(document.leaves[ordinal]).kind, layout.mark(at: ordinal))
        }
    }

    /// One line changed inside a block whose lines only mean something
    /// together. Line by line, the old and the new line went into one fence
    /// with blank lines between them and no mark at all; a table row fell out
    /// of its table and was shown as pipes; changed front matter held both
    /// dates. The block is the unit there: the old one removed, the new one
    /// added, each still the kind of block it was.
    func testABlockThatOnlyReadsWholeIsComparedWhole() {
        let cases: [(String, String, BlockKind)] = [
            (
                "```swift\nlet a = 1\nlet b = 2\n```\n", "```swift\nlet a = 1\nlet b = 3\n```\n",
                .codeBlock
            ),
            (
                "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n",
                "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 5 |\n", .table
            ),
            (
                "---\ntitle: T\ndate: 2026-08-04\n---\n", "---\ntitle: T\ndate: 2026-08-11\n---\n",
                .frontMatter
            ),
            (
                "<table>\n<tr><td>1</td></tr>\n<tr><td>2</td></tr>\n</table>\n",
                "<table>\n<tr><td>1</td></tr>\n<tr><td>3</td></tr>\n</table>\n", .htmlBlock
            ),
        ]
        for (old, new, kind) in cases {
            // Front matter is only front matter on the file's first line.
            let head = kind == .frontMatter ? "" : "# Title\n\n"
            let before: [BlockKind] = kind == .frontMatter ? [] : [.heading]
            let unmarked: [CompareEngine.Mark?] = kind == .frontMatter ? [] : [nil]
            let source = "\(head)\(old)\nTail.\n"
            let changed = "\(head)\(new)\nTail.\n"
            let merged = blocks(merge(changed, source))
            // Front matter opens a file or is not front matter; the new copy
            // is the same YAML in a fence, drawn the same way.
            let second: BlockKind = kind == .frontMatter ? .codeBlock : kind
            XCTAssertEqual(merged.map(\.0), before + [kind, second, .paragraph], "\(kind)")
            XCTAssertEqual(merged.map(\.1), unmarked + [.removed, .added, nil], "\(kind)")

            let sides = CompareEngine.split(
                current: Array(changed.utf8), baseline: Array(source.utf8))
            XCTAssertEqual(blocks(sides.baseline).map(\.0), before + [kind, .paragraph], "\(kind)")
            XCTAssertEqual(blocks(sides.baseline).map(\.1), unmarked + [.removed, nil], "\(kind)")
            XCTAssertEqual(blocks(sides.current).map(\.0), before + [kind, .paragraph], "\(kind)")
            XCTAssertEqual(blocks(sides.current).map(\.1), unmarked + [.added, nil], "\(kind)")
        }
    }

    /// The fence keeps its own lines: nothing is put between them.
    func testAChangedFenceKeepsItsLinesTogether() {
        let result = merge("```\none\ntwo\nthree\n```\n", "```\none\n2\nthree\n```\n")
        XCTAssertEqual(text(result), "```\none\n2\nthree\n```\n\n```\none\ntwo\nthree\n```\n")
    }

    /// A formula written across lines is one paragraph whose lines are one
    /// formula; split, neither half is a formula.
    func testAFormulaAcrossLinesIsComparedWhole() {
        let result = merge("$$\na + c\n$$\n", "$$\na + b\n$$\n")
        XCTAssertEqual(text(result), "$$\na + b\n$$\n\n$$\na + c\n$$\n")
        XCTAssertEqual(result.marks.map(\.mark), [.removed, .added])
    }

    /// The fence round the new copy of the front matter is longer than any
    /// backticks inside it, and the YAML itself is kept as it was.
    func testTheSecondFrontMatterIsFencedAsYAML() {
        let result = merge("---\nnote: |\n  ```\n---\nBody.\n", "---\nnote: x\n---\nBody.\n")
        XCTAssertEqual(
            text(result), "---\nnote: x\n---\n\n````yaml\nnote: |\n  ```\n````\n\nBody.\n")
    }

    /// Prose is still compared a line at a time: one changed line of a long
    /// paragraph does not mark the rest of it.
    func testAParagraphIsStillComparedLineByLine() {
        let result = merge("one\ntwo\nthree\n", "one\n2\nthree\n")
        XCTAssertNil(mark(result, containing: "one"))
        XCTAssertEqual(mark(result, containing: "2"), .removed)
        XCTAssertEqual(mark(result, containing: "two"), .added)
    }

    func testWithoutAComparisonNothingIsMarked() {
        let layout = DocumentLayout(
            document: Document(text: "# Title\n\nBody.\n"),
            theme: Theme(isDark: false),
            columnWidth: 520
        )
        XCTAssertNil(layout.mark(at: 0))
    }
}
