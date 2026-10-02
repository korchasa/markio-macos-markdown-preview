import Foundation
import MarkioRender

/// Prints where one Mermaid graph's boxes, lines and words were drawn, as
/// JSON, for `deno task layoutbench` to count crossings on.
///
/// The width is wide enough that nothing is drawn smaller to fit: a layout is
/// judged at the size it chose, not at whatever a reading column allows.
@MainActor
enum Layout {
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 1 else {
            print("usage: markio-bench layout <in.mmd>")
            return 2
        }
        let input = URL(fileURLWithPath: arguments[0])
        guard let source = try? String(contentsOf: input, encoding: .utf8) else {
            print("error: cannot read \(input.path)")
            return 1
        }
        do {
            guard
                let json = try DocumentRenderer.diagramGeometry(
                    source: source, theme: Theme(isDark: false), width: 100_000)
            else {
                print("refused")
                return 3
            }
            FileHandle.standardOutput.write(json)
            return 0
        } catch {
            print("error: \(error)")
            return 1
        }
    }
}
