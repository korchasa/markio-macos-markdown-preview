import AppKit

/// What the document says about itself to the system.
///
/// Drawing glyphs with CoreText buys the speed this app is built on, but it
/// buys nothing a screen reader can use: a view that draws and says nothing is
/// an empty rectangle to VoiceOver. An app whose whole purpose is reading has
/// to answer for its text, and a renderer of its own is exactly the case where
/// nobody answers for it — a web view would have done it unasked.
///
/// Only the blocks on screen are published, which is the same rule the drawing
/// follows and the same one `NSTableView` follows for its rows. Walking the
/// whole document to build a tree would undo the design: a 32 MB file has
/// hundreds of thousands of blocks, and none of them is typeset until it is
/// visible.
extension DocumentView {
    public override func isAccessibilityElement() -> Bool { true }

    public override func accessibilityRole() -> NSAccessibility.Role? { .group }

    public override func accessibilityChildren() -> [Any]? { accessibleBlocks() }

    /// One element per visible block, carrying the same text Copy and Find use.
    ///
    /// The result is cached, and rebuilt only when the blocks on screen change
    /// or their text does — the latter because a file rewritten under the
    /// reader keeps the same range and would otherwise still be read out with
    /// its old words.
    private func accessibleBlocks() -> [NSAccessibilityElement] {
        guard layout.blockCount > 0 else { return [] }
        let range = ordinals(in: visibleRect)
        if range == accessibleRange, textIsUnchanged(in: range) { return accessibleElements }

        let originX = contentX
        var elements: [NSAccessibilityElement] = []

        for ordinal in range {
            guard !layout.isHidden(ordinal), let box = layout.box(at: ordinal) else { continue }
            let text = box.plainText
            // A rule, a spacer or a collapsed section's closing tag has no text
            // to read. Publishing it would make VoiceOver stop on nothing.
            guard !text.isEmpty else { continue }

            let element = NSAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityValue(text)
            element.setAccessibilityFrameInParentSpace(
                CGRect(
                    x: originX,
                    y: layout.offset(of: ordinal) + verticalPadding,
                    width: box.width,
                    height: box.height
                )
            )
            elements.append(element)
        }

        accessibleElements = elements
        accessibleRange = range
        return elements
    }

    /// Whether the cached elements still say what their blocks say.
    private func textIsUnchanged(in range: Range<Int>) -> Bool {
        var index = 0
        for ordinal in range {
            guard !layout.isHidden(ordinal), let box = layout.box(at: ordinal) else { continue }
            guard !box.plainText.isEmpty else { continue }
            guard index < accessibleElements.count,
                accessibleElements[index].accessibilityValue() as? String == box.plainText
            else { return false }
            index += 1
        }
        return index == accessibleElements.count
    }
}
