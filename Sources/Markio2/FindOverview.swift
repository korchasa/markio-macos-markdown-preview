import AppKit

/// The strip down the right edge of the text that shows where the matches are.
///
/// A counter tells the reader how many matches there are; this tells them
/// *where* — whether the word they are looking for is clustered in one section
/// or spread over the whole document, and how far the next one is. Clicking a
/// mark jumps to it.
@MainActor
final class FindOverview: NSView {
    /// Called with the index of the match nearest the click.
    var onSelect: ((Int) -> Void)?

    /// Each match's position as a fraction of the document's height, in
    /// reading order.
    private var marks: [CGFloat] = []
    private var current = -1

    override var isFlipped: Bool { true }

    func setMarks(_ marks: [CGFloat], current: Int) {
        self.marks = marks
        self.current = current
        isHidden = marks.isEmpty
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !marks.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let inset: CGFloat = 3
        let markWidth = bounds.width - inset * 2
        let markHeight: CGFloat = 2.5
        let usable = max(1, bounds.height - markHeight)

        let ordinary = NSColor.secondaryLabelColor.withAlphaComponent(0.55).cgColor
        let accent = NSColor.controlAccentColor.cgColor

        // Marks are in reading order, so they arrive sorted; anything landing on
        // a row already painted adds nothing but time, and a large document can
        // report six figures of matches.
        var lastY: CGFloat = -10
        for (index, fraction) in marks.enumerated() {
            let y = min(usable, max(0, fraction * usable))
            let isCurrent = index == current
            if !isCurrent, abs(y - lastY) < 1 { continue }
            lastY = y
            context.setFillColor(isCurrent ? accent : ordinary)
            let rect = CGRect(x: inset, y: y, width: markWidth, height: markHeight)
            context.fill(rect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !marks.isEmpty else { return }
        let point = convert(event.locationInWindow, from: nil)
        let fraction = bounds.height > 0 ? point.y / bounds.height : 0
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, mark) in marks.enumerated() {
            let distance = abs(mark - fraction)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        onSelect?(best)
    }
}
