import CoreGraphics

/// Lines at right angles through the gaps between boxes that stand where they
/// stand — a block diagram's grid, which the author counted out and the
/// layout may not move.
///
/// Every line is the cheapest walk over a grid of candidate coordinates: the
/// middles of the gaps between box edges, the centres of the boxes (so a line
/// runs straight on from a box's middle), and one lane outside everything. A
/// turn costs as much as a long run, so a line takes few of them. Lines that
/// come to share a stretch of a gap are then spread over tracks of their own,
/// and lines meeting one side of a box over points of their own along it.
enum GridRouter {
    struct Line {
        var from: CGRect
        var to: CGRect
        /// Obstacles this line may pass over: the frames that hold its ends.
        var exempt: Set<Int> = []
    }

    struct Result {
        /// One route per line, from the border it leaves to the border it
        /// reaches; nil where no walk exists.
        var routes: [[CGPoint]?]
        /// The most lines that run side by side in one gap.
        var tracks: Int
    }

    /// Routes every line around `obstacles`, which include the lines' own end
    /// boxes: a line may leave and reach its ends, never pass over them.
    ///
    /// - Parameters:
    ///   - margin: how far outside everything the outer lane runs.
    ///   - spacing: how far apart two lines sharing a gap or a side stand.
    ///   - stub: the shortest straight run a line keeps at either end, so its
    ///     end mark is drawn on a straight piece.
    ///   - bend: what one turn costs, in points of length.
    static func route(
        _ lines: [Line], obstacles: [CGRect], margin: CGFloat, spacing: CGFloat, stub: CGFloat,
        bend: CGFloat
    ) -> Result {
        let all = obstacles + lines.flatMap { [$0.from, $0.to] }
        let xs = coordinates(all.flatMap { [$0.minX, $0.maxX] }, centres: all.map(\.midX), margin)
        let ys = coordinates(all.flatMap { [$0.minY, $0.maxY] }, centres: all.map(\.midY), margin)
        var routes: [[CGPoint]?] = []
        var sides: [(start: Side, end: Side)?] = []
        // Lines are walked one after another, and crossing one already walked
        // costs as much as a turn: two lines that can share a gap or go round
        // each other do, instead of cutting across.
        var walked: [(CGPoint, CGPoint)] = []
        for line in lines {
            let blocking = obstacles.enumerated().filter { !line.exempt.contains($0.offset) }
                .map { $0.element.insetBy(dx: -clearance, dy: -clearance) }
            if let found = walk(
                line, blocking: blocking, xs: xs, ys: ys, stub: stub, bend: bend, across: walked)
            {
                walked += zip(found.points, found.points.dropFirst()).map { ($0, $1) }
                routes.append(found.points)
                sides.append((found.start, found.end))
            } else {
                routes.append(nil)
                sides.append(nil)
            }
        }
        let tracks = spreadTracks(&routes, spacing: spacing)
        spreadPorts(&routes, sides: sides, lines: lines, spacing: spacing)
        return Result(routes: routes, tracks: tracks)
    }

    /// How far a line keeps off any box it passes.
    private static let clearance: CGFloat = 3

    /// A side of a box. The raw values double as the directions a walk
    /// steps in — right, down, left, up — so a side is also the way out
    /// through it.
    enum Side: Int, CaseIterable {
        case right, bottom, left, top

        func centre(of box: CGRect) -> CGPoint {
            switch self {
            case .right: return CGPoint(x: box.maxX, y: box.midY)
            case .bottom: return CGPoint(x: box.midX, y: box.maxY)
            case .left: return CGPoint(x: box.minX, y: box.midY)
            case .top: return CGPoint(x: box.midX, y: box.minY)
            }
        }

        var horizontal: Bool { self == .top || self == .bottom }
    }

    /// The middles between neighbouring edges, the centres, and one lane
    /// beyond either end; close values are one value.
    private static func coordinates(_ edges: [CGFloat], centres: [CGFloat], _ margin: CGFloat)
        -> [CGFloat]
    {
        let sorted = Array(Set(edges)).sorted()
        guard let first = sorted.first, let last = sorted.last else { return [] }
        var values = centres + [first - margin, last + margin]
        for (a, b) in zip(sorted, sorted.dropFirst()) where b - a > 1 { values.append((a + b) / 2) }
        var out: [CGFloat] = []
        for value in values.sorted() where out.last.map({ value - $0 > 0.5 }) ?? true {
            out.append(value)
        }
        return out
    }

    private static func inside(_ point: CGPoint, _ rects: [CGRect]) -> Bool {
        rects.contains {
            point.x > $0.minX && point.x < $0.maxX && point.y > $0.minY && point.y < $0.maxY
        }
    }

