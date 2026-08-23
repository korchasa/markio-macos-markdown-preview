/// Inline parsing: code spans, links, images, autolinks, emphasis, entities,
/// breaks, and the handful of inline HTML tags that map onto a text style.
///
/// Runs per block, on demand, when a block is about to be drawn — never for the
/// document as a whole. On a 100 MB file the viewer inline-parses the few
/// kilobytes on screen and nothing else.
///
/// Emphasis follows CommonMark's delimiter-stack algorithm, including the
/// flanking rules and the "rule of three". Brackets are resolved before
/// emphasis and emphasis is not matched across a link boundary — a deliberate
/// simplification of the interleaved reference algorithm that agrees with it on
/// every construct that appears in real documents.
public enum InlineParser {
    /// - Parameter footnotes: the labels the document defines. A `[^label]`
    ///   whose label is not among them is text, not a reference — which is why
    ///   the set has to come from outside a block that knows only itself.
    public static func parse(
        content: [UInt8],
        references: [String: Document.LinkReference],
        documentBytes: [UInt8],
        footnotes: [String: Int32] = [:]
    ) -> InlineContent {
        guard !content.isEmpty else { return .empty }
        return content.withUnsafeBufferPointer { buffer in
            var parser = Parser(
                bytes: buffer,
                references: references,
                documentBytes: documentBytes,
                footnotes: footnotes
            )
            parser.tokenize()
            parser.resolveBrackets()
            parser.resolveEmphasis()
            return parser.flatten()
        }
    }

    // MARK: - Tokens

    fileprivate enum TokenKind: UInt8 {
        case text
        case code
        case entity
        case softBreak
        case hardBreak
        case delimiter
        case bracketOpen
        case bracketClose
        /// Resolved link/image boundaries produced by bracket matching.
        case linkOpen
        case linkClose
        /// A style-carrying inline HTML tag (`<kbd>`, `<mark>`, `<u>`, …).
        case styleOpen
        case styleClose
    }

    fileprivate struct Token {
        var kind: TokenKind
        var range: ByteRange = .empty
        /// Where this token started in the content buffer. Tokens with no text
        /// of their own — breaks, link boundaries — still need a position so
        /// that link syntax can be dropped by byte range rather than by kind.
        var origin: Int32 = -1
        /// Delimiter character, or the style bit an HTML tag maps to.
        var character: UInt8 = 0
        var style: InlineStyle = []
        /// Remaining unmatched delimiter characters.
        var count: Int32 = 0
        var canOpen = false
        var canClose = false
        /// Emphasis levels opened and closed at this token.
        var openEmphasis: UInt8 = 0
        var openStrong: UInt8 = 0
        var openStrike: UInt8 = 0
        var closeEmphasis: UInt8 = 0
        var closeStrong: UInt8 = 0
        var closeStrike: UInt8 = 0
        /// Index into the link table for `.linkOpen`, or -1.
        var link: Int32 = -1
        var isImage = false
        var scalar: UInt32 = 0
        /// A bracket that was consumed by link resolution and must not be shown.
        var dropped = false
    }

    fileprivate struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        let references: [String: Document.LinkReference]
        let documentBytes: [UInt8]
        let footnotes: [String: Int32]
        var tokens: [Token] = []
        var links: [InlineLink] = []
        var pendingTextStart = -1
        /// How many `[` are open. A link inside a link is not a link, so bare
        /// URLs are left alone in there — and, more to the point, a bare scan
        /// that ran past a `]` would swallow the destination that follows it
        /// and leave neither link standing.
        var openBrackets = 0

        init(
            bytes: UnsafeBufferPointer<UInt8>,
            references: [String: Document.LinkReference],
            documentBytes: [UInt8],
            footnotes: [String: Int32]
        ) {
            self.bytes = bytes
            self.references = references
            self.documentBytes = documentBytes
            self.footnotes = footnotes
            tokens.reserveCapacity(bytes.count / 8 + 4)
        }

        // MARK: Tokenizer

