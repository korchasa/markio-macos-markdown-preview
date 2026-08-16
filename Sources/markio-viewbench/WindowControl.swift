import AppKit

/// Puts every subject's window in the same place, at the same size, in sight.
///
/// Two problems, one answer. The first is that a window nothing can see is not
/// drawn: AppKit stops sending display cycles to an occluded window, so a
/// subject launched in the background never lays the document out and reads as
/// an application that cannot open it. Activating the app fixes that and takes
/// the keyboard away from whoever is at the machine, forty times an hour.
/// Accessibility offers the third option — `AXRaise` puts a window in front
/// without making its application active, so the window is drawn and the
/// keyboard stays where it was.
///
/// The second is a fairness problem that predates all of this: each subject
/// opened at whatever size it happened to remember, and how much of a document
/// gets laid out depends on how big the window is. A viewer measured in a small
/// window was being credited for work it never did. Since the window is being
/// touched anyway, it is given the same geometry for every subject.
enum WindowControl {
    /// A reading window: large enough that laying out a screenful is real work,
    /// small enough to leave the desk usable while the benchmark runs.
    static let frame = CGRect(x: 80, y: 60, width: 1280, height: 900)

    /// Best effort — without Accessibility permission there is nothing to do
    /// here, and the run is then judged by `WindowVisibility` alone.
    static func normalize(pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.5)

        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
                == .success,
            let windows = value as? [AXUIElement]
        else { return }

        for window in windows {
            var position = CGPoint(x: frame.minX, y: frame.minY)
            var size = CGSize(width: frame.width, height: frame.height)
            if let point = AXValueCreate(.cgPoint, &position) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, point)
            }
            if let extent = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
            }
            // Documented not to activate the application, which is the whole
            // reason this is done through accessibility rather than by asking
            // the app to come forward.
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }
}
