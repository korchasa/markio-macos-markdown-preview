import AppKit
import Foundation
import MarkdownKit
import MarkioRender

/// Renders one Mermaid source to a PNG of exactly the picture, with no page
/// around it.
///
/// `snapshot` renders a whole document at a fixed size, which leaves a drawing
/// sitting in a field of empty page. Comparing this renderer against another
/// one needs the picture and nothing else, so this goes through the same path
/// the enlarged window and Copy PNG use.
@MainActor
enum Diagram {
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count >= 2 else {
            print("usage: markio-bench diagram <in.mmd> <out.png> [width] [dark]")
            return 2
        }
        let input = URL(fileURLWithPath: arguments[0])
        let output = URL(fileURLWithPath: arguments[1])
        let width = arguments.count > 2 ? Double(arguments[2]) ?? 720 : 720
        let dark = arguments.count > 3 && arguments[3] == "dark"

        guard let source = try? String(contentsOf: input, encoding: .utf8) else {
            print("error: cannot read \(input.path)")
            return 1
        }
        guard
            let image = DocumentRenderer.diagram(
                source: source, theme: Theme(isDark: dark), width: CGFloat(width))
        else {
            // Not a failure: a source this cannot draw is shown as a code block,
            // and a caller comparing renderers wants to know that happened.
            print("refused")
            return 3
        }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]),
            (try? data.write(to: output)) != nil
        else {
            print("error: cannot write \(output.path)")
            return 1
        }
        print("wrote \(output.path) — \(image.width)×\(image.height)")
        return 0
    }
}