    /// Whether an upright or level run passes through the inside of a box.
    private static func crosses(_ a: CGPoint, _ b: CGPoint, _ rects: [CGRect]) -> Bool {
        rects.contains { rect in
            if abs(a.y - b.y) < 0.01 {
                return a.y > rect.minY && a.y < rect.maxY
                    && max(min(a.x, b.x), rect.minX) < min(max(a.x, b.x), rect.maxX)
            }
            return a.x > rect.minX && a.x < rect.maxX
                && max(min(a.y, b.y), rect.minY) < min(max(a.y, b.y), rect.maxY)
        }
    }

    /// Where a line steps off a box through one side: the first grid point
    /// straight out from the side's centre at least `stub` away from it.
    private static func doorway(
        _ box: CGRect, _ side: Side, xs: [CGFloat], ys: [CGFloat], stub: CGFloat,
        blocking: [CGRect]
    ) -> (port: CGPoint, x: Int, y: Int)? {
        let port = side.centre(of: box)
        guard let x = xs.firstIndex(where: { abs($0 - port.x) < 0.5 }) ?? nearest(port.x, xs),
            let y = ys.firstIndex(where: { abs($0 - port.y) < 0.5 }) ?? nearest(port.y, ys)
        else { return nil }
        var step: (x: Int, y: Int)
        switch side {
        case .right:
            guard let index = xs.firstIndex(where: { $0 >= port.x + stub }) else { return nil }
            step = (index, y)
        case .left:
            guard let index = xs.lastIndex(where: { $0 <= port.x - stub }) else { return nil }
            step = (index, y)
        case .bottom:
            guard let index = ys.firstIndex(where: { $0 >= port.y + stub }) else { return nil }
            step = (x, index)
        case .top:
            guard let index = ys.lastIndex(where: { $0 <= port.y - stub }) else { return nil }
            step = (x, index)
        }
        let point = CGPoint(x: xs[step.x], y: ys[step.y])
        let others = blocking.filter { !$0.contains(port) }
        guard !inside(point, blocking), !crosses(port, point, others) else { return nil }
        return (port, step.x, step.y)
    }

    private static func nearest(_ value: CGFloat, _ values: [CGFloat]) -> Int? {
        values.indices.min { abs(values[$0] - value) < abs(values[$1] - value) }
    }

    /// The cheapest walk from one box to the other: length plus a price for
    /// every turn. A side is only used through its centre; spreading lines
    /// along a side comes afterwards.
    private static func walk(
        _ line: Line, blocking: [CGRect], xs: [CGFloat], ys: [CGFloat], stub: CGFloat,
        bend: CGFloat, across walked: [(CGPoint, CGPoint)]
    ) -> (points: [CGPoint], start: Side, end: Side)? {
        let width = xs.count
        let count = width * ys.count
        func point(_ index: Int) -> CGPoint { CGPoint(x: xs[index % width], y: ys[index / width]) }
        var open = [Bool?](repeating: nil, count: count)
        func free(_ index: Int) -> Bool {
            if let known = open[index] { return known }
            let answer = !inside(point(index), blocking)
            open[index] = answer
            return answer
        }
        // A state is a grid point and the direction the walk arrived in; the
        // last four states stand for having reached the target by each side.
        let goals = count * 4
        var cost = [CGFloat](repeating: .infinity, count: goals + 4)
        var parent = [Int](repeating: -1, count: goals + 4)
        var startSide = [Int](repeating: -1, count: goals + 4)
        var heap = Heap()
        for side in Side.allCases {
            guard
                let door = doorway(
                    line.from, side, xs: xs, ys: ys, stub: stub, blocking: blocking)
            else { continue }
            let state = (door.y * width + door.x) * 4 + side.rawValue
            let length = hypot(xs[door.x] - door.port.x, ys[door.y] - door.port.y)
            if length < cost[state] {
                cost[state] = length
                startSide[state] = side.rawValue
                heap.push(state, length)
            }
        }
        var arrivals: [Int: [(side: Side, length: CGFloat, port: CGPoint)]] = [:]
        for side in Side.allCases {
            guard
                let door = doorway(line.to, side, xs: xs, ys: ys, stub: stub, blocking: blocking)
            else { continue }
            arrivals[door.y * width + door.x, default: []].append(
                (side, hypot(xs[door.x] - door.port.x, ys[door.y] - door.port.y), door.port))
        }
        let steps: [(dx: Int, dy: Int)] = [(1, 0), (0, 1), (-1, 0), (0, -1)]
        while let (state, spent) = heap.pop() {
            guard spent <= cost[state] else { continue }
            if state >= goals { break }
            let index = state / 4
            let heading = state % 4
            for (side, length, _) in arrivals[index] ?? [] {
                // Coming in against the side's outward direction is coming
                // straight in; anything else turns once more at the door, and
                // arriving the way out would double back.
                let inward = (side.rawValue + 2) % 4
                guard heading != side.rawValue else { continue }
                let total = spent + length + (heading == inward ? 0 : bend)
                let goal = goals + side.rawValue
                if total < cost[goal] {
                    cost[goal] = total
                    parent[goal] = state
                    startSide[goal] = startSide[state]
                    heap.push(goal, total)
                }
            }
            let x = index % width
            let y = index / width
            for (direction, step) in steps.enumerated() where direction != (heading + 2) % 4 {
                let nx = x + step.dx
                let ny = y + step.dy
                guard nx >= 0, nx < width, ny >= 0, ny < ys.count else { continue }
                let next = ny * width + nx
                guard free(next) else { continue }
                let total =
                    spent + hypot(xs[nx] - xs[x], ys[ny] - ys[y])
                    + (direction == heading ? 0 : bend)
                    + bend
                    * CGFloat(
                        walked.filter {
                            cut(point(index), point(next), $0.0, $0.1)
                        }.count)
                let nextState = next * 4 + direction
                if total < cost[nextState] {
                    cost[nextState] = total
                    parent[nextState] = state
                    startSide[nextState] = startSide[state]
                    heap.push(nextState, total)
                }
            }
        }
        guard let goal = (goals..<(goals + 4)).min(by: { cost[$0] < cost[$1] }),
            cost[goal] < .infinity, let end = Side(rawValue: goal - goals),
            let start = Side(rawValue: startSide[goal])
        else { return nil }
        var points = [end.centre(of: line.to)]
        var walkBack = parent[goal]
        while walkBack >= 0 {
            points.append(point(walkBack / 4))
            walkBack = parent[walkBack]
        }
        points.append(start.centre(of: line.from))
        return (straightened(points.reversed()), start, end)
    }

