/// Inline HTML, mapped onto text styles instead of being interpreted.
///
/// Markio 2 has no HTML engine, so a tag can only mean something if the native
/// renderer already knows how to draw it. `<kbd>`, `<mark>`, `<b>`, `<i>`,
/// `<u>`, `<s>`, `<code>` and `<br>` all have exact native equivalents and are
/// honoured; every other well-formed tag is dropped, leaving its text content
/// visible. Nothing is executed and nothing is fetched — there is no engine to
/// do either.
enum InlineHTML {
    struct Tag {
        var end: Int
        var isClosing: Bool
        var isBreak: Bool
        var style: InlineStyle?
    }

    private static let styles: [String: InlineStyle] = [
        "b": .strong,
        "strong": .strong,
        "i": .emphasis,
        "em": .emphasis,
        "cite": .emphasis,
        "s": .strikethrough,
        "del": .strikethrough,
        "strike": .strikethrough,
        "u": .underline,
        "ins": .underline,
        "mark": .highlight,
        "kbd": .keyboard,
        "code": .code,
        "samp": .code,
        "tt": .code,
        "var": .emphasis,
    ]

    /// Parse a well-formed tag starting at `<`. Returns nil when the text is
    /// not a tag at all, which leaves it as literal `<`.
    static func tag(bytes: UnsafeBufferPointer<UInt8>, start: Int, end: Int) -> Tag? {
        var index = start + 1
        guard index < end else { return nil }

        if bytes[index] == ASCII.bang || bytes[index] == 0x3F {
            // Comments, declarations and processing instructions carry no text
            // a reader needs; skip to the closer if it is on this line.
            var cursor = index
            while cursor < end, bytes[cursor] != ASCII.greaterThan { cursor += 1 }
            guard cursor < end else { return nil }
            return Tag(end: cursor + 1, isClosing: false, isBreak: false, style: nil)
        }

        var isClosing = false
        if bytes[index] == ASCII.slash {
            isClosing = true
            index += 1
        }
        guard index < end, isAlpha(bytes[index]) else { return nil }

        var name = ""
        name.reserveCapacity(8)
        while index < end, isAlphanumeric(bytes[index]) || bytes[index] == ASCII.hyphen {
            name.append(Character(UnicodeScalar(lowercased(bytes[index]))))
            index += 1
        }

        // Attributes: consume to the closing `>`, respecting quoted values so a
        // `>` inside an attribute does not end the tag early.
        var quote: UInt8 = 0
        while index < end {
            let byte = bytes[index]
            if quote != 0 {
                if byte == quote { quote = 0 }
            } else if byte == ASCII.quote || byte == ASCII.apostrophe {
                quote = byte
            } else if byte == ASCII.greaterThan {
                let isBreak = name == "br" || name == "wbr"
                return Tag(
                    end: index + 1,
                    isClosing: isClosing,
                    isBreak: isBreak && !isClosing,
                    style: styles[name]
                )
            } else if byte == ASCII.lessThan {
                return nil
            }
            index += 1
        }
        return nil
    }
}
