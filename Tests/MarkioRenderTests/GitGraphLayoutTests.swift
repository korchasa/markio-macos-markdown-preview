import AppKit
import XCTest

@testable import MarkioRender

/// Where a git graph writes its branch names.
@MainActor
final class GitGraphLayoutTests: XCTestCase {
    private func drawing(_ source: String) throws -> MermaidLayout.Drawing {
        let diagram = try XCTUnwrap(MermaidDiagram.parse(source), "did not parse")
        return MermaidLayout.draw(diagram, theme: Theme(isDark: false), width: 900)
    }

    /// The tags are the coloured plates the names are written on: whatever is
    /// filled under a word near the top of the picture.
    private func tags(in drawing: MermaidLayout.Drawing) -> [CGRect] {
        var found: [CGRect] = []
        for decoration in drawing.decorations {
            guard case .glyphs(let line, let origin) = decoration else { continue }
            var ascent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, nil, nil))
            let point = CGPoint(x: origin.x + width / 2, y: origin.y - ascent / 2)
            for painted in drawing.decorations {
                if case .fill(let rect, _, _) = painted, rect.contains(point) { found.append(rect) }
            }
        }
        return found
    }

    /// Down the page the names stand side by side, and a lane is only as wide
    /// as the dot in it: the two tags met in the middle and read as one word.
    func testTwoBranchTagsStandApart() throws {
        let picture = try drawing("gitGraph TB:\n commit\n branch feature\n commit")
        let plates = tags(in: picture).sorted { $0.minX < $1.minX }
        XCTAssertEqual(plates.count, 2, "each branch is named on a tag of its own")
        XCTAssertGreaterThan(plates[1].minX - plates[0].maxX, 4)
    }
}