        mutating func tokenize() {
            var pos = 0
            let end = bytes.count
            while pos < end {
                let byte = bytes[pos]
                switch byte {
                case ASCII.backslash:
                    if pos + 1 < end, bytes[pos + 1] == ASCII.newline {
                        flushText(upTo: pos)
                        emit(Token(kind: .hardBreak), at: pos)
                        pos += 2
                        continue
                    }
                    if pos + 1 < end, isASCIIPunctuation(bytes[pos + 1]) {
                        flushText(upTo: pos)
                        emit(Token(kind: .text, range: ByteRange(pos + 1, pos + 2)), at: pos)
                        pos += 2
                        continue
                    }
                    startText(at: pos)
                    pos += 1
                case ASCII.backtick:
                    if let consumed = scanCodeSpan(at: pos, end: end) {
                        pos = consumed
                        continue
                    }
                    startText(at: pos)
                    pos += 1
                case ASCII.lessThan:
                    if let consumed = scanAngle(at: pos, end: end) {
                        pos = consumed
                        continue
                    }
                    startText(at: pos)
                    pos += 1
                case ASCII.ampersand:
                    if let consumed = scanEntity(at: pos, end: end) {
                        pos = consumed
                        continue
                    }
                    startText(at: pos)
                    pos += 1
                case ASCII.dollar:
                    if let consumed = scanMath(at: pos, end: end) {
                        pos = consumed
                        continue
                    }
                    startText(at: pos)
                    pos += 1
                case ASCII.bang:
                    if pos + 1 < end, bytes[pos + 1] == ASCII.leftBracket {
                        flushText(upTo: pos)
                        var token = Token(kind: .bracketOpen, range: ByteRange(pos, pos + 2))
                        token.isImage = true
                        emit(token, at: pos)
                        openBrackets += 1
                        pos += 2
                        continue
                    }
                    startText(at: pos)
                    pos += 1
                case ASCII.leftBracket:
                    flushText(upTo: pos)
                    emit(Token(kind: .bracketOpen, range: ByteRange(pos, pos + 1)), at: pos)
                    openBrackets += 1
                    pos += 1
                case ASCII.rightBracket:
                    flushText(upTo: pos)
                    emit(Token(kind: .bracketClose, range: ByteRange(pos, pos + 1)), at: pos)
                    openBrackets = max(0, openBrackets - 1)
                    pos += 1
                case ASCII.asterisk, ASCII.underscore, ASCII.tilde:
                    pos = scanDelimiterRun(at: pos, end: end)
                case ASCII.newline:
                    flushText(upTo: trimmedTextEnd(before: pos))
                    let hard = trailingSpaces(before: pos) >= 2
                    emit(Token(kind: hard ? .hardBreak : .softBreak), at: pos)
                    pos += 1
                // GFM's bare links, with the second byte tested before the
                // call. Every `h` and `w` in ordinary prose passes through
                // here — `the`, `which`, `show` — and a call for each of them
                // was most of what this feature cost.
                case ASCII.lowerH, ASCII.upperH:
                    if pos + 1 < end, lowercased(bytes[pos + 1]) == ASCII.lowerT,
                        let consumed = scanBareLink(at: pos, end: end)
                    {
                        pos = consumed
                        continue
                    }
                    startText(at: pos)
                    pos += 1
                case ASCII.lowerW, ASCII.upperW:
                    if pos + 1 < end, lowercased(bytes[pos + 1]) == ASCII.lowerW,
                        let consumed = scanBareLink(at: pos, end: end)
                    {
                        pos = consumed
                        continue
                    }
                    startText(at: pos)
                    pos += 1
                case ASCII.at:
                    if let consumed = scanBareLink(at: pos, end: end) {
                        pos = consumed
                        continue
                    }
                    startText(at: pos)
                    pos += 1
                default:
                    startText(at: pos)
                    pos += 1
                }
            }
            flushText(upTo: end)
        }

        @inline(__always)
        mutating func emit(_ token: Token, at origin: Int) {
            var token = token
            token.origin = Int32(origin)
            tokens.append(token)
        }

        @inline(__always)
        mutating func startText(at pos: Int) {
            if pendingTextStart < 0 { pendingTextStart = pos }
        }

        @inline(__always)
        mutating func flushText(upTo end: Int) {
            guard pendingTextStart >= 0 else { return }
            if end > pendingTextStart {
                emit(
                    Token(kind: .text, range: ByteRange(pendingTextStart, end)),
                    at: pendingTextStart)
            }
            pendingTextStart = -1
        }

