import SwiftUI

/// Edit-menu Find actions routed to the focused document window. File actions
/// stay in `FileCommands`; the standard Edit clipboard surface is untouched.
/// [REF:fr:find] [REF:sds:find-bar] [REF:sds:menu-commands]
struct FindCommands: Commands {
    @FocusedObject private var model: DocumentModel?

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Section {
                Button("Find…") { model?.openFind() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model == nil)
                Button("Find Next") { model?.findNext() }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled((model?.findResult.count ?? 0) == 0)
                Button("Find Previous") { model?.findPrev() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled((model?.findResult.count ?? 0) == 0)
            }
        }
    }
}
