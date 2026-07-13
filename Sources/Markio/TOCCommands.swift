import SwiftUI

/// View-menu toggle for the TOC sidebar (⌥⌘S — the macOS sidebar-toggle
/// convention, cf. Finder/Mail), routed to the focused document window's model
/// via the shared `FocusedValue`. [REF:fr:toc] [REF:sds:toc-sidebar]
struct TOCCommands: Commands {
    @FocusedValue(\.documentModel) private var model

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(
                model?.tocVisible == true
                    ? "Hide Table of Contents" : "Show Table of Contents"
            ) {
                model?.toggleTOC()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(model == nil)
        }
    }
}
