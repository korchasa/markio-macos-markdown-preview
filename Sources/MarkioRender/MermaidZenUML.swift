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

        /// The openers, with the block kind each becomes.
        let openers: [(word: String, kind: String)] = [
            ("if", "alt"), ("while", "loop"), ("for", "loop"), ("forEach", "loop"),
            ("opt", "opt"), ("par", "par"), ("try", "try"),
        ]

        for raw in lines {
            var line = raw
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
                guard let frame = stack.popLast() else { return nil }
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
                guard callers.count > 1 else { return nil }
                let words = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
                append(
                    .message(
                        SequenceDiagram.Message(
                            from: callers[callers.count - 1], to: callers[callers.count - 2],
                            text: words, dashed: true)))
                continue
            }

            var body = line
            var opens = false
            if body.hasSuffix("{") {
                opens = true
                body = body.dropLast().trimmingCharacters(in: .whitespaces)[...]
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
            message.activates = opens
            append(.message(message))
            if opens {
                callers.append(message.to)
                stack.append(.call)
            } else if callers.isEmpty {
                // The first plain `A->B` message says who is calling from now on.
                callers = [message.from]
            }
        }
        guard stack.isEmpty, !diagram.messages.isEmpty else { return nil }
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
        // itself is what the arrow is labelled with.
        guard let dot = body.firstIndex(of: "."), body.hasSuffix(")"),
            let to = index(String(body[body.startIndex..<dot]))
        else { return nil }
        let method = String(body[body.index(after: dot)...])
        guard !method.isEmpty else { return nil }
        return (SequenceDiagram.Message(from: from, to: to, text: method, dashed: false), false)
    }

    /// `(more == true)` reads better over a frame as `more == true`.
    private static func condition(_ text: String) -> String {
        guard text.hasPrefix("("), text.hasSuffix(")") else { return text }
        return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }
}
