import CoreGraphics

/// A directed graph drawn in layers, with lines that only run along and across
/// them.
///
/// This is the layered pipeline from the literature, stage by stage, written
/// from the papers rather than from any implementation:
///
/// 1. Cycles are broken in the order the author wrote the boxes: inside a
///    cycle, an edge that points back to a box written earlier is turned round
///    for the layout and drawn the right way afterwards. An edge that is part
///    of no cycle keeps its direction whatever order its ends were written in —
///    `A --> C` then `B --> C` puts B above C, not below it.
/// 2. Layers come from network simplex (Gansner, Koutsofios, North and Vo,
///    "A technique for drawing directed graphs", 1993), which makes the sum of
///    edge lengths as small as it can be rather than pushing every box as far
///    down as the longest path to it.
/// 3. An edge's words are a box of their own in the layer between its ends, so
///    the layout makes room for them instead of the words looking for room
///    afterwards. An edge spanning several layers gets an empty box per layer
///    it passes through.
/// 4. The order inside each layer comes from sweeping the barycenter heuristic
///    up and down (Sugiyama, Tagawa and Toda 1981), with adjacent swaps that
///    remove crossings, from several starting orders; the author's order is
///    the first start and wins a tie.
/// 5. Positions across the layers come from Brandes and Köpf, "Fast and simple
///    horizontal coordinate assignment" (2001): four alignments of each box
///    with the median of its neighbours, balanced.
/// 6. Lines leave a box from its bottom and enter one at its top. Between two
///    layers each line that has to move sideways gets a track of its own, and
///    the tracks are stacked so that as few lines cross as possible (Sander,
///    "Layout of directed hypergraphs with orthogonal hyperedges", 2004).
///
/// A frame laid out on its own passes in the points on its border where lines
/// from outside come in or go out, pinned to its first or last layer, so those
/// lines are routed inside the frame like any other.
///
/// Everything here is measured down the page: layers run top to bottom and a
/// box's width is across them. A caller laying out left to right swaps the
/// sizes it passes in and the coordinates it gets back.
enum LayeredLayout {
    struct Edge {
        var from: Int
        var to: Int
        /// The edge's words, already broken into their lines, or `nil`.
        var label: CGSize?
        /// Where on its box the line has to leave or arrive, measured across
        /// from the box's left: set when the box is a frame whose own layout
        /// already ran the line up to that point on its border.
        var fromPort: CGFloat? = nil
        var toPort: CGFloat? = nil
    }

    /// A box held to the edge of the layout: a point on a frame's border where
    /// a line from outside comes in or goes out.
    enum Pin {
        case first, last
    }

    struct Spacing {
        /// Between two boxes side by side in a layer.
        var node: CGFloat
        /// The least distance between two layers.
        var layer: CGFloat
        /// Between two lines, and between a line and a box it passes.
        var edge: CGFloat
    }

    struct Result {
        /// Per box passed in.
        var frames: [CGRect]
        /// Per edge passed in, from `from` to `to`, starting on the border of
        /// one box and stopping on the border of the other. Empty for an edge
        /// from a box to itself, which the caller draws.
        var routes: [[CGPoint]]
        /// Per edge passed in: where its words go.
        var labels: [CGRect?]
        var size: CGSize
    }

    /// Lays a graph out.
    ///
    /// - Parameter loopRoom: per box, room to keep free on its right for a
    ///   line that leaves the box and comes back to it, which the caller draws.
    static func layout(
        sizes: [CGSize], edges: [Edge], loopRoom: [CGFloat] = [], pinned: [Int: Pin] = [:],
        spacing: Spacing
    ) -> Result {
        var graph = Graph(sizes: sizes, loopRoom: loopRoom)
        graph.pinned = Set(pinned.keys)
        let arcs = graph.arcs(for: edges, spacing: spacing)
        var rank = ranks(count: graph.count, arcs: arcs)
        // A pinned box takes a layer of its own beyond everything else, so
        // the line from it crosses every layer it has to on the inside.
        if !pinned.isEmpty {
            let free = rank.indices.filter { pinned[$0] == nil }.map { rank[$0] }
            let low = free.min() ?? 0
            let high = free.max() ?? 0
            for (node, pin) in pinned { rank[node] = pin == .first ? low - 1 : high + 1 }
            let lowest = rank.min() ?? 0
            rank = rank.map { $0 - lowest }
            for arc in arcs where rank[arc.from] >= rank[arc.to] {
                preconditionFailure(
                    "edge \(arc.edge) runs against the layers from a pinned box; pass it the other way round"
                )
            }
        }
        let chains = graph.chains(edges: edges, arcs: arcs, rank: rank)
        var layers = graph.layers(rank: rank, chains: chains)
        let links = Links(count: graph.count, chains: chains)
        order(&layers, links: links, graph: graph)
        let x = coordinates(layers: layers, links: links, graph: graph, spacing: spacing)
        return route(
            layers: layers, x: x, chains: chains, edges: edges, graph: graph, spacing: spacing)
    }

