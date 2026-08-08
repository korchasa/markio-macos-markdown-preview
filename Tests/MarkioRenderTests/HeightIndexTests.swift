import XCTest

@testable import MarkioRender

/// The Fenwick tree behind every scroll offset.
///
/// Each test compares it against the obvious O(n) answer, because the whole
/// point of the structure is that it agrees with the naive sum while being
/// cheap enough to consult on every frame.
final class HeightIndexTests: XCTestCase {
    private func naiveOffset(_ heights: [Float], _ index: Int) -> CGFloat {
        CGFloat(heights.prefix(index).reduce(0) { $0 + Double($1) })
    }

    func testOffsetsMatchPrefixSums() {
        let estimates: [Float] = (0..<200).map { Float(10 + ($0 % 7) * 13) }
        let index = HeightIndex(estimates: estimates)
        for i in stride(from: 0, through: estimates.count, by: 1) {
            XCTAssertEqual(index.offset(of: i), naiveOffset(estimates, i), accuracy: 0.001)
        }
        XCTAssertEqual(index.totalHeight, naiveOffset(estimates, estimates.count), accuracy: 0.001)
    }

    func testMeasuringUpdatesEveryLaterOffset() {
        var heights: [Float] = Array(repeating: 20, count: 64)
        var index = HeightIndex(estimates: heights)

        let shift = index.setHeight(95, at: 10)
        heights[10] = 95
        // The return value is what the caller needs in order to keep the
        // reader's position: how much everything below just moved.
        XCTAssertEqual(shift, 75, accuracy: 0.001)
        XCTAssertTrue(index.isMeasured(at: 10))
        XCTAssertFalse(index.isMeasured(at: 11))

        for i in stride(from: 0, through: heights.count, by: 1) {
            XCTAssertEqual(index.offset(of: i), naiveOffset(heights, i), accuracy: 0.001)
        }
    }

    func testSearchFindsTheBlockContainingAnOffset() {
        let estimates: [Float] = (0..<128).map { Float(5 + ($0 % 11) * 9) }
        let index = HeightIndex(estimates: estimates)
        for target in stride(from: CGFloat(0), to: index.totalHeight, by: 7) {
            let found = index.index(atOffset: target)
            let start = index.offset(of: found)
            let end = start + index.height(at: found)
            XCTAssertLessThanOrEqual(start, target)
            XCTAssertGreaterThan(end, target)
        }
    }

    func testSearchClampsToTheEnds() {
        let index = HeightIndex(estimates: [30, 30, 30])
        XCTAssertEqual(index.index(atOffset: -500), 0)
        XCTAssertEqual(index.index(atOffset: 10_000), 2)
    }

    func testEmptyDocument() {
        let index = HeightIndex(estimates: [])
        XCTAssertEqual(index.count, 0)
        XCTAssertEqual(index.totalHeight, 0)
        XCTAssertEqual(index.index(atOffset: 42), 0)
    }
}
