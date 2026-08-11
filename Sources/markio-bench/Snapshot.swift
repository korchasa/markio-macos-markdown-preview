import AppKit
import Foundation
import MarkdownKit
import MarkioRender

/// Renders a document to a PNG without opening a window.
///
/// The renderer's output is the product; being able to look at it from a script
/// is what makes a visual change reviewable, and it is how store screenshots
/// will be produced later — no screen recording, no window management, exact
/// pixel dimensions every time.
@MainActor
enum Snapshot {
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count >= 2 else {
            print(
                "usage: markio-bench snapshot <in.md> <out.png> [width] [height] [dark] "
                    + "[scrollY] [baseline.md]")
            return 2
        }
        let input = URL(fileURLWithPath: arguments[0])
        let output = URL(fileURLWithPath: arguments[1])
        let width = arguments.count > 2 ? Double(arguments[2]) ?? 1_280 : 1_280
        let height = arguments.count > 3 ? Double(arguments[3]) ?? 900 : 900
        let dark = arguments.count > 4 && arguments[4] == "dark"
        let scrollY = arguments.count > 5 ? Double(arguments[5]) ?? 0 : 0

        guard let data = try? Data(contentsOf: input) else {
            print("error: cannot read \(input.path)")
            return 1
        }
        // With a baseline, what gets rendered is the merge of the two versions
        // and the marks that say which side each block came from — the same
        // thing the window shows while comparing.
        var comparison: CompareEngine.Result?
        if arguments.count > 6 {
            guard let baseline = try? Data(contentsOf: URL(fileURLWithPath: arguments[6])) else {
                print("error: cannot read \(arguments[6])")
                return 1
            }
            comparison = CompareEngine.merge(
                current: [UInt8](data),
                baseline: [UInt8](baseline)
            )
        }
        let document = Document(bytes: comparison?.bytes ?? [UInt8](data))
        let theme = Theme(isDark: dark)
        let columnWidth = min(CGFloat(width) - 120, 720)
        let layout = DocumentLayout(
            document: document,
            theme: theme,
            columnWidth: columnWidth,
            baseURL: input
        )
        layout.comparison = comparison

        guard
            let image = DocumentRenderer.image(
                layout: layout,
                size: CGSize(width: width, height: height),
                scrollOffset: CGFloat(scrollY)
            )
        else {
            print("error: could not create the bitmap context")
            return 1
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            print("error: could not encode PNG")
            return 1
        }
        do {
            try png.write(to: output)
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
        print("wrote \(output.path) — \(image.width)×\(image.height)")
        return 0
    }
}