        /// Trailing spaces before a newline are the hard-break marker and are
        /// never part of the text.
        func trimmedTextEnd(before pos: Int) -> Int {
            var end = pos
            while end > 0, bytes[end - 1] == ASCII.space { end -= 1 }
            return end
        }

        func trailingSpaces(before pos: Int) -> Int {
            var count = 0
            var index = pos
            while index > 0, bytes[index - 1] == ASCII.space {
                count += 1
                index -= 1
            }
            return count
        }

        /// A code span: a run of N backticks closed by the next run of exactly N.
        mutating func scanCodeSpan(at start: Int, end: Int) -> Int? {
            var openEnd = start
            while openEnd < end, bytes[openEnd] == ASCII.backtick { openEnd += 1 }
            let width = openEnd - start
            var index = openEnd
            while index < end {
                guard bytes[index] == ASCII.backtick else {
                    index += 1
                    continue
                }
                var closeEnd = index
                while closeEnd < end, bytes[closeEnd] == ASCII.backtick { closeEnd += 1 }
                if closeEnd - index == width {
                    flushText(upTo: start)
                    var contentStart = openEnd
                    var contentEnd = index
                    // One space on each side is stripping syntax, not content —
                    // it is what lets a span hold a literal backtick.
                    if contentEnd > contentStart, bytes[contentStart] == ASCII.space,
                        bytes[contentEnd - 1] == ASCII.space, contentEnd - contentStart > 1
                    {
                        contentStart += 1
                        contentEnd -= 1
                    }
                    var token = Token(kind: .code, range: ByteRange(contentStart, contentEnd))
                    token.style = .code
                    emit(token, at: start)
                    return closeEnd
                }
                index = closeEnd
            }
            return nil
        }

        /// `$…$` and `$$…$$`. The parser only marks the run as a formula and
        /// says whether it was written in display form; reading the LaTeX is the
        /// renderer's job, and a formula it cannot read keeps this source.
        mutating func scanMath(at start: Int, end: Int) -> Int? {
            let display = start + 1 < end && bytes[start + 1] == ASCII.dollar
            let width = display ? 2 : 1
            let contentStart = start + width
            guard contentStart < end, !isSpaceOrTab(bytes[contentStart]) else { return nil }
            var index = contentStart
            while index < end {
                if bytes[index] == ASCII.backslash {
                    index += 2
                    continue
                }
                if bytes[index] == ASCII.dollar {
                    let runEnd = index + width
                    guard runEnd <= end else { return nil }
                    if display, index + 1 >= end || bytes[index + 1] != ASCII.dollar {
                        index += 1
                        continue
                    }
                    guard index > contentStart, !isSpaceOrTab(bytes[index - 1]) else { return nil }
                    // `$5 and $10` must not become math.
                    if !display, runEnd < end, isDigit(bytes[runEnd]) { return nil }
                    flushText(upTo: start)
                    var token = Token(kind: .code, range: ByteRange(contentStart, index))
                    token.style = display ? [.math, .displayMath] : .math
                    emit(token, at: start)
                    return runEnd
                }
                if bytes[index] == ASCII.newline, !display { return nil }
                index += 1
            }
            return nil
        }

        /// `<…>`: an autolink, a style-carrying inline tag, or a tag to drop.
        mutating func scanAngle(at start: Int, end: Int) -> Int? {
            if let result = scanAutolink(at: start, end: end) { return result }
            guard let tag = InlineHTML.tag(bytes: bytes, start: start, end: end) else { return nil }
            flushText(upTo: start)
            if tag.isBreak {
                emit(Token(kind: .hardBreak), at: start)
            } else if let style = tag.style {
                var token = Token(kind: tag.isClosing ? .styleClose : .styleOpen)
                token.style = style
                emit(token, at: start)
            }
            // Tags with no visual meaning of their own are dropped: there is no
            // HTML engine here to give them one.
            return tag.end
        }

