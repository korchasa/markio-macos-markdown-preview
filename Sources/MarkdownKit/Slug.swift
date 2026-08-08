/// GitHub-compatible heading slugs.
///
/// The rule GitHub applies: lowercase, drop everything that is not a letter,
/// digit, space, hyphen or underscore, then turn spaces into hyphens. Letters
/// outside ASCII are kept, so a Cyrillic or Greek heading gets a usable anchor.
/// Matching GitHub matters because `#anchor` links in real documents were
/// written against it.
public enum Slug {
    public static func make(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.lowercased().unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\n" {
                out.append("-")
            } else if isSlugSafe(scalar) {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func isSlugSafe(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "-" || scalar == "_" { return true }
        if scalar.value >= 0x30 && scalar.value <= 0x39 { return true }
        return scalar.properties.isAlphabetic
    }
}
