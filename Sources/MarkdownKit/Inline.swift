/// The result of inline parsing: a *flat* sequence of styled runs.
///
/// Emphasis nests in the source but not in the output. Collapsing `**bold with
/// *italic* inside**` into runs that each carry a cumulative style set is what
/// lets the renderer build one attributed string per block with no tree walk,
/// and it is why inline parsing can be deferred until a block is about to be
/// drawn.
public struct InlineContent: Sendable {
    public var runs: [InlineRun]
    public var links: [InlineLink]

    public static let empty = InlineContent(runs: [], links: [])
}

public struct InlineStyle: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let emphasis = InlineStyle(rawValue: 1 << 0)
    public static let strong = InlineStyle(rawValue: 1 << 1)
    public static let strikethrough = InlineStyle(rawValue: 1 << 2)
    public static let code = InlineStyle(rawValue: 1 << 3)
    public static let link = InlineStyle(rawValue: 1 << 4)
    public static let math = InlineStyle(rawValue: 1 << 5)
    public static let keyboard = InlineStyle(rawValue: 1 << 6)
    public static let highlight = InlineStyle(rawValue: 1 << 7)
    public static let underline = InlineStyle(rawValue: 1 << 8)
}

public enum InlineRunKind: UInt8, Sendable {
    /// Text taken verbatim from the block's content buffer.
    case text
    /// A single decoded character (an HTML entity) that has no byte range.
    case entity
    /// A line break inside a paragraph — rendered as a space or a break
    /// depending on the reflow rules.
    case softBreak
    /// An explicit break: two trailing spaces, a trailing backslash, or `<br>`.
    case hardBreak
    /// An image; `link` points at its destination.
    case image
}

public struct InlineRun: Sendable {
    public var kind: InlineRunKind
    public var style: InlineStyle
    /// Byte range inside the *block content* buffer, not the document.
    public var range: ByteRange
    /// Index into `InlineContent.links`, or -1.
    public var link: Int32
    /// Decoded scalar for `.entity` runs.
    public var scalar: UInt32

    init(
        kind: InlineRunKind,
        style: InlineStyle,
        range: ByteRange,
        link: Int32 = -1,
        scalar: UInt32 = 0
    ) {
        self.kind = kind
        self.style = style
        self.range = range
        self.link = link
        self.scalar = scalar
    }
}

public struct InlineLink: Sendable, Equatable {
    public var destination: String
    public var title: String
    public var isImage: Bool
}

/// Plain-text projection of inline content, used for headings, slugs, the
/// table of contents and search.
public enum InlineText {
    public static func plain(_ content: [UInt8]) -> String {
        let parsed = InlineParser.parse(content: content, references: [:], documentBytes: [])
        return plain(parsed, bytes: content)
    }

    public static func plain(_ content: InlineContent, bytes: [UInt8]) -> String {
        var out = ""
        out.reserveCapacity(bytes.count)
        for run in content.runs {
            switch run.kind {
            case .text:
                out += bytes.text(in: run.range)
            case .entity:
                if let scalar = Unicode.Scalar(run.scalar) { out.unicodeScalars.append(scalar) }
            case .softBreak, .hardBreak:
                out.append(" ")
            case .image:
                out += bytes.text(in: run.range)
            }
        }
        return out
    }
}