        mutating func scanAutolink(at start: Int, end: Int) -> Int? {
            var index = start + 1
            var sawColon = false
            var sawAt = false
            while index < end {
                let byte = bytes[index]
                if byte == ASCII.greaterThan { break }
                if byte == ASCII.space || byte == ASCII.newline || byte == ASCII.lessThan {
                    return nil
                }
                if byte == ASCII.colon { sawColon = true }
                if byte == 0x40 { sawAt = true }
                index += 1
            }
            guard index < end, index > start + 1, sawColon || sawAt else { return nil }
            let inner = ByteRange(start + 1, index)
            let text = bytes.textSlice(inner)
            guard !text.isEmpty else { return nil }
            flushText(upTo: start)
            let destination = sawColon ? text : "mailto:\(text)"
            links.append(InlineLink(destination: destination, title: "", isImage: false))
            var open = Token(kind: .linkOpen)
            open.link = Int32(links.count - 1)
            emit(open, at: start)
            emit(Token(kind: .text, range: inner), at: start + 1)
            emit(Token(kind: .linkClose), at: index)
            return index + 1
        }

        /// A URL or an address written bare, as GitHub links them.
        ///
        /// An email is found from its `@`, by which time its local part has
        /// been read as text — so the scan may reach back, but never further
        /// than the text run being built, or it would rewrite something already
        /// tokenized.
        mutating func scanBareLink(at start: Int, end: Int) -> Int? {
            guard openBrackets == 0 else { return nil }
            // `](https://…)` is a destination, not prose: the brackets closed a
            // moment ago and what follows belongs to the link they are part of.
            // Checked here, before anything is scanned, because a document full
            // of ordinary links would otherwise scan and build every
            // destination twice — that alone cost a third of the parser's
            // throughput on a 32 MB file.
            if start >= 2, bytes[start - 1] == ASCII.leftParen,
                bytes[start - 2] == ASCII.rightBracket
            {
                return nil
            }
            let match: ExtendedAutolink.Match?
            if bytes[start] == ASCII.at {
                guard pendingTextStart >= 0 else { return nil }
                match = ExtendedAutolink.email(
                    bytes, at: start, end: end, notBefore: pendingTextStart)
            } else {
                match = ExtendedAutolink.url(bytes, at: start, end: end)
            }
            guard let match else { return nil }
            // The same for an address, whose local part put its start behind
            // the cursor: `](me@example.com)` is a destination too.
            if match.start >= 2, bytes[match.start - 1] == ASCII.leftParen,
                bytes[match.start - 2] == ASCII.rightBracket
            {
                return nil
            }
            flushText(upTo: match.start)
            links.append(
                InlineLink(destination: match.destination, title: "", isImage: false))
            var open = Token(kind: .linkOpen)
            open.link = Int32(links.count - 1)
            emit(open, at: match.start)
            emit(
                Token(kind: .text, range: ByteRange(match.start, match.end)), at: match.start)
            emit(Token(kind: .linkClose), at: match.end)
            return match.end
        }

        mutating func scanEntity(at start: Int, end: Int) -> Int? {
            guard let entity = Entities.decode(bytes: bytes, start: start, end: end) else {
                return nil
            }
            flushText(upTo: start)
            var token = Token(kind: .entity)
            token.scalar = entity.scalar
            emit(token, at: start)
            return entity.end
        }

        mutating func scanDelimiterRun(at start: Int, end: Int) -> Int {
            let character = bytes[start]
            var runEnd = start
            while runEnd < end, bytes[runEnd] == character { runEnd += 1 }
            let length = runEnd - start
            // A single `~` is not GFM strikethrough; leave it as text.
            if character == ASCII.tilde, length < 2 {
                startText(at: start)
                return runEnd
            }
            flushText(upTo: start)

            let before: UInt8? = start > 0 ? bytes[start - 1] : nil
            let after: UInt8? = runEnd < end ? bytes[runEnd] : nil
            let beforeWhitespace = before.map { isWhitespaceByte($0) } ?? true
            let afterWhitespace = after.map { isWhitespaceByte($0) } ?? true
            let beforePunctuation = before.map { isASCIIPunctuation($0) } ?? false
            let afterPunctuation = after.map { isASCIIPunctuation($0) } ?? false

            let leftFlanking =
                !afterWhitespace && (!afterPunctuation || beforeWhitespace || beforePunctuation)
            let rightFlanking =
                !beforeWhitespace && (!beforePunctuation || afterWhitespace || afterPunctuation)

            var token = Token(kind: .delimiter, range: ByteRange(start, runEnd))
            token.character = character
            token.count = Int32(length)
            if character == ASCII.underscore {
                token.canOpen = leftFlanking && (!rightFlanking || beforePunctuation)
                token.canClose = rightFlanking && (!leftFlanking || afterPunctuation)
            } else {
                token.canOpen = leftFlanking
                token.canClose = rightFlanking
            }
            emit(token, at: start)
            return runEnd
        }

