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
    static func showsText(_ needle: String, pid: pid_t, nodeBudget: Int = 600) -> Bool {
        let application = AXUIElementCreateApplication(pid)

        // Every attribute read is a round trip to the app, answered on its main
        // thread — the very thread that is busy drawing the document. Without a
        // timeout the probe waits as long as the app takes, which would time
        // the probe instead of the app and can hang the run outright.
        AXUIElementSetMessagingTimeout(application, 0.25)

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

    /// Print an app's accessibility tree. A probe that finds nothing and an app
    /// that publishes nothing look identical from the outside; this is what
    /// tells them apart.
    static func dump(pid: pid_t, depth: Int = 6, nodeBudget: Int = 400) -> String {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1.0)
        var lines: [String] = []
        var visited = 0

        func walk(_ element: AXUIElement, level: Int) {
            guard level <= depth, visited < nodeBudget else { return }
            visited += 1
            let role = string(of: element, attribute: kAXRoleAttribute) ?? "?"
            let value = string(of: element, attribute: kAXValueAttribute)
            let title = string(of: element, attribute: kAXTitleAttribute)
            let text = (value ?? title ?? "").prefix(60).replacingOccurrences(of: "\n", with: " ")
            let children = self.children(of: element)
            lines.append(
                String(repeating: "  ", count: level)
                    + "\(role) [\(children.count)] \(text)")
            for child in children { walk(child, level: level + 1) }
        }

        walk(application, level: 0)
        return lines.joined(separator: "\n")
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
