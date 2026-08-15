import ApplicationServices
import Foundation

/// Deciding when a document is actually on screen.
///
/// The honest signal for "the reader can read it" is a pixel, and capturing
/// pixels needs Screen Recording. The accessibility tree is the next thing to
/// it and needs only Accessibility: an app publishes the text it has laid out,
/// so the moment a line from the top of the document appears in the tree is the
/// moment that line exists on screen.
///
/// Its cost has to be declared, not hidden. Attaching an accessibility client
/// makes a web view build an accessibility tree it would not otherwise build,
/// which is work a real reader never pays for. So this probe is run as its own
/// pass and never in the same run as the CPU and footprint numbers.
enum Readiness {
    static func isTrusted(prompting: Bool) -> Bool {
        // The key is spelled out rather than read from
        // `kAXTrustedCheckOptionPrompt`: that symbol is a mutable global, which
        // Swift 6 refuses to touch from concurrent code. Its value is this
        // string and has been since the API appeared.
        let options = ["AXTrustedCheckOptionPrompt": prompting] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Whether `needle` is visible anywhere in the app's accessibility tree.
    ///
    /// Breadth-first with a node budget: a viewer that publishes its whole
    /// document rather than just the visible part has an enormous tree, and
    /// walking all of it would time the walk instead of the app. The needle is
    /// taken from the first screenful, so a breadth-first walk reaches it early
    /// or the document is not drawn yet.
    static func showsText(_ needle: String, pid: pid_t, nodeBudget: Int = 4000) -> Bool {
        let application = AXUIElementCreateApplication(pid)
        var queue: [AXUIElement] = [application]
        var visited = 0

        while !queue.isEmpty && visited < nodeBudget {
            let element = queue.removeFirst()
            visited += 1

            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let text = string(of: element, attribute: attribute), text.contains(needle) {
                    return true
                }
            }
            queue.append(contentsOf: children(of: element))
        }
        return false
    }

    private static func string(of element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
                == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
