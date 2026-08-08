/// GFM task-list checkboxes.
///
/// The scanner treats `[ ]` as ordinary text because at block level it is; only
/// the renderer, which knows this leaf heads a list item, has the context to
/// read it as a checkbox. Recognising it here keeps that decision out of the
/// scanner's hot loop.
extension Document {
    public struct TaskMarker: Sendable, Equatable {
        public var isChecked: Bool
        /// Offset in the block's content buffer where the text after the
        /// checkbox begins.
        public var contentStart: Int
    }

    public func taskMarker(in content: [UInt8], leaf index: Int32) -> TaskMarker? {
        let block = blocks[Int(index)]
        guard block.kind == .paragraph, block.flags.contains(.itemHead) else { return nil }
        guard content.count >= 3, content[0] == ASCII.leftBracket,
            content[2] == ASCII.rightBracket
        else { return nil }
        let state = content[1]
        let checked: Bool
        switch state {
        case ASCII.space: checked = false
        case ASCII.lowerX, ASCII.upperX: checked = true
        default: return nil
        }
        var start = 3
        // A checkbox must be followed by whitespace or nothing, or `[x]y` would
        // read as a ticked box.
        if start < content.count {
            guard isSpaceOrTab(content[start]) else { return nil }
            while start < content.count, isSpaceOrTab(content[start]) { start += 1 }
        }
        return TaskMarker(isChecked: checked, contentStart: start)
    }
}
