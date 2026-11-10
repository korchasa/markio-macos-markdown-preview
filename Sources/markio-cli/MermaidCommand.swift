import CoreGraphics
import Foundation
import MarkioRender

/// The three places a run touches that are not files it was given by name.
///
/// Handed in rather than reached for, so a test can be the terminal: what is
/// typed into it, what comes out of it, and what it is told went wrong.
struct IO {
    /// Standard input, read to its end.
    var read: () -> Data
    /// Standard output. Bytes, because it may be the picture.
    var write: (Data) -> Void
    /// One line on standard error.
    var complain: (String) -> Void

    /// The process's own streams.
    static var standard: IO {
        IO(
            read: { FileHandle.standardInput.readDataToEndOfFile() },
            write: { FileHandle.standardOutput.write($0) },
            complain: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
    }
}

/// How a run ended, as the number a shell sees.
enum Status {
    static let written: Int32 = 0
    /// An input that could not be read, or an output that could not be made.
    static let failed: Int32 = 1
    static let misused: Int32 = 2
    /// A source the layout does not draw. Apart from a failure on purpose: a
    /// caller trying one renderer after another wants to tell "not for this
    /// one" from "this one broke".
    static let refused: Int32 = 3
}

@MainActor
enum Tool {
    /// Run one command line and answer with its exit status.
    static func run(arguments: [String], io: IO) -> Int32 {
        let parsed: Arguments
        do {
            parsed = try Arguments.parse(arguments)
        } catch {
            io.complain("markio: \(error.message)")
            io.complain(Arguments.usage)
            return Status.misused
        }
        switch parsed {
        case .help:
            io.write(Data((Arguments.usage + "\n").utf8))
            return Status.written
        case .mermaid(let options):
            return MermaidCommand.run(options, io: io)
        }
    }
}

/// `markio mermaid`: one Mermaid source to a PNG.
///
/// The picture is the one the app writes when a reader opens a diagram on its
/// own, reached the same way — measured, then drawn at the density that size
/// deserves — so a diagram looks the same whichever of the two made the file.
@MainActor
enum MermaidCommand {
    static func run(_ options: MermaidOptions, io: IO) -> Int32 {
        let bytes: Data
        switch options.input {
        case .standard:
            bytes = io.read()
        case .file(let path):
            do {
                bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            } catch {
                io.complain("markio: cannot read \(path): \(error.localizedDescription)")
                return Status.failed
            }
        }
        guard let source = String(data: bytes, encoding: .utf8) else {
            io.complain("markio: the source is not UTF-8 text")
            return Status.failed
        }

        let theme = Theme(isDark: false)
        let width = options.width.map { CGFloat($0) } ?? DocumentRenderer.naturalWidth
        // Measured at one pixel per point first: how dense the bitmap should be
        // depends on how large the picture turns out. This is also the pass
        // that can refuse, so a `nil` from the second one is never a refusal.
        guard
            let measured = DocumentRenderer.diagram(
                source: source, theme: theme, width: width, scale: 1)
        else {
            io.complain("markio: refused — not a Mermaid diagram this renderer draws")
            return Status.refused
        }
        let size = CGSize(width: measured.width, height: measured.height)
        let density = options.scale.map { CGFloat($0) } ?? DocumentRenderer.density(for: size)
        let drawn =
            density == 1
            ? measured
            : DocumentRenderer.diagram(source: source, theme: theme, width: width, scale: density)
        guard let image = drawn, let png = DocumentRenderer.png(image, density: density) else {
            io.complain(
                "markio: cannot make a \(measured.width)×\(measured.height) point picture"
                    + " at \(density) pixels per point")
            return Status.failed
        }

        switch options.output {
        case .standard:
            io.write(png)
        case .file(let path):
            do {
                // Whole or not at all: a reader of the file must never find the
                // first half of a picture where a picture was promised.
                try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                io.complain("markio: cannot write \(path): \(error.localizedDescription)")
                return Status.failed
            }
            io.write(Data("wrote \(path) — \(image.width)×\(image.height)\n".utf8))
        }
        return Status.written
    }
}