    // MARK: - The graph with its added boxes

    /// The boxes passed in, followed by the boxes the layout adds: one for each
    /// edge's words, one per layer a long edge passes through.
    fileprivate struct Graph {
        var width: [CGFloat]
        var height: [CGFloat]
        /// How far a box reaches right of its middle beyond half its width.
        var extra: [CGFloat]
        /// Where the box comes in the author's order; added boxes take the
        /// place just after the box their edge leaves.
        var key: [Double]
        /// 0 for a box passed in, 1 for an edge's words, 2 for a stretch of a
        /// long edge.
        var kind: [UInt8]
        /// The edges turned round to break a cycle, drawn the other way again
        /// at the end.
        var turned = Set<Int>()
        /// Boxes held to the first or last layer.
        var pinned = Set<Int>()
        let real: Int

        var count: Int { width.count }

        init(sizes: [CGSize], loopRoom: [CGFloat]) {
            width = sizes.map(\.width)
            height = sizes.map(\.height)
            extra = sizes.indices.map { $0 < loopRoom.count ? loopRoom[$0] : 0 }
            key = sizes.indices.map(Double.init)
            kind = Array(repeating: 0, count: sizes.count)
            real = sizes.count
        }

        mutating func add(width: CGFloat, height: CGFloat, key: Double, kind: UInt8) -> Int {
            self.width.append(width)
            self.height.append(height)
            extra.append(0)
            self.key.append(key)
            self.kind.append(kind)
            return count - 1
        }

        /// The edges as the layout sees them: pointing down, with the edges
        /// that close a cycle turned round, and split in two around their words
        /// when they have any.
        mutating func arcs(for edges: [Edge], spacing: Spacing) -> [Arc] {
            let cycle = LayeredLayout.cycles(count: real, edges: edges)
            var arcs: [Arc] = []
            for (index, edge) in edges.enumerated() where edge.from != edge.to {
                let back = cycle[edge.from] == cycle[edge.to] && edge.from > edge.to
                if back { turned.insert(index) }
                let (top, bottom) = back ? (edge.to, edge.from) : (edge.from, edge.to)
                let order = Double(top) + 0.5 + Double(index) * 1e-4
                if let label = edge.label {
                    let words = add(
                        width: label.width + spacing.edge, height: label.height, key: order,
                        kind: 1)
                    arcs.append(Arc(from: top, to: words, edge: index))
                    arcs.append(Arc(from: words, to: bottom, edge: index))
                } else {
                    arcs.append(Arc(from: top, to: bottom, edge: index))
                }
            }
            return arcs
        }

        /// Every edge as the boxes it passes, top to bottom, with a stretch box
        /// added in each layer it crosses without one.
        mutating func chains(edges: [Edge], arcs: [Arc], rank: [Int]) -> [[Int]] {
            var chains = [[Int]](repeating: [], count: edges.count)
            for arc in arcs {
                if chains[arc.edge].isEmpty { chains[arc.edge] = [arc.from] }
                let order = key[arc.from] + 1e-5
                var level = rank[arc.from] + 1
                while level < rank[arc.to] {
                    let stretch = add(width: 0, height: 0, key: order, kind: 2)
                    chains[arc.edge].append(stretch)
                    level += 1
                }
                chains[arc.edge].append(arc.to)
            }
            return chains
        }

        func layers(rank: [Int], chains: [[Int]]) -> [[Int]] {
            var level = rank + Array(repeating: 0, count: count - rank.count)
            for chain in chains where chain.count > 2 {
                for step in 1..<chain.count where chain[step] >= rank.count {
                    level[chain[step]] = level[chain[step - 1]] + 1
                }
            }
            var layers = [[Int]](repeating: [], count: (level.max() ?? -1) + 1)
            for node in 0..<count { layers[level[node]].append(node) }
            return layers.map { $0.sorted { key[$0] < key[$1] } }
        }
    }

    /// Which cycle each box belongs to: the strongly connected parts of the
    /// graph (Tarjan), numbered. Two boxes share a number when each can reach
    /// the other.
    static func cycles(count: Int, edges: [Edge]) -> [Int] {
        var out = [[Int]](repeating: [], count: count)
        for edge in edges where edge.from != edge.to { out[edge.from].append(edge.to) }
        var index = [Int](repeating: -1, count: count)
        var low = [Int](repeating: 0, count: count)
        var onStack = [Bool](repeating: false, count: count)
        var stack: [Int] = []
        var part = [Int](repeating: -1, count: count)
        var counter = 0
        var parts = 0
        for root in 0..<count where index[root] < 0 {
            // The walk is kept on a stack of its own rather than in recursion,
            // so a long chain of boxes cannot run the thread out of stack.
            var walk: [(node: Int, next: Int)] = [(root, 0)]
            index[root] = counter
            low[root] = counter
            counter += 1
            stack.append(root)
            onStack[root] = true
            while let top = walk.last {
                if top.next < out[top.node].count {
                    walk[walk.count - 1].next += 1
                    let next = out[top.node][top.next]
                    if index[next] < 0 {
                        index[next] = counter
                        low[next] = counter
                        counter += 1
                        stack.append(next)
                        onStack[next] = true
                        walk.append((next, 0))
                    } else if onStack[next] {
                        low[top.node] = min(low[top.node], index[next])
                    }
                    continue
                }
                walk.removeLast()
                if let parent = walk.last {
                    low[parent.node] = min(low[parent.node], low[top.node])
                }
                if low[top.node] == index[top.node] {
                    while let member = stack.popLast() {
                        onStack[member] = false
                        part[member] = parts
                        if member == top.node { break }
                    }
                    parts += 1
                }
            }
        }
        return part
    }

