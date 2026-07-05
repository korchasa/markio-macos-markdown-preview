import SwiftUI
import UniformTypeIdentifiers

/// Read-only `FileDocument` carrying a file's Markdown text. The per-window unit
/// `DocumentGroup` builds on: each open file becomes one window backed by one of
/// these. Never writable → no Save, never marked dirty. [REF:fr:multidoc] [REF:sds:markdown-document]
struct MarkdownDocument: FileDocument {
    /// Canonical set of recognized Markdown file extensions — the single source
    /// of truth. `types` and `URL.isMarkdown` both derive from this. The
    /// Info.plist `CFBundleTypeExtensions` array is a third copy kept in sync
    /// manually; `MarkdownExtensionsTests` asserts the plist matches this list.
    static let extensions = ["md", "markdown"]

    /// `.md` / `.markdown` (resolved at runtime) plus plain text as a fallback.
    static let types: [UTType] =
        extensions.compactMap { UTType(filenameExtension: $0) } + [.plainText]

    static var readableContentTypes: [UTType] { types }
    /// Read-only viewer: declaring nothing writable disables Save and keeps the
    /// document from ever entering an edited state. [REF:fr:multidoc]
    static var writableContentTypes: [UTType] { [] }

    let text: String

    init(text: String = "") {
        self.text = text
    }

    /// Decode file bytes as UTF-8; throw on invalid input rather than render
    /// garbage (fail fast). [REF:fr:multidoc]
    init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        self.text = text
    }

    /// `FileDocument` entry point: unwrap the file's bytes and delegate to
    /// `init(data:)` for UTF-8 decoding (fail fast on missing/binary content).
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try self.init(data: data)
    }

    /// Read-only: writing is unsupported.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.featureUnsupported)
    }
}

extension URL {
    /// True when the path extension is a recognized Markdown extension
    /// (case-insensitive), per `MarkdownDocument.extensions`. [REF:fr:open]
    var isMarkdown: Bool {
        MarkdownDocument.extensions.contains(pathExtension.lowercased())
    }
}
