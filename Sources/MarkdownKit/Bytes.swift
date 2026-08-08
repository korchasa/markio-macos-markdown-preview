/// Byte-level primitives shared by the scanner and the inline parser.
///
/// Everything in MarkdownKit works on raw UTF-8 bytes rather than `String` or
/// `Character`. Grapheme-aware types allocate and normalize; a viewer that must
/// open a 100 MB document cannot pay that on the way in. Multi-byte sequences
/// are never split because every delimiter Markdown cares about is ASCII, and
/// ASCII bytes never appear inside a multi-byte UTF-8 sequence.
enum ASCII {
    static let tab: UInt8 = 0x09
    static let newline: UInt8 = 0x0A
    static let carriageReturn: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let bang: UInt8 = 0x21
    static let quote: UInt8 = 0x22
    static let hash: UInt8 = 0x23
    static let dollar: UInt8 = 0x24
    static let ampersand: UInt8 = 0x26
    static let apostrophe: UInt8 = 0x27
    static let leftParen: UInt8 = 0x28
    static let rightParen: UInt8 = 0x29
    static let asterisk: UInt8 = 0x2A
    static let plus: UInt8 = 0x2B
    static let hyphen: UInt8 = 0x2D
    static let dot: UInt8 = 0x2E
    static let slash: UInt8 = 0x2F
    static let zero: UInt8 = 0x30
    static let nine: UInt8 = 0x39
    static let colon: UInt8 = 0x3A
    static let lessThan: UInt8 = 0x3C
    static let equals: UInt8 = 0x3D
    static let greaterThan: UInt8 = 0x3E
    static let upperA: UInt8 = 0x41
    static let upperX: UInt8 = 0x58
    static let upperZ: UInt8 = 0x5A
    static let leftBracket: UInt8 = 0x5B
    static let backslash: UInt8 = 0x5C
    static let rightBracket: UInt8 = 0x5D
    static let backtick: UInt8 = 0x60
    static let lowerA: UInt8 = 0x61
    static let lowerX: UInt8 = 0x78
    static let lowerZ: UInt8 = 0x7A
    static let lowerZChar: UInt8 = 0x7A
    static let underscore: UInt8 = 0x5F
    static let pipe: UInt8 = 0x7C
    static let tilde: UInt8 = 0x7E
}

@inline(__always)
func isSpaceOrTab(_ byte: UInt8) -> Bool {
    byte == ASCII.space || byte == ASCII.tab
}

@inline(__always)
func isDigit(_ byte: UInt8) -> Bool {
    byte >= ASCII.zero && byte <= ASCII.nine
}

@inline(__always)
func isAlpha(_ byte: UInt8) -> Bool {
    (byte >= ASCII.upperA && byte <= ASCII.upperZ) || (byte >= ASCII.lowerA && byte <= ASCII.lowerZ)
}

@inline(__always)
func isAlphanumeric(_ byte: UInt8) -> Bool {
    isAlpha(byte) || isDigit(byte)
}

@inline(__always)
func lowercased(_ byte: UInt8) -> UInt8 {
    (byte >= ASCII.upperA && byte <= ASCII.upperZ) ? byte + 0x20 : byte
}

/// A half-open byte range inside the document buffer.
///
/// `Int32` rather than `Int`: two of these are the bulk of every block record,
/// and halving them halves the parse tree. It caps a document at 2 GiB, which
/// is far past the point where any viewer stays usable.
public struct ByteRange: Equatable, Sendable {
    public var start: Int32
    public var end: Int32

    public init(start: Int32, end: Int32) {
        self.start = start
        self.end = end
    }

    public init(_ start: Int, _ end: Int) {
        self.start = Int32(start)
        self.end = Int32(end)
    }

    public static let empty = ByteRange(start: 0, end: 0)

    public var isEmpty: Bool { end <= start }
    public var count: Int { Int(end) - Int(start) }
    public var lowerBound: Int { Int(start) }
    public var upperBound: Int { Int(end) }
}

extension Array where Element == UInt8 {
    /// Decode a byte range as UTF-8, substituting replacement characters for
    /// malformed sequences rather than failing — a viewer must show whatever it
    /// was handed.
    public func text(in range: ByteRange) -> String {
        guard !range.isEmpty else { return "" }
        return withUnsafeBufferPointer { buffer in
            String(
                decoding: UnsafeBufferPointer(
                    rebasing: buffer[range.lowerBound..<range.upperBound]), as: UTF8.self)
        }
    }
}
