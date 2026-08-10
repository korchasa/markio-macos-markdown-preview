import Foundation

/// Boxes with rows in them, joined by lines whose ends mean something: a class
/// diagram and an entity–relationship diagram.
///
/// The two look different on the page and are almost the same picture — a
/// titled box, a list of members, a line whose ends say what the relation is —
/// so they share a shape here and differ only in how they are read and in which
/// ends their lines carry.
struct BoxDiagram {
    /// What is drawn where a line meets a box.
    enum End: Equatable {
        case none
        /// An association: a filled head.
        case arrow
        /// Inheritance: a hollow triangle.
        case triangle
        /// Composition and aggregation.
        case diamond
        case hollowDiamond
        /// Crow's feet: what an entity–relationship line says about how many.
        case one
        case zeroOrOne
        case oneOrMore
        case zeroOrMore
    }

    struct Box {
        var name: String
        /// `<<interface>>`, written above the name.
        var stereotype: String
        /// One list per compartment, drawn with a rule between them.
        var compartments: [[String]]
        /// The `namespace` the class was written inside, if any.
        var namespace: Int?
        var style = Flowchart.Style()
    }

    /// A `namespace`: a titled frame around the classes written inside it.
    struct Namespace {
        var name: String
        var members: [Int] = []
    }

    struct Link {
        var from: Int
        var to: Int
        var label: String
        var dashed: Bool
        var fromEnd: End
        var toEnd: End
        /// The `"1"` and `"many"` a class diagram writes beside each end.
        var fromCount: String
        var toCount: String
    }

    /// A `note`: a slip of paper with words on it, either standing on its own or
    /// tied to one box by a dotted line.
    struct Note {
        var text: String
        var attached: Int?
    }

    var boxes: [Box]
    var links: [Link]
    var notes: [Note] = []
    var namespaces: [Namespace] = []
    /// A class diagram is drawn with the parent above; an entity diagram reads
    /// across the page.
    var direction: Flowchart.Direction

    mutating func index(of name: String) -> Int {
        if let existing = boxes.firstIndex(where: { $0.name == name }) { return existing }
        boxes.append(Box(name: name, stereotype: "", compartments: [], namespace: nil))
        return boxes.count - 1
    }
}

// MARK: - Class diagram

enum ClassDiagram {
    /// The ends a class relation can be written with, longest spelling first so
    /// `<|--` is never read as `<--` with a stray bar.
    private static let leftEnds: [(text: String, end: BoxDiagram.End)] = [
        ("<|", .triangle), ("*", .diamond), ("o", .hollowDiamond), ("<", .arrow),
    ]
    private static let rightEnds: [(text: String, end: BoxDiagram.End)] = [
        ("|>", .triangle), ("*", .diamond), ("o", .hollowDiamond), (">", .arrow),
    ]

