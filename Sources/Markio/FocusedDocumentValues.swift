import SwiftUI

/// Scene-wide values shared by commands that target the focused document.
/// [REF:sds:menu-commands]
struct FocusedDocumentModelKey: FocusedValueKey {
    typealias Value = DocumentModel
}

/// Synchronous URL from `DocumentGroup`, available before model startup.
/// [REF:fr:menu]
struct FocusedDocumentFileURLKey: FocusedValueKey {
    typealias Value = URL
}

extension FocusedValues {
    var documentModel: DocumentModel? {
        get { self[FocusedDocumentModelKey.self] }
        set { self[FocusedDocumentModelKey.self] = newValue }
    }

    var documentFileURL: URL? {
        get { self[FocusedDocumentFileURLKey.self] }
        set { self[FocusedDocumentFileURLKey.self] = newValue }
    }
}
