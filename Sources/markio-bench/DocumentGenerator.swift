import Foundation

/// Builds synthetic documents of a requested size, shaped like the ones people
/// actually open: prose with emphasis and links, headings, lists, tables and
/// code blocks in roughly the proportions a repository's docs have.
///
/// Deterministic — the same size always yields the same bytes, so a number
/// measured today is comparable with one measured next month.
enum DocumentGenerator {
    static func make(megabytes: Int) -> [UInt8] {
        make(targetBytes: megabytes * 1_024 * 1_024)
    }

    static func make(targetBytes: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(targetBytes + 4_096)
        var random = SplitMix64(seed: 0x4D61_726B_696F_3202)
        var section = 0
        while out.count < targetBytes {
            section += 1
            append(&out, "## Section \(section)\n\n")
            let shape = random.next() % 10
            switch shape {
            case 0, 1, 2, 3:
                appendParagraphs(&out, count: 3, random: &random)
            case 4, 5:
                appendList(&out, random: &random)
            case 6:
                appendTable(&out, random: &random)
            case 7:
                appendCode(&out, random: &random)
            case 8:
                appendQuote(&out, random: &random)
            default:
                appendParagraphs(&out, count: 1, random: &random)
                appendList(&out, random: &random)
            }
        }
        return out
    }

    private static let words = [
        "the", "renderer", "keeps", "every", "block", "in", "one", "flat", "array", "so", "that",
        "layout", "never", "walks", "a", "tree", "of", "objects", "while", "scrolling", "through",
        "a", "document", "whose", "size", "would", "otherwise", "dominate", "memory", "use",
    ]

    private static func appendParagraphs(_ out: inout [UInt8], count: Int, random: inout SplitMix64)
    {
        for _ in 0..<count {
            var line = ""
            let length = 40 + Int(random.next() % 60)
            for index in 0..<length {
                let word = words[Int(random.next() % UInt64(words.count))]
                switch index % 17 {
                case 5: line += "**\(word)** "
                case 9: line += "*\(word)* "
                case 13: line += "`\(word)` "
                case 16: line += "[\(word)](https://example.com/\(word)) "
                default: line += "\(word) "
                }
            }
            append(&out, line.trimmingCharacters(in: .whitespaces) + "\n\n")
        }
    }

    private static func appendList(_ out: inout [UInt8], random: inout SplitMix64) {
        let items = 4 + Int(random.next() % 8)
        for index in 0..<items {
            let word = words[Int(random.next() % UInt64(words.count))]
            append(&out, "- item \(index + 1): \(word) with **emphasis**\n")
            if index % 3 == 2 {
                append(&out, "  - nested detail about \(word)\n")
            }
        }
        append(&out, "\n")
    }

    private static func appendTable(_ out: inout [UInt8], random: inout SplitMix64) {
        append(&out, "| Name | Value | Note |\n| --- | ---: | :---: |\n")
        let rows = 3 + Int(random.next() % 10)
        for index in 0..<rows {
            let word = words[Int(random.next() % UInt64(words.count))]
            append(&out, "| \(word) | \(index * 37) | `\(word)` |\n")
        }
        append(&out, "\n")
    }

    private static func appendCode(_ out: inout [UInt8], random: inout SplitMix64) {
        append(&out, "```swift\n")
        let lines = 6 + Int(random.next() % 20)
        for index in 0..<lines {
            append(&out, "    let value\(index) = compute(\(index), scale: \(index * 3))\n")
        }
        append(&out, "```\n\n")
    }

    private static func appendQuote(_ out: inout [UInt8], random: inout SplitMix64) {
        let lines = 2 + Int(random.next() % 4)
        for _ in 0..<lines {
            let word = words[Int(random.next() % UInt64(words.count))]
            append(&out, "> a quoted remark about \(word) and its consequences\n")
        }
        append(&out, "\n")
    }

    private static func append(_ out: inout [UInt8], _ text: String) {
        out.append(contentsOf: text.utf8)
    }
}

/// A tiny deterministic generator: the benchmark must not depend on the
/// platform's random number machinery to stay reproducible.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