    fileprivate struct Arc {
        var from: Int
        var to: Int
        var edge: Int
    }

    /// Who is joined to whom between two neighbouring layers, counted once per
    /// line so that two lines between the same boxes weigh twice.
    fileprivate struct Links {
        var up: [[Int]]
        var down: [[Int]]

        init(count: Int, chains: [[Int]]) {
            up = Array(repeating: [], count: count)
            down = Array(repeating: [], count: count)
            for chain in chains where chain.count > 1 {
                for step in 1..<chain.count {
                    down[chain[step - 1]].append(chain[step])
                    up[chain[step]].append(chain[step - 1])
                }
            }
        }
    }

    // MARK: - Layers

    /// Network simplex over each connected part of the graph, every edge
    /// wanting a length of one layer and weighing the same.
    static func ranks(count: Int, arcs: [(from: Int, to: Int)]) -> [Int] {
        var rank = [Int](repeating: 0, count: count)
        var part = Array(0..<count)
        func find(_ node: Int) -> Int {
            var node = node
            while part[node] != node {
                part[node] = part[part[node]]
                node = part[node]
            }
            return node
        }
        for arc in arcs { part[find(arc.from)] = find(arc.to) }
        var parts: [Int: [Int]] = [:]
        for node in 0..<count { parts[find(node), default: []].append(node) }
        for members in parts.values {
            var local: [Int: Int] = [:]
            for (index, node) in members.enumerated() { local[node] = index }
            let inner = arcs.compactMap { arc -> (from: Int, to: Int)? in
                guard let from = local[arc.from], let to = local[arc.to] else { return nil }
                return (from, to)
            }
            let ranked = simplex(count: members.count, arcs: inner)
            for (index, node) in members.enumerated() { rank[node] = ranked[index] }
        }
        return rank
    }

    fileprivate static func ranks(count: Int, arcs: [Arc]) -> [Int] {
        ranks(count: count, arcs: arcs.map { ($0.from, $0.to) })
    }

    /// Network simplex on one connected, acyclic graph.
    private static func simplex(count: Int, arcs: [(from: Int, to: Int)]) -> [Int] {
        guard count > 1 else { return Array(repeating: 0, count: count) }
        // A first feasible answer: every box one layer below the lowest box
        // pointing at it.
        var rank = [Int](repeating: 0, count: count)
        var incoming = [Int](repeating: 0, count: count)
        var outgoing = [[Int]](repeating: [], count: count)
        for (index, arc) in arcs.enumerated() {
            incoming[arc.to] += 1
            outgoing[arc.from].append(index)
        }
        var ready = (0..<count).filter { incoming[$0] == 0 }
        while let node = ready.popLast() {
            for index in outgoing[node] {
                let next = arcs[index].to
                rank[next] = max(rank[next], rank[node] + 1)
                incoming[next] -= 1
                if incoming[next] == 0 { ready.append(next) }
            }
        }
        func slack(_ index: Int) -> Int { rank[arcs[index].to] - rank[arcs[index].from] - 1 }

        // A spanning tree of edges with no slack, made tight by moving the
        // part already in the tree whenever it stops growing.
        var inTree = [Bool](repeating: false, count: count)
        var tree = [Bool](repeating: false, count: arcs.count)
        inTree[0] = true
        var size = 1
        while size < count {
            var grew = true
            while grew {
                grew = false
                for index in arcs.indices where !tree[index] && slack(index) == 0 {
                    let arc = arcs[index]
                    guard inTree[arc.from] != inTree[arc.to] else { continue }
                    tree[index] = true
                    inTree[arc.from] = true
                    inTree[arc.to] = true
                    size += 1
                    grew = true
                }
            }
            guard size < count else { break }
            var best: Int?
            for index in arcs.indices
            where inTree[arcs[index].from] != inTree[arcs[index].to] {
                if best == nil || slack(index) < slack(best!) { best = index }
            }
            guard let best else { break }
            let delta = inTree[arcs[best].to] ? -slack(best) : slack(best)
            for node in 0..<count where inTree[node] { rank[node] += delta }
        }

        // Swap a tree edge whose cut value is negative for the non-tree edge
        // with the least slack across the same cut, until none is left.
        var neighbours = [[Int]](repeating: [], count: count)
        func rebuild() {
            neighbours = Array(repeating: [], count: count)
            for index in arcs.indices where tree[index] {
                neighbours[arcs[index].from].append(index)
                neighbours[arcs[index].to].append(index)
            }
        }
        /// The boxes still joined to the tail of a tree edge once it is cut.
        func tail(of cut: Int) -> [Bool] {
            var side = [Bool](repeating: false, count: count)
            var stack = [arcs[cut].from]
            side[arcs[cut].from] = true
            while let node = stack.popLast() {
                for index in neighbours[node] where index != cut {
                    let other = arcs[index].from == node ? arcs[index].to : arcs[index].from
                    if !side[other] {
                        side[other] = true
                        stack.append(other)
                    }
                }
            }
            return side
        }
        rebuild()
        var rounds = 0
        while rounds < count * 8 {
            rounds += 1
            var leaving: (index: Int, side: [Bool], value: Int)?
            for index in arcs.indices where tree[index] {
                let side = tail(of: index)
                var value = 0
                for arc in arcs {
                    if side[arc.from] && !side[arc.to] { value += 1 }
                    if !side[arc.from] && side[arc.to] { value -= 1 }
                }
                if value < 0, leaving == nil || value < leaving!.value {
                    leaving = (index, side, value)
                }
            }
            guard let leaving else { break }
            var entering: Int?
            for index in arcs.indices
            where !tree[index] && !leaving.side[arcs[index].from] && leaving.side[arcs[index].to] {
                if entering == nil || slack(index) < slack(entering!) { entering = index }
            }
            guard let entering else { break }
            let delta = slack(entering)
            for node in 0..<count where leaving.side[node] { rank[node] -= delta }
            tree[leaving.index] = false
            tree[entering] = true
            rebuild()
        }
        let lowest = rank.min() ?? 0
        return rank.map { $0 - lowest }
    }

