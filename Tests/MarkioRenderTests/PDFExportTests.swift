import PDFKit
import XCTest

@testable import MarkdownKit
@testable import MarkioRender

/// Pages, and what has to be true of them.
///
/// The claim being tested is the one a reader can check: the text in the file
/// is text, the diagrams are curves, and a page break never lands in the middle
/// of a line. The first two come from drawing through `DocumentRenderer` — the
/// same code that paints the window — so what is really being held here is that
/// the export keeps using it rather than growing a bitmap path of its own.
@MainActor
final class PDFExportTests: XCTestCase {
    private let geometry = PageLayout.Geometry(
        pageSize: CGSize(width: 612, height: 792), margin: 54)

    private func layout(_ text: String) -> DocumentLayout {
        PDFExport.pageLayout(document: Document(text: text), baseURL: nil, geometry: geometry)
    }

    private func url() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("markio-pdf-\(UUID().uuidString).pdf")
    }

    func testAShortDocumentIsOnePage() {
        let pages = PageLayout.paginate(
            layout: layout("# Title\n\nOne paragraph."), geometry: geometry)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].slices.count, 2)
        XCTAssertEqual(pages[0].slices[0].from, 0)
    }

    func testALongFenceBreaksAtALineBoundary() {
        let fence = "```\n" + (1...200).map { "line \($0)" }.joined(separator: "\n") + "\n```"
        let document = layout(fence)
        let pages = PageLayout.paginate(layout: document, geometry: geometry)
        XCTAssertGreaterThan(pages.count, 1)

        // Every cut has to sit on the bottom of a typeset line, which is what
        // keeps half a row of letters from ending up on the next page.
        guard let box = document.box(at: 0) else { return XCTFail("no box") }
        let bottoms = Set(
            box.segments.flatMap {
                $0.lines.map { line in (line.origin.y + line.descent).rounded() }
            })
        for page in pages.dropLast() {
            guard let last = page.slices.last else { continue }
            XCTAssertTrue(
                bottoms.contains(last.to.rounded()),
                "a page ends at \(last.to), which is not the bottom of any line")
        }
    }

    func testSlicesCoverTheBlockExactlyOnce() {
        let fence = "```\n" + (1...200).map { "line \($0)" }.joined(separator: "\n") + "\n```"
        let document = layout(fence)
        let pages = PageLayout.paginate(layout: document, geometry: geometry)
        let slices = pages.flatMap(\.slices).filter { $0.ordinal == 0 }
        XCTAssertEqual(slices.first?.from, 0)
        XCTAssertEqual(slices.last?.to ?? 0, document.box(at: 0)?.height ?? 0, accuracy: 0.5)
        for (previous, next) in zip(slices, slices.dropFirst()) {
            XCTAssertEqual(previous.to, next.from, accuracy: 0.5)
        }
    }

    func testNothingOverflowsThePage() {
        let text = """
            # Report

            \((1...40).map { "Paragraph number \($0), with enough words in it to wrap." }
                .joined(separator: "\n\n"))
            """
        let pages = PageLayout.paginate(layout: layout(text), geometry: geometry)
        for page in pages {
            let bottom = page.slices.map { $0.y + $0.height }.max() ?? 0
            XCTAssertLessThanOrEqual(bottom, geometry.contentHeight + 0.5)
        }
    }

    func testAPictureTallerThanAPageIsScaledRatherThanCut() {
        // A diagram has no typeset lines to break on, so the only honest answer
        // is to draw it smaller.
        let diagram = """
            ```mermaid
            flowchart TD
            \((1...40).map { "    A\($0)[Step \($0)] --> A\($0 + 1)[Step \($0 + 1)]" }
                .joined(separator: "\n"))
            ```
            """
        let document = layout(diagram)
        let pages = PageLayout.paginate(layout: document, geometry: geometry)
        let slice = pages.flatMap(\.slices).first { $0.ordinal == 0 }
        XCTAssertNotNil(slice)
        XCTAssertLessThan(slice?.scale ?? 1, 1)
        XCTAssertLessThanOrEqual((slice?.height ?? 0), geometry.contentHeight + 0.5)
    }

    func testTheTextInTheFileIsTextAndNotAPicture() throws {
        let target = url()
        defer { try? FileManager.default.removeItem(at: target) }
        let written = try PDFExport.write(
            document: Document(text: "# Ledger migration\n\nA sentence worth finding."),
            baseURL: nil,
            to: target,
            title: "probe",
            geometry: geometry
        )
        XCTAssertEqual(written, 1)
        let pdf = try XCTUnwrap(PDFDocument(url: target))
        let text = pdf.string ?? ""
        XCTAssertTrue(text.contains("Ledger migration"), "no heading text in the PDF: \(text)")
        XCTAssertTrue(text.contains("A sentence worth finding."))
    }

    func testAPageCarriesTheDiagramAsCurvesRatherThanAsABitmap() throws {
        let target = url()
        defer { try? FileManager.default.removeItem(at: target) }
        try PDFExport.write(
            document: Document(
                text: "```mermaid\nflowchart TD\n    A[Freeze] --> B[Backfill]\n```"),
            baseURL: nil,
            to: target,
            title: "probe",
            geometry: geometry
        )
        let pdf = try XCTUnwrap(PDFDocument(url: target))
        // The labels inside the boxes are drawn as glyphs, so they come back as
        // text — which they could not if the diagram were a picture of itself.
        XCTAssertTrue((pdf.string ?? "").contains("Freeze"))
    }
}
