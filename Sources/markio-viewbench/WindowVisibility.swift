import AppKit

/// How much of a subject's window is actually in sight.
///
/// Each subject is brought to the front before it is timed, but being asked to
/// come forward and being in sight are not the same thing, and the difference
/// is invisible in the result: AppKit sends no display cycles to a window that
/// is entirely covered, so the document is never laid out, the probe never
/// fires, and the app is reported as unreadable when it was simply never asked
/// to draw.
///
/// So the window is measured as well as commanded. A run whose subject was
/// buried is refused rather than believed.
enum WindowVisibility {
    /// What a look at the desk says about one subject.
    struct Reading {
        /// The fraction of its frontmost window that nothing covers.
        var visible: Double
        /// Who is standing in front of it, largest first. Without this a
        /// refused run says only that the window was hidden, and the operator
        /// has no idea what to move.
        var coveredBy: [String]
    }

    /// The fraction of the subject's frontmost window that nothing covers, or
    /// nil when it has no ordinary window on screen at all.
    static func visibleFraction(pid: pid_t, samples: Int = 20) -> Double? {
        look(pid: pid, samples: samples)?.visible
    }

    static func look(pid: pid_t, samples: Int = 20) -> Reading? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard
            let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        // The list runs front to back, so the subject's frontmost window is its
        // first entry, and everything before that entry stands in front of it.
        //
        // Frontmost, not largest. Each run opens a warmup document and then the
        // one being measured, which leaves the app with two windows of the same
        // size — and picking the larger one picked the one behind, reporting
        // every subject as completely covered by itself.
        var subjectRect: CGRect?
        var subjectIndex = 0
        for (index, info) in list.enumerated() {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let rect = bounds(of: info), rect.width > 1, rect.height > 1
            else { continue }
            subjectRect = rect
            subjectIndex = index
            break
        }
        guard let rect = subjectRect else { return nil }

        let covers = list.prefix(subjectIndex).compactMap { info -> (CGRect, String)? in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
                // The Dock's window is the size of the screen and sits on the
                // ordinary layer, so counting it made every subject 100%
                // covered whenever it happened to be ahead in the list. macOS
                // does not treat a window under the Dock as occluded, and
                // neither does a reader.
                (info[kCGWindowOwnerName as String] as? String) != "Dock",
                // The subject's own windows are not something hiding it from
                // the reader — the app is right there, drawing.
                (info[kCGWindowOwnerPID as String] as? pid_t) != pid,
                let rect = bounds(of: info)
            else { return nil }
            return (rect, info[kCGWindowOwnerName as String] as? String ?? "something unnamed")
        }

        // A grid over the window is enough: the question is whether the reader
        // can see it, not its exact area to the pixel.
        var seen = 0
        var blame: [String: Int] = [:]
        for row in 0..<samples {
            for column in 0..<samples {
                let point = CGPoint(
                    x: rect.minX + rect.width * (Double(column) + 0.5) / Double(samples),
                    y: rect.minY + rect.height * (Double(row) + 0.5) / Double(samples))
                if let cover = covers.first(where: { $0.0.contains(point) }) {
                    blame[cover.1, default: 0] += 1
                } else {
                    seen += 1
                }
            }
        }
        return Reading(
            visible: Double(seen) / Double(samples * samples),
            coveredBy: blame.sorted { $0.value > $1.value }.map(\.key))
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
