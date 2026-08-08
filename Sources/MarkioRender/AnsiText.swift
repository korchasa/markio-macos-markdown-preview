import AppKit

/// Terminal colour escapes inside a fenced block.
///
/// Documents written by agents are full of pasted terminal output, and the
/// escapes in it are not text: shown literally they are noise, dropped
/// silently they lose the one thing that made the log readable. This turns
/// them into colour and removes them from the text.
///
/// Only SGR (`ESC [ … m`) carries meaning here. Every other CSI sequence —
/// cursor moves, erase, scroll — is removed too: it describes motion on a
/// terminal that does not exist, and leaving it in would show as mojibake.
enum AnsiText {
    struct Span {
        var start: Int
        var end: Int
        var color: CGColor?
        var background: CGColor?
        var bold: Bool
    }

    struct Result {
        /// The bytes with every escape sequence removed.
        var text: [UInt8]
        var spans: [Span]
    }

    private static let escape: UInt8 = 0x1B
    private static let bracket: UInt8 = 0x5B

    /// Cheap enough to run on every code block before deciding what to do.
    static func containsEscapes(_ content: [UInt8]) -> Bool {
        var index = 0
        while index + 1 < content.count {
            if content[index] == escape, content[index + 1] == bracket { return true }
            index += 1
        }
        return false
    }

    /// The text without the escapes, for anyone who needs the characters but
    /// not the colour — Find and Copy go through here.
    static func strip(_ content: [UInt8]) -> [UInt8] {
        parse(content, palette: Palette(isDark: false)).text
    }

    static func parse(_ content: [UInt8], palette: Palette) -> Result {
        var text: [UInt8] = []
        text.reserveCapacity(content.count)
        var spans: [Span] = []
        var state = State()
        var runStart = 0
        var index = 0

        func closeRun(at end: Int) {
            guard end > runStart, !state.isDefault else {
                runStart = end
                return
            }
            spans.append(
                Span(
                    start: runStart,
                    end: end,
                    color: state.foreground.map { palette.color($0, bright: state.bold) },
                    background: state.background.map { palette.color($0, bright: false) },
                    bold: state.bold
                )
            )
            runStart = end
        }

        while index < content.count {
            guard content[index] == escape, index + 1 < content.count, content[index + 1] == bracket
            else {
                text.append(content[index])
                index += 1
                continue
            }
            // A CSI sequence: parameters, then one final byte in @…~.
            var cursor = index + 2
            while cursor < content.count, content[cursor] < 0x40 || content[cursor] > 0x7E {
                cursor += 1
            }
            guard cursor < content.count else {
                // Truncated escape at the end of the block: drop the remainder
                // rather than print it.
                break
            }
            let final = content[cursor]
            if final == 0x6D {  // 'm'
                closeRun(at: text.count)
                state.apply(parameters(content[(index + 2)..<cursor]))
            }
            index = cursor + 1
        }
        closeRun(at: text.count)
        return Result(text: text, spans: spans)
    }

    private static func parameters(_ bytes: ArraySlice<UInt8>) -> [Int] {
        var values: [Int] = []
        var current = 0
        var sawDigit = false
        for byte in bytes {
            if byte >= 0x30, byte <= 0x39 {
                current = current * 10 + Int(byte - 0x30)
                sawDigit = true
            } else if byte == 0x3B || byte == 0x3A {  // ';' or ':'
                values.append(sawDigit ? current : 0)
                current = 0
                sawDigit = false
            }
        }
        values.append(sawDigit ? current : 0)
        return values
    }

    /// What the escapes have set so far. `ESC[m` with no parameters resets.
    private struct State {
        var foreground: Colour?
        var background: Colour?
        var bold = false

        var isDefault: Bool { foreground == nil && background == nil && !bold }

        mutating func apply(_ codes: [Int]) {
            var index = 0
            while index < codes.count {
                let code = codes[index]
                switch code {
                case 0:
                    self = State()
                case 1:
                    bold = true
                case 22:
                    bold = false
                case 30...37:
                    foreground = .indexed(code - 30)
                case 39:
                    foreground = nil
                case 40...47:
                    background = .indexed(code - 40)
                case 49:
                    background = nil
                case 90...97:
                    foreground = .indexed(code - 90 + 8)
                case 100...107:
                    background = .indexed(code - 100 + 8)
                case 38, 48:
                    let extended = Self.extendedColour(codes, from: &index)
                    if code == 38 { foreground = extended } else { background = extended }
                default:
                    break
                }
                index += 1
            }
        }

