/// HTML entity decoding, limited to what documents actually contain.
///
/// Numeric entities are decoded in full. Named entities are matched against the
/// short table below rather than the 2 000-entry HTML5 list: the long tail
/// never appears in Markdown, and the table is consulted for every `&` in the
/// document, so its size is a hot-path cost.
enum Entities {
    struct Decoded {
        var scalar: UInt32
        var end: Int
    }

    private static let semicolon: UInt8 = 0x3B

    private static let named: [String: UInt32] = [
        "amp": 38, "lt": 60, "gt": 62, "quot": 34, "apos": 39, "nbsp": 160,
        "copy": 169, "reg": 174, "trade": 8482, "hellip": 8230, "mdash": 8212,
        "ndash": 8211, "lsquo": 8216, "rsquo": 8217, "ldquo": 8220, "rdquo": 8221,
        "laquo": 171, "raquo": 187, "deg": 176, "plusmn": 177, "times": 215,
        "divide": 247, "frac12": 189, "frac14": 188, "frac34": 190, "micro": 181,
        "para": 182, "sect": 167, "dagger": 8224, "Dagger": 8225, "bull": 8226,
        "middot": 183, "larr": 8592, "uarr": 8593, "rarr": 8594, "darr": 8595,
        "harr": 8596, "infin": 8734, "ne": 8800, "le": 8804, "ge": 8805,
        "minus": 8722, "prime": 8242, "euro": 8364, "pound": 163, "yen": 165,
        "cent": 162, "check": 10003, "cross": 10007, "star": 9733, "hearts": 9829,
        "shy": 173, "ensp": 8194, "emsp": 8195, "thinsp": 8201, "zwnj": 8204,
        "zwj": 8205,
    ]

    static func decode(bytes: UnsafeBufferPointer<UInt8>, start: Int, end: Int) -> Decoded? {
        var index = start + 1
        guard index < end else { return nil }

        if bytes[index] == ASCII.hash {
            index += 1
            guard index < end else { return nil }
            var value: UInt32 = 0
            var digits = 0
            if bytes[index] == ASCII.lowerX || bytes[index] == ASCII.upperX {
                index += 1
                while index < end, digits < 8, let digit = hexValue(bytes[index]) {
                    value = value &* 16 &+ digit
                    index += 1
                    digits += 1
                }
            } else {
                while index < end, digits < 9, isDigit(bytes[index]) {
                    value = value &* 10 &+ UInt32(bytes[index] - ASCII.zero)
                    index += 1
                    digits += 1
                }
            }
            guard digits > 0, index < end, bytes[index] == semicolon else { return nil }
            return finish(value: value, end: index + 1)
        }

        var name = ""
        name.reserveCapacity(8)
        while index < end, isAlphanumeric(bytes[index]), name.utf8.count < 12 {
            name.append(Character(UnicodeScalar(bytes[index])))
            index += 1
        }
        guard index < end, bytes[index] == semicolon, let value = named[name] else { return nil }
        return Decoded(scalar: value, end: index + 1)
    }

    /// An out-of-range or surrogate code point becomes U+FFFD, as HTML requires.
    private static func finish(value: UInt32, end: Int) -> Decoded {
        if value == 0 || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF) {
            return Decoded(scalar: 0xFFFD, end: end)
        }
        return Decoded(scalar: value, end: end)
    }

    private static func hexValue(_ byte: UInt8) -> UInt32? {
        if isDigit(byte) { return UInt32(byte - ASCII.zero) }
        let lower = lowercased(byte)
        if lower >= ASCII.lowerA, lower <= 0x66 { return UInt32(lower - ASCII.lowerA) + 10 }
        return nil
    }
}
