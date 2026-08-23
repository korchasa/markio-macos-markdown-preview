/// GFM's autolink extension: a link the author never marked up.
///
/// Reports written by people and by agents are full of bare addresses — a
/// repository, a dashboard, an email at the foot of a summary — and every one
/// of them is a link on GitHub. Without this the same file reads here as plain
/// text, and that is the first difference a reader notices between the two.
///
/// What follows is the extension's own arithmetic: what may stand in front of a
/// bare link, what a domain is allowed to be made of, and which trailing
/// characters belong to the sentence rather than to the link. The last of those
/// is the whole difficulty — `see www.example.com.` ends in a full stop, and
/// `(see https://example.com/a_(b))` ends in a bracket that closes the aside
/// rather than the path.
enum ExtendedAutolink {
    struct Match {
        /// Where the link starts in the block's bytes — behind the cursor for
        /// an email, whose local part has already been read as text.
        var start: Int
        var end: Int
        var destination: String
    }

    /// What may precede a bare link.
    ///
    /// Anything else and the run is ordinary text, which is what stops
    /// `notwww.example.com` and an `@` inside a word from becoming links.
    static func canStart(after byte: UInt8?) -> Bool {
        guard let byte else { return true }
        if isWhitespaceByte(byte) { return true }
        return byte == ASCII.asterisk || byte == ASCII.underscore || byte == ASCII.tilde
            || byte == ASCII.leftParen
    }

    /// A URL written bare: `https://…`, `http://…` or `www.…`.
    static func url(_ bytes: UnsafeBufferPointer<UInt8>, at start: Int, end: Int) -> Match? {
        // The second byte first, because it is one comparison and it throws out
        // nearly every candidate: every word beginning with h or w that is not
        // `ht…` or `ww…` — `how`, `window`, `heading` — leaves here. Reaching
        // the prefix comparisons for all of those cost a third of the inline
        // parser's throughput on a 32 MB document.
        guard start + 1 < end else { return nil }
        let second = lowercased(bytes[start + 1])
        switch lowercased(bytes[start]) {
        case ASCII.lowerH where second == ASCII.lowerT: break
        case ASCII.lowerW where second == ASCII.lowerW: break
        default: return nil
        }
        guard canStart(after: start > 0 ? bytes[start - 1] : nil) else { return nil }
        let isWWW: Bool
        // Where the domain begins for the purpose of checking it. `www.` is
        // part of the link's text but not part of the domain that has to hold a
        // period — which is why `www.example` is not a link and
        // `www.example.com` is.
        let domainStart: Int
        if matches(bytes, at: start, end: end, "https://") {
            isWWW = false
            domainStart = start + 8
        } else if matches(bytes, at: start, end: end, "http://") {
            isWWW = false
            domainStart = start + 7
        } else if matches(bytes, at: start, end: end, "www.") {
            isWWW = true
            domainStart = start + 4
        } else {
            return nil
        }

        var domainEnd = domainStart
        while domainEnd < end, isDomainByte(bytes[domainEnd]) { domainEnd += 1 }
        guard
            isDomain(
                bytes, from: domainStart, to: trimmedDots(bytes, from: domainStart, to: domainEnd))
        else { return nil }

        // The path runs to the first space. `<` ends it too, because a bare
        // link that swallowed an HTML tag would take the tag's text with it.
        var stop = domainEnd
        while stop < end, !isWhitespaceByte(bytes[stop]), bytes[stop] != ASCII.lessThan {
            stop += 1
        }
        let finish = trimTrailing(bytes, from: start, to: stop)
        // Trimming must not eat into the domain: `www.example.` is not a link.
        guard finish >= domainStart, isDomain(bytes, from: domainStart, to: min(finish, domainEnd))
        else { return nil }
        let text = string(bytes, from: start, to: finish)
        return Match(start: start, end: finish, destination: isWWW ? "http://\(text)" : text)
    }

    /// An email address written bare, found from its `@`.
    ///
    /// The local part has already been read as text by the time the `@` turns
    /// up, so this is the one scan that walks backwards — and `floor` is how
    /// far back it may go: the start of the text run being built, never past
    /// something already tokenized.
    static func email(
        _ bytes: UnsafeBufferPointer<UInt8>, at atSign: Int, end: Int, notBefore floor: Int
    ) -> Match? {
        var start = atSign
        while start > floor, isLocalByte(bytes[start - 1]) { start -= 1 }
        guard start < atSign else { return nil }
        guard canStart(after: start > 0 ? bytes[start - 1] : nil) else { return nil }

        var domainEnd = atSign + 1
        while domainEnd < end, isDomainByte(bytes[domainEnd]) { domainEnd += 1 }
        let finish = trimmedDots(bytes, from: atSign + 1, to: domainEnd)
        guard finish > atSign + 1 else { return nil }
        // At least one period, and nothing that reads as the end of a sentence.
        guard contains(bytes, ASCII.dot, from: atSign + 1, to: finish) else { return nil }
        let last = bytes[finish - 1]
        guard last != ASCII.hyphen, last != ASCII.underscore else { return nil }
        let text = string(bytes, from: start, to: finish)
        return Match(start: start, end: finish, destination: "mailto:\(text)")
    }