        /// `38;5;n` picks from the 256-colour cube, `38;2;r;g;b` is direct.
        private static func extendedColour(_ codes: [Int], from index: inout Int) -> Colour? {
            guard index + 1 < codes.count else { return nil }
            switch codes[index + 1] {
            case 5 where index + 2 < codes.count:
                let value = codes[index + 2]
                index += 2
                return .indexed(value)
            case 2 where index + 4 < codes.count:
                let red = codes[index + 2]
                let green = codes[index + 3]
                let blue = codes[index + 4]
                index += 4
                return .rgb(red, green, blue)
            default:
                index = codes.count
                return nil
            }
        }
    }

    fileprivate enum Colour: Equatable {
        case indexed(Int)
        case rgb(Int, Int, Int)
    }

    /// Terminal colours picked for a document, not a terminal: readable on the
    /// code block's tinted background in both appearances.
    struct Palette {
        private let isDark: Bool

        init(isDark: Bool) { self.isDark = isDark }

        fileprivate func color(_ colour: Colour, bright: Bool) -> CGColor {
            switch colour {
            case .rgb(let red, let green, let blue):
                return CGColor(
                    srgbRed: CGFloat(red) / 255,
                    green: CGFloat(green) / 255,
                    blue: CGFloat(blue) / 255,
                    alpha: 1
                )
            case .indexed(let value):
                return indexed(value, bright: bright)
            }
        }

        private func indexed(_ value: Int, bright: Bool) -> CGColor {
            if value < 16 {
                let slot = bright && value < 8 ? value + 8 : value
                return Self.base[slot][isDark ? 1 : 0]
            }
            if value < 232 {
                // The 6×6×6 cube.
                let offset = value - 16
                let steps: [CGFloat] = [0, 0.373, 0.529, 0.686, 0.843, 1]
                return CGColor(
                    srgbRed: steps[(offset / 36) % 6],
                    green: steps[(offset / 6) % 6],
                    blue: steps[offset % 6],
                    alpha: 1
                )
            }
            // The 24-step grey ramp.
            let level = CGFloat(value - 232) / 23
            return CGColor(srgbRed: level, green: level, blue: level, alpha: 1)
        }

        /// The sixteen ANSI colours, each in a light-background and a
        /// dark-background variant.
        private static let base: [[CGColor]] = {
            func pair(_ light: (Int, Int, Int), _ dark: (Int, Int, Int)) -> [CGColor] {
                [
                    CGColor(
                        srgbRed: CGFloat(light.0) / 255, green: CGFloat(light.1) / 255,
                        blue: CGFloat(light.2) / 255, alpha: 1),
                    CGColor(
                        srgbRed: CGFloat(dark.0) / 255, green: CGFloat(dark.1) / 255,
                        blue: CGFloat(dark.2) / 255, alpha: 1),
                ]
            }
            return [
                pair((60, 60, 60), (170, 170, 170)),  // black
                pair((190, 40, 40), (255, 106, 106)),  // red
                pair((30, 130, 60), (108, 208, 126)),  // green
                pair((160, 120, 20), (222, 184, 92)),  // yellow
                pair((40, 90, 200), (110, 160, 255)),  // blue
                pair((160, 60, 170), (222, 130, 232)),  // magenta
                pair((30, 130, 150), (100, 200, 220)),  // cyan
                pair((90, 90, 90), (220, 220, 220)),  // white
                pair((120, 120, 120), (140, 140, 140)),  // bright black
                pair((215, 60, 60), (255, 140, 140)),  // bright red
                pair((40, 160, 80), (140, 230, 155)),  // bright green
                pair((190, 150, 40), (240, 208, 120)),  // bright yellow
                pair((70, 120, 230), (150, 190, 255)),  // bright blue
                pair((190, 90, 200), (238, 160, 245)),  // bright magenta
                pair((50, 160, 180), (140, 220, 235)),  // bright cyan
                pair((40, 40, 40), (250, 250, 250)),  // bright white
            ]
        }()
    }
}