    // MARK: - Order inside the layers

    /// The sweeps settle on a local best, and which one depends on where they
    /// start: moving a whole long edge to the other side of a column of boxes
    /// costs crossings at every step and is never found by swapping
    /// neighbours. So the sweeps run from several starts — the author's order,
    /// the order a walk down from the first box meets them, that walk from the
    /// last box, and two dozen shuffles from a fixed seed — and the start with
    /// fewest crossings wins, the author's order on a tie.
    private static func order(_ layers: inout [[Int]], links: Links, graph: Graph) {
        guard layers.count > 1 else { return }
        var starts = [layers]
        for fromEnd in [false, true] {
            var seen = [Int](repeating: -1, count: graph.count)
            var counter = 0
            let roots = layers[0].sorted { graph.key[$0] < graph.key[$1] }
            for root in fromEnd ? roots.reversed() : roots where seen[root] < 0 {
                var stack = [root]
                while let node = stack.popLast() {
                    guard seen[node] < 0 else { continue }
                    seen[node] = counter
                    counter += 1
                    let next = links.down[node].sorted { graph.key[$0] < graph.key[$1] }
                    stack += fromEnd ? next : next.reversed()
                }
            }
            for node in 0..<graph.count where seen[node] < 0 {
                seen[node] = counter
                counter += 1
            }
            starts.append(layers.map { layer in layer.sorted { seen[$0] < seen[$1] } })
        }
        // Shuffles from a fixed seed, so the same source always draws the same
        // picture.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<24 {
            starts.append(
                layers.map { layer in
                    var shuffled = layer
                    for index in shuffled.indices.reversed() where index > 0 {
                        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                        shuffled.swapAt(index, Int((seed >> 33) % UInt64(index + 1)))
                    }
                    return shuffled
                })
        }
        let answers = starts.map { start -> (layers: [[Int]], crossings: Int) in
            var attempt = start
            sweep(&attempt, links: links, graph: graph)
            return (attempt, crossings(attempt, links: links))
        }
        let best = answers.indices.min {
            (answers[$0].crossings, $0) < (answers[$1].crossings, $1)
        }!
        layers = answers[best].layers
    }

    private static func sweep(_ layers: inout [[Int]], links: Links, graph: Graph) {
        var best = layers
        var fewest = crossings(layers, links: links)
        var stale = 0
        for round in 0..<32 where fewest > 0 {
            let downwards = round % 2 == 0
            let sequence: [Int] =
                downwards ? Array(1..<layers.count) : Array((0..<layers.count - 1).reversed())
            for level in sequence {
                let fixed = layers[downwards ? level - 1 : level + 1]
                var place: [Int: Int] = [:]
                for (index, node) in fixed.enumerated() { place[node] = index }
                let current = layers[level]
                var centre: [Int: Double] = [:]
                for (index, node) in current.enumerated() {
                    let others = (downwards ? links.up[node] : links.down[node]).compactMap {
                        place[$0]
                    }
                    centre[node] =
                        others.isEmpty
                        ? Double(index) / Double(max(1, current.count - 1))
                            * Double(max(0, fixed.count - 1))
                        : Double(others.reduce(0, +)) / Double(others.count)
                }
                // A tie keeps the order the layer already has: that is what
                // lets the starts differ, and the author's order is the
                // first of them.
                var was: [Int: Int] = [:]
                for (index, node) in current.enumerated() { was[node] = index }
                layers[level] = current.sorted {
                    centre[$0]! != centre[$1]! ? centre[$0]! < centre[$1]! : was[$0]! < was[$1]!
                }
            }
            transpose(&layers, links: links)
            let count = crossings(layers, links: links)
            if count < fewest {
                fewest = count
                best = layers
                stale = 0
            } else {
                stale += 1
                if stale >= 6 { break }
            }
        }
        layers = best
        // Where nothing is lost by it, boxes stand in the order they were
        // written: a reader looks for the second state to the right of the
        // first.
        for level in layers.indices {
            var moved = true
            var passes = 0
            while moved && passes < layers[level].count {
                moved = false
                passes += 1
                for index in 1..<max(1, layers[level].count) {
                    let left = layers[level][index - 1]
                    let right = layers[level][index]
                    guard graph.key[right] < graph.key[left] else { continue }
                    let before = local(layers, level, links: links)
                    layers[level].swapAt(index - 1, index)
                    if local(layers, level, links: links) > before {
                        layers[level].swapAt(index - 1, index)
                    } else {
                        moved = true
                    }
                }
            }
        }
    }

    /// Swaps two neighbours wherever that removes crossings, until nothing
    /// more can be had.
    private static func transpose(_ layers: inout [[Int]], links: Links) {
        var improved = true
        var passes = 0
        while improved && passes < 8 {
            improved = false
            passes += 1
            for level in layers.indices where layers[level].count > 1 {
                for index in 1..<layers[level].count {
                    let before = local(layers, level, links: links)
                    layers[level].swapAt(index - 1, index)
                    if local(layers, level, links: links) < before {
                        improved = true
                    } else {
                        layers[level].swapAt(index - 1, index)
                    }
                }
            }
        }
    }

    /// Crossings a layer takes part in: with the layer above and the one below.
    private static func local(_ layers: [[Int]], _ level: Int, links: Links) -> Int {
        var total = 0
        if level > 0 { total += crossings(layers[level - 1], layers[level], links: links) }
        if level + 1 < layers.count {
            total += crossings(layers[level], layers[level + 1], links: links)
        }
        return total
    }

    private static func crossings(_ layers: [[Int]], links: Links) -> Int {
        guard layers.count > 1 else { return 0 }
        return (1..<layers.count).reduce(0) {
            $0 + crossings(layers[$1 - 1], layers[$1], links: links)
        }
    }

    private static func crossings(_ upper: [Int], _ lower: [Int], links: Links) -> Int {
        var place: [Int: Int] = [:]
        for (index, node) in lower.enumerated() { place[node] = index }
        var ends: [(Int, Int)] = []
        for (index, node) in upper.enumerated() {
            for next in links.down[node] { if let at = place[next] { ends.append((index, at)) } }
        }
        var total = 0
        for one in ends.indices {
            for other in ends.indices where other > one {
                let a = ends[one]
                let b = ends[other]
                if (a.0 - b.0) * (a.1 - b.1) < 0 { total += 1 }
            }
        }
        return total
    }

    // MARK: - Positions across the layers

    private static func coordinates(
        layers: [[Int]], links: Links, graph: Graph, spacing: Spacing
    ) -> [CGFloat] {
        let count = graph.count
        func left(_ node: Int) -> CGFloat { graph.width[node] / 2 }
        func right(_ node: Int) -> CGFloat { graph.width[node] / 2 + graph.extra[node] }
        func gap(_ one: Int, _ other: Int) -> CGFloat {
            graph.kind[one] == 2 || graph.kind[other] == 2 ? spacing.edge : spacing.node
        }
        // A line between two stretch boxes is part of a long edge, and a long
        // edge is what most needs to run straight; a short line crossing it is
        // the one that gives way.
        var conflicted = Set<Int>()
        for level in 1..<max(1, layers.count) {
            var place: [Int: Int] = [:]
            for (index, node) in layers[level].enumerated() { place[node] = index }
            var segments: [(upper: Int, lower: Int, a: Int, b: Int, inner: Bool)] = []
            for (index, node) in layers[level - 1].enumerated() {
                for next in links.down[node] {
                    guard let at = place[next] else { continue }
                    segments.append(
                        (index, at, node, next, graph.kind[node] != 0 && graph.kind[next] != 0))
                }
            }
            for one in segments where !one.inner {
                if segments.contains(where: {
                    $0.inner && ($0.upper - one.upper) * ($0.lower - one.lower) < 0
                }) {
                    conflicted.insert(one.a * count + one.b)
                }
            }
        }

        var layouts: [[CGFloat]] = []
        for downwards in [true, false] {
            for leftwards in [true, false] {
                let ordered = (downwards ? layers : layers.reversed()).map {
                    leftwards ? $0 : $0.reversed()
                }
                var place = [Int](repeating: 0, count: count)
                for layer in ordered {
                    for (index, node) in layer.enumerated() { place[node] = index }
                }
                var root = Array(0..<count)
                var align = Array(0..<count)
                for level in 1..<max(1, ordered.count) {
                    var reach = -1
                    for node in ordered[level] {
                        let others = (downwards ? links.up[node] : links.down[node]).sorted {
                            place[$0] < place[$1]
                        }
                        guard !others.isEmpty else { continue }
                        let low = (others.count - 1) / 2
                        let high = others.count / 2
                        for median in Set([low, high]).sorted() where align[node] == node {
                            let other = others[median]
                            let pair = downwards ? other * count + node : node * count + other
                            guard !conflicted.contains(pair), reach < place[other] else { continue }
                            align[other] = node
                            root[node] = root[other]
                            align[node] = root[node]
                            reach = place[other]
                        }
                    }
                }
                // Each aligned column is one block; blocks are packed left to
                // right as tightly as their neighbours allow, then pulled back
                // towards whatever they were packed away from.
                var after = [Int: [(Int, CGFloat)]]()
                var before = [Int: [(Int, CGFloat)]]()
                for layer in ordered where layer.count > 1 {
                    for index in 1..<layer.count {
                        let one = layer[index - 1]
                        let other = layer[index]
                        let distance =
                            (leftwards ? right(one) + left(other) : left(one) + right(other))
                            + gap(one, other)
                        after[root[one], default: []].append((root[other], distance))
                        before[root[other], default: []].append((root[one], distance))
                    }
                }
                let blocks = (0..<count).filter { root[$0] == $0 }
                var waiting = [Int: Int]()
                for block in blocks { waiting[block] = before[block]?.count ?? 0 }
                var queue = blocks.filter { waiting[$0] == 0 }
                var sequence: [Int] = []
                while let block = queue.popLast() {
                    sequence.append(block)
                    for (next, _) in after[block] ?? [] {
                        waiting[next]! -= 1
                        if waiting[next] == 0 { queue.append(next) }
                    }
                }
                var at = [Int: CGFloat]()
                // Kahn's order has every block after all it is packed against;
                // a block left out would mean the alignment crossed itself, and
                // it is then simply packed at the start.
                for block in sequence {
                    at[block] =
                        (before[block] ?? []).compactMap { pair in at[pair.0].map { $0 + pair.1 } }
                        .max() ?? 0
                }
                for block in sequence.reversed() {
                    let room = (after[block] ?? []).compactMap { pair in
                        at[pair.0].map { $0 - pair.1 }
                    }
                    guard let nearest = room.min(), let here = at[block] else { continue }
                    at[block] = max(here, nearest)
                }
                var x = [CGFloat](repeating: 0, count: count)
                for node in 0..<count { x[node] = (at[root[node]] ?? 0) * (leftwards ? 1 : -1) }
                layouts.append(x)
            }
        }
        // The four answers lean four ways; each is moved to line up with the
        // narrowest along the side it was packed against, and every box takes
        // the mean of its two middle positions.
        func extent(_ x: [CGFloat]) -> (CGFloat, CGFloat) {
            var low = CGFloat.infinity
            var high = -CGFloat.infinity
            for node in 0..<count {
                low = min(low, x[node] - left(node))
                high = max(high, x[node] + right(node))
            }
            return (low, high)
        }
        let extents = layouts.map(extent)
        let narrowest = extents.indices.min {
            extents[$0].1 - extents[$0].0 < extents[$1].1 - extents[$1].0
        }!
        for index in layouts.indices {
            let shift =
                index % 2 == 0
                ? extents[narrowest].0 - extents[index].0 : extents[narrowest].1 - extents[index].1
            layouts[index] = layouts[index].map { $0 + shift }
        }
        return (0..<count).map { node in
            let values = layouts.map { $0[node] }.sorted()
            return (values[1] + values[2]) / 2
        }
    }

    // MARK: - Lines

    /// One line's passage between two neighbouring layers.
    private struct Hop {
        var edge: Int
        var upper: Int
        var lower: Int
        var out: CGFloat = 0
        var into: CGFloat = 0
        var track = -1
    }

    private static func route(
        layers: [[Int]], x: [CGFloat], chains: [[Int]], edges: [Edge], graph: Graph,
        spacing: Spacing
    ) -> Result {
        let count = graph.count
        var level = [Int](repeating: 0, count: count)
        for (index, layer) in layers.enumerated() { for node in layer { level[node] = index } }

        // Every passage between two layers, grouped by the gap it crosses.
        var gaps = [[Hop]](repeating: [], count: max(0, layers.count - 1))
        for (edge, chain) in chains.enumerated() where chain.count > 1 {
            for step in 1..<chain.count {
                gaps[level[chain[step - 1]]].append(
                    Hop(edge: edge, upper: chain[step - 1], lower: chain[step]))
            }
        }

        // Where on a box each line leaves or arrives. A line headed straight
        // down to something within the box's own width leaves right above it;
        // several lines on one side keep the order of what they reach, so they
        // do not cross on the way out.
        func fixed(_ edge: Int, _ node: Int) -> CGFloat? {
            let left = x[node] - graph.width[node] / 2
            if node == edges[edge].from, let port = edges[edge].fromPort { return left + port }
            if node == edges[edge].to, let port = edges[edge].toPort { return left + port }
            return nil
        }
        func ports(_ node: Int, _ towards: [CGFloat]) -> [CGFloat] {
            guard graph.kind[node] == 0 else { return towards.map { _ in x[node] } }
            let half = graph.width[node] / 2
            if towards.count == 1 {
                let margin = min(half * 0.6, max(4, half - 12))
                return abs(towards[0] - x[node]) < margin ? towards : [x[node]]
            }
            let low = x[node] - half * 0.7
            let high = x[node] + half * 0.7
            let step = min(spacing.edge, (high - low) / CGFloat(towards.count - 1))
            var placed = towards.map { min(max($0, low), high) }
            for index in placed.indices.dropFirst() {
                placed[index] = max(placed[index], placed[index - 1] + step)
            }
            for index in placed.indices.reversed() {
                let limit = index == placed.count - 1 ? high : placed[index + 1] - step
                placed[index] = min(placed[index], limit)
            }
            return placed
        }
        for gap in gaps.indices {
            var leaving: [Int: [Int]] = [:]
            var arriving: [Int: [Int]] = [:]
            for (index, hop) in gaps[gap].enumerated() {
                leaving[hop.upper, default: []].append(index)
                arriving[hop.lower, default: []].append(index)
            }
            for (node, hops) in leaving {
                let sorted = hops.sorted {
                    (x[gaps[gap][$0].lower], $0) < (x[gaps[gap][$1].lower], $1)
                }
                let at = ports(node, sorted.map { x[gaps[gap][$0].lower] })
                for (index, hop) in sorted.enumerated() {
                    gaps[gap][hop].out = fixed(gaps[gap][hop].edge, node) ?? at[index]
                }
            }
            for (node, hops) in arriving {
                let sorted = hops.sorted { (gaps[gap][$0].out, $0) < (gaps[gap][$1].out, $1) }
                let at = ports(node, sorted.map { gaps[gap][$0].out })
                for (index, hop) in sorted.enumerated() {
                    gaps[gap][hop].into = fixed(gaps[gap][hop].edge, node) ?? at[index]
                }
            }
        }

        // Tracks: a line that moves sideways runs across the gap at a height
        // of its own. Of two that overlap, the one whose going down would cross
        // the other's crossing over stands below it.
        var tracks = [Int](repeating: 0, count: gaps.count)
        for gap in gaps.indices {
            let moving = gaps[gap].indices.filter {
                abs(gaps[gap][$0].out - gaps[gap][$0].into) > 0.5
            }
            func span(_ index: Int) -> (CGFloat, CGFloat) {
                let hop = gaps[gap][index]
                return (min(hop.out, hop.into), max(hop.out, hop.into))
            }
            func strictly(_ value: CGFloat, _ range: (CGFloat, CGFloat)) -> Bool {
                value > range.0 + 0.5 && value < range.1 - 0.5
            }
            var below = [Int: [Int]]()
            for (position, one) in moving.enumerated() {
                for other in moving[(position + 1)...] {
                    let a = span(one)
                    let b = span(other)
                    guard max(a.0, b.0) < min(a.1, b.1) + spacing.edge else { continue }
                    let hopA = gaps[gap][one]
                    let hopB = gaps[gap][other]
                    // Crossings if A runs above B: A's way down passes through
                    // B's run, and B's way in from above passes through A's.
                    let aAbove =
                        (strictly(hopA.into, b) ? 1 : 0) + (strictly(hopB.out, a) ? 1 : 0)
                    let bAbove =
                        (strictly(hopB.into, a) ? 1 : 0) + (strictly(hopA.out, b) ? 1 : 0)
                    if aAbove <= bAbove {
                        below[one, default: []].append(other)
                    } else {
                        below[other, default: []].append(one)
                    }
                }
            }
            // A preference can come back on itself round three lines; a walk
            // turns the edge that closes such a loop round.
            var state = [Int: UInt8]()
            var final = [Int: [Int]]()
            func visit(_ node: Int) {
                state[node] = 1
                for next in below[node] ?? [] {
                    switch state[next] {
                    case nil:
                        final[node, default: []].append(next)
                        visit(next)
                    case .some(1):
                        final[next, default: []].append(node)
                    default:
                        final[node, default: []].append(next)
                    }
                }
                state[node] = 2
            }
            for node in moving where state[node] == nil { visit(node) }
            var depth = [Int: Int]()
            func deepest(_ node: Int) -> Int {
                if let known = depth[node] { return known }
                var value = 0
                for (above, list) in final where list.contains(node) {
                    value = max(value, deepest(above) + 1)
                }
                depth[node] = value
                return value
            }
            for index in moving {
                gaps[gap][index].track = deepest(index)
                tracks[gap] = max(tracks[gap], gaps[gap][index].track + 1)
            }
        }

        // Heights: each layer as deep as its deepest box, each gap deep
        // enough for its tracks.
        let depth = layers.map { layer in layer.map { graph.height[$0] }.max() ?? 0 }
        var top = [CGFloat](repeating: 0, count: layers.count)
        var room = [CGFloat](repeating: 0, count: gaps.count)
        // Next to a layer that holds only points on a frame's border, the gap
        // needs room for its tracks and nothing more: there is no box there
        // for the lines to keep clear of.
        let bare = layers.map { layer in !layer.isEmpty && layer.allSatisfy(graph.pinned.contains) }
        for gap in gaps.indices {
            let needed = spacing.edge * 2 + CGFloat(max(0, tracks[gap] - 1)) * spacing.edge
            room[gap] = bare[gap] || bare[gap + 1] ? needed : max(spacing.layer, needed)
            top[gap + 1] = top[gap] + depth[gap] + room[gap]
        }
        func middle(_ node: Int) -> CGFloat { top[level[node]] + depth[level[node]] / 2 }
        func rect(_ node: Int) -> CGRect {
            CGRect(
                x: x[node] - graph.width[node] / 2, y: middle(node) - graph.height[node] / 2,
                width: graph.width[node], height: graph.height[node])
        }

        var routes = [[CGPoint]](repeating: [], count: edges.count)
        for gap in gaps.indices {
            let floor = top[gap] + depth[gap]
            let used = CGFloat(max(0, tracks[gap] - 1)) * spacing.edge
            let first = floor + (room[gap] - used) / 2
            for hop in gaps[gap] {
                var points = routes[hop.edge]
                if points.isEmpty { points.append(CGPoint(x: hop.out, y: rect(hop.upper).maxY)) }
                if hop.track >= 0 {
                    let height = first + CGFloat(hop.track) * spacing.edge
                    points.append(CGPoint(x: hop.out, y: height))
                    points.append(CGPoint(x: hop.into, y: height))
                }
                points.append(CGPoint(x: hop.into, y: rect(hop.lower).minY))
                if graph.kind[hop.lower] != 0 {
                    points.append(CGPoint(x: hop.into, y: rect(hop.lower).maxY))
                }
                routes[hop.edge] = points
            }
        }
        var labels = [CGRect?](repeating: nil, count: edges.count)
        for (edge, chain) in chains.enumerated() {
            routes[edge] = simplified(routes[edge])
            if graph.turned.contains(edge) { routes[edge].reverse() }
            if let words = chain.first(where: { graph.kind[$0] == 1 }), let size = edges[edge].label
            {
                labels[edge] = CGRect(
                    x: x[words] - size.width / 2, y: middle(words) - size.height / 2,
                    width: size.width, height: size.height)
            }
        }

        // Everything moved so the picture starts at the origin.
        var frames = (0..<graph.real).map(rect)
        var bounds = CGRect.null
        for (node, frame) in frames.enumerated() {
            bounds = bounds.union(frame)
            bounds = bounds.union(
                CGRect(x: frame.maxX, y: frame.minY, width: graph.extra[node], height: frame.height)
            )
        }
        for route in routes {
            for point in route { bounds = bounds.union(CGRect(origin: point, size: .zero)) }
        }
        for label in labels { if let label { bounds = bounds.union(label) } }
        guard !bounds.isNull else {
            return Result(frames: frames, routes: routes, labels: labels, size: .zero)
        }
        let dx = -bounds.minX
        let dy = -bounds.minY
        frames = frames.map { $0.offsetBy(dx: dx, dy: dy) }
        routes = routes.map { $0.map { CGPoint(x: $0.x + dx, y: $0.y + dy) } }
        labels = labels.map { $0?.offsetBy(dx: dx, dy: dy) }
        return Result(frames: frames, routes: routes, labels: labels, size: bounds.size)
    }

    /// A line with its repeated points and the points in the middle of a
    /// straight run left out, so a corner is a corner.
    static func simplified(_ points: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for point in points {
            if let last = out.last, abs(last.x - point.x) < 0.01, abs(last.y - point.y) < 0.01 {
                continue
            }
            if out.count >= 2 {
                let a = out[out.count - 2]
                let b = out[out.count - 1]
                let cross = (b.x - a.x) * (point.y - b.y) - (b.y - a.y) * (point.x - b.x)
                if abs(cross) < 0.01 {
                    out[out.count - 1] = point
                    continue
                }
            }
            out.append(point)
        }
        return out
    }
}
