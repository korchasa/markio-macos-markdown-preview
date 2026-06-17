import Foundation

/// Locates the vendored web bundle inside the app's resource bundle.
///
/// Lives in the `Markview` target on purpose: `Bundle.module` resolves to this
/// target's bundle even when called from the test target, so tests load the
/// same `template.html` + `vendor/` the app ships. [REF:sds:vendor]
enum ResourceLocator {
    /// Directory holding `template.html` and the `vendor/` tree (bundle root).
    static var resourcesRoot: URL {
        guard let base = Bundle.module.resourceURL else {
            fatalError("Markview resource bundle missing")
        }
        return base
    }

    /// The HTML shell loaded into the web view.
    static var templateURL: URL {
        resourcesRoot.appendingPathComponent("template.html", isDirectory: false)
    }
}
