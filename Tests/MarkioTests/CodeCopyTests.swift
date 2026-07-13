import AppKit
import XCTest

@testable import Markio

/// Exercises the copy-button + language-badge decoration on fenced code blocks
/// and the `markioCopy` page→native pasteboard channel. Uses a uniquely named
/// pasteboard so tests never clobber the user's clipboard. [REF:fr:code-copy]
@MainActor
final class CodeCopyTests: XCTestCase {
    /// A loaded preview writing to a private, uniquely named pasteboard.
    private func makeCopyPreview() async throws -> (PreviewController, NSPasteboard) {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("dev.markio.tests.\(UUID().uuidString)"))
        let preview = PreviewController(pasteboard: pasteboard)
        try await preview.loadTemplate()
        return (preview, pasteboard)
    }

    func testCopyButtonCopiesRawCode() async throws {
        let (preview, pasteboard) = try await makeCopyPreview()
        let markdown = """
            ```swift
            let answer = 42
            ```
            """
        await preview.render(markdown)

        var copied: String?
        let delivered = expectation(description: "markioCopy delivered")
        preview.onCodeCopied = { text in
            copied = text
            delivered.fulfill()
        }
        _ = try await preview.evaluate(
            "document.querySelector('#content button.markio-copy').click(); true")
        await fulfillment(of: [delivered], timeout: 5)

        XCTAssertEqual(copied, "let answer = 42\n", "Copy must deliver the raw fence content")
        XCTAssertEqual(
            pasteboard.string(forType: .string), "let answer = 42\n",
            "Raw code must land on the native pasteboard")
    }

    func testLanguageBadgeFromFenceInfo() async throws {
        let (preview, _) = try await makeCopyPreview()
        let markdown = """
            ```swift
            let a = 1
            ```

            ```
            plain text, no info string
            ```
            """
        await preview.render(markdown)

        let buttons = try await count(
            preview, "document.querySelectorAll('#content button.markio-copy').length")
        XCTAssertEqual(buttons, 2, "Every fenced block gets a Copy button")

        let badges = try await count(
            preview, "document.querySelectorAll('#content .markio-code-lang').length")
        XCTAssertEqual(badges, 1, "Only the tagged fence gets a language badge")

        let badgeText = try await preview.evaluate(
            "document.querySelector('#content .markio-code-lang').textContent")
        XCTAssertEqual(badgeText as? String, "swift", "Badge shows the fence info's first word")
    }

    func testMermaidAndFrontmatterExcluded() async throws {
        let (preview, _) = try await makeCopyPreview()
        let markdown = """
            ---
            title: Meta
            ---

            ```mermaid
            flowchart LR
              A --> B
            ```

            ```swift
            let a = 1
            ```
            """
        await preview.render(markdown)

        let buttons = try await count(
            preview, "document.querySelectorAll('#content button.markio-copy').length")
        XCTAssertEqual(buttons, 1, "Only the real code fence is decorated")

        let inFrontmatter = try await count(
            preview,
            "document.querySelectorAll('#content .markio-frontmatter-box button.markio-copy').length"
        )
        XCTAssertEqual(inFrontmatter, 0, "Frontmatter box gets no copy UI")

        let inMermaid = try await count(
            preview,
            "document.querySelectorAll('#content pre.mermaid button.markio-copy').length")
        XCTAssertEqual(inMermaid, 0, "Mermaid blocks get no copy UI")
    }

    func testFindSkipsCopyUI() async throws {
        let (preview, _) = try await makeCopyPreview()
        let markdown = """
            ```zig
            hello world
            ```
            """
        await preview.render(markdown)

        let labelMatches = await preview.search("Copy")
        XCTAssertEqual(labelMatches.count, 0, "Find must never match the Copy button label")
        await preview.clearSearch()

        let badgeMatches = await preview.search("zig")
        XCTAssertEqual(badgeMatches.count, 0, "Find must never match the language badge text")
    }
}
