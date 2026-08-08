/// Where every line begins, and how much of its head is container scaffolding.
///
/// The scanner strips block-quote markers and list indentation by *recording*
/// how many bytes to skip, never by copying the line somewhere clean. A leaf
/// block is therefore a run of lines plus a per-line skip count, and the
/// document text stays exactly one allocation for the whole file.
public struct LineIndex: Sendable {
    /// Byte offset of each line start, plus a trailing sentinel at the end of
    /// the buffer, so `starts[i + 1]` is always valid for a real line `i`.
    public private(set) var starts: [Int32]
    /// Bytes to skip at the head of each line: block-quote markers, list
    /// indentation, the indent of an indented code block. Filled by the scanner
    /// as lines are consumed; `UInt16` caps a strip at 65535 bytes, past any
    /// nesting depth a human writes.
    public internal(set) var contentOffsets: [UInt16]

    public var count: Int { starts.count - 1 }

    /// Split a buffer into lines. Single pass, one branch per byte; the two
    /// arrays are reserved up front from a bytes-per-line estimate so the scan
    /// never reallocates mid-document.
    public init(bytes: UnsafeBufferPointer<UInt8>) {
        let total = bytes.count
        var starts: [Int32] = []
        let estimate = total / 32 + 8
        starts.reserveCapacity(estimate)
        starts.append(0)

        var index = 0
        while index < total {
            if bytes[index] == ASCII.newline {
                starts.append(Int32(index + 1))
            }
            index += 1
        }
        // The sentinel doubles as the final line's end. A file ending in a
        // newline would otherwise gain a phantom empty last line.
        if starts.last != Int32(total) {
            starts.append(Int32(total))
        }
        self.starts = starts
        self.contentOffsets = [UInt16](repeating: 0, count: starts.count - 1)
    }

    @inline(__always)
    public func start(of line: Int) -> Int { Int(starts[line]) }

    /// End of a line's text, with the line terminator excluded.
    @inline(__always)
    public func end(of line: Int, bytes: UnsafeBufferPointer<UInt8>) -> Int {
        let lineStart = Int(starts[line])
        var end = Int(starts[line + 1])
        if end > lineStart, bytes[end - 1] == ASCII.newline { end -= 1 }
        if end > lineStart, bytes[end - 1] == ASCII.carriageReturn { end -= 1 }
        return end
    }

    /// The line's text after its recorded container scaffolding, clamped so a
    /// short line (a blank one inside a deep list) can never produce an
    /// inverted range.
    @inline(__always)
    public func contentRange(of line: Int, bytes: UnsafeBufferPointer<UInt8>) -> ByteRange {
        let end = end(of: line, bytes: bytes)
        let start = min(Int(starts[line]) + Int(contentOffsets[line]), end)
        return ByteRange(start, end)
    }
}