        // MARK: Brackets

        /// Match `[` … `]` pairs into links and images, consuming the
        /// destination that follows. Unmatched brackets stay literal text.
        mutating func resolveBrackets() {
            var stack: [Int] = []
            var index = 0
            while index < tokens.count {
                guard !tokens[index].dropped else {
                    index += 1
                    continue
                }
                switch tokens[index].kind {
                case .bracketOpen:
                    stack.append(index)
                case .bracketClose:
                    guard let openIndex = stack.popLast() else {
                        tokens[index].kind = .text
                        index += 1
                        continue
                    }
                    if matchFootnote(openIndex: openIndex, closeIndex: index) {
                        index += 1
                        continue
                    }
                    if let resolved = matchLink(openIndex: openIndex, closeIndex: index) {
                        index = resolved
                        continue
                    }
                    tokens[openIndex].kind = .text
                    tokens[index].kind = .text
                default:
                    break
                }
                index += 1
            }
            // Any bracket still open never closed; show it.
            for openIndex in stack { tokens[openIndex].kind = .text }
        }

        /// Turn `[^label]` into a reference to the footnote of that label.
        ///
        /// It becomes a link to the definition's anchor, raised and set small
        /// the way a footnote marker is. The caret is syntax and is trimmed off
        /// the text token, so what the reader sees — and what Find searches —
        /// is the label alone.
        mutating func matchFootnote(openIndex: Int, closeIndex: Int) -> Bool {
            guard !tokens[openIndex].isImage, !footnotes.isEmpty else { return false }
            let start = Int(tokens[openIndex].range.end)
            let end = Int(tokens[closeIndex].range.start)
            guard end > start + 1, bytes[start] == ASCII.caret else { return false }
            let label = bytes.textSlice(ByteRange(start + 1, end))
            guard footnotes[LinkLabel.normalize(label)] != nil else { return false }

            links.append(
                InlineLink(
                    destination: Footnote.destination(label: label),
                    title: "",
                    isImage: false
                )
            )
            let link = Int32(links.count - 1)
            tokens[openIndex].kind = .linkOpen
            tokens[openIndex].link = link
            tokens[openIndex].style = [.raised, .footnote]
            tokens[closeIndex].kind = .linkClose
            tokens[closeIndex].link = link
            tokens[closeIndex].style = [.raised, .footnote]
            for cursor in (openIndex + 1)..<closeIndex
            where tokens[cursor].kind == .text && Int(tokens[cursor].range.start) == start {
                tokens[cursor].range.start += 1
            }
            return true
        }

        /// Turn a matched bracket pair into link tokens, or return nil when
        /// nothing valid follows the `]`.
        mutating func matchLink(openIndex: Int, closeIndex: Int) -> Int? {
            let isImage = tokens[openIndex].isImage
            let afterClose = Int(tokens[closeIndex].range.end)

            var destination = ""
            var title = ""
            var consumedTo = afterClose

            if afterClose < bytes.count, bytes[afterClose] == ASCII.leftParen {
                guard let inline = parseInlineDestination(from: afterClose + 1) else { return nil }
                destination = inline.destination
                title = inline.title
                consumedTo = inline.end
            } else {
                var labelRange: ByteRange
                if afterClose + 1 < bytes.count, bytes[afterClose] == ASCII.leftBracket,
                    let labelEnd = findLabelEnd(from: afterClose + 1)
                {
                    labelRange = ByteRange(afterClose + 1, labelEnd)
                    consumedTo = labelEnd + 1
                    if labelRange.isEmpty {
                        labelRange = textRange(from: openIndex, to: closeIndex)
                    }
                } else {
                    labelRange = textRange(from: openIndex, to: closeIndex)
                }
                let key = normalizedLabel(labelRange)
                guard let reference = references[key] else { return nil }
                destination = documentBytes.text(in: reference.destination)
                title = documentBytes.text(in: reference.title)
            }

            links.append(
                InlineLink(destination: destination, title: title, isImage: isImage)
            )
            let link = Int32(links.count - 1)
            tokens[openIndex].kind = .linkOpen
            tokens[openIndex].link = link
            tokens[openIndex].isImage = isImage
            tokens[closeIndex].kind = .linkClose
            tokens[closeIndex].link = link
            // Whatever followed the `]` is syntax; drop the text tokens it
            // covers so the destination is not printed twice.
            dropTextTokens(coveringFrom: afterClose, to: consumedTo, after: closeIndex)
            return closeIndex + 1
        }

