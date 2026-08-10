import AppKit

/// Offscreen store screenshots, at the one size the App Store accepts.
///
/// `--capture=` photographs the window as it happens to be: its own size, the
/// screen's backing scale. That is right for checking a rendering by eye and
/// wrong for a store screenshot, which has to be 2880×1800 exactly on whatever
/// machine runs it. So the window is resized to order and the bitmap is built
/// at a fixed 2×, never inherited from a display.
///
/// What to shoot is not decided here. The shot list lives beside the document
/// it describes, as `<name>.snapshot.json` — the pictures are store content,
/// and store content belongs with the rest of it rather than compiled into the
/// app.
@MainActor
enum Snapshot {
    /// 1440×900 points at 2× — the Mac App Store's size, in the units AppKit
    /// lays out in.
    static let storeSize = NSSize(width: 1440, height: 900)
    static let scale: CGFloat = 2

    enum Failure: Error, CustomStringConvertible {
        case noPlan(URL)
        case unreadablePlan(URL, String)
        case noWindow
        case noBaseline(String)
        case cannotDraw(NSSize)
        case wrongSize(String, expected: (Int, Int), got: (Int, Int))
        case cannotEncode(String)

        var description: String {
            switch self {
            case .noPlan(let url):
                return "no shot plan at \(url.path)"
            case .unreadablePlan(let url, let reason):
                return "cannot read the shot plan at \(url.path): \(reason)"
            case .noWindow:
                return "no document window to shoot"
            case .noBaseline(let name):
                return "the plan asks to compare against \(name), which is not there"
            case .cannotDraw(let size):
                return "cannot make a \(Int(size.width))×\(Int(size.height)) bitmap"
            case .wrongSize(let file, let expected, let got):
                return
                    "\(file) came out \(got.0)×\(got.1), not \(expected.0)×\(expected.1)"
            case .cannotEncode(let file):
                return "cannot encode \(file) as PNG"
            }
        }
    }

    // MARK: - The plan

    enum Appearance: String, Decodable {
        case light
        case dark

        var systemName: NSAppearance.Name { self == .dark ? .darkAqua : .aqua }
    }

    /// One picture: which file, in which appearance, with the window put into
    /// which state first.
    struct Shot: Decodable {
        let file: String
        let appearance: Appearance
        /// Open the outline sidebar.
        var outline: Bool = false
        /// Scroll to a heading, by the slug the outline uses.
        var anchor: String?
        /// Compare against this file, resolved beside the document.
        var compare: String?
        /// Give the baseline a column of its own rather than interleaving it.
        var sideBySide: Bool = false

        private enum CodingKeys: String, CodingKey {
            case file, appearance, outline, anchor, compare, sideBySide
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            file = try values.decode(String.self, forKey: .file)
            appearance = try values.decode(Appearance.self, forKey: .appearance)
            outline = try values.decodeIfPresent(Bool.self, forKey: .outline) ?? false
            anchor = try values.decodeIfPresent(String.self, forKey: .anchor)
            compare = try values.decodeIfPresent(String.self, forKey: .compare)
            sideBySide = try values.decodeIfPresent(Bool.self, forKey: .sideBySide) ?? false
        }
    }

    struct Plan: Decodable {
        let shots: [Shot]

        /// Read `<document-stem>.snapshot.json` from the document's own folder.
        ///
        /// Absent or malformed is an error rather than an empty run: a store
        /// screenshot quietly not taken is discovered in App Store Connect,
        /// which is far too late.
        static func beside(_ document: URL) throws -> Plan {
            let url = document.deletingPathExtension().appendingPathExtension("snapshot.json")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Failure.noPlan(url)
            }
            do {
                return try JSONDecoder().decode(Plan.self, from: Data(contentsOf: url))
            } catch {
                throw Failure.unreadablePlan(url, String(describing: error))
            }
        }
    }

    // MARK: - Drawing

    /// Draw a window's content into a bitmap of exactly `size` × `scale` pixels.
    ///
    /// The bitmap is built by hand rather than through
    /// `bitmapImageRepForCachingDisplay`, which sizes itself from the screen the
    /// window is on. Setting `rep.size` in points is what makes the drawing
    /// scale up: the graphics context maps the point-sized view onto the
    /// pixel-sized buffer.
    static func image(of window: NSWindow, size: NSSize) throws -> NSBitmapImageRep {
        window.setContentSize(size)
        window.layoutIfNeeded()
        guard let view = window.contentView else { throw Failure.noWindow }
        view.layoutSubtreeIfNeeded()

        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale),
                pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { throw Failure.cannotDraw(size) }

        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.displayIgnoringOpacity(view.bounds, in: context)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: - The run

    /// Take every shot in the plan into `directory`, then quit.
    ///
    /// Runs on the window that is already open for `document`, putting it into
    /// each state in turn. Anything wrong — a missing plan, a missing baseline,
    /// a picture that came out the wrong size — stops the run with a message
    /// and a non-zero exit, because the alternative is a store listing built on
    /// a screenshot nobody checked.
    static func run(document: URL, into directory: URL) throws {
        let plan = try Plan.beside(document)
        guard
            let controller = NSApp.windows.compactMap({
                $0.windowController as? DocumentWindowController
            }).first,
            let window = controller.window
        else { throw Failure.noWindow }

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        for shot in plan.shots {
            try apply(shot, to: controller, window: window, beside: document)
            let rep = try image(of: window, size: storeSize)
            try write(rep, named: shot.file, into: directory)
        }
    }

    /// Put the window into the state one shot wants. Each shot starts from a
    /// plain document, so the states of earlier shots never leak into later
    /// ones — the reason the comparison is stopped and the sidebar set rather
    /// than toggled.
    private static func apply(
        _ shot: Shot,
        to controller: DocumentWindowController,
        window: NSWindow,
        beside document: URL
    ) throws {
        NSApp.appearance = NSAppearance(named: shot.appearance.systemName)

        controller.stopComparing(nil)
        controller.setOutline(visible: shot.outline)

        if let name = shot.compare {
            let baseline = document.deletingLastPathComponent().appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: baseline.path) else {
                throw Failure.noBaseline(name)
            }
            controller.compare(with: baseline, sideBySide: shot.sideBySide)
        }
        if let anchor = shot.anchor {
            controller.jumpToAnchor(anchor)
        } else if shot.compare == nil {
            controller.scrollToTop()
        }

        window.layoutIfNeeded()
        // One turn of the run loop, so a scroll or a rebuilt comparison has
        // landed before the picture is taken.
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    private static func write(_ rep: NSBitmapImageRep, named file: String, into directory: URL)
        throws
    {
        let expected = (Int(storeSize.width * scale), Int(storeSize.height * scale))
        guard (rep.pixelsWide, rep.pixelsHigh) == expected else {
            throw Failure.wrongSize(file, expected: expected, got: (rep.pixelsWide, rep.pixelsHigh))
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw Failure.cannotEncode(file)
        }
        try png.write(to: directory.appendingPathComponent(file))
        print("snapshot \(expected.0)x\(expected.1) -> \(file)")
    }
}