    /// Whether a step lands across a run already walked: it comes in at a
    /// right angle to the run, onto a point inside it. Every run lies on grid
    /// lines, so two lines can only meet at a grid point, and this is where.
    private static func cut(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        let level = abs(a.y - b.y) < 0.01
        guard level != (abs(c.y - d.y) < 0.01) else { return false }
        if level {
            return abs(b.x - c.x) < 0.01 && b.y > min(c.y, d.y) + 0.01
                && b.y < max(c.y, d.y) - 0.01
        }
        return abs(b.y - c.y) < 0.01 && b.x > min(c.x, d.x) + 0.01 && b.x < max(c.x, d.x) - 0.01
    }

    /// The same run with every point that does not turn taken out.
    private static func straightened(_ points: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for point in points {
            if let last = out.last, abs(last.x - point.x) < 0.01, abs(last.y - point.y) < 0.01 {
                continue
            }
            if out.count >= 2 {
                let a = out[out.count - 2]
                let b = out[out.count - 1]
                if (abs(a.x - b.x) < 0.01 && abs(b.x - point.x) < 0.01)
                    || (abs(a.y - b.y) < 0.01 && abs(b.y - point.y) < 0.01)
                {
                    out[out.count - 1] = point
                    continue
                }
            }
            out.append(point)
        }
        return out
    }

    private struct Key: Hashable {
        var x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, side: Int
    }

    /// Lines meeting one side of a box are given points of their own along it.
    /// Lines turning one way stand on that side of the ones turning the other,
    /// and of two turning the same way, the one that runs further out before
    /// it turns takes the outer point — so the lines nest instead of crossing
    /// at the door. Tracks are spread first, so how far out each line runs is
    /// already known.
    private static func spreadPorts(
        _ routes: inout [[CGPoint]?], sides: [(start: Side, end: Side)?], lines: [Line],
        spacing: CGFloat
    ) {
        var groups: [Key: [(route: Int, atStart: Bool, order: CGFloat)]] = [:]
        for (index, route) in routes.enumerated() {
            guard let route, route.count >= 2, let side = sides[index] else { continue }
            for atStart in [true, false] {
                let box = atStart ? lines[index].from : lines[index].to
                let which = atStart ? side.start : side.end
                // The line read from this door outwards.
                let out = atStart ? route : route.reversed()
                var order: CGFloat = 0
                if out.count >= 3 {
                    let along = which.horizontal ? out[2].x - out[1].x : out[2].y - out[1].y
                    let depth =
                        which.horizontal ? abs(out[1].y - out[0].y) : abs(out[1].x - out[0].x)
                    // A big step for the way it turns, a small one for how far
                    // out it turns: deeper is outer on the side it turns to.
                    order = along.turn * (100_000 - depth)
                }
                groups[
                    Key(
                        x: box.minX, y: box.minY, width: box.width, height: box.height,
                        side: which.rawValue),
                    default: []
                ].append((index, atStart, order))
            }
        }
        for (key, members) in groups where members.count > 1 {
            let side = Side(rawValue: key.side)!
            let room = (side.horizontal ? key.width : key.height) * 0.8
            let gap = min(spacing, room / CGFloat(members.count - 1))
            let sorted = members.sorted { ($0.order, $0.route) < ($1.order, $1.route) }
            for (rank, member) in sorted.enumerated() {
                let offset = (CGFloat(rank) - CGFloat(members.count - 1) / 2) * gap
                guard var route = routes[member.route] else { continue }
                // A straight line moves its far end with it, or it would slant.
                let ends =
                    route.count == 2
                    ? [0, 1] : member.atStart ? [0, 1] : [route.count - 1, route.count - 2]
                for end in ends {
                    if side.horizontal { route[end].x += offset } else { route[end].y += offset }
                }
                routes[member.route] = route
            }
        }
    }

