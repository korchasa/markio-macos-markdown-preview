import SwiftUI

/// Exposes the focused window's `DocumentModel` to app-level menu commands, so a
/// single Find menu drives whichever document window is key. [REF:fr:find]
struct FocusedDocumentModelKey: FocusedValueKey {
    typealias Value = DocumentModel
}

extension FocusedValues {
    var documentModel: DocumentModel? {
        get { self[FocusedDocumentModelKey.self] }
        set { self[FocusedDocumentModelKey.self] = newValue }
    }
}

/// Standard macOS Find menu items (Find… / Find Next / Find Previous) wired to
/// the focused document window's find bar via `@FocusedValue`. Next/Previous are
/// disabled until a search has matches. [REF:fr:find] [REF:sds:find-bar]
struct FindCommands: Commands {
    @FocusedValue(\.documentModel) private var model

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
