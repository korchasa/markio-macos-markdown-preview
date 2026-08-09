import Foundation

/// A packet diagram: a run of bits, cut into named fields.
struct PacketDiagram {
    struct Field {
        var label: String
        /// Inclusive, counted from the first bit of the packet.
        var first: Int
        var last: Int

        var width: Int { last - first + 1 }
    }

    var title: String
    var fields: [Field]
    /// How many bits are drawn on one row.
    let bitsPerRow = 32

    static func parse(_ lines: [Substring]) -> PacketDiagram? {
        var packet = PacketDiagram(title: "", fields: [])
        var next = 0
        for line in lines {
            if line.hasPrefix("title ") {
                packet.title = String(line.dropFirst(6))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let range = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let label = line[line.index(after: colon)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            guard !label.isEmpty else { return nil }

            var first = next
            var last: Int
            if range.hasPrefix("+") {
                // `+16` means sixteen more bits after the field above it.
                guard let width = Int(range.dropFirst()), width > 0 else { return nil }
                last = first + width - 1
            } else if let dash = range.firstIndex(of: "-") {
                guard let low = Int(range[range.startIndex..<dash]),
                    let high = Int(range[range.index(after: dash)...]), high >= low
                else { return nil }
                first = low
                last = high
            } else {
                guard let only = Int(range) else { return nil }
                first = only
                last = only
            }
            // A packet with a hole in it, or with two fields over one bit, is
            // not a packet this can draw honestly.
            guard first == next else { return nil }
            packet.fields.append(Field(label: label, first: first, last: last))
            next = last + 1
        }
        guard !packet.fields.isEmpty else { return nil }
        return packet
    }
}

/// A kanban board: columns of cards.
struct KanbanBoard {
    struct Card {
        var label: String
        /// `@{ ticket: MC-2038 }`: what the work is called wherever it is
        /// tracked. Drawn as a link when the preamble says where that is.
        var ticket: String = ""
        /// The rest of the `@{ assigned: … }` metadata, in the order it is
        /// drawn.
        var details: [String]
        var priority: String
    }

    struct Column {
        var title: String
        var cards: [Card]
    }

    var columns: [Column]
    /// `config.kanban.ticketBaseUrl` from the preamble. With one, a ticket id is
    /// a link, and Mermaid draws it as one.
    var ticketBaseUrl: String = ""

    static func parse(_ lines: [(indent: Int, text: Substring)], ticketBaseUrl: String = "")
        -> KanbanBoard?
    {
        var board = KanbanBoard(columns: [], ticketBaseUrl: ticketBaseUrl)
        // The first line's indent is what a column is written at; anything
        // deeper is a card in the column above it.
        guard let columnIndent = lines.first?.indent else { return nil }
        for line in lines {
            // A line shallower than the first one means the board's own columns
            // are not all written at one depth, and which line is a card would
            // be a guess.
            guard line.indent >= columnIndent else { return nil }
            if line.indent == columnIndent {
                let title = title(of: line.text)
                guard let title else { return nil }
                board.columns.append(Column(title: title, cards: []))
                continue
            }
            guard !board.columns.isEmpty, let card = card(line.text) else { return nil }
            board.columns[board.columns.count - 1].cards.append(card)
        }
        guard !board.columns.isEmpty else { return nil }
        return board
    }

    /// `Todo` or `id[To do]`.
    private static func title(of text: Substring) -> String? {
        if let bracket = text.firstIndex(of: "["), text.hasSuffix("]") {
            let inner = text[text.index(after: bracket)..<text.index(before: text.endIndex)]
            let label = inner.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return label.isEmpty ? nil : label
        }
        let label = text.trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }

    private static func card(_ text: Substring) -> Card? {
        var body = text
        var ticket = ""
        var details: [String] = []
        var priority = ""
        if let brace = body.range(of: "@{") {
            guard body.hasSuffix("}") else { return nil }
            let inside = body[brace.upperBound..<body.index(before: body.endIndex)]
            for pair in inside.split(separator: ",") {
                guard let colon = pair.firstIndex(of: ":") else { return nil }
                let key = pair[pair.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                let value = pair[pair.index(after: colon)...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "' \""))
                guard !value.isEmpty else { return nil }
                switch key {
                case "assigned": details.append(value)
                case "ticket": ticket = value
                case "priority": priority = value
                // Anything else changes how the card looks in ways this does
                // not draw, so the board falls back to its source.
                default: return nil
                }
            }
            body = body[body.startIndex..<brace.lowerBound]
        }
        guard let label = title(of: Substring(body.trimmingCharacters(in: .whitespaces))) else {
            return nil
        }
        return Card(label: label, ticket: ticket, details: details, priority: priority)
    }
}
