import SwiftUI

/// View-menu toggles: the TOC sidebar (⌥⌘S — the macOS sidebar-toggle
/// convention, cf. Finder/Mail) and the compare layout (inline vs side-by-side
/// columns — a *view* concern, so it lives here, not in File). Both route to
/// the focused document window's model via `FocusedObject`. Checkmark
/// `Toggle`s with STATIC titles, not Show/Hide button pairs: a
/// state-dependent title makes SwiftUI rebuild the menu item, which drops its
/// displayed key equivalent. [REF:fr:toc] [REF:fr:compare]
/// [REF:sds:toc-sidebar] [REF:sds:compare]
struct TOCCommands: Commands {
    @FocusedObject private var model: DocumentModel?

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

            Toggle(
                "Compare Side by Side",
                isOn: Binding(
                    get: { model?.compareSplit == true },
                    set: { model?.setCompareSplit($0) }
                )
            )
            .disabled(model?.isCompared != true)
        }
    }
}
