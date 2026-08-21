import Foundation
import MarkdownKit

/// Turning the paths `CodePath` recognised into links a reader can click.
///
/// `CodePath` says what looks like a path; this says which of those are real,
/// and it is the existence check that makes the feature safe to have at all. A
/// document can name any path it likes; nothing becomes clickable unless the
/// file is genuinely beside the document, so a report cannot talk the viewer
/// into opening something the reader never pointed it at.
///
/// The text is untouched — a run is split, never rewritten — so find, copy and
/// the plain-text projection see exactly the characters they saw before.
enum CodePathLinks {
    /// Add link runs for every path in `content` that `exists` accepts.
    ///
    /// - Parameter exists: answers with the destination string to record, or
    ///   nil when this path is not a file worth offering. Passed in rather than
    ///   reached for, so the split can be tested with no disk at all.
    static func apply(
        to content: InlineContent,
        bytes: [UInt8],
        exists: (CodePath.Candidate) -> String?
    ) -> InlineContent {
        let candidates = CodePath.candidates(in: bytes)
        guard !candidates.isEmpty else { return content }

        var runs: [InlineRun] = []
        runs.reserveCapacity(content.runs.count)
        var links = content.links
        var found = false

        for run in content.runs {
            // Only plain text, and only text that is not already inside a link:
            // a path written as the label of one belongs to that link.
            guard run.kind == .text, run.link < 0 else {
                runs.append(run)
                continue
            }
            var cursor = run.range.start
            for candidate in candidates
            where candidate.range.start >= run.range.start && candidate.range.end <= run.range.end {
                guard let destination = exists(candidate) else { continue }
                if candidate.range.start > cursor {
                    var before = run
                    before.range = ByteRange(start: cursor, end: candidate.range.start)
                    runs.append(before)
                }
                var linked = run
                linked.range = candidate.range
                linked.style.insert(.link)
                linked.link = Int32(links.count)
                links.append(
                    InlineLink(destination: destination, title: "", isImage: false))
                runs.append(linked)
                cursor = candidate.range.end
                found = true
            }
            guard cursor > run.range.start else {
                runs.append(run)
                continue
            }
            if cursor < run.range.end {
                var after = run
                after.range = ByteRange(start: cursor, end: run.range.end)
                runs.append(after)
            }
        }
        guard found else { return content }
        return InlineContent(runs: runs, links: links)
    }

    /// Whether a path names a file this app may offer to open, and what to
    /// record as the link's destination.
    ///
    /// Three conditions, all of them necessary: the path is relative (enforced
    /// by `CodePath`), it resolves to somewhere under the document's own
    /// folder, and the file is really there. In a sandboxed build the third one
    /// also answers "and the reader has granted that folder" — an ungranted
    /// folder reads as empty, which is the honest answer to give: the app
    /// cannot see the file, so it must not claim it can open it.
    static func destination(for candidate: CodePath.Candidate, near document: URL?) -> String? {
        guard let document else { return nil }
        let folder = document.deletingLastPathComponent().standardizedFileURL
        let target = URL(fileURLWithPath: candidate.path, relativeTo: folder).standardizedFileURL
        // `../` out of the document's folder is refused for the same reason an
        // absolute path is: this reaches the files beside the document.
        guard target.path.hasPrefix(folder.path + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else { return nil }
        guard let line = candidate.line else { return candidate.path }
        return "\(candidate.path):\(line)"
    }
}
