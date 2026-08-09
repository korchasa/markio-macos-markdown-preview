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
    /// A class diagram is drawn with the parent above; an entity diagram reads
    /// across the page.
    var direction: Flowchart.Direction

    mutating func index(of name: String) -> Int {
        if let existing = boxes.firstIndex(where: { $0.name == name }) { return existing }
        boxes.append(Box(name: name, stereotype: "", compartments: []))
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
            switch word {
            case "direction":
                guard let read = Flowchart.direction(header: Substring("flowchart \(rest)"))
                else { return nil }
                diagram.direction = read
                continue
            case "class":
                guard declared(rest, in: &diagram, opening: &open) else { return nil }
                continue
            case "note":
                guard let note = note(rest, in: &diagram) else { return nil }
                diagram.notes.append(note)
                continue
            case "click", "callback", "link", "style", "classDef", "cssClass", "namespace":
                return nil
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
            return nil
        }
        guard open == nil, !diagram.boxes.isEmpty else { return nil }
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
    private static func declared(_ rest: String, in diagram: inout BoxDiagram, opening: inout Int?)
        -> Bool
    {
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
                // `text`, `docref` — are the author's own and stay as written.
                let written =
                    ["risk", "verifymethod", "type"].contains(key)
                    ? value.prefix(1).uppercased() + value.dropFirst() : value
                diagram.boxes[box].compartments[0].append("\(named(key)): \(written)")
                continue
            }
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            if let kind = words.first, kinds.contains(String(kind)) {
                guard words.count == 3, words[2] == "{" else { return nil }
                let index = diagram.index(of: String(words[1]))
                diagram.boxes[index].stereotype = String(kind)
                diagram.boxes[index].compartments = [[]]
                open = index
                continue
            }
            // `test_entity - satisfies -> test_req`
            guard words.count == 5, words[1] == "-", relations.contains(String(words[2])),
                words[3] == "->" || words[3] == "<-"
            else { return nil }
            let forwards = words[3] == "->"
            diagram.links.append(
                BoxDiagram.Link(
                    from: diagram.index(of: String(words[forwards ? 0 : 4])),
                    to: diagram.index(of: String(words[forwards ? 4 : 0])),
                    label: String(words[2]),
                    dashed: true,
                    fromEnd: .none,
                    toEnd: .arrow,
                    fromCount: "",
                    toCount: ""
                )
            )
        }
        guard open == nil, !diagram.boxes.isEmpty else { return nil }
        return diagram
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
    private static let leftEnds: [(text: String, end: BoxDiagram.End)] = [
        ("||", .one), ("|o", .zeroOrOne), ("}|", .oneOrMore), ("}o", .zeroOrMore),
    ]
    private static let rightEnds: [(text: String, end: BoxDiagram.End)] = [
        ("||", .one), ("o|", .zeroOrOne), ("|{", .oneOrMore), ("o{", .zeroOrMore),
    ]

    static func parse(_ lines: [Substring]) -> BoxDiagram? {
        var diagram = BoxDiagram(boxes: [], links: [], direction: .down)
        var open: Int?
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
            if line.hasSuffix("{") {
                let name = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !name.contains(" ") else { return nil }
                let index = diagram.index(of: name)
                if diagram.boxes[index].compartments.isEmpty {
                    diagram.boxes[index].compartments = [[]]
                }
                open = index
                continue
            }
            guard let link = relation(line, in: &diagram) else { return nil }
            diagram.links.append(link)
        }
        guard open == nil, !diagram.boxes.isEmpty else { return nil }
        return diagram
    }

    private static func relation(_ line: Substring, in diagram: inout BoxDiagram) -> BoxDiagram
        .Link?
    {
        // `CUSTOMER ||--o{ ORDER : places`
        var body = line
        var label = ""
        if let colon = body.lastIndex(of: ":") {
            label = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            body = body[body.startIndex..<colon]
        }
        let words = body.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count == 3 else { return nil }
        let joint = String(words[1])
        guard let dash = joint.range(of: "--") ?? joint.range(of: "..") else { return nil }
        let head = String(joint[joint.startIndex..<dash.lowerBound])
        let tail = String(joint[dash.upperBound...])
        guard let fromEnd = leftEnds.first(where: { $0.text == head })?.end,
            let toEnd = rightEnds.first(where: { $0.text == tail })?.end
        else { return nil }
        return BoxDiagram.Link(
            from: diagram.index(of: String(words[0])),
            to: diagram.index(of: String(words[2])),
            label: label,
            dashed: joint.contains(".."),
            fromEnd: fromEnd,
            toEnd: toEnd,
            fromCount: "",
            toCount: ""
        )
    }
}
