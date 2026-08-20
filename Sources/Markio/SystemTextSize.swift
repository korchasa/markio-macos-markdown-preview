import AppKit
import MarkioRender

/// What the system says about how large text should be, as a zoom factor.
///
/// macOS keeps a text size in Accessibility settings — the slider that moves
/// apps between the `UICTContentSizeCategory` steps — but exposes no way to
/// read the category itself. The one public reading is the body text style: it
/// comes back at the system size when the slider is where it shipped, and
/// larger when the reader has moved it. So the factor is what that size is a
/// multiple of, and a system that says nothing yields exactly 1.
enum SystemTextSize {
    /// The zoom a window opens at when the reader has not set one for the
    /// document, snapped to a step so ⌘0 and ⌘+ agree about where they are.
    @MainActor
    static var zoom: CGFloat {
        let preferred = NSFont.preferredFont(forTextStyle: .body).pointSize
        let base = NSFont.systemFontSize
        guard base > 0, preferred > 0 else { return 1 }
        return Preferences.zoom(Preferences.clampZoom(preferred / base), steppedBy: 0)
    }
}
