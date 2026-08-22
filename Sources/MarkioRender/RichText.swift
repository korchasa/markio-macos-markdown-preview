import AppKit
import CoreText

/// The copied selection with its styles kept.
///
/// A block's text is already attributed — it has to be, to be drawn — but with
/// CoreText's own attribute keys, and RTF wants AppKit's. Two of them differ in
/// a way no amount of casting hides: `kCTForegroundColorAttributeName` is not
/// `.foregroundColor`, and its value is a `CGColor` where AppKit wants an
/// `NSColor`. So a translation pass is unavoidable, and this is it.
///
/// Plain text stays on the pasteboard beside the rich flavour, character for
/// character what it was before this existed: a rich paste is an addition, and
/// nothing that pastes today may paste differently.
public enum RichText {
    /// The part of a block's text between two offsets, with its attributes.
    ///
    /// The text comes out identical to the same range of `box.plainText`,
    /// separators included. That is why the gaps between segments — the tabs
    /// and newlines a table puts between its cells — are copied as plain text
    /// rather than skipped: they are part of what the reader selected.
    public static func attributed(box: BlockBox, from: Int, to: Int) -> NSAttributedString {
        let plain = box.plainText as NSString
        let start = min(max(0, from), plain.length)
        let end = min(max(start, to), plain.length)
        let result = NSMutableAttributedString()
        guard end > start else { return result }

        var cursor = start
        for segment in box.segments.filter({ $0.textOffset >= 0 })
            .sorted(by: { $0.textOffset < $1.textOffset })
        {
            let segmentStart = segment.textOffset
            let segmentEnd = segmentStart + segment.attributed.length
            guard segmentEnd > start, segmentStart < end else { continue }
            if segmentStart > cursor {
                result.append(
                    NSAttributedString(
                        string: plain.substring(
                            with: NSRange(
                                location: cursor, length: min(segmentStart, end) - cursor))))
                cursor = min(segmentStart, end)
            }
            let localFrom = max(0, cursor - segmentStart)
            let localTo = min(segment.attributed.length, end - segmentStart)
            guard localTo > localFrom else { continue }
            result.append(
                segment.attributed.attributedSubstring(
                    from: NSRange(location: localFrom, length: localTo - localFrom)))
            cursor = segmentStart + localTo
        }
        if cursor < end {
            result.append(
                NSAttributedString(
                    string: plain.substring(with: NSRange(location: cursor, length: end - cursor))))
        }
        return result
    }

    /// The same text with attributes AppKit understands.
    ///
    /// Whatever is not translated is dropped rather than carried: an RTF writer
    /// given a CoreText colour writes nothing for it, and an attribute nobody
    /// reads is weight on the pasteboard.
    public static func appKit(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text.string)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) {
            attributes, range, _ in
            var translated: [NSAttributedString.Key: Any] = [:]
            for (key, value) in attributes {
                switch key {
                case AttributedBuilder.fontKey:
                    // A CTFont is an NSFont; the keys are what differ.
                    translated[.font] = value
                case AttributedBuilder.colorKey:
                    // The value is a `CGColor` by construction — the key is the
                    // CoreText one — but the type is checked rather than
                    // assumed, because a wrong guess here is a crash.
                    guard CFGetTypeID(value as CFTypeRef) == CGColor.typeID else { continue }
                    guard let color = NSColor(cgColor: value as! CGColor) else { continue }
                    translated[.foregroundColor] = color
                case .link, .strikethroughStyle, .strikethroughColor, .underlineStyle:
                    translated[key] = value
                default:
                    continue
                }
            }
            result.addAttributes(translated, range: range)
        }
        return result
    }

    /// The RTF flavour, or nil for text nothing could be made of.
    public static func rtf(_ text: NSAttributedString) -> Data? {
        let translated = appKit(text)
        return translated.rtf(
            from: NSRange(location: 0, length: translated.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }
}
