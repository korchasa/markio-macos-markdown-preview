import AppKit

/// How much of a subject's window is actually in sight.
///
/// The harness used to bring each subject to the front before timing it, which
/// keeps App Nap off and the window drawing — and takes the keyboard away from
/// whoever is at the machine, once per run, for an hour. Launching without
/// activation gives that back, but it introduces a failure that looks exactly
/// like a slow application: AppKit stops sending display cycles to a window
/// that is entirely covered, so the document is never laid out, the probe never
/// fires, and the app is reported as unreadable when it simply was not asked to
/// draw.
///
/// So the window is measured instead of commanded. A run whose subject was
/// buried is refused rather than believed.
enum WindowVisibility {
    /// The fraction of the subject's largest window that nothing covers, or
    /// nil when it has no ordinary window on screen at all.
    static func visibleFraction(pid: pid_t, samples: Int = 20) -> Double? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        // The list runs front to back, so everything before the subject is a
        // window standing in front of it.
        var subjectRect: CGRect?
        var subjectIndex = 0
        for (index, info) in list.enumerated() {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let rect = bounds(of: info)
            else { continue }
            if subjectRect.map({ rect.area > $0.area }) ?? true {
                subjectRect = rect
                subjectIndex = index
            }
        }
        guard let rect = subjectRect, rect.width > 1, rect.height > 1 else { return nil }

        let covers = list.prefix(subjectIndex).compactMap { info -> CGRect? in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0,
                (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.1
            else { return nil }
            return bounds(of: info)
        }

        // A grid over the window is enough: the question is whether the reader
        // can see it, not its exact area to the pixel.
        var seen = 0
        for row in 0..<samples {
            for column in 0..<samples {
                let point = CGPoint(
                    x: rect.minX + rect.width * (Double(column) + 0.5) / Double(samples),
                    y: rect.minY + rect.height * (Double(row) + 0.5) / Double(samples))
                if !covers.contains(where: { $0.contains(point) }) { seen += 1 }
            }
        }
        return Double(seen) / Double(samples * samples)
    }

    /// Whether there is anywhere on this desk for a subject's window to be seen.
    ///
    /// A full-screen application owns its Space outright: every other window
    /// lives on a different Space and appears in no on-screen list, so no
    /// subject is ever drawn and every run is refused. Worth learning before an
    /// hour of runs rather than after the first one.
    static func deskIsUsable() -> Bool {
        guard let screen = NSScreen.screens.first else { return true }
        let full = screen.frame
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return !list.contains { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let rect = bounds(of: info)
            else { return false }
            return rect.width >= full.width && rect.height >= full.height
        }
    }

    private static func bounds(of info: [String: Any]) -> CGRect? {
        guard let dictionary = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }
}

extension CGRect {
    fileprivate var area: CGFloat { width * height }
}
