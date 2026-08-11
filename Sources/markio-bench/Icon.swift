import AppKit
import Foundation

/// Draws the app icon into an asset catalog.
///
/// The icon is code, not a bitmap someone has to keep: a change to it is a
/// diff, every size comes from the same drawing, and there is no 1024 px PNG in
/// the repository that quietly stops matching the smaller ones.
///
///     markio-bench icon packaging/Assets.xcassets/AppIcon.appiconset
enum Icon {
    /// The sizes macOS asks for, as (points, scale).
    private static let variants: [(point: Int, scale: Int)] = [
        (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2),
        (512, 1), (512, 2),
    ]

    static func run(arguments: [String]) -> Int32 {
        guard let directory = arguments.first else {
            print("usage: markio-bench icon <AppIcon.appiconset>")
            return 2
        }
        let base = URL(fileURLWithPath: directory)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            var images: [[String: String]] = []
            for variant in variants {
                let pixels = variant.point * variant.scale
                let name = "icon_\(variant.point)x\(variant.point)@\(variant.scale)x.png"
                guard let data = png(pixels: pixels) else {
                    print("error: could not render \(pixels)px")
                    return 1
                }
                try data.write(to: base.appendingPathComponent(name))
                images.append([
                    "idiom": "mac",
                    "size": "\(variant.point)x\(variant.point)",
                    "scale": "\(variant.scale)x",
                    "filename": name,
                ])
            }
            let contents: [String: Any] = [
                "images": images,
                "info": ["version": 1, "author": "markio-bench"],
            ]
            let json = try JSONSerialization.data(
                withJSONObject: contents,
                options: [.prettyPrinted, .sortedKeys]
            )
            try json.write(to: base.appendingPathComponent("Contents.json"))
        } catch {
            print("error: \(error.localizedDescription)")
            return 1
        }
        print("wrote \(variants.count) icons to \(base.path)")
        return 0
    }

    /// One rendering, at whatever size is asked for.
    ///
    /// Everything is expressed as a fraction of the canvas, so the 16 px icon is
    /// the same drawing as the 1024 px one rather than a separate design that
    /// drifts.
    private static func png(pixels: Int) -> Data? {
        guard
            let context = CGContext(
                data: nil,
                width: pixels,
                height: pixels,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            )
        else { return nil }

        let size = CGFloat(pixels)
        // macOS leaves a margin around the rounded square; the artwork is not
        // supposed to reach the edge of its canvas.
        let inset = size * 0.09
        let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let corner = plate.width * 0.225

        context.saveGState()
        context.addPath(
            CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner, transform: nil))
        context.clip()
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
                CGColor(srgbRed: 0.16, green: 0.22, blue: 0.38, alpha: 1),
                CGColor(srgbRed: 0.07, green: 0.10, blue: 0.19, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        )
        if let gradient {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: plate.minX, y: plate.maxY),
                end: CGPoint(x: plate.maxX, y: plate.minY),
                options: []
            )
        }
        context.restoreGState()

        // The page: a sheet of text, which is the whole subject of the app.
        let page = CGRect(
            x: plate.minX + plate.width * 0.22,
            y: plate.minY + plate.height * 0.16,
            width: plate.width * 0.56,
            height: plate.height * 0.68
        )
        let pageCorner = page.width * 0.08
        context.setFillColor(CGColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1))
        context.addPath(
            CGPath(
                roundedRect: page, cornerWidth: pageCorner, cornerHeight: pageCorner,
                transform: nil))
        context.fillPath()

        // Lines of text, the first one short and accented like a heading.
        let lineHeight = page.height * 0.075
        let gap = page.height * 0.075
        let left = page.minX + page.width * 0.14
        let full = page.width * 0.72
        var y = page.maxY - page.height * 0.20
        let widths: [CGFloat] = [0.62, 1.0, 0.86, 1.0, 0.74]
        for (index, fraction) in widths.enumerated() {
            let rect = CGRect(x: left, y: y, width: full * fraction, height: lineHeight)
            context.setFillColor(
                index == 0
                    ? CGColor(srgbRed: 0.26, green: 0.50, blue: 0.90, alpha: 1)
                    : CGColor(srgbRed: 0.62, green: 0.65, blue: 0.72, alpha: 1)
            )
            context.addPath(
                CGPath(
                    roundedRect: rect,
                    cornerWidth: lineHeight / 2,
                    cornerHeight: lineHeight / 2,
                    transform: nil
                ))
            context.fillPath()
            y -= lineHeight + gap
        }

        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
