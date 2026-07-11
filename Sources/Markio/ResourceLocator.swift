import Foundation

/// Locates the vendored web bundle (`template.html` + `vendor/`) that ships
/// inside the app's resource bundle.
///
/// We deliberately do **not** use SwiftPM's generated `Bundle.module`. Its
/// accessor looks for `Markio_Markio.bundle` next to `Bundle.main.bundleURL`
/// and, failing that, at a build-time absolute path baked into the binary.
/// Both hold while running from `.build` (tests, `swift run`) but neither holds
/// in a packaged `.app`, where the binary is relocated to `Contents/MacOS/` and
/// the resource bundle to `Contents/Resources/`. There, merely referencing
/// `Bundle.module` hits its `fatalError` — which is exactly what crashed the
/// shipped build on launch of the first document. Instead we resolve the bundle
/// ourselves across every layout we ship. [REF:sds:vendor]
enum ResourceLocator {
    /// A type whose defining bundle we can query at runtime.
    private final class BundleToken {}

    /// Basename of the SwiftPM-produced resource bundle.
    private static let bundleName = "Markio_Markio.bundle"

    /// Directory holding `template.html` and the `vendor/` tree (bundle root).
    ///
    /// Searched, in order: the packaged `.app` (`Contents/Resources`), the raw
    /// SwiftPM layout (resource bundle a **sibling** of the runner — used by
    /// `swift test`, where it sits next to the `.xctest`, and `swift run`), and
    /// the enclosing framework bundle. The first location that actually contains
    /// `template.html` wins; a hard failure here means the app was assembled
    /// without its resources, which is unrecoverable.
    static var resourcesRoot: URL {
        let tokenBundle = Bundle(for: BundleToken.self)
        let searchBases: [URL] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            // Sibling of the runner: `.build/.../debug/Markio_Markio.bundle`.
            Bundle.main.bundleURL.deletingLastPathComponent(),
            tokenBundle.resourceURL,
            tokenBundle.bundleURL,
            tokenBundle.bundleURL.deletingLastPathComponent(),
        ].compactMap { $0 }

        for base in searchBases {
            let candidate = base.appendingPathComponent(bundleName, isDirectory: true)
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("template.html").path
            ) {
                return candidate
            }
        }
        fatalError("Markio resource bundle (\(bundleName)) not found near the executable")
    }

    /// The HTML shell loaded into the web view.
    static var templateURL: URL {
        resourcesRoot.appendingPathComponent("template.html", isDirectory: false)
    }

    /// `template.html` with every vendored `<link>`/`<script src>` replaced by its
    /// inlined `<style>`/`<script>` body, producing a single self-contained
    /// document with **no** subresource references.
    ///
    /// Why: under the Mac App Store App Sandbox, `WKWebView.loadFileURL(_:
    /// allowingReadAccessTo:)` fails to render the packaged shell — the confined
    /// WebContent process never completes the `file:` navigation, so the view
    /// stays blank (reproduced on a signed TestFlight build). Reading the assets
    /// app-side (own-bundle reads are always permitted in the sandbox) and handing
    /// WebKit one `loadHTMLString(baseURL: nil)` avoids `file:` entirely.
    /// [REF:sds:vendor] [REF:fr:offline]
    static func selfContainedHTML() throws -> String {
        let root = resourcesRoot
        var html = try String(contentsOf: templateURL, encoding: .utf8)
        // Stylesheets: <link rel="stylesheet" href="vendor/…" [media="…"]> → <style [media]>…</style>
        let linkPattern =
            #"<link\s+rel="stylesheet"\s+href="(vendor/[^"]+)""#
            + #"(?:\s+media="([^"]*)")?\s*/?>"#
        html = try inlineVendor(in: html, pattern: linkPattern, root: root) { body, media in
            let mediaAttr = media.map { " media=\"\($0)\"" } ?? ""
            return "<style\(mediaAttr)>\n\(body)\n</style>"
        }
        // Scripts: <script src="vendor/…"></script> → <script>…</script>
        html = try inlineVendor(
            in: html,
            pattern: #"<script\s+src="(vendor/[^"]+)"\s*></script>"#,
            root: root
        ) { body, _ in "<script>\n\(body)\n</script>" }
        return html
    }

    /// Replace every match of `pattern` (capture 1 = vendor-relative path,
    /// optional capture 2 = media query) with `wrap(fileContents, media)`.
    /// Matches are applied last-to-first so earlier ranges stay valid.
    private static func inlineVendor(
        in html: String,
        pattern: String,
        root: URL,
        wrap: (_ body: String, _ media: String?) -> String
    ) throws -> String {
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var result = html
        for match in matches.reversed() {
            let rel = ns.substring(with: match.range(at: 1))
            let media: String? =
                match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound
                ? ns.substring(with: match.range(at: 2)) : nil
            let body = try String(
                contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: wrap(body, media))
        }
        return result
    }
}
