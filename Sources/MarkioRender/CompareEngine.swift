import Foundation
import MarkdownKit

/// Compares two versions of a Markdown file and builds one source out of both.
///
/// The result is a single byte buffer that reads like the current document with
/// the lines it lost since the baseline put back where they used to be, plus a
/// note of which byte ranges came from which side. Everything downstream —
/// parser, layout, find, outline — then works on ordinary Markdown and knows
/// nothing about comparison; the view tints the blocks whose bytes are marked.
///
/// The diff is line-based. Word-level refinement would need a second engine
/// inside every changed line and buys little on prose that is edited a
/// paragraph at a time. A block whose lines only mean something together — a
/// fence, a table, front matter, an HTML block, a formula written across lines
/// — is compared as one unit instead: a line apart from its block is not
/// Markdown that parses back into that block.
public enum CompareEngine {
    public enum Mark: Sendable, Equatable {
        /// In the current document but not in the baseline.
        case added
        /// In the baseline but not in the current document.
        case removed
    }

    public struct Result: Sendable {
        /// The merged Markdown source.
        public var bytes: [UInt8]
        /// Marked byte ranges of `bytes`, in order and non-overlapping.
        public var marks: [(range: Range<Int>, mark: Mark)]
        /// Whether the two versions differ at all.
        public var hasChanges: Bool { !marks.isEmpty }

        /// The mark covering a byte offset, if any.
        public func mark(atByte offset: Int) -> Mark? {
            var low = 0
            var high = marks.count - 1
            while low <= high {
                let middle = (low + high) / 2
                let range = marks[middle].range
                if range.contains(offset) { return marks[middle].mark }
                if offset < range.lowerBound { high = middle - 1 } else { low = middle + 1 }
            }
            return nil
        }
    }

    /// The two versions kept apart rather than merged, each carrying only its
    /// own changes: the baseline with what was taken out of it, the current file
    /// with what was put in.
    ///
    /// This is what a side-by-side reading needs. The unchanged lines are in
    /// both, which is what makes the two columns run level for as long as
    /// nothing has changed.
    public struct Sides: Sendable {
        public var baseline: Result
        public var current: Result

        public var hasChanges: Bool { baseline.hasChanges || current.hasChanges }
    }

    /// Merge `current` with `baseline`, marking what changed between them.
    public static func merge(current: [UInt8], baseline: [UInt8]) -> Result {
        let comparison = script(current: current, baseline: baseline)
        var merged = Builder(capacity: current.count + baseline.count / 4)
        // Front matter is front matter only on the first line of a file, so the
        // second copy of a changed one would be read as a rule and a heading.
        // It goes in as the YAML it is, in a fence, which the page draws as
        // YAML code too.
        var fence: [UInt8]?
        func add(
            _ source: [UInt8], _ lines: [Range<Int>], _ front: Range<Int>?, _ index: Int,
            _ mark: Mark?
        ) {
            guard let front, front.contains(index) else {
                return merged.add(source[lines[index]], mark: mark)
            }
            if index == front.lowerBound {
                fence =
                    merged.bytes.isEmpty ? nil : self.fence(around: front.map { source[lines[$0]] })
            }
            guard let fence, index == front.lowerBound || index == front.upperBound - 1 else {
                return merged.add(source[lines[index]], mark: mark)
            }
            merged.add(
                index == front.lowerBound ? fence + Array("yaml\n".utf8) : fence + [0x0A],
                mark: mark)
        }
        for step in comparison.steps {
            switch step {
            case .same(let index):
                add(current, comparison.currentLines, comparison.currentFront, index, nil)
            case .added(let index):
                add(current, comparison.currentLines, comparison.currentFront, index, .added)
            case .removed(let index):
                add(baseline, comparison.baselineLines, comparison.baselineFront, index, .removed)
            }
        }
        return merged.result
    }

