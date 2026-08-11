import AppKit
import ImageIO

/// Decodes the images a document points at, at the size they will be drawn.
///
/// Two rules keep this from undoing the memory design. Nothing is decoded until
/// its block is about to be drawn, and nothing is decoded at full size: Image
/// I/O produces a thumbnail at the column's pixel width, so a 6000-pixel photo
/// costs what a 1800-pixel one does. The cache is small and bounded; a document
/// full of images cannot grow it past the budget.
@MainActor
enum ImageLoader {
    /// Roughly one screen of images. Past this the oldest go, which is right
    /// for a reader moving in one direction through a document.
    private static let budget = 48 * 1_024 * 1_024

    private struct Entry {
        var image: CGImage
        var cost: Int
        var key: String
    }

    private static var cache: [String: Entry] = [:]
    private static var order: [String] = []
    private static var total = 0

    /// The image at `url`, fitted to `maxWidth` points, or nil if it is not
    /// something this machine can decode.
    static func image(at url: URL, maxWidth: CGFloat, scale: CGFloat = 2) -> CGImage? {
        let pixelWidth = max(1, Int((maxWidth * scale).rounded()))
        let key = "\(url.path)|\(pixelWidth)"
        if let entry = cache[key] {
            touch(key)
            return entry.image
        }
        guard let image = decode(url: url, pixelWidth: pixelWidth) else { return nil }
        store(image, key: key)
        return image
    }

    private static func decode(url: URL, pixelWidth: Int) -> CGImage? {
        // Local files only. Markio makes no network requests, so a remote
        // image is simply not something it can show.
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelWidth,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func store(_ image: CGImage, key: String) {
        let cost = image.bytesPerRow * image.height
        cache[key] = Entry(image: image, cost: cost, key: key)
        order.append(key)
        total += cost
        while total > budget, let oldest = order.first {
            order.removeFirst()
            if let entry = cache.removeValue(forKey: oldest) { total -= entry.cost }
        }
    }

    private static func touch(_ key: String) {
        guard let position = order.firstIndex(of: key) else { return }
        order.remove(at: position)
        order.append(key)
    }
}
