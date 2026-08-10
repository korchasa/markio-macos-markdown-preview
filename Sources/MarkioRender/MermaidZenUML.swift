import Foundation

/// A ZenUML diagram, read into a sequence diagram.
///
/// It says the same thing a `sequenceDiagram` says and says it as code: a call
/// is `B.method()`, who is calling is wherever the reader has got to, and a
/// block of calls sits in the braces after it. So the work here is keeping that
/// stack of callers while the braces open and close, and handing the result to
/// the layout a sequence diagram already has.
enum ZenUML {
    private enum Frame {
        /// A call whose braces are open: the callee is on top until they close.
        case call
        case control(SequenceDiagram.Block)
    }

    static func parse(_ lines: [Substring]) -> SequenceDiagram? {
        var diagram = SequenceDiagram(participants: [], items: [])
        var stack: [Frame] = []
        /// Who is calling, innermost last.
        var callers: [Int] = []
        /// The `//` lines read so far, waiting for the message they belong to.
        var pending: [String] = []
        /// Set by a bare `@return`/`@reply`: the next message is an answer.
        var answers = false

        func index(of name: String) -> Int? {
            let id = name.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            guard !id.isEmpty, !id.contains(" ") else { return nil }
            if let existing = diagram.participants.firstIndex(where: { $0.id == id }) {
                return existing
            }
            diagram.participants.append(SequenceDiagram.Participant(id: id, label: id))
            return diagram.participants.count - 1
        }

        func append(_ item: SequenceDiagram.Item) {
            for position in stack.indices.reversed() {
                guard case .control(var block) = stack[position] else { continue }
                block.sections[block.sections.count - 1].items.append(item)
                stack[position] = .control(block)
                return
            }
            diagram.items.append(item)
        }

        /// Put a message down, with whatever was written above it and with the
        /// dashes a `@return` annotator asked for.
        func say(_ message: SequenceDiagram.Message) {
            var message = message
            if answers {
                message.dashed = true
                answers = false
            }
            if !pending.isEmpty {
                append(.comment(pending))
                pending = []
            }
            append(.message(message))
        }

        /// Who is calling. Nobody having said, it is the nameless figure
        /// Mermaid draws to the left of everyone.
        func starter() -> Int? {
            if let caller = callers.last { return caller }
            diagram.participants.insert(
                SequenceDiagram.Participant(id: "__starter", label: "", isActor: true), at: 0)
            callers = [0]
            return 0
        }

        /// The openers, with the block kind each becomes.
        let openers: [(word: String, kind: String)] = [
            ("if", "alt"), ("while", "loop"), ("for", "loop"), ("forEach", "loop"),
            ("opt", "opt"), ("par", "par"), ("try", "try"),
        ]

        for raw in lines {
            var line = raw
            // A comment belongs to the message under it, so it waits here until
            // that message is written; one standing over a participant is
            // dropped, which is what ZenUML does with it.
            if line.hasPrefix("//") {
                pending.append(
                    String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                continue
            }
            // `} else if (…) {` is a closing and an opening on one line, so the
            // closing brace is dealt with before anything else on it.
            if line.hasPrefix("}") {
                line = line.dropFirst().trimmingCharacters(in: .whitespaces)[...]
                let arms = ["else", "catch", "finally"]
                if let arm = arms.first(where: { line.hasPrefix($0) }) {
                    guard case .control(var block)? = stack.last else { return nil }
                    guard line.hasSuffix("{") else { return nil }
                    // `else if (x) {` names its arm `x`; a plain `else {` has
                    // nothing of its own to say, and `catch`/`finally` are
                    // named by the word itself.
                    var words = String(line.dropFirst(arm.count).dropLast())
                        .trimmingCharacters(in: .whitespaces)
                    if words.hasPrefix("if") {
                        words = String(words.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    }
                    var title = condition(words)
                    if arm != "else" { title = title.isEmpty ? arm : "\(arm) \(title)" }
                    block.sections.append(SequenceDiagram.Section(title: title, items: []))
                    stack[stack.count - 1] = .control(block)
                    continue
                }
                // A brace closing nothing closes nothing, which is how Mermaid
                // reads a stray one.
                guard let frame = stack.popLast() else { continue }
                switch frame {
                case .call:
                    guard let callee = callers.last, callers.count > 1 else { return nil }
                    // The bar down the callee's lifeline lasts exactly as long
                    // as the braces do.
                    append(.deactivate(callee))
                    callers.removeLast()
                case .control(let block):
                    append(.block(block))
                }
                guard line.isEmpty else { return nil }
                continue
            }

            let word = String(line.prefix(while: { !$0.isWhitespace && $0 != "(" }))
            if word == "title" {
                diagram.title = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
                continue
            }
            if word == "autonumber" {
                diagram.autonumber = true
                continue
            }
            if word.hasPrefix("@") {
                // `@return` and `@reply` standing alone say that the message
                // written under them is an answer rather than a call.
                if word == "@return" || word == "@reply",
                    line.dropFirst(word.count).trimmingCharacters(in: .whitespaces).isEmpty
                {
                    answers = true
                    continue
                }
                // `@Starter(A)` says where the first call comes from; every other
                // `@Word Name` is a participant with a kind this does not draw.
                if word == "@Starter" {
                    guard let open = line.firstIndex(of: "("), line.hasSuffix(")"),
                        let start = index(
                            of: String(
                                line[line.index(after: open)..<line.index(before: line.endIndex)]))
                    else { return nil }
                    callers = [start]
                    continue
                }
                let name = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, index(of: name) != nil else { return nil }
                continue
            }
            if let opener = openers.first(where: { $0.word == word }) {
                guard line.hasSuffix("{") else { return nil }
                let title = condition(
                    String(line.dropFirst(word.count).dropLast()).trimmingCharacters(
                        in: .whitespaces))
                stack.append(
                    .control(
                        SequenceDiagram.Block(
                            kind: opener.kind,
                            sections: [SequenceDiagram.Section(title: title, items: [])])))
                continue
            }
            if word == "return" || word == "@return" {
                // A reply goes back to whoever is waiting, which is the caller
                // one step down the stack.
                // A reply with nobody waiting for it has nowhere to go, and
                // Mermaid draws the diagram without it.
                guard callers.count > 1 else { continue }
                let words = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
                say(
                    SequenceDiagram.Message(
                        from: callers[callers.count - 1], to: callers[callers.count - 2],
                        text: words, dashed: true))
                continue
            }
            // `new A(with, parameters)` makes a participant and says so on the
            // arrow that makes it.
            if word == "new" {
                let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
                let name = String(rest.prefix(while: { $0 != "(" }))
                    .trimmingCharacters(in: .whitespaces)
                let args = arguments(
                    String(rest.dropFirst(name.count))
                        .trimmingCharacters(in: .whitespaces))
                guard let caller = starter(), let made = index(of: name) else { return nil }
                say(
                    SequenceDiagram.Message(
                        from: caller, to: made,
                        text: args.isEmpty ? "«create»" : "« \(args) »", dashed: true))
                continue
            }
            // A word on its own declares a participant, and `A as Alice` gives
            // it something else to show. Neither draws an arrow.
            if let declared = declaration(line) {
                guard let index = index(of: declared.id) else { return nil }
                if !declared.label.isEmpty { diagram.participants[index].label = declared.label }
                // A comment over a participant is not drawn, so it is dropped
                // rather than carried down to the next message.
                pending = []
                continue
            }

            var body = line
            var opens = false
            if body.hasSuffix("{") {
                opens = true
                body = body.dropLast().trimmingCharacters(in: .whitespaces)[...]
            }
            // `a = A.method()`, and `SomeType a = A.method()`: the call is the
            // arrow and the name on the left is what comes back on the answer.
            var answer = ""
            if let split = assignment(body) {
                answer = split.name
                body = split.call[...]
            }
            if callers.isEmpty, !body.contains("->") {
                // A call nobody made comes from the nameless figure Mermaid
                // draws in that case, standing to the left of everyone.
                diagram.participants.insert(
                    SequenceDiagram.Participant(id: "__starter", label: "", isActor: true), at: 0)
                callers = [0]
            }
            guard var message = self.call(body, from: callers.last, index: index)?.message else {
                return nil
            }
            message.activates = opens || !answer.isEmpty
            say(message)
            if !answer.isEmpty {
                append(
                    .message(
                        SequenceDiagram.Message(
                            from: message.to, to: message.from, text: answer, dashed: true)))
                append(.deactivate(message.to))
            }
            // The first message says who is calling from now on, whether or not
            // it opens braces: a caller nobody pushed leaves every reply inside
            // those braces with nowhere to go back to.
            if callers.isEmpty { callers = [message.from] }
            if opens {
                callers.append(message.to)
                stack.append(.call)
            }
        }
        // A brace never closed is closed at the end of the diagram, which is
        // what Mermaid's own reading of it comes to.
        while let frame = stack.popLast() {
            switch frame {
            case .call:
                if let callee = callers.last, callers.count > 1 {
                    append(.deactivate(callee))
                    callers.removeLast()
                }
            case .control(let block):
                append(.block(block))
            }
        }
        guard !diagram.messages.isEmpty || !diagram.participants.isEmpty else { return nil }
        return diagram
    }

    /// `A->B: words`, `A->B.method()` or a bare `B.method()`.
    private static func call(
        _ line: Substring, from caller: Int?, index: (String) -> Int?
    ) -> (message: SequenceDiagram.Message, opensCall: Bool)? {
        var from = caller
        var rest = line
        if let arrow = line.range(of: "->") {
            guard let sender = index(String(line[line.startIndex..<arrow.lowerBound])) else {
                return nil
            }
            from = sender
            rest = line[arrow.upperBound...]
        }
        let body = rest.trimmingCharacters(in: .whitespaces)
        guard let from else { return nil }
        if let colon = body.firstIndex(of: ":") {
            guard let to = index(String(body[body.startIndex..<colon])) else { return nil }
            let words = String(body[body.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            return (
                SequenceDiagram.Message(from: from, to: to, text: words, dashed: false), false
            )
        }
        // `B.method(args)`: the receiver is before the first dot, and the call
        // itself is what the arrow is labelled with. The parentheses are the
        // author's to leave off — `A.SyncMessage` is the same call as
        // `A.SyncMessage()` and is drawn as what is written.
        guard let dot = body.firstIndex(of: "."),
            let to = index(String(body[body.startIndex..<dot]))
        else { return nil }
        let method = tightened(String(body[body.index(after: dot)...]))
        guard !method.isEmpty else { return nil }
        return (SequenceDiagram.Message(from: from, to: to, text: method, dashed: false), false)
    }

    /// `Bob` standing on its own, or `A as Alice`: somebody taking part and
    /// nothing else. A name is letters, digits and underscores, so a call and a
    /// fragment of prose both fall through to be read as what they are.
    private static func declaration(_ line: Substring) -> (id: String, label: String)? {
        let words = line.split(separator: " ", omittingEmptySubsequences: true)
        if words.count == 1, isName(words[0]) { return (String(words[0]), "") }
        guard words.count >= 3, words[1] == "as", isName(words[0]) else { return nil }
        return (String(words[0]), words.dropFirst(2).joined(separator: " "))
    }

    private static func isName(_ word: Substring) -> Bool {
        !word.isEmpty && word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// `a = A.method()` and `SomeType a = A.method()` split into the name the
    /// answer carries and the call that earns it. A type written in front of
    /// the name says nothing about the picture, so the name alone is kept.
    /// `==` is a comparison rather than an assignment and is left alone.
    private static func assignment(_ line: Substring) -> (name: String, call: String)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let after = line.index(after: equals)
        guard after < line.endIndex, line[after] != "=" else { return nil }
        if equals > line.startIndex, "=!<>".contains(line[line.index(before: equals)]) {
            return nil
        }
        let names = line[line.startIndex..<equals]
            .split(separator: " ", omittingEmptySubsequences: true)
        guard (1...2).contains(names.count), names.allSatisfy(isName),
            let last = names.last
        else { return nil }
        let call = line[after...].trimmingCharacters(in: .whitespaces)
        guard !call.isEmpty else { return nil }
        return (String(last), call)
    }

    /// What `new A(with, parameters)` writes on its arrow: `with,parameters`.
    private static func arguments(_ text: String) -> String {
        guard text.hasPrefix("("), text.hasSuffix(")") else { return "" }
        return tightened(String(text.dropFirst().dropLast()))
    }

    /// ZenUML writes an argument list with no space after a comma, and a label
    /// that reads one way in the source and another in the picture is a
    /// difference a reader would notice.
    private static func tightened(_ text: String) -> String {
        text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ",")
    }

    /// `(more == true)` reads better over a frame as `more == true`.
    private static func condition(_ text: String) -> String {
        guard text.hasPrefix("("), text.hasSuffix(")") else { return text }
        return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }
}