    /// Lines that run along the same stretch of one gap are moved apart onto
    /// tracks of their own. The stretches next to a box are left alone: those
    /// are the doors, already spread along their sides.
    private static func spreadTracks(_ routes: inout [[CGPoint]?], spacing: CGFloat) -> Int {
        struct Run {
            var route: Int
            var segment: Int
            var at: CGFloat
            var low: CGFloat
            var high: CGFloat
            var order: CGFloat
        }
        var most = 1
        var moves: [(route: Int, segment: Int, level: Bool, by: CGFloat)] = []
        for level in [true, false] {
            var runs: [Run] = []
            for (index, route) in routes.enumerated() {
                guard let route, route.count >= 4 else { continue }
                for segment in 1..<(route.count - 2) {
                    let a = route[segment]
                    let b = route[segment + 1]
                    let isLevel = abs(a.y - b.y) < 0.01
                    guard isLevel == level else { continue }
                    // Which way the line turns at either end of the run: a line
                    // turning down at both ends belongs lower. Of two turning
                    // the same way, the shorter run stands nearer the way they
                    // turn, inside the longer one, the way brackets nest.
                    let before = route[segment - 1]
                    let after = route[segment + 2]
                    let turns =
                        level
                        ? (before.y - a.y).turn + (after.y - b.y).turn
                        : (before.x - a.x).turn + (after.x - b.x).turn
                    let span = level ? abs(b.x - a.x) : abs(b.y - a.y)
                    let order = turns * 100_000 - turns.turn * span
                    runs.append(
                        Run(
                            route: index, segment: segment, at: level ? a.y : a.x,
                            low: level ? min(a.x, b.x) : min(a.y, b.y),
                            high: level ? max(a.x, b.x) : max(a.y, b.y), order: order))
                }
            }
            runs.sort { ($0.at, $0.low) < ($1.at, $1.low) }
            var start = 0
            while start < runs.count {
                var end = start + 1
                var reach = runs[start].high
                while end < runs.count, abs(runs[end].at - runs[start].at) < 0.5,
                    runs[end].low < reach - 0.5
                {
                    reach = max(reach, runs[end].high)
                    end += 1
                }
                let group = runs[start..<end].sorted { ($0.order, $0.route) < ($1.order, $1.route) }
                if Set(group.map(\.route)).count > 1 {
                    most = max(most, group.count)
                    for (rank, run) in group.enumerated() {
                        let offset = (CGFloat(rank) - CGFloat(group.count - 1) / 2) * spacing
                        moves.append((run.route, run.segment, level, offset))
                    }
                }
                start = end
            }
        }
        for move in moves {
            guard var route = routes[move.route] else { continue }
            for end in [move.segment, move.segment + 1] {
                if move.level { route[end].y += move.by } else { route[end].x += move.by }
            }
            routes[move.route] = route
        }
        return most
    }
}

extension CGFloat {
    fileprivate var turn: CGFloat { self > 0.01 ? 1 : self < -0.01 ? -1 : 0 }
}

/// A binary min-heap of states by cost.
private struct Heap {
    private var items: [(state: Int, cost: CGFloat)] = []

    mutating func push(_ state: Int, _ cost: CGFloat) {
        items.append((state, cost))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].cost < items[parent].cost else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> (Int, CGFloat)? {
        guard let first = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var parent = 0
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var smallest = parent
                if left < items.count, items[left].cost < items[smallest].cost { smallest = left }
                if right < items.count, items[right].cost < items[smallest].cost {
                    smallest = right
                }
                guard smallest != parent else { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }
        }
        return (first.state, first.cost)
    }
}