    static func parse(_ lines: [Substring]) -> BoxDiagram? {
        var diagram = BoxDiagram(boxes: [], links: [], direction: .down)
        var open: Int?
        var openNamespace: Int?
        /// The styles `classDef` named, waiting for a `cssClass` to use them.
        var styles: [String: Flowchart.Style] = [:]
        for line in lines {
            let word = String(line.prefix(while: { !$0.isWhitespace }))
            let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            if let box = open {
                if line == "}" {
                    open = nil
                    continue
                }
                append(String(line), to: &diagram.boxes[box])
                continue
            }
            if line == "}" {
                guard openNamespace != nil else { return nil }
                openNamespace = nil
                continue
            }
            switch word {
            case "direction":
                guard let read = Flowchart.direction(header: Substring("flowchart \(rest)"))
                else { return nil }
                diagram.direction = read
                continue
            case "namespace":
                guard openNamespace == nil, rest.hasSuffix("{") else { return nil }
                let name = String(rest.dropLast()).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains(" ") else { return nil }
                diagram.namespaces.append(BoxDiagram.Namespace(name: name))
                openNamespace = diagram.namespaces.count - 1
                continue
            case "class":
                guard declared(rest, in: &diagram, opening: &open, inside: openNamespace) else {
                    return nil
                }
                continue
            case "note":
                guard let note = note(rest, in: &diagram) else { return nil }
                diagram.notes.append(note)
                continue
            case "classDef":
                let parts = rest.split(
                    separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2, let style = Flowchart.style(from: String(parts[1]))
                else { return nil }
                for name in parts[0].split(separator: ",") {
                    styles[name.trimmingCharacters(in: .whitespaces)] = style
                }
                continue
            case "style":
                let parts = rest.split(
                    separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2, let style = Flowchart.style(from: String(parts[1]))
                else { return nil }
                // A class nobody wrote leaves the line with nothing to paint.
                if let index = diagram.boxes.firstIndex(where: { $0.name == String(parts[0]) }) {
                    diagram.boxes[index].style.merge(style)
                }
                continue
            case "cssClass":
                // `cssClass "Duck,Fish" highlight`, the names always quoted.
                let parts = rest.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count == 2 else { return nil }
                guard let style = styles[String(parts[1])] else { continue }
                let named = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                for name in named.split(separator: ",") {
                    let box = name.trimmingCharacters(in: .whitespaces)
                    guard let index = diagram.boxes.firstIndex(where: { $0.name == box }) else {
                        continue
                    }
                    diagram.boxes[index].style.merge(style)
                }
                continue
            case "click", "callback", "link":
                // A picture cannot be followed anywhere, and Mermaid draws a
                // clickable class like any other, so this changes nothing drawn.
                let parts = rest.split(
                    separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2 else { return nil }
                continue
            default:
                break
            }
            // `<<interface>> Flyer` and `Flyer : +fly()` and the relations.
            if line.hasPrefix("<<") {
                guard let close = line.range(of: ">>") else { return nil }
                let stereotype = String(
                    line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
                let name = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return nil }
                diagram.boxes[diagram.index(of: name)].stereotype = stereotype
                continue
            }
            if let relation = relation(line, in: &diagram) {
                diagram.links.append(relation)
                continue
            }
            if let colon = line.firstIndex(of: ":") {
                let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                let member = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !member.isEmpty else { return nil }
                let index = diagram.index(of: name)
                append(member, to: &diagram.boxes[index])
                continue
            }
            // A line the grammar cannot read declares nothing, which is what
            // Mermaid makes of it: it draws the diagram without it.
            continue
        }
        guard open == nil, openNamespace == nil else { return nil }
        return diagram
    }

    /// `note "words"` stands on its own; `note for Duck "words"` is tied to the
    /// box it names. The words are always quoted, and a note with none of them
    /// says nothing, so both forms are refused when the quotes are missing.
    private static func note(_ rest: String, in diagram: inout BoxDiagram) -> BoxDiagram.Note? {
        var text = rest
        var attached: Int?
        if text.hasPrefix("for ") {
            let body = String(text.dropFirst("for ".count)).trimmingCharacters(in: .whitespaces)
            guard let quote = body.firstIndex(of: "\"") else { return nil }
            let name = String(body[body.startIndex..<quote]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { return nil }
            attached = diagram.index(of: name)
            text = String(body[quote...])
        }
        guard text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 else { return nil }
        let words = String(text.dropFirst().dropLast())
        guard !words.isEmpty else { return nil }
        return BoxDiagram.Note(text: words, attached: attached)
    }

    /// `class Animal`, `class Animal {`, `class Animal["A nicer name"]`.
    private static func declared(
        _ rest: String, in diagram: inout BoxDiagram, opening: inout Int?, inside namespace: Int?
    ) -> Bool {
        var text = rest
        var opens = false
        if text.hasSuffix("{") {
            opens = true
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        var name = text
        var label: String?
        if let bracket = text.firstIndex(of: "["), text.hasSuffix("]") {
            name = String(text[text.startIndex..<bracket]).trimmingCharacters(in: .whitespaces)
            label = String(text[text.index(after: bracket)..<text.index(before: text.endIndex)])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        // `class Shape~T~` is a generic, and the tilde is part of the name.
        guard !name.isEmpty, !name.contains(" ") else { return false }
        let index = diagram.index(of: name)
        if let label { diagram.boxes[index].name = label }
        if opens { opening = index }
        // A class written in a second namespace stays where it was first put:
        // one class is drawn once, inside one frame.
        if let namespace, diagram.boxes[index].namespace == nil {
            diagram.boxes[index].namespace = namespace
            diagram.namespaces[namespace].members.append(index)
        }
        return true
    }

    /// A member goes in the second compartment when it looks like a call.
    private static func append(_ member: String, to box: inout BoxDiagram.Box) {
        while box.compartments.count < 2 { box.compartments.append([]) }
        let text = member.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("<<") {
            box.stereotype = text.replacingOccurrences(of: "<<", with: "")
                .replacingOccurrences(of: ">>", with: "")
            return
        }
        box.compartments[text.contains("(") ? 1 : 0].append(text)
    }

    private static func relation(_ line: Substring, in diagram: inout BoxDiagram) -> BoxDiagram
        .Link?
    {
        // `Animal "1" <|-- "many" Duck : eats`
        var body = line
        var label = ""
        if let colon = body.lastIndex(of: ":") {
            label = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            body = body[body.startIndex..<colon]
        }
        guard let dash = body.range(of: "--") ?? body.range(of: "..") else { return nil }
        let dashed = body[dash.lowerBound] == "."
        var head = String(body[body.startIndex..<dash.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        var tail = String(body[dash.upperBound...]).trimmingCharacters(in: .whitespaces)

        var fromEnd = BoxDiagram.End.none
        for candidate in leftEnds where head.hasSuffix(candidate.text) {
            fromEnd = candidate.end
            head = String(head.dropLast(candidate.text.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        var toEnd = BoxDiagram.End.none
        for candidate in rightEnds where tail.hasPrefix(candidate.text) {
            toEnd = candidate.end
            tail = String(tail.dropFirst(candidate.text.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        let (from, fromCount) = counted(head)
        let (to, toCount) = counted(tail)
        guard !from.isEmpty, !to.isEmpty, !from.contains(" "), !to.contains(" ") else { return nil }
        return BoxDiagram.Link(
            from: diagram.index(of: from),
            to: diagram.index(of: to),
            label: label,
            dashed: dashed,
            fromEnd: fromEnd,
            toEnd: toEnd,
            fromCount: fromCount,
            toCount: toCount
        )
    }

    /// Splits `Animal "1"` and `"many" Duck` into a name and a count.
    private static func counted(_ text: String) -> (name: String, count: String) {
        guard let first = text.firstIndex(of: "\""),
            let last = text.lastIndex(of: "\""), first < last
        else { return (text, "") }
        let count = String(text[text.index(after: first)..<last])
        var name = text
        name.removeSubrange(first...last)
        return (name.trimmingCharacters(in: .whitespaces), count)
    }
}

// MARK: - Requirement diagram

/// Requirements and the things that satisfy them: the same titled boxes with
/// rows in them, joined by lines that say which way the claim runs.
enum RequirementDiagram {
    private static let kinds: Set<String> = [
        "requirement", "functionalRequirement", "interfaceRequirement",
        "performanceRequirement", "physicalRequirement", "designConstraint", "element",
    ]
    private static let relations: Set<String> = [
        "contains", "copies", "derives", "satisfies", "verifies", "refines", "traces",
    ]

    static func parse(_ lines: [Substring]) -> BoxDiagram? {
        var diagram = BoxDiagram(boxes: [], links: [], direction: .down)
        var open: Int?
        var styles: [String: Flowchart.Style] = [:]
        /// Which class each box asked for, kept until every `classDef` has been
        /// read: a class may be named before it is written.
        var painted: [(box: Int, name: String)] = []
        for line in lines {
            if let box = open {
                if line == "}" {
                    open = nil
                    continue
                }
                // `id: 1`, `text: the test text.`, `risk: high`
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                guard !key.isEmpty, !value.isEmpty else { return nil }
                // `risk: high` and `verifymethod: test` are chosen from a list
                // of words the syntax spells in lower case; the prose ones —
                // `text`, `docref`, an element's `type` — are the author's own
                // and stay as written.
                let written =
                    ["risk", "verifymethod"].contains(key)
                    ? value.prefix(1).uppercased() + value.dropFirst() : value
                diagram.boxes[box].compartments[0].append("\(named(key)): \(written)")
                continue
            }
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            let first = String(words.first ?? "")
            switch first {
            case "direction":
                guard words.count == 2,
                    let read = Flowchart.direction(header: Substring("flowchart \(words[1])"))
                else { return nil }
                diagram.direction = read
                continue
            case "classDef", "style", "class":
                let rest = line.dropFirst(first.count).trimmingCharacters(in: .whitespaces)
                let parts = rest.split(
                    separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2 else { return nil }
                if first == "class" {
                    // `class test_entity important`: a box asks for a class by
                    // name, and one nobody wrote paints nothing.
                    for name in parts[0].split(separator: ",") {
                        let box = name.trimmingCharacters(in: .whitespaces)
                        guard let index = diagram.boxes.firstIndex(where: { $0.name == box })
                        else { continue }
                        painted.append((index, String(parts[1])))
                    }
                    continue
                }
                guard let style = Flowchart.style(from: String(parts[1])) else { return nil }
                if first == "classDef" {
                    for name in parts[0].split(separator: ",") {
                        styles[name.trimmingCharacters(in: .whitespaces)] = style
                    }
                    continue
                }
                for name in parts[0].split(separator: ",") {
                    let box = name.trimmingCharacters(in: .whitespaces)
                    guard let index = diagram.boxes.firstIndex(where: { $0.name == box })
                    else { continue }
                    diagram.boxes[index].style.merge(style)
                }
                continue
            default:
                break
            }
            if kinds.contains(first) {
                guard words.count == 3, words[2] == "{" else { return nil }
                // `requirement test_req:::important {`
                var name = String(words[1])
                if let mark = name.range(of: ":::") {
                    let asked = String(name[mark.upperBound...])
                    guard !asked.isEmpty else { return nil }
                    name = String(name[name.startIndex..<mark.lowerBound])
                    painted.append((diagram.index(of: name), asked))
                }
                let index = diagram.index(of: name)
                // A requirement wears its kind in angle brackets and in words:
                // `<<Functional Requirement>>`, not the keyword as typed.
                diagram.boxes[index].stereotype = "<<\(spaced(first))>>"
                diagram.boxes[index].compartments = [[]]
                open = index
                continue
            }
            // `test_entity - satisfies -> test_req`, and the same claim written
            // the other way round as `test_req <- satisfies - test_entity`.
            guard words.count == 5, relations.contains(String(words[2])),
                (words[1] == "-" && words[3] == "->") || (words[1] == "<-" && words[3] == "-")
            else { return nil }
            let forwards = words[3] == "->"
            diagram.links.append(
                BoxDiagram.Link(
                    from: diagram.index(of: String(words[forwards ? 0 : 4])),
                    to: diagram.index(of: String(words[forwards ? 4 : 0])),
                    label: "<<\(words[2])>>",
                    dashed: true,
                    fromEnd: .none,
                    toEnd: .arrow,
                    fromCount: "",
                    toCount: ""
                )
            )
        }
        guard open == nil, !diagram.boxes.isEmpty else { return nil }
        for (box, name) in painted {
            guard let style = styles[name] else { continue }
            diagram.boxes[box].style.merge(style)
        }
        return diagram
    }

    /// `functionalRequirement` as a reader would say it: `Functional Requirement`.
    private static func spaced(_ keyword: String) -> String {
        var out = keyword.prefix(1).uppercased()
        for character in keyword.dropFirst() {
            if character.isUppercase { out.append(" ") }
            out.append(character)
        }
        return out
    }

    /// A property as a reader would write it rather than as the syntax spells
    /// it: `verifymethod` is a keyword, `Verification` is a word.
    private static func named(_ key: String) -> String {
        switch key {
        case "id": return "ID"
        case "verifymethod": return "Verification"
        case "docref": return "Doc ref"
        default: return key.prefix(1).uppercased() + key.dropFirst()
        }
    }
}

// MARK: - Entity–relationship diagram

enum EntityDiagram {
    /// The marks at an end. Each count has a spelling that faces left and one
    /// that faces right, and either may be written at either end: which side it
    /// stands on decides how it is drawn, not which spelling was used.
    private static let ends: [String: BoxDiagram.End] = [
        "||": .one,
        "|o": .zeroOrOne, "o|": .zeroOrOne,
        "}|": .oneOrMore, "|{": .oneOrMore,
        "}o": .zeroOrMore, "o{": .zeroOrMore,
    ]
    /// The words an author may write instead of the marks. Both ends read from
    /// one table: which side a count stands on decides how it is drawn, not
    /// what it means.
    private static let counts: [String: BoxDiagram.End] = [
        "only one": .one, "1": .one,
        "zero or one": .zeroOrOne, "one or zero": .zeroOrOne,
        "zero or more": .zeroOrMore, "zero or many": .zeroOrMore,
        "many(0)": .zeroOrMore, "0+": .zeroOrMore,
        "one or more": .oneOrMore, "one or many": .oneOrMore,
        "many(1)": .oneOrMore, "1+": .oneOrMore,
    ]

    static func parse(_ lines: [Substring]) -> BoxDiagram? {
        var diagram = BoxDiagram(boxes: [], links: [], direction: .down)
        var open: Int?
        /// An entity is known by its id, which is not always what it shows.
        var ids: [String: Int] = [:]
        var styles: [String: Flowchart.Style] = [:]
        /// Which class each entity asked for, kept until every `classDef` has
        /// been read: a class may be named before it is written.
        var painted: [(box: Int, name: String)] = []
        for line in lines {
            if let box = open {
                if line == "}" {
                    open = nil
                    continue
                }
                // `string name PK "the customer's name"`
                var text = String(line)
                if let quote = text.firstIndex(of: "\"") {
                    text = String(text[text.startIndex..<quote])
                }
                let words = text.split(separator: " ", omittingEmptySubsequences: true)
                guard words.count >= 2 else { return nil }
                // Type first and then the name, the order the line is written
                // in and the order the diagram is read in.
                let keys = words.dropFirst(2).joined(separator: " ")
                let member =
                    keys.isEmpty
                    ? "\(words[0])  \(words[1])" : "\(words[0])  \(words[1])  \(keys)"
                diagram.boxes[box].compartments[0].append(member)
                continue
            }
            let word = String(line.prefix(while: { !$0.isWhitespace }))
            let rest = line.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
            switch word {
            case "direction":
                guard let read = Flowchart.direction(header: Substring("flowchart \(rest)"))
                else { return nil }
                diagram.direction = read
                continue
            case "classDef":
                let parts = rest.split(
                    separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2, let style = Flowchart.style(from: String(parts[1]))
                else { return nil }
                for name in parts[0].split(separator: ",") {
                    styles[name.trimmingCharacters(in: .whitespaces)] = style
                }
                continue
            case "style":
                let parts = rest.split(
                    separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard parts.count == 2, let style = Flowchart.style(from: String(parts[1]))
                else { return nil }
                // An entity nobody wrote leaves the line with nothing to paint.
                for name in parts[0].split(separator: ",") {
                    guard let index = ids[name.trimmingCharacters(in: .whitespaces)] else {
                        continue
                    }
                    diagram.boxes[index].style.merge(style)
                }
                continue
            default:
                break
            }
            var tokens = fields(String(line))
            guard !tokens.isEmpty else { continue }
            var opens = false
            if tokens.last == "{" {
                tokens.removeLast()
                opens = true
            } else if let last = tokens.last, last.count > 1, last.hasSuffix("{"),
                !last.contains("--"), !last.contains("..")
            {
                tokens[tokens.count - 1] = String(last.dropLast())
                opens = true
            }
            if opens {
                guard tokens.count == 1,
                    let index = entity(tokens[0], in: &diagram, ids: &ids, painted: &painted)
                else { return nil }
                if diagram.boxes[index].compartments.isEmpty {
                    diagram.boxes[index].compartments = [[]]
                }
                open = index
                continue
            }
            if let link = relation(tokens, in: &diagram, ids: &ids, painted: &painted) {
                diagram.links.append(link)
                continue
            }
            // A line that joins nothing is a list of entities standing on their
            // own, however many words it holds. It is why `subgraph one` draws
            // two boxes: an entity diagram has no frames, so both words name
            // something.
            guard !tokens.contains(":") else { return nil }
            for token in tokens {
                guard entity(token, in: &diagram, ids: &ids, painted: &painted) != nil else {
                    return nil
                }
            }
        }
        guard open == nil, !diagram.boxes.isEmpty else { return nil }
        // `classDef default` paints everything; a named class paints what asked
        // for it, and a class nobody wrote paints nothing.
        if let fallback = styles["default"] {
            for index in diagram.boxes.indices { diagram.boxes[index].style.merge(fallback) }
        }
        for (box, name) in painted {
            guard let style = styles[name] else { continue }
            diagram.boxes[box].style.merge(style)
        }
        return diagram
    }

    /// The words of a line, with anything quoted or bracketed kept whole:
    /// `a["Customer Account"] {` is two words, not three.
    private static func fields(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        var depth = 0
        for char in line {
            if char == "\"" {
                quoted.toggle()
                current.append(char)
                continue
            }
            if !quoted, char == "[" { depth += 1 }
            if !quoted, char == "]" { depth = max(depth - 1, 0) }
            if !quoted, depth == 0, char == " " {
                if !current.isEmpty {
                    out.append(current)
                    current = ""
                }
                continue
            }
            current.append(char)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func unquoted(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        return String(text.dropFirst().dropLast())
    }

    /// An entity is named by an id and may be shown under other words:
    /// `CAR`, `"This ❤ Unicode"`, `p[Person]`, `a["Customer Account"]`, and any
    /// of them with a `:::class` hung off the end.
    private static func entity(
        _ token: String, in diagram: inout BoxDiagram, ids: inout [String: Int],
        painted: inout [(box: Int, name: String)]
    ) -> Int? {
        var token = token
        var asked: String?
        if let mark = token.range(of: ":::") {
            asked = String(token[mark.upperBound...])
            token = String(token[token.startIndex..<mark.lowerBound])
            guard let name = asked, !name.isEmpty else { return nil }
        }
        var id = token
        var label: String?
        var written = true
        if token.hasPrefix("\""), token.hasSuffix("\""), token.count >= 2 {
            id = unquoted(token)
            label = id
            written = false
        } else if let open = token.firstIndex(of: "["), token.hasSuffix("]") {
            id = String(token[token.startIndex..<open])
            let shown = String(
                token[token.index(after: open)..<token.index(before: token.endIndex)])
            guard shown.hasPrefix("\"") || !shown.contains(" ") else { return nil }
            label = unquoted(shown)
        }
        // Quoting is what lets a name hold a space; a bare word is one word.
        guard !id.isEmpty, !written || !id.contains(" ") else { return nil }
        let index: Int
        if let known = ids[id] {
            index = known
            if let shown = label { diagram.boxes[index].name = shown }
        } else {
            diagram.boxes.append(
                BoxDiagram.Box(
                    name: label ?? id, stereotype: "", compartments: [], namespace: nil))
            index = diagram.boxes.count - 1
            ids[id] = index
        }
        if let name = asked { painted.append((index, name)) }
        return index
    }

    private static func relation(
        _ tokens: [String], in diagram: inout BoxDiagram, ids: inout [String: Int],
        painted: inout [(box: Int, name: String)]
    ) -> BoxDiagram.Link? {
        // `CUSTOMER ||--o{ ORDER : places`
        var tokens = tokens
        var label = ""
        if let cut = tokens.lastIndex(of: ":"), cut + 1 < tokens.count {
            label = tokens[(cut + 1)...].joined(separator: " ")
            tokens = Array(tokens[..<cut])
        }
        guard let (from, joint, to) = ends(tokens) else { return nil }
        guard
            let start = entity(from, in: &diagram, ids: &ids, painted: &painted),
            let stop = entity(to, in: &diagram, ids: &ids, painted: &painted)
        else { return nil }
        return BoxDiagram.Link(
            from: start, to: stop, label: unquoted(label), dashed: joint.dashed,
            fromEnd: joint.from, toEnd: joint.to, fromCount: "", toCount: "")
    }

    /// What stands between the two entities: either the marks Mermaid draws,
    /// written together or apart, or the words that mean the same thing.
    private static func ends(_ tokens: [String])
        -> (
            from: String, joint: (from: BoxDiagram.End, to: BoxDiagram.End, dashed: Bool),
            to: String
        )?
    {
        if tokens.count == 1, let split = marks(tokens[0]) { return split }
        if tokens.count == 3, let read = joint(tokens[1]) { return (tokens[0], read, tokens[2]) }
        // `CAR 1 to zero or more NAMED-DRIVER` and `PERSON many(0) optionally
        // to 0+ NAMED-DRIVER`: the entities stand at the ends and the words
        // between them are the two counts, told apart by the `to` in the middle.
        guard tokens.count >= 4, let cut = tokens.firstIndex(of: "to"), cut >= 2,
            cut + 1 < tokens.count - 1
        else { return nil }
        var head = Array(tokens[1..<cut])
        let dashed = head.last == "optionally"
        if dashed { head.removeLast() }
        guard let from = counts[head.joined(separator: " ")],
            let to = counts[tokens[(cut + 1)..<(tokens.count - 1)].joined(separator: " ")]
        else { return nil }
        return (tokens[0], (from, to, dashed), tokens[tokens.count - 1])
    }

    /// `id1||--||id2`, written with no room around the marks.
    private static func marks(_ token: String)
        -> (String, (from: BoxDiagram.End, to: BoxDiagram.End, dashed: Bool), String)?
    {
        guard let dash = token.range(of: "--") ?? token.range(of: "..") else { return nil }
        let head = token[token.startIndex..<dash.lowerBound]
        let tail = token[dash.upperBound...]
        let signs: Set<Character> = ["|", "o", "{", "}"]
        var left = head.endIndex
        while left > head.startIndex, signs.contains(head[head.index(before: left)]) {
            left = head.index(before: left)
        }
        var right = tail.startIndex
        while right < tail.endIndex, signs.contains(tail[right]) {
            right = tail.index(after: right)
        }
        let from = String(head[head.startIndex..<left])
        let to = String(tail[right...])
        guard !from.isEmpty, !to.isEmpty,
            let read = joint(String(head[left...]) + String(token[dash]) + String(tail[..<right]))
        else { return nil }
        return (from, read, to)
    }

    private static func joint(_ text: String)
        -> (from: BoxDiagram.End, to: BoxDiagram.End, dashed: Bool)?
    {
        guard let dash = text.range(of: "--") ?? text.range(of: "..") else { return nil }
        let head = String(text[text.startIndex..<dash.lowerBound])
        let tail = String(text[dash.upperBound...])
        guard let from = ends[head], let to = ends[tail] else { return nil }
        return (from, to, text.contains(".."))
    }
}
