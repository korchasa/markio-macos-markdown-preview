import AppKit

/// The folders a reader has let this app read, and what asks for them.
///
/// A sandboxed app is given the document it was told to open and nothing else —
/// not the folder it sits in, and not the picture beside it. So a document that
/// says `![a picture](pic.png)` drew the empty frame VIEW-16 keeps for a file it
/// cannot read, on the Mac App Store and nowhere else: an unsigned build has no
/// sandbox, which is why every local run looked right.
///
/// There is no entitlement for "the folder my document is in". The only way in
/// is the reader pointing at that folder in a panel, and a security-scoped
/// bookmark so they are not asked again after a relaunch. This holds the
/// bookmarks and answers the one question the drawing needs — may this be read
/// — while the panel itself belongs to the window that would show it.
@MainActor
public final class FolderAccess {
    public static let shared = FolderAccess(defaults: .standard)

    /// Called with the folder a document just failed to read something from,
    /// once per folder per run. The app answers it by asking the reader.
    public var onNeedsGrant: ((URL) -> Void)?

    private let defaults: UserDefaults
    private let key = "FolderGrants"
    /// Resolved folders, kept open for as long as the app runs. Access is
    /// balanced by the process ending: a document is read again on every
    /// scroll, and stopping between reads would cost a resolve each time.
    private var open: [URL] = []
    private var asked: Set<String> = []
    private var loaded = false

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Whether `url` sits inside a folder the reader has already granted.
    ///
    /// Both sides are resolved through their symlinks first. A panel hands back
    /// the path the reader saw — `/tmp/notes` — while the document it belongs
    /// to arrives as `/private/tmp/notes`, and comparing those two spellings
    /// says the folder was never granted.
    public func covers(_ url: URL) -> Bool {
        load()
        let path = Self.real(url).pathComponents
        return open.contains { folder in
            let granted = folder.pathComponents
            return path.count > granted.count && Array(path.prefix(granted.count)) == granted
        }
    }

    /// One spelling for one place on disk.
    ///
    /// `resolvingSymlinksInPath` only rewrites a path that exists, and the
    /// picture a document points at is exactly the path that may not — so the
    /// deepest part of it that does exist is resolved and the rest put back on.
    /// Without it a grant on `/tmp/notes` did not cover `/private/tmp/notes`,
    /// which is the pair a panel and a document actually arrive with.
    private static func real(_ url: URL) -> URL {
        var tail: [String] = []
        var walk = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: walk.path), walk.pathComponents.count > 1 {
            tail.append(walk.lastPathComponent)
            walk = walk.deletingLastPathComponent()
        }
        var resolved = walk.resolvingSymlinksInPath()
        for part in tail.reversed() { resolved.appendPathComponent(part) }
        return resolved.standardizedFileURL
    }

    /// A file the drawing could not read.
    ///
    /// A file inside a folder already granted is simply a file this machine
    /// cannot decode — a truncated PNG, a name pointing at nothing — and says
    /// nothing about access. Everything else is a folder worth asking for, and
    /// asked for once: a document with ten pictures in it would otherwise put
    /// ten panels on the screen.
    public func noteUnreadable(_ url: URL) {
        guard !covers(url) else { return }
        let folder = Self.real(url).deletingLastPathComponent()
        guard asked.insert(folder.path).inserted else { return }
        onNeedsGrant?(folder)
    }

    /// Keep a folder the reader chose in a panel. Returns false when the
    /// bookmark cannot be made, which is what a build without the
    /// `files.bookmarks.app-scope` entitlement does.
    @discardableResult
    public func remember(_ folder: URL) -> Bool {
        load()
        guard
            let data = try? folder.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil,
                relativeTo: nil)
        else { return false }
        var stored = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
        stored[folder.standardizedFileURL.path] = data
        defaults.set(stored, forKey: key)
        _ = folder.startAccessingSecurityScopedResource()
        open.append(Self.real(folder))
        asked.remove(Self.real(folder).path)
        // Every picture in that folder was read before the grant and failed.
        // Nothing keeps a failure, but the boxes laid out around them are kept,
        // so what the reader sees next has to be drawn again from nothing.
        ImageLoader.forget()
        return true
    }

    /// Every folder granted so far, in the order they were granted.
    public var granted: [URL] {
        load()
        return open
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let stored = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
        for (path, data) in stored.sorted(by: { $0.key < $1.key }) {
            var stale = false
            guard
                let url = try? URL(
                    resolvingBookmarkData: data, options: .withSecurityScope,
                    relativeTo: nil, bookmarkDataIsStale: &stale)
            else { continue }
            _ = url.startAccessingSecurityScopedResource()
            open.append(Self.real(url))
            // A folder that moved resolves to where it is now, and the stored
            // bookmark still names where it was. Rewriting it here is what
            // keeps one grant from being asked for twice.
            if stale || url.standardizedFileURL.path != path {
                var refreshed = defaults.dictionary(forKey: key) as? [String: Data] ?? [:]
                refreshed.removeValue(forKey: path)
                if let data = try? url.bookmarkData(
                    options: .withSecurityScope, includingResourceValuesForKeys: nil,
                    relativeTo: nil)
                {
                    refreshed[url.standardizedFileURL.path] = data
                }
                defaults.set(refreshed, forKey: key)
            }
        }
    }
}
