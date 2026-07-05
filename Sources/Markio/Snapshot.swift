import AppKit
import WebKit

/// Offscreen screenshot mode for App Store assets: `Markio --snapshot <dir> <file.md>`
/// renders the given document in a borderless window (never shown to the user)
/// and writes PNGs sized 2880×1800 (the Mac App Store 1440×900@2x slot) into
/// `<dir>`. Web content is captured with `WKWebView.takeSnapshot` — regular
/// `cacheDisplay` returns an empty image for WebKit-drawn layers.
@MainActor
enum Snapshot {
    /// Points size of the captured window; exported pixels are 2× this.
    private static let frame = NSSize(width: 1440, height: 900)

    /// Detects `--snapshot <dir>` on the command line. When present, runs the
    /// capture flow and terminates the app; the caller must skip its normal
    /// launch path. Returns `false` when the flag is absent.
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--snapshot"), args.count > flag + 1 else {
            return false
        }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        let document = args.dropFirst()
            .map { URL(fileURLWithPath: $0) }
            .last { $0.isMarkdown }
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await capture(document: document, into: dir)
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            }
            NSApp.terminate(nil)
        }
        return true
    }

    private static func capture(document: URL?, into dir: URL) async throws {
        guard let document else {
            throw NSError(
                domain: "Snapshot", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no markdown file argument"])
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let preview = PreviewController()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: frame),
            styleMask: .borderless, backing: .buffered, defer: false)
        preview.webView.frame = NSRect(origin: .zero, size: frame)
        window.contentView = preview.webView
        window.orderBack(nil)

        try await preview.loadTemplate()
        let text = try String(contentsOf: document, encoding: .utf8)
        await preview.setContentWidth(80)

        // 01 — top of the document, light appearance.
        await preview.setDark(false)
        await preview.render(text)
        try await settle()
        try await shoot(preview.webView, to: dir.appendingPathComponent("01-light.png"))

        // 02 — the Mermaid diagram in view.
        _ = try? await preview.evaluate(
            "document.querySelector('.mermaid, pre.mermaid')?.scrollIntoView({block: 'center'})")
        try await settle(seconds: 0.5)
        try await shoot(preview.webView, to: dir.appendingPathComponent("02-mermaid.png"))

        // 03 — same top view, dark appearance. The page's palette follows
        // `prefers-color-scheme`, i.e. the window appearance; `setDark` only
        // re-themes Mermaid, and a re-render applies it.
        window.appearance = NSAppearance(named: .darkAqua)
        await preview.setDark(true)
        await preview.render(text)
        _ = try? await preview.evaluate("window.scrollTo(0, 0)")
        try await settle()
        try await shoot(preview.webView, to: dir.appendingPathComponent("03-dark.png"))
    }

    /// Let Mermaid, highlighting and lazy layout finish before capturing.
    private static func settle(seconds: Double = 1.5) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func shoot(_ webView: WKWebView, to url: URL) async throws {
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(origin: .zero, size: frame)
        let image = try await webView.takeSnapshot(configuration: config)
        try write(image, to: url)
    }

    /// Draws `image` into an exact 2880×1800 opaque bitmap (App Store
    /// screenshots must not rely on the offscreen window's backing scale).
    private static func write(_ image: NSImage, to url: URL) throws {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(frame.width) * 2, pixelsHigh: Int(frame.height) * 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else {
            throw NSError(
                domain: "Snapshot", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "could not create bitmap"])
        }
        rep.size = frame
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.textBackgroundColor.setFill()
        NSRect(origin: .zero, size: frame).fill()
        image.draw(
            in: NSRect(origin: .zero, size: frame), from: .zero,
            operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "Snapshot", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "could not encode PNG"])
        }
        try png.write(to: url)
    }
}
