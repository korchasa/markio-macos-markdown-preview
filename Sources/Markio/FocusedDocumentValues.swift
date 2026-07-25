import SwiftUI

/// Scene-wide values shared by commands that target the focused document.
/// The `DocumentModel` itself travels as a focused OBJECT
/// (`.focusedSceneObject`/`@FocusedObject`), not a focused value: `Commands`
/// bodies must observe its `@Published` state so menu items update without a
/// window-focus change. [REF:sds:menu-commands]
///
/// Synchronous URL from `DocumentGroup`, available before model startup.
/// [REF:fr:menu]
struct FocusedDocumentFileURLKey: FocusedValueKey {
    typealias Value = URL
}

extension FocusedValues {
    var documentFileURL: URL? {
        get { self[FocusedDocumentFileURLKey.self] }
        set { self[FocusedDocumentFileURLKey.self] = newValue }
    }
}