    // MARK: - The domain

    /// Segments of alphanumerics, hyphens and underscores, separated by
    /// periods, with at least one period and no underscore in the last two
    /// segments — which is the rule that keeps `a_b.c` from linking.
    private static func isDomain(_ bytes: UnsafeBufferPointer<UInt8>, from: Int, to: Int) -> Bool {
        guard to > from else { return false }
        var segments: [(start: Int, end: Int)] = []
        var segmentStart = from
        var index = from
        while index <= to {
            if index == to || bytes[index] == ASCII.dot {
                guard index > segmentStart else { return false }
                segments.append((segmentStart, index))
                segmentStart = index + 1
            }
            index += 1
        }
        guard segments.count >= 2 else { return false }
        for segment in segments {
            for byte in segment.start..<segment.end {
                let value = bytes[byte]
                guard isAlphanumeric(value) || value == ASCII.hyphen || value == ASCII.underscore
                else { return false }
            }
        }
        for segment in segments.suffix(2) {
            if contains(bytes, ASCII.underscore, from: segment.start, to: segment.end) {
                return false
            }
        }
        return true
    }

    // MARK: - Where a link ends

    /// Trailing characters that belong to the prose rather than to the link.
    private static func trimTrailing(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> Int {
        var stop = end
        while stop > start {
            let byte = bytes[stop - 1]
            if byte == ASCII.question || byte == ASCII.bang || byte == ASCII.dot
                || byte == ASCII.comma || byte == ASCII.colon || byte == ASCII.semicolon
                || byte == ASCII.asterisk || byte == ASCII.underscore || byte == ASCII.tilde
            {
                // A semicolon may be the tail of an entity, and then the whole
                // entity goes: `https://x.com/a&amp;` links to `…/a`.
                if byte == ASCII.semicolon, let amp = entityStart(bytes, before: stop, floor: start)
                {
                    stop = amp
                    continue
                }
                stop -= 1
                continue
            }
            // A closing bracket is part of the path only while the path opened
            // one: `(see https://x.com/a)` ends at the `a`, `…/a_(b)` does not.
            if byte == ASCII.rightParen {
                var opens = 0
                var closes = 0
                for index in start..<stop {
                    if bytes[index] == ASCII.leftParen { opens += 1 }
                    if bytes[index] == ASCII.rightParen { closes += 1 }
                }
                if closes > opens {
                    stop -= 1
                    continue
                }
            }
            break
        }
        return stop
    }

    /// Where the `&name;` ending at `end` begins, if it is one.
    private static func entityStart(
        _ bytes: UnsafeBufferPointer<UInt8>, before end: Int, floor: Int
    ) -> Int? {
        var index = end - 1
        while index > floor, isAlphanumeric(bytes[index - 1]) { index -= 1 }
        guard index > floor, bytes[index - 1] == ASCII.ampersand, index < end - 1 else {
            return nil
        }
        return index - 1
    }

    // MARK: - Bytes

    private static func isDomainByte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == ASCII.hyphen || byte == ASCII.underscore
            || byte == ASCII.dot
    }

    private static func isLocalByte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == ASCII.dot || byte == ASCII.hyphen
            || byte == ASCII.underscore || byte == ASCII.plus
    }

    private static func trimmedDots(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> Int {
        var stop = end
        while stop > start, bytes[stop - 1] == ASCII.dot { stop -= 1 }
        return stop
    }

    private static func contains(
        _ bytes: UnsafeBufferPointer<UInt8>, _ byte: UInt8, from start: Int, to end: Int
    ) -> Bool {
        for index in start..<end where bytes[index] == byte { return true }
        return false
    }

    /// Case-insensitive, because `HTTPS://` and `WWW.` are written too.
    ///
    /// `StaticString` rather than `String`: this runs on every `h` and `w` that
    /// starts a word, and building an array of the needle each time halved the
    /// inline parser's throughput on a 32 MB document. A static string hands
    /// over its bytes without allocating anything.
    @inline(__always)
    private static func matches(
        _ bytes: UnsafeBufferPointer<UInt8>, at start: Int, end: Int, _ text: StaticString
    ) -> Bool {
        text.withUTF8Buffer { needle in
            guard start + needle.count <= end else { return false }
            for offset in 0..<needle.count
            where lowercased(bytes[start + offset]) != needle[offset] {
                return false
            }
            return true
        }
    }

    private static func string(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(end - start)
        for index in start..<end { out.append(bytes[index]) }
        return String(decoding: out, as: UTF8.self)
    }
}
