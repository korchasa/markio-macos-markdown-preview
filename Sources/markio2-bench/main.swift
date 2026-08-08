import Foundation
import MarkdownKit

/// The performance harness.
///
/// Two numbers decide whether Markio 2 is worth building: how long a large
/// document takes to become structure, and how much memory that structure
/// costs. Both are reported against the raw file size, because a parse tree
/// several times the size of the file is what makes a viewer fall over.
///
///     deno task bench            # 1, 8 and 32 MB
///     deno task bench 64         # one size, in megabytes
///     deno task bench /path.md   # a real document

let arguments = Array(CommandLine.arguments.dropFirst())

// `snapshot` renders a document to a PNG and `icon` draws the app icon;
// everything else is a measurement.
if arguments.first == "snapshot" {
    exit(Snapshot.run(arguments: Array(arguments.dropFirst())))
}
if arguments.first == "icon" {
    exit(Icon.run(arguments: Array(arguments.dropFirst())))
}

func report(name: String, bytes: [UInt8]) {
    let before = Measure.residentBytes()
    let (document, parseSeconds) = Measure.time { Document(bytes: bytes) }
    let after = Measure.residentBytes()

    // What the block structure costs beyond the file itself.
    let blockBytes = document.blocks.count * MemoryLayout<Block>.stride
    let lineBytes =
        document.lines.starts.count * MemoryLayout<Int32>.stride
        + document.lines.contentOffsets.count * MemoryLayout<UInt16>.stride
    let leafBytes = document.leaves.count * MemoryLayout<Int32>.stride
    let structure = blockBytes + lineBytes + leafBytes

    // A viewport holds on the order of a hundred blocks; that is the inline
    // work a scroll actually pays for.
    let window = min(120, document.leaves.count)
    let (_, inlineSeconds) = Measure.time {
        var runs = 0
        for leaf in document.leaves.prefix(window) {
            let content = document.content(of: leaf)
            let parsed = InlineParser.parse(
                content: content,
                references: document.references,
                documentBytes: document.bytes
            )
            runs += parsed.runs.count
        }
        return runs
    }

    // The worst case a feature like search or the outline can force: every
    // block's inline structure, all at once.
    let (_, fullInlineSeconds) = Measure.time {
        var runs = 0
        for leaf in document.leaves {
            let content = document.content(of: leaf)
            let parsed = InlineParser.parse(
                content: content,
                references: document.references,
                documentBytes: document.bytes
            )
            runs += parsed.runs.count
        }
        return runs
    }

    let (headings, headingSeconds) = Measure.time { document.headings() }

    print("")
    print("\(name) — \(Measure.megabytes(bytes.count)), \(document.lines.count) lines")
    print(
        "  parse            \(Measure.milliseconds(parseSeconds))"
            + "  (\(Measure.throughput(bytes: bytes.count, seconds: parseSeconds)))")
    print("  blocks           \(document.blocks.count) (\(document.leaves.count) leaves)")
    print(
        "  structure        \(Measure.megabytes(structure))"
            + "  = \(percent(structure, of: bytes.count)) of the file")
    print("  resident delta   \(Measure.megabytes(max(0, after - before)))")
    print("  inline: viewport \(Measure.milliseconds(inlineSeconds)) for \(window) blocks")
    print(
        "  inline: whole    \(Measure.milliseconds(fullInlineSeconds))"
            + "  (\(Measure.throughput(bytes: bytes.count, seconds: fullInlineSeconds)))")
    print(
        "  outline          \(Measure.milliseconds(headingSeconds)) for \(headings.count) headings")
}

func percent(_ part: Int, of whole: Int) -> String {
    guard whole > 0 else { return "—" }
    return String(format: "%.0f%%", Double(part) / Double(whole) * 100)
}

print("markio2-bench — parse cost and structure footprint")

if let path = arguments.first, FileManager.default.fileExists(atPath: path) {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    report(name: path, bytes: [UInt8](data))
} else {
    let sizes = arguments.compactMap(Int.init)
    for megabytes in sizes.isEmpty ? [1, 8, 32] : sizes {
        let bytes = DocumentGenerator.make(megabytes: megabytes)
        report(name: "generated \(megabytes) MB", bytes: bytes)
    }
}

print("")
print("peak resident \(Measure.megabytes(Measure.peakResidentBytes()))")
