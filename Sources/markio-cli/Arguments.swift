import Foundation

/// What a command line was asking for that this program does not do.
struct UsageError: Error, Equatable {
    let message: String
}

/// One end of the command: a file, or the standard stream in that direction.
enum Stream: Equatable {
    case standard
    case file(String)

    /// `-` is the stream, the way every tool that reads a file spells it.
    init(_ argument: String) {
        self = argument == "-" ? .standard : .file(argument)
    }
}

/// What `markio mermaid` was asked to draw, and how.
struct MermaidOptions: Equatable {
    var input: Stream
    var output: Stream
    /// The width labels wrap at, in points. `nil` is the diagram's own size.
    var width: Double?
    /// Pixels per point. `nil` lets the size of the picture decide.
    var scale: Double?
}

/// The command line as a value.
///
/// Read whole before anything is drawn, so a mistyped option is answered with
/// the usage and never with a picture made from the half that was understood.
/// Parsed by hand: one subcommand and three options do not earn a dependency,
/// and this package has none.
///
/// There is no option for a dark picture, and that is not an omission. A
/// diagram is drawn on a white page whatever is around it (`Theme.forDiagrams`),
/// and the one way to other colours is the theme its own source names — which
/// travels with the diagram instead of with whoever happened to draw it.
enum Arguments: Equatable {
    case help
    case mermaid(MermaidOptions)

    static let usage = """
        usage: markio mermaid <input.mmd | -> -o <output.png | -> [options]

        Draws one Mermaid diagram to a PNG. A dash reads the source from standard
        input, or writes the picture to standard output.

          -o, --output <path>   where the PNG goes
          --width <points>      the width labels wrap at (default: the diagram's own)
          --scale <factor>      pixels per point (default: 2, fewer for a huge picture)
          -h, --help            this text

        Colours come from the source: a theme it names, as in
        %%{init: {"theme": "dark"}}%%, is the one it is drawn in.

        Exit status: 0 written, 1 cannot read or write, 2 bad command line,
        3 a diagram this renderer does not draw.
        """

    static func parse(_ arguments: [String]) throws(UsageError) -> Arguments {
        guard let command = arguments.first else {
            throw UsageError(message: "no command given")
        }
        if command == "--help" || command == "-h" { return .help }
        guard command == "mermaid" else {
            throw UsageError(message: "unknown command: \(command)")
        }

        var input: Stream?
        var output: Stream?
        var options = MermaidOptions(input: .standard, output: .standard)
        var rest = arguments.dropFirst()

        func value(of option: String) throws(UsageError) -> String {
            guard let value = rest.popFirst() else {
                throw UsageError(message: "\(option) needs a value")
            }
            return value
        }
        func number(of option: String) throws(UsageError) -> Double {
            let text = try value(of: option)
            guard let number = Double(text), number > 0, number.isFinite else {
                throw UsageError(message: "\(option) takes a number above zero, not \(text)")
            }
            return number
        }

        while let argument = rest.popFirst() {
            switch argument {
            case "--help", "-h":
                return .help
            case "-o", "--output":
                output = Stream(try value(of: argument))
            case "--width":
                options.width = try number(of: argument)
            case "--scale":
                options.scale = try number(of: argument)
            case "-":
                input = try only(input, then: argument)
            default:
                guard !argument.hasPrefix("-") else {
                    throw UsageError(message: "unknown option: \(argument)")
                }
                input = try only(input, then: argument)
            }
        }

        guard let input else { throw UsageError(message: "no input named") }
        // No default beside the input and none on standard output: a picture
        // that lands somewhere the caller did not name is found later, in the
        // wrong folder or in a terminal full of bytes.
        guard let output else {
            throw UsageError(message: "no output named — add -o <output.png>")
        }
        options.input = input
        options.output = output
        return .mermaid(options)
    }

    /// One source per run. A second name is more likely a forgotten `-o` than a
    /// wish for two pictures, and guessing which would write over a file.
    private static func only(_ first: Stream?, then argument: String) throws(UsageError) -> Stream {
        if case .file(let earlier) = first {
            throw UsageError(message: "one input at a time: \(earlier), then \(argument)")
        }
        if first == .standard {
            throw UsageError(message: "one input at a time: -, then \(argument)")
        }
        return Stream(argument)
    }
}
