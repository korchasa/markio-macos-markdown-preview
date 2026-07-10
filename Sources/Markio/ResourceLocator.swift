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
}