        struct InlineDestination {
            var destination: String
            var title: String
            var end: Int
        }

        func parseInlineDestination(from start: Int) -> InlineDestination? {
            var index = start
            let end = bytes.count
            while index < end, isWhitespaceByte(bytes[index]) { index += 1 }
            var destination = ""
            if index < end, bytes[index] == ASCII.lessThan {
                let open = index + 1
                index = open
                while index < end, bytes[index] != ASCII.greaterThan, bytes[index] != ASCII.newline
                {
                    index += 1
                }
                guard index < end, bytes[index] == ASCII.greaterThan else { return nil }
                destination = bytes.textSlice(ByteRange(open, index))
                index += 1
            } else {
                let open = index
                var depth = 0
                while index < end {
                    let byte = bytes[index]
                    if byte == ASCII.backslash {
                        index += 2
                        continue
                    }
                    if byte == ASCII.leftParen { depth += 1 }
                    if byte == ASCII.rightParen {
                        if depth == 0 { break }
                        depth -= 1
                    }
                    if isWhitespaceByte(byte) { break }
                    index += 1
                }
                destination = unescaped(ByteRange(open, index))
            }
            while index < end, isWhitespaceByte(bytes[index]) { index += 1 }
            var title = ""
            if index < end, bytes[index] == ASCII.quote || bytes[index] == ASCII.apostrophe {
                let quote = bytes[index]
                let open = index + 1
                index = open
                while index < end, bytes[index] != quote {
                    if bytes[index] == ASCII.backslash { index += 1 }
                    index += 1
                }
                guard index < end else { return nil }
                title = unescaped(ByteRange(open, index))
                index += 1
            }
            while index < end, isWhitespaceByte(bytes[index]) { index += 1 }
            guard index < end, bytes[index] == ASCII.rightParen else { return nil }
            return InlineDestination(destination: destination, title: title, end: index + 1)
        }

        func findLabelEnd(from start: Int) -> Int? {
            var index = start
            let end = bytes.count
            while index < end {
                if bytes[index] == ASCII.backslash {
                    index += 2
                    continue
                }
                if bytes[index] == ASCII.rightBracket { return index }
                if bytes[index] == ASCII.leftBracket { return nil }
                index += 1
            }
            return nil
        }

        func textRange(from openIndex: Int, to closeIndex: Int) -> ByteRange {
            let start = tokens[openIndex].range.end
            let end = tokens[closeIndex].range.start
            return ByteRange(start: start, end: max(start, end))
        }

        func normalizedLabel(_ range: ByteRange) -> String {
            LinkLabel.normalize(bytes.textSlice(range))
        }

        /// Drop backslash escapes, staying in byte space so multi-byte UTF-8
        /// sequences survive intact.
        func unescaped(_ range: ByteRange) -> String {
            var out: [UInt8] = []
            out.reserveCapacity(range.count)
            var index = range.lowerBound
            while index < range.upperBound {
                if bytes[index] == ASCII.backslash, index + 1 < range.upperBound,
                    isASCIIPunctuation(bytes[index + 1])
                {
                    index += 1
                }
                out.append(bytes[index])
                index += 1
            }
            return String(decoding: out, as: UTF8.self)
        }

