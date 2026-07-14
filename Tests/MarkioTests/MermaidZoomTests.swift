import AppKit
import XCTest

@testable import Markio

/// Exercises Mermaid diagram interaction: the click-to-zoom overlay (pan/zoom,
/// close paths) and "Copy PNG" over the one-way `markioCopyImage` channel.
/// Uses a uniquely named pasteboard so tests never clobber the user's
/// clipboard. [REF:fr:mermaid-zoom]
@MainActor
final class MermaidZoomTests: XCTestCase {
    private static let diagram = """
        ```mermaid
        flowchart LR
          A[Start here] --> B[Finish line]
        ```
        """

    /// A loaded preview with a rendered flowchart, writing to a private,
    /// uniquely named pasteboard.
    private func makeZoomPreview() async throws -> (PreviewController, NSPasteboard) {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("dev.markio.tests.\(UUID().uuidString)"))
        let preview = PreviewController(pasteboard: pasteboard)
        try await preview.loadTemplate()
        await preview.render(Self.diagram)
        return (preview, pasteboard)
    }

    /// Evaluate page JS that may await promises (evaluate() is sync-only).
    private func evaluateAsync(
        _ preview: PreviewController, _ body: String
    ) async throws -> Any? {
        try await preview.webView.callAsyncJavaScript(
            body, arguments: [:], contentWorld: .page)
    }

    private func openOverlay(_ preview: PreviewController) async throws {
        _ = try await preview.evaluate(
            "document.querySelector('#content pre.mermaid svg')"
                + ".dispatchEvent(new MouseEvent('click', {bubbles: true})); true")
    }

    private func overlayHidden(_ preview: PreviewController) async throws -> Bool {
        let hidden = try await preview.evaluate(
            "var z = document.getElementById('markio-zoom'); z ? z.hidden : true")
        return (hidden as? Bool) ?? (hidden as? NSNumber)?.boolValue ?? true
    }

    func testClickOpensZoomOverlay() async throws {
        let (preview, _) = try await makeZoomPreview()

        let rendered = try await count(
            preview, "document.querySelectorAll('#content pre.mermaid svg').length")
        XCTAssertEqual(rendered, 1, "Sanity: the flowchart must render as an SVG")

        try await openOverlay(preview)
        let hidden = try await overlayHidden(preview)
        XCTAssertFalse(hidden, "Clicking the diagram must open the zoom overlay")

        let cloned = try await count(
            preview, "document.querySelectorAll('#markio-zoom svg').length")
        XCTAssertEqual(cloned, 1, "The overlay must show a clone of the diagram SVG")
    }

    func testZoomAndPanTransform() async throws {
        let (preview, _) = try await makeZoomPreview()
        try await openOverlay(preview)

        let initialScale = try await preview.evaluate(
            "parseFloat(document.querySelector('#markio-zoom .markio-zoom-canvas').dataset.scale)"
        )
        XCTAssertEqual(
            (initialScale as? NSNumber)?.doubleValue ?? -1, 1.0,
            "Overlay opens at scale 1")

        _ = try await preview.evaluate(
            "document.querySelector('#markio-zoom button.markio-zoom-in').click();"
                + "document.querySelector('#markio-zoom button.markio-zoom-in').click(); true")
        let zoomed = try await preview.evaluate(
            "parseFloat(document.querySelector('#markio-zoom .markio-zoom-canvas').dataset.scale)"
        )
        XCTAssertGreaterThan(
            (zoomed as? NSNumber)?.doubleValue ?? -1, 1.0,
            "Zoom-in button must grow the scale")

        // The overlay opens centered (fitZoom), so pan is asserted as a delta
        // from the current offset, not an absolute position.
        let txBefore = try await preview.evaluate(
            "parseFloat(document.querySelector('#markio-zoom .markio-zoom-canvas').dataset.tx)")
        _ = try await preview.evaluate(
            """
            var stage = document.querySelector('#markio-zoom .markio-zoom-stage');
            stage.dispatchEvent(new PointerEvent('pointerdown',
              {bubbles: true, clientX: 200, clientY: 200, pointerId: 1, button: 0}));
            stage.dispatchEvent(new PointerEvent('pointermove',
              {bubbles: true, clientX: 260, clientY: 240, pointerId: 1}));
            stage.dispatchEvent(new PointerEvent('pointerup',
              {bubbles: true, clientX: 260, clientY: 240, pointerId: 1}));
            true
            """)
        let tx = try await preview.evaluate(
            "parseFloat(document.querySelector('#markio-zoom .markio-zoom-canvas').dataset.tx)")
        let panDelta =
            ((tx as? NSNumber)?.doubleValue ?? 0)
            - ((txBefore as? NSNumber)?.doubleValue ?? 0)
        XCTAssertEqual(
            panDelta, 60, accuracy: 0.5,
            "Dragging must pan the diagram by the pointer delta")

        _ = try await preview.evaluate(
            "document.querySelector('#markio-zoom button.markio-zoom-reset').click(); true")
        let reset = try await preview.evaluate(
            "parseFloat(document.querySelector('#markio-zoom .markio-zoom-canvas').dataset.scale)"
        )
        XCTAssertEqual(
            (reset as? NSNumber)?.doubleValue ?? -1, 1.0,
            "Reset must restore scale 1")
    }

    func testOverlayCloses() async throws {
        let (preview, _) = try await makeZoomPreview()

        try await openOverlay(preview)
        _ = try await preview.evaluate(
            "window.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape'})); true")
        var hidden = try await overlayHidden(preview)
        XCTAssertTrue(hidden, "Esc must close the overlay")

        try await openOverlay(preview)
        _ = try await preview.evaluate(
            "document.querySelector('#markio-zoom button.markio-zoom-close').click(); true")
        hidden = try await overlayHidden(preview)
        XCTAssertTrue(hidden, "The close button must close the overlay")

        try await openOverlay(preview)
        _ = try await preview.evaluate(
            "document.querySelector('#markio-zoom .markio-zoom-stage')"
                + ".dispatchEvent(new MouseEvent('click', {bubbles: true})); true")
        hidden = try await overlayHidden(preview)
        XCTAssertTrue(hidden, "A backdrop click must close the overlay")
    }

    func testHotkeysDriveZoom() async throws {
        let (preview, _) = try await makeZoomPreview()
        try await openOverlay(preview)

        _ = try await preview.evaluate(
            "window.dispatchEvent(new KeyboardEvent('keydown', {key: '+'})); true")
        let zoomed = try await preview.evaluate(
            "parseFloat(document.querySelector('#markio-zoom .markio-zoom-canvas').dataset.scale)"
        )
        XCTAssertEqual(
            (zoomed as? NSNumber)?.doubleValue ?? -1, 1.25, accuracy: 0.001,
            "'+' must zoom in by one step")

        _ = try await preview.evaluate(
            "window.dispatchEvent(new KeyboardEvent('keydown', {key: '0'})); true")
        let fitted = try await preview.evaluate(
            "parseFloat(document.querySelector('#markio-zoom .markio-zoom-canvas').dataset.scale)"
        )
        XCTAssertEqual(
            (fitted as? NSNumber)?.doubleValue ?? -1, 1.0,
            "'0' must re-fit (identity transform on a zero-sized stage)")

        let tyBefore = try await preview.evaluate(
            "parseFloat(document.querySelector('#markio-zoom .markio-zoom-canvas').dataset.ty)")
        _ = try await preview.evaluate(
            "window.dispatchEvent(new KeyboardEvent('keydown', {key: 'ArrowDown'})); true")
        let tyAfter = try await preview.evaluate(
            "parseFloat(document.querySelector('#markio-zoom .markio-zoom-canvas').dataset.ty)")
        XCTAssertEqual(
            ((tyAfter as? NSNumber)?.doubleValue ?? 0)
                - ((tyBefore as? NSNumber)?.doubleValue ?? 0),
            -60, accuracy: 0.5,
            "Arrow keys must pan by a fixed step")
    }

    func testRerenderClosesOverlay() async throws {
        let (preview, _) = try await makeZoomPreview()
        try await openOverlay(preview)

        await preview.render(Self.diagram)
        let hidden = try await overlayHidden(preview)
        XCTAssertTrue(hidden, "A re-render (live reload) must close a stale overlay")
    }

    func testRasterSVGCarriesTextLabelsNoForeignObject() async throws {
        let (preview, _) = try await makeZoomPreview()

        let svg = try await evaluateAsync(
            preview,
            "return await markioRasterSVG("
                + "document.querySelector('#content pre.mermaid').dataset.markioSrc);")
        let svgText = try XCTUnwrap(svg as? String, "Raster prep must return an SVG string")
        XCTAssertTrue(
            svgText.contains("<text"),
            "Raster SVG must carry labels as SVG <text> elements")
        // Element check, not substring: mermaid's embedded <style> block
        // mentions foreignObject in CSS selectors even when no element exists.
        XCTAssertFalse(
            svgText.contains("<foreignObject"),
            "Raster SVG must not contain foreignObject (WebKit will not paint it in canvas)")
        // Word-level check: mermaid splits SVG-text labels into per-word
        // tspans ("Start" + " here"), so the joined phrase never appears.
        XCTAssertTrue(
            svgText.contains("Start") && svgText.contains("here"),
            "Raster SVG must preserve the node label text")
    }

    func testCopyPNGWritesRasterToPasteboard() async throws {
        let (preview, pasteboard) = try await makeZoomPreview()

        var copiedBytes = 0
        let delivered = expectation(description: "markioCopyImage delivered")
        preview.onImageCopied = { data in
            copiedBytes = data.count
            delivered.fulfill()
        }
        _ = try await preview.evaluate(
            "document.querySelector('#content .markio-mermaid button.markio-mermaid-copy')"
                + ".click(); true")
        await fulfillment(of: [delivered], timeout: 10)
        XCTAssertGreaterThan(copiedBytes, 0, "The page must deliver a non-empty PNG")

        let data = try XCTUnwrap(
            pasteboard.data(forType: .png), "A PNG must land on the native pasteboard")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data), "Pasteboard PNG must decode")
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)

        // Non-blank raster: a diagram must produce more than one distinct
        // color — a blank canvas (the foreignObject failure mode) is uniform.
        var colors = Set<String>()
        let stepX = max(1, bitmap.pixelsWide / 64)
        let stepY = max(1, bitmap.pixelsHigh / 64)
        for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
                if let color = bitmap.colorAt(x: x, y: y) {
                    colors.insert(
                        String(
                            format: "%.2f/%.2f/%.2f", color.redComponent,
                            color.greenComponent, color.blueComponent))
                }
                if colors.count > 1 { break }
            }
            if colors.count > 1 { break }
        }
        XCTAssertGreaterThan(colors.count, 1, "The PNG must not be a blank canvas")
    }

    func testOverlayCopyPNGButtonCopies() async throws {
        let (preview, pasteboard) = try await makeZoomPreview()
        try await openOverlay(preview)

        let delivered = expectation(description: "overlay copy delivered")
        preview.onImageCopied = { _ in delivered.fulfill() }
        _ = try await preview.evaluate(
            "document.querySelector('#markio-zoom button.markio-mermaid-copy').click(); true")
        await fulfillment(of: [delivered], timeout: 10)

        XCTAssertNotNil(
            pasteboard.data(forType: .png),
            "The overlay Copy PNG button must write a PNG to the pasteboard")
    }

    func testFindSkipsMermaidUI() async throws {
        let (preview, _) = try await makeZoomPreview()

        var matches = await preview.search("Copy PNG")
        XCTAssertEqual(matches.count, 0, "Find must never match the hover Copy PNG label")
        await preview.clearSearch()

        try await openOverlay(preview)
        matches = await preview.search("Copy PNG")
        XCTAssertEqual(
            matches.count, 0,
            "Find must never match overlay controls (overlay lives outside #content)")
        await preview.clearSearch()
    }
}
