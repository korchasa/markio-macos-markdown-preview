import SwiftUI

/// File-menu entry points for side-by-side compare, routed to the focused
/// document window's model via the shared `FocusedValue` (the same pattern as
/// Find and TOC). `Compare Side by Side…` prompts for the second document and
/// pairs the windows; `Stop Comparing` breaks the focused window's pair.
/// Anchored after the (emptied) save group, so the items land between
/// Open Recent and the print section. [REF:fr:compare]
struct CompareCommands: Commands {
    @FocusedValue(\.documentModel) private var model

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Divider()

            Button("Compare Side by Side…") {
                model?.startCompare()
            }
            .disabled(model == nil)

            Button("Stop Comparing") {
                model?.stopCompare()
            }
            .disabled(model?.isCompared != true)
        }
    }
}