        /// Drop the tokens covering a link's destination syntax.
        ///
        /// By byte range, not by token kind: the destination may have been
        /// tokenized as anything at all — an autolink inside `[t](<u>)`, a
        /// bracket pair inside `[t][ref]` — and a kind-based rule misses
        /// exactly those cases.
        mutating func dropTextTokens(coveringFrom start: Int, to end: Int, after index: Int) {
            guard end > start else { return }
            var cursor = index + 1
            while cursor < tokens.count {
                let token = tokens[cursor]
                guard Int(token.origin) < end else { return }
                if token.kind == .text, Int(token.range.end) > end, Int(token.range.start) < end {
                    // A text token straddling the end keeps its tail.
                    tokens[cursor].range = ByteRange(end, Int(token.range.end))
                    return
                }
                tokens[cursor].dropped = true
                cursor += 1
            }
        }

        // MARK: Emphasis

        mutating func resolveEmphasis() {
            var stack: [Int] = []
            var index = 0
            while index < tokens.count {
                let token = tokens[index]
                // A link boundary is a hard wall: emphasis never spans it.
                if token.kind == .linkOpen || token.kind == .linkClose {
                    stack.removeAll(keepingCapacity: true)
                    index += 1
                    continue
                }
                guard token.kind == .delimiter, !token.dropped else {
                    index += 1
                    continue
                }
                if token.canClose {
                    matchCloser(at: index, stack: &stack)
                }
                if tokens[index].count > 0, tokens[index].canOpen {
                    stack.append(index)
                }
                index += 1
            }
        }

        mutating func matchCloser(at closerIndex: Int, stack: inout [Int]) {
            while tokens[closerIndex].count > 0 {
                var openerSlot = -1
                var slot = stack.count - 1
                while slot >= 0 {
                    let openerIndex = stack[slot]
                    let opener = tokens[openerIndex]
                    if opener.count > 0, opener.character == tokens[closerIndex].character,
                        !violatesRuleOfThree(opener: openerIndex, closer: closerIndex)
                    {
                        openerSlot = slot
                        break
                    }
                    slot -= 1
                }
                guard openerSlot >= 0 else { return }
                let openerIndex = stack[openerSlot]
                let character = tokens[closerIndex].character
                let strike = character == ASCII.tilde
                let strong =
                    strike || (tokens[openerIndex].count >= 2 && tokens[closerIndex].count >= 2)
                let width: Int32 = strong ? 2 : 1
                if strike, tokens[openerIndex].count < 2 || tokens[closerIndex].count < 2 { return }

                if strike {
                    tokens[openerIndex].openStrike += 1
                    tokens[closerIndex].closeStrike += 1
                } else if strong {
                    tokens[openerIndex].openStrong += 1
                    tokens[closerIndex].closeStrong += 1
                } else {
                    tokens[openerIndex].openEmphasis += 1
                    tokens[closerIndex].closeEmphasis += 1
                }
                tokens[openerIndex].count -= width
                tokens[closerIndex].count -= width
                // Delimiters trapped between a matched pair can never match now.
                stack.removeSubrange((openerSlot + 1)..<stack.count)
                if tokens[openerIndex].count == 0 { stack.removeLast() }
            }
        }

        /// CommonMark's rule of three: a run that both opens and closes may not
        /// pair with one whose combined length is a multiple of three unless
        /// both lengths are.
        func violatesRuleOfThree(opener: Int, closer: Int) -> Bool {
            let openerToken = tokens[opener]
            let closerToken = tokens[closer]
            guard openerToken.canClose || closerToken.canOpen else { return false }
            let originalOpener = Int(openerToken.range.count)
            let originalCloser = Int(closerToken.range.count)
            guard (originalOpener + originalCloser) % 3 == 0 else { return false }
            return !(originalOpener % 3 == 0 && originalCloser % 3 == 0)
        }

        // MARK: Flatten

