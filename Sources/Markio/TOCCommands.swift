import SwiftUI

/// View-menu toggle for the TOC sidebar (⌥⌘S — the macOS sidebar-toggle
/// convention, cf. Finder/Mail), routed to the focused document window's model
/// via the shared `FocusedValue`. A checkmark `Toggle` with a STATIC title, not
/// a Show/Hide button pair: a state-dependent title makes SwiftUI rebuild the
/// menu item, which drops its displayed key equivalent. [REF:fr:toc]
/// [REF:sds:toc-sidebar]
struct TOCCommands: Commands {
    @FocusedValue(\.documentModel) private var model

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Toggle(
                "Table of Contents",
                isOn: Binding(
                    get: { model?.tocVisible == true },
                    set: { _ in model?.toggleTOC() }
                )
            )
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(model == nil)
        }
    }
}
