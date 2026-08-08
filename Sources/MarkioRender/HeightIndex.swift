import CoreGraphics

/// Vertical positions of every block, kept correct while heights change.
///
/// A virtualized document needs three answers constantly: where does block *i*
/// start, which block is at scroll offset *y*, and how tall is the document.
/// A plain array of heights answers the first two in linear time, which is fine
/// at a thousand blocks and hopeless at a million.
///
/// A Fenwick tree answers all three in O(log n) and updates in O(log n) when a
/// block's estimated height is replaced by its measured one — which happens for
/// every block that scrolls into view, so the update path matters as much as
/// the query path.
struct HeightIndex {
    /// Per-block height. `Float` halves the array against `Double` and its
    /// precision is far finer than a device pixel at any plausible height.
    private(set) var heights: [Float]
    /// Fenwick tree of partial sums, 1-based. `Double` because the sums run to
    /// hundreds of thousands of points and repeated `Float` addition would
    /// visibly drift by the bottom of a large document.
    private var tree: [Double]
    /// Whether a block's height is a measurement or still an estimate.
    private(set) var measured: [Bool]

    var count: Int { heights.count }

    init(estimates: [Float]) {
        heights = estimates
        measured = [Bool](repeating: false, count: estimates.count)
        tree = [Double](repeating: 0, count: estimates.count + 1)
        // Building in place is O(n); inserting one by one would be O(n log n).
        for index in 0..<estimates.count {
            tree[index + 1] += Double(estimates[index])
            let parent = index + 1 + ((index + 1) & -(index + 1))
            if parent <= estimates.count { tree[parent] += tree[index + 1] }
        }
    }

    /// Replace a block's height. Returns the change, which the caller needs in
    /// order to keep the scroll position anchored when a block *above* the
    /// viewport turns out to be a different size than estimated.
    @discardableResult
    mutating func setHeight(_ height: CGFloat, at index: Int) -> CGFloat {
        let new = Float(height)
        let delta = new - heights[index]
        measured[index] = true
        guard delta != 0 else { return 0 }
        heights[index] = new
        var position = index + 1
        let doubleDelta = Double(delta)
        while position <= count {
            tree[position] += doubleDelta
            position += position & -position
        }
        return CGFloat(delta)
    }

    @inline(__always)
    func height(at index: Int) -> CGFloat { CGFloat(heights[index]) }

    @inline(__always)
    func isMeasured(at index: Int) -> Bool { measured[index] }

    /// Total height of blocks `0..<index` — i.e. where block `index` starts.
    func offset(of index: Int) -> CGFloat {
        var position = min(index, count)
        var sum: Double = 0
        while position > 0 {
            sum += tree[position]
            position -= position & -position
        }
        return CGFloat(sum)
    }

    var totalHeight: CGFloat { offset(of: count) }

    /// The block containing vertical offset `y`, clamped to the document.
    ///
    /// This is the Fenwick "search by prefix sum" walk: it descends the tree by
    /// powers of two instead of scanning, which is what keeps scrolling a
    /// million-block document constant-cost.
    func index(atOffset y: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        var target = Double(max(0, y))
        var position = 0
        var step = 1
        while step << 1 <= count { step <<= 1 }
        while step > 0 {
            let next = position + step
            if next <= count, tree[next] <= target {
                position = next
                target -= tree[next]
            }
            step >>= 1
        }
        return min(position, count - 1)
    }
}