        mutating func flatten() -> InlineContent {
            var runs: [InlineRun] = []
            runs.reserveCapacity(tokens.count)
            var emphasis = 0
            var strong = 0
            var strike = 0
            var htmlStyles: [InlineStyle] = []
            var linkStack: [Int32] = []

            func currentStyle() -> InlineStyle {
                var style: InlineStyle = []
                if emphasis > 0 { style.insert(.emphasis) }
                if strong > 0 { style.insert(.strong) }
                if strike > 0 { style.insert(.strikethrough) }
                if !linkStack.isEmpty { style.insert(.link) }
                for extra in htmlStyles { style.formUnion(extra) }
                return style
            }

            for token in tokens where !token.dropped {
                switch token.kind {
                case .text:
                    guard !token.range.isEmpty else { continue }
                    runs.append(
                        InlineRun(
                            kind: .text,
                            style: currentStyle(),
                            range: token.range,
                            link: linkStack.last ?? -1
                        )
                    )
                case .code:
                    var style = currentStyle()
                    style.formUnion(token.style)
                    runs.append(
                        InlineRun(
                            kind: .text,
                            style: style,
                            range: token.range,
                            link: linkStack.last ?? -1
                        )
                    )
                case .entity:
                    runs.append(
                        InlineRun(
                            kind: .entity,
                            style: currentStyle(),
                            range: .empty,
                            link: linkStack.last ?? -1,
                            scalar: token.scalar
                        )
                    )
                case .softBreak:
                    runs.append(InlineRun(kind: .softBreak, style: [], range: .empty))
                case .hardBreak:
                    runs.append(InlineRun(kind: .hardBreak, style: [], range: .empty))
                case .delimiter:
                    strike -= Int(token.closeStrike)
                    strong -= Int(token.closeStrong)
                    emphasis -= Int(token.closeEmphasis)
                    // Characters that never found a partner are literal text.
                    if token.count > 0 {
                        let start = Int(token.range.start)
                        runs.append(
                            InlineRun(
                                kind: .text,
                                style: currentStyle(),
                                range: ByteRange(start, start + Int(token.count)),
                                link: linkStack.last ?? -1
                            )
                        )
                    }
                    emphasis += Int(token.openEmphasis)
                    strong += Int(token.openStrong)
                    strike += Int(token.openStrike)
                case .linkOpen:
                    if token.isImage {
                        runs.append(
                            InlineRun(
                                kind: .image,
                                style: currentStyle(),
                                range: .empty,
                                link: token.link
                            )
                        )
                    }
                    linkStack.append(token.link)
                    // A footnote marker carries its own style: the link is what
                    // makes it clickable, the raised style is what makes it
                    // look like a footnote.
                    if !token.style.isEmpty { htmlStyles.append(token.style) }
                case .linkClose:
                    if !linkStack.isEmpty { linkStack.removeLast() }
                    if !token.style.isEmpty,
                        let position = htmlStyles.lastIndex(of: token.style)
                    {
                        htmlStyles.remove(at: position)
                    }
                case .styleOpen:
                    htmlStyles.append(token.style)
                case .styleClose:
                    if let position = htmlStyles.lastIndex(of: token.style) {
                        htmlStyles.remove(at: position)
                    }
                case .bracketOpen, .bracketClose:
                    runs.append(
                        InlineRun(
                            kind: .text,
                            style: currentStyle(),
                            range: token.range,
                            link: linkStack.last ?? -1
                        )
                    )
                }
            }
            return InlineContent(runs: runs, links: links)
        }
    }
}

@inline(__always)
func isWhitespaceByte(_ byte: UInt8) -> Bool {
    byte == ASCII.space || byte == ASCII.tab || byte == ASCII.newline
        || byte == ASCII.carriageReturn
}

@inline(__always)
func isASCIIPunctuation(_ byte: UInt8) -> Bool {
    (byte >= 0x21 && byte <= 0x2F) || (byte >= 0x3A && byte <= 0x40)
        || (byte >= 0x5B && byte <= 0x60) || (byte >= 0x7B && byte <= 0x7E)
}

extension UnsafeBufferPointer where Element == UInt8 {
    func textSlice(_ range: ByteRange) -> String {
        guard !range.isEmpty else { return "" }
        return String(
            decoding: UnsafeBufferPointer(rebasing: self[range.lowerBound..<range.upperBound]),
            as: UTF8.self
        )
    }
}

/// Link labels compare case-insensitively with runs of whitespace collapsed.
enum LinkLabel {
    static func normalize(_ label: String) -> String {
        var out = ""
        out.reserveCapacity(label.count)
        var pendingSpace = false
        for scalar in label.lowercased().unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\n" {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.unicodeScalars.append(scalar)
        }
        return out
    }
}
