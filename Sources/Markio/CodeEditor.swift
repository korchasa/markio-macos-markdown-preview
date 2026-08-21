import AppKit

/// Where a clicked path opens, and how the line number gets there.
///
/// There is no portable "open this file at line 214" on macOS: every editor
/// invented its own URL scheme and none of them agrees with another. A URL is a
/// launch rather than a read, so the sandbox permits all of them — what it
/// cannot do is guess which editor the reader wants, and guessing wrong opens
/// the wrong app. So the choice is the reader's, made in the menu, and the
/// answer for someone who never makes it is the system's own handler for the
/// file type: the right app, at the top of the file.
enum CodeEditor: String, CaseIterable {
    /// Whatever macOS opens this kind of file with. Loses the line number,
    /// which is why it is not the only option.
    case system
    case vscode
    case cursor
    case zed
    case sublime
    case bbedit

    var title: String {
        switch self {
        case .system: return "Default App"
        case .vscode: return "Visual Studio Code"
        case .cursor: return "Cursor"
        case .zed: return "Zed"
        case .sublime: return "Sublime Text"
        case .bbedit: return "BBEdit"
        }
    }

    /// The URL that opens `file`, at `line` where the editor accepts one.
    ///
    /// Returning nil means "hand it to the system", which is both the answer
    /// for `.system` and the fallback for a scheme that cannot be built.
    func url(for file: URL, line: Int?) -> URL? {
        let path = file.standardizedFileURL.path
        let suffix = line.map { ":\($0)" } ?? ""
        switch self {
        case .system:
            return nil
        case .vscode:
            return URL(string: "vscode://file\(encoded(path))\(suffix)")
        case .cursor:
            return URL(string: "cursor://file\(encoded(path))\(suffix)")
        case .zed:
            return URL(string: "zed://file\(encoded(path))\(suffix)")
        case .sublime:
            return URL(string: "subl://open?url=file://\(encoded(path))\(query(line))")
        case .bbedit:
            return URL(string: "x-bbedit://open?url=file://\(encoded(path))\(query(line))")
        }
    }

    private func query(_ line: Int?) -> String {
        line.map { "&line=\($0)" } ?? ""
    }

    /// A path lands inside a URL, so a space or a hash in a folder name has to
    /// survive the trip. The separators stay themselves.
    private func encoded(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "#?")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    /// Open a file in the reader's chosen editor.
    ///
    /// An editor that is not installed answers nothing at all — macOS simply
    /// fails to open the scheme — so the system handler is tried after it. That
    /// is a fallback the reader would ask for if they could see it happening:
    /// the alternative is a click that does nothing and explains nothing.
    @MainActor
    static func open(_ file: URL, line: Int?) {
        let choice = Preferences.codeEditor
        guard let url = choice.url(for: file, line: line) else {
            NSWorkspace.shared.open(file)
            return
        }
        NSWorkspace.shared.open(
            url, configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: { _, error in
                guard error != nil else { return }
                DispatchQueue.main.async { NSWorkspace.shared.open(file) }
            })
    }
}