    /// A backtick fence longer than any run of backticks opening a line inside
    /// it, so nothing in the YAML can close it early. A closing fence may be
    /// indented by up to three spaces.
    private static func fence(around lines: [ArraySlice<UInt8>]) -> [UInt8] {
        var longest = 2
        for line in lines {
            let text = line.dropFirst(min(3, line.prefix { $0 == 0x20 }.count))
            longest = max(longest, text.prefix { $0 == 0x60 }.count)
        }
        return [UInt8](repeating: 0x60, count: longest + 1)
    }

    /// The same comparison, kept in two documents instead of one.
    public static func split(current: [UInt8], baseline: [UInt8]) -> Sides {
        let comparison = script(current: current, baseline: baseline)
        var left = Builder(capacity: baseline.count)
        var right = Builder(capacity: current.count)
        for step in comparison.steps {
            switch step {
            case .same(let index):
                // The line is the same on both sides, so one copy of it serves
                // for both columns.
                left.add(current[comparison.currentLines[index]], mark: nil)
                right.add(current[comparison.currentLines[index]], mark: nil)
            case .added(let index):
                right.add(current[comparison.currentLines[index]], mark: .added)
            case .removed(let index):
                left.add(baseline[comparison.baselineLines[index]], mark: .removed)
            }
        }
        return Sides(baseline: left.result, current: right.result)
    }

    /// Accumulates one side of a comparison: the bytes and the marks over them.
    private struct Builder {
        var bytes: [UInt8] = []
        var marks: [(range: Range<Int>, mark: Mark)] = []
        /// The previous line's origin. Doubly optional on purpose: "no line yet"
        /// and "an unchanged line" are different answers.
        private var previous: Mark??

        init(capacity: Int) { bytes.reserveCapacity(capacity) }

        mutating func add<Line: Collection<UInt8>>(_ line: Line, mark: Mark?) {
            // A removed line followed straight away by the line that replaced it
            // would be read as one paragraph, and the whole thing would take the
            // mark of its first byte. A blank line between runs of different
            // origin keeps them separate blocks. It belongs to neither side, so
            // it goes in before the mark's range starts.
            if previous != nil, previous! != mark { separate(&bytes) }
            previous = mark
            let start = bytes.count
            appendLine(&bytes, line)
            if let mark { append(&marks, start..<bytes.count, mark) }
        }

        var result: Result { Result(bytes: bytes, marks: marks) }
    }

    /// The line ranges of both versions and the edit script between them, so
    /// merging and splitting share one comparison.
    private static func script(current: [UInt8], baseline: [UInt8]) -> (
        steps: [Step], currentLines: [Range<Int>], baselineLines: [Range<Int>],
        currentFront: Range<Int>?, baselineFront: Range<Int>?
    ) {
        let currentLines = lines(of: current)
        let baselineLines = lines(of: baseline)
        let currentUnits = units(of: current, lineCount: currentLines.count)
        let baselineUnits = units(of: baseline, lineCount: baselineLines.count)
        let unitSteps = diff(
            baseline: baselineUnits.units.map { hash(baseline, baselineLines, $0) },
            current: currentUnits.units.map { hash(current, currentLines, $0) }
        )
        var steps: [Step] = []
        steps.reserveCapacity(max(currentLines.count, baselineLines.count))
        for step in unitSteps {
            switch step {
            case .same(let unit): steps += currentUnits.units[unit].map { .same($0) }
            case .added(let unit): steps += currentUnits.units[unit].map { .added($0) }
            case .removed(let unit): steps += baselineUnits.units[unit].map { .removed($0) }
            }
        }
        return (steps, currentLines, baselineLines, currentUnits.front, baselineUnits.front)
    }

