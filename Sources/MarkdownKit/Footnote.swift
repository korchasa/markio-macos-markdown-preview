/// Footnotes: `[^label]` in the text, `[^label]: …` on a line of its own.
///
/// The label is shown as written rather than renumbered. Renumbering would
/// need the whole document counted before any block could be drawn, which is
/// exactly what this viewer refuses to do — and in the documents people write
/// the labels are already `1`, `2`, `3`, so the two agree anyway.
public enum Footnote {
    /// The anchor a reference points at, so a click can find the definition.
    /// Prefixed, so a footnote called `notes` cannot collide with a heading of
    /// the same name.
    public static func anchor(label: String) -> String {
        "fn-" + Slug.make(label)
    }

    /// The destination given to a reference's link, in the form a link resolver
    /// already understands.
    public static func destination(label: String) -> String {
        "#" + anchor(label: label)
    }
}
