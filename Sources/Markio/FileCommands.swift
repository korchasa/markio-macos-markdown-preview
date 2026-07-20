import AppKit
import SwiftUI

/// Owns the complete read-only File surface so its three semantic groups keep
/// a deterministic order: open, focused-document actions, close.
/// [REF:fr:menu] [REF:fr:compare] [REF:sds:menu-commands]
struct FileCommands: Commands {
    @FocusedValue(\.documentFileURL) private var documentFileURL
    @FocusedValue(\.documentModel) private var model

    var body: some Commands {
        // Keep DocumentGroup's native Open/Open Recent intact. Replacing the
        // save/close group once avoids unstable combinations of command-group
        // anchors while preserving the required File reading order.
        CommandGroup(replacing: .saveItem) {
            Button("Copy File Path") {
                _ = FilePathClipboard().copy(documentFileURL)
            }
            .disabled(documentFileURL == nil)

            Button("Compare Side by Side…") {
                model?.startCompare()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model == nil)

            Button("Stop Comparing") {
                model?.stopCompare()
            }
            .disabled(model?.isCompared != true)

            Divider()

            Button("Close") {
                NSApp.keyWindow?.performClose(nil)
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(documentFileURL == nil)

            Button("Close All") {
                NSDocumentController.shared.closeAllDocuments(
                    withDelegate: nil,
                    didCloseAllSelector: nil,
                    contextInfo: nil
                )
            }
            .keyboardShortcut("w", modifiers: [.command, .option])
            .disabled(documentFileURL == nil)
        }
    }
}
