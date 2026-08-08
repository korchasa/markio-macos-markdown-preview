/// What a block is. Containers hold other blocks; leaves hold lines.
public enum BlockKind: UInt8, Sendable {
    case document
    case blockQuote
    case list
    case listItem
    case paragraph
    case heading
    case codeBlock
    case htmlBlock
    case thematicBreak
    case table
    case frontMatter
    /// The text of a footnote (`[^label]: …`), drawn beside its label.
    case footnoteDefinition
    /// `<details>` or `</details>`: the two ends of a collapsible section.
    case disclosure
}

extension BlockKind {
    /// Leaves own lines and are the unit of layout; containers only nest.
    public var isLeaf: Bool {
        switch self {
        case .document, .blockQuote, .list, .listItem: return false
        case .paragraph, .heading, .codeBlock, .htmlBlock, .thematicBreak, .table, .frontMatter,
            .footnoteDefinition, .disclosure:
            return true
        }
    }
}

public struct BlockFlags: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// List with no blank line between its items — rendered without item spacing.
    public static let tight = BlockFlags(rawValue: 1 << 0)
    /// Ordered list (`1.`) rather than a bullet.
    public static let ordered = BlockFlags(rawValue: 1 << 1)
    /// List item carrying a GFM task checkbox.
    public static let task = BlockFlags(rawValue: 1 << 2)
    /// Task checkbox is ticked.
    public static let taskChecked = BlockFlags(rawValue: 1 << 3)
    /// Code block written with ``` or ~~~ rather than by indentation.
    public static let fenced = BlockFlags(rawValue: 1 << 4)
    /// Heading written by underlining rather than with leading `#`.
    public static let setext = BlockFlags(rawValue: 1 << 5)
    /// First leaf inside a list item — the one the item marker is drawn beside.
    public static let itemHead = BlockFlags(rawValue: 1 << 6)
    /// `<details open>` — the section starts showing its contents.
    public static let expanded = BlockFlags(rawValue: 1 << 7)
}

/// One node of the parsed document.
///
/// Deliberately 24 bytes and free of references: the whole tree is one flat
/// array, so parsing allocates twice (blocks + lines) no matter how large the
/// document is, and walking it never chases a pointer out of cache.
public struct Block: Sendable {
    public var kind: BlockKind
    /// Heading level 1…6; the nesting depth of a list; unused elsewhere.
    public var level: UInt8
    public var flags: BlockFlags
    /// Index of the enclosing container, or -1 for a top-level block.
    public var parent: Int32
    /// First line owned by this leaf. Containers carry the span of their subtree.
    public var firstLine: Int32
    public var lineCount: Int32
    /// A kind-dependent byte range: a fence's info string, a heading's text
    /// before trailing hashes are stripped, a table's delimiter row.
    public var info: ByteRange
    /// A kind-dependent number: an ordered list's start, a table's column count.
    public var aux: Int32

    init(
        kind: BlockKind,
        parent: Int32,
        firstLine: Int32,
        level: UInt8 = 0,
        flags: BlockFlags = [],
        info: ByteRange = .empty,
        aux: Int32 = 0
    ) {
        self.kind = kind
        self.level = level
        self.flags = flags
        self.parent = parent
        self.firstLine = firstLine
        self.lineCount = 0
        self.info = info
        self.aux = aux
    }

    public var lastLine: Int32 { firstLine + lineCount - 1 }
}