    /// The lines a version is compared in, as runs of line indices: one line
    /// each, except where a block only reads whole.
    ///
    /// Line by line, one changed line of a fence put the old and the new line
    /// into the same fence with a blank line between them and no mark on
    /// either, and a changed table row fell out of its table and was shown as
    /// pipes. The blocks come from the parser rather than from a second set of
    /// rules about what a fence is; its lines are split at the same newlines as
    /// `lines(of:)`, so the indices agree. The front matter's lines come back
    /// on their own as well, since a merge has to treat them differently.
    private static func units(of bytes: [UInt8], lineCount: Int) -> (
        units: [Range<Int>], front: Range<Int>?
    ) {
        let document = Document(bytes: bytes)
        var spans: [Range<Int>] = []
        var front: Range<Int>?
        for leaf in document.leaves {
            let block = document.block(leaf)
            var first = Int(block.firstLine)
            var last = Int(block.lastLine)
            switch block.kind {
            case .codeBlock where block.flags.contains(.fenced), .frontMatter:
                // The fences are lines of the block too, though not of its
                // content. An unclosed fence runs to the end of the file.
                first -= 1
                last = min(Int(block.firstLine + block.lineCount), lineCount - 1)
            case .codeBlock, .table, .htmlBlock:
                break
            case .paragraph where spansFormula(document, leaf):
                break
            default:
                continue
            }
            guard first >= 0, last > first else { continue }
            spans.append(first..<(last + 1))
            if block.kind == .frontMatter { front = spans.last }
        }
        var units: [Range<Int>] = []
        units.reserveCapacity(lineCount)
        var line = 0
        var next = 0
        while line < lineCount {
            while next < spans.count, spans[next].upperBound <= line { next += 1 }
            if next < spans.count, spans[next].lowerBound == line {
                units.append(spans[next])
                line = spans[next].upperBound
            } else {
                units.append(line..<(line + 1))
                line += 1
            }
        }
        return (units, front)
    }

    /// A paragraph holding `$$`: a display formula may be written across its
    /// lines, and half a formula is not one.
    private static func spansFormula(_ document: Document, _ leaf: Int32) -> Bool {
        guard document.block(leaf).lineCount > 1 else { return false }
        let range = document.sourceRange(of: leaf)
        var index = Int(range.lowerBound)
        while index + 1 < Int(range.upperBound) {
            if document.bytes[index] == 0x24, document.bytes[index + 1] == 0x24 { return true }
            index += 1
        }
        return false
    }

    /// End the current block, unless the source already ended one.
    private static func separate(_ bytes: inout [UInt8]) {
        guard bytes.count >= 2 else { return }
        guard !(bytes[bytes.count - 1] == 0x0A && bytes[bytes.count - 2] == 0x0A) else { return }
        bytes.append(0x0A)
    }

    /// Copy a line into the merged source, giving it a newline if the file it
    /// came from ended without one.
    ///
    /// A file whose last line is unterminated is otherwise glued to whatever
    /// follows it, and the two versions differ exactly where the reader is least
    /// interested — at the end of the file.
    private static func appendLine<Line: Collection<UInt8>>(_ bytes: inout [UInt8], _ line: Line) {
        bytes.append(contentsOf: line)
        if bytes.last != 0x0A { bytes.append(0x0A) }
    }

    /// Merge neighbouring ranges of the same kind, so a changed paragraph is one
    /// mark rather than one per line.
    private static func append(
        _ marks: inout [(range: Range<Int>, mark: Mark)],
        _ range: Range<Int>,
        _ mark: Mark
    ) {
        if let last = marks.last, last.mark == mark, last.range.upperBound == range.lowerBound {
            marks[marks.count - 1].range = last.range.lowerBound..<range.upperBound
            return
        }
        marks.append((range: range, mark: mark))
    }

    // MARK: - Lines

    /// Byte ranges of the lines, each including its newline.
    private static func lines(of bytes: [UInt8]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        for index in bytes.indices where bytes[index] == 0x0A {
            result.append(start..<(index + 1))
            start = index + 1
        }
        if start < bytes.count { result.append(start..<bytes.count) }
        return result
    }

