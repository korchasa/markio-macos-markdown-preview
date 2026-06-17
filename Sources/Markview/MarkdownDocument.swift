import SwiftUI
import UniformTypeIdentifiers

/// Read-only `FileDocument` carrying a file's Markdown text. The per-window unit
/// `DocumentGroup` builds on: each open file becomes one window backed by one of
/// these. Never writable → no Save, never marked dirty. [REF:fr:multidoc] [REF:sds:markdown-document]
struct MarkdownDocument: FileDocument {
    /// `.md` / `.markdown` (resolved at runtime) plus plain text as a fallback.
    static let types: [UTType] = {
        var types: [UTType] = [.plainText]
        if let md = UTType(filenameExtension: "md") { types.insert(md, at: 0) }
        if let markdown = UTType(filenameExtension: "markdown") { types.insert(markdown, at: 1) }
        return types
    }()

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