    /// FNV-1a over a line, so the diff compares 64-bit numbers instead of
    /// slices. A collision would show one line as changed when it is not, at
    /// odds no reader will meet.
    ///
    /// The trailing newline is left out of the hash: whether a file ends with
    /// one is not a change worth marking.
    /// One unit's lines, folded into one number.
    private static func hash(_ bytes: [UInt8], _ lines: [Range<Int>], _ unit: Range<Int>) -> UInt64
    {
        guard unit.count > 1 else { return hash(bytes, lines[unit.lowerBound]) }
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for line in unit {
            value = (value ^ hash(bytes, lines[line])) &* 0x0000_0100_0000_01b3
        }
        return value
    }

    private static func hash(_ bytes: [UInt8], _ range: Range<Int>) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        var range = range
        if bytes[range.upperBound - 1] == 0x0A { range = range.lowerBound..<(range.upperBound - 1) }
        for index in range {
            value = (value ^ UInt64(bytes[index])) &* 0x0000_0100_0000_01b3
        }
        return value
    }

    // MARK: - Diff

    private enum Step {
        case same(Int)
        case added(Int)
        case removed(Int)

        /// Which side this line came from — nil for text present in both.
        var mark: Mark? {
            switch self {
            case .same: return nil
            case .added: return .added
            case .removed: return .removed
            }
        }
    }

    /// A longest-common-subsequence diff, trimmed at both ends first.
    ///
    /// Trimming is what keeps this affordable: two versions of a document share
    /// almost all of their lines, so the table is built over the handful in the
    /// middle that actually differ rather than over the whole file.
    private static func diff(baseline: [UInt64], current: [UInt64]) -> [Step] {
        var head = 0
        while head < baseline.count, head < current.count, baseline[head] == current[head] {
            head += 1
        }
        var tail = 0
        while tail < baseline.count - head, tail < current.count - head,
            baseline[baseline.count - 1 - tail] == current[current.count - 1 - tail]
        {
            tail += 1
        }

        var steps: [Step] = (0..<head).map { .same($0) }
        steps.append(
            contentsOf: middle(
                baseline: Array(baseline[head..<(baseline.count - tail)]),
                current: Array(current[head..<(current.count - tail)]),
                baselineOffset: head,
                currentOffset: head
            )
        )
        steps.append(contentsOf: ((current.count - tail)..<current.count).map { .same($0) })
        return steps
    }

    /// Beyond this many differing lines on either side the table would cost more
    /// than the comparison is worth, so the middle is reported as a wholesale
    /// replacement: everything removed, then everything added.
    private static let tableLimit = 4000

    private static func middle(
        baseline: [UInt64],
        current: [UInt64],
        baselineOffset: Int,
        currentOffset: Int
    ) -> [Step] {
        if baseline.isEmpty { return current.indices.map { .added(currentOffset + $0) } }
        if current.isEmpty { return baseline.indices.map { .removed(baselineOffset + $0) } }
        if baseline.count > tableLimit || current.count > tableLimit {
            return baseline.indices.map { .removed(baselineOffset + $0) }
                + current.indices.map { .added(currentOffset + $0) }
        }

        // lengths[i][j] — the longest common subsequence of the last i baseline
        // lines and the last j current lines.
        var lengths = [[Int]](
            repeating: [Int](repeating: 0, count: current.count + 1),
            count: baseline.count + 1
        )
        for i in stride(from: baseline.count - 1, through: 0, by: -1) {
            for j in stride(from: current.count - 1, through: 0, by: -1) {
                lengths[i][j] =
                    baseline[i] == current[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var steps: [Step] = []
        var i = 0
        var j = 0
        while i < baseline.count, j < current.count {
            if baseline[i] == current[j] {
                steps.append(.same(currentOffset + j))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                // A line that leaves before the line that arrives, so a changed
                // paragraph reads as its old text followed by its new text.
                steps.append(.removed(baselineOffset + i))
                i += 1
            } else {
                steps.append(.added(currentOffset + j))
                j += 1
            }
        }
        while i < baseline.count {
            steps.append(.removed(baselineOffset + i))
            i += 1
        }
        while j < current.count {
            steps.append(.added(currentOffset + j))
            j += 1
        }
        return steps
    }
}
