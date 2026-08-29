import Foundation

/// A point in window coordinates, encoded as `[x, y]`.
///
/// The pair form, not `{"x":…,"y":…}`, and that is the whole reason this type has a
/// hand-written `Codable`. A drawn shape is hundreds of points; the object form
/// spends four times the bytes saying "x" and "y" over and over, in a payload that
/// travels off a phone on whatever network is going.
public struct Point: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
    }
}

/// What a drawn shape is, and what makes one worth keeping.
///
/// Platform-free on purpose: a lasso is the same shape on a Mac, an iPad and a web
/// page, and the rules about what counts as a real one should not be written three
/// times and drift.
public enum LoupePath {

    /// The smallest area a shape can enclose and still mean something, in square
    /// window points. A 20pt square.
    ///
    /// **Area, not the bounding box, and that distinction is the whole rule.** A
    /// lasso says "the things inside this". A straight swipe has a bounding box a
    /// hundred points wide and encloses nothing at all, so by any box measure it is a
    /// fine shape and by the only measure that matters it is empty - and the crop it
    /// produces is a rectangle of blank ground. Every single-segment gesture is that
    /// swipe, which is to say: most accidents.
    public static let leastUsefulArea: Double = 20 * 20

    /// Ramer-Douglas-Peucker, in window points.
    ///
    /// A finger dragged slowly emits a point per frame, so a shape around one card
    /// arrives as several hundred of them, nearly all of which sit on top of each
    /// other. They cost bytes in every bundle and buy nothing: at two points of
    /// tolerance the simplified shape is indistinguishable on screen from the raw
    /// one, and a consumer can draw it with four lines of anything.
    ///
    /// - Parameter tolerance: how far a point may sit from the line through its
    ///   neighbours before it is worth keeping. Two points is about the width of the
    ///   stroke it is drawn with.
    public static func simplified(_ points: [Point], tolerance: Double = 2) -> [Point] {
        guard points.count > 2, tolerance > 0 else { return points }

        // Douglas-Peucker keeps the ends and asks which point in between is furthest
        // from the straight line joining them. If even that one is close enough, the
        // whole run is a straight line and everything between the ends goes.
        let first = points[0]
        let last = points[points.count - 1]
        var furthest = 0
        var distance = 0.0
        for index in 1..<(points.count - 1) {
            let candidate = perpendicularDistance(points[index], from: first, to: last)
            if candidate > distance {
                distance = candidate
                furthest = index
            }
        }

        guard distance > tolerance else { return [first, last] }

        let left = simplified(Array(points[0...furthest]), tolerance: tolerance)
        let right = simplified(Array(points[furthest...]), tolerance: tolerance)
        // `furthest` is the last of the left run and the first of the right, so one
        // copy of it is dropped rather than emitted twice.
        return left.dropLast() + right
    }

    /// The smallest rectangle containing every point.
    ///
    /// This is what `ElementRef.bounds` carries for a drawn shape, and it is the
    /// reason a consumer that has never heard of a path still works: it gets the
    /// rectangle it would have got from a drag, which is the honest degradation.
    public static func bounds(_ points: [Point]) -> Rect {
        guard let first = points.first else {
            return Rect(x: 0, y: 0, width: 0, height: 0)
        }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Whether this is a shape or a mis-fire.
    ///
    /// A tap that moved a little, and a swipe that went straight across, are both
    /// common inside draw mode and neither must become a note with a crop of blank
    /// ground. The caller falls back to picking the element under the first point,
    /// which is what the person almost certainly meant - rather than refusing, which
    /// would lose the gesture entirely and explain nothing.
    ///
    /// No bounding-box test here on purpose. A shape drawn down a column of rows is
    /// tall and narrow and completely valid, so neither side can carry a minimum;
    /// what it must have is an inside.
    public static func isUsable(_ points: [Point]) -> Bool {
        guard points.count >= 3 else { return false }
        return area(points) >= leastUsefulArea
    }

    /// The area the closed shape encloses, by the shoelace formula. Always positive:
    /// which way round somebody drew is not information.
    public static func area(_ points: [Point]) -> Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        var j = points.count - 1
        for i in 0..<points.count {
            sum += (points[j].x + points[i].x) * (points[j].y - points[i].y)
            j = i
        }
        return abs(sum) / 2
    }

    /// Whether a point is inside the closed shape, by the even-odd rule.
    ///
    /// Used to say which elements were circled. Even-odd rather than winding because
    /// a hand-drawn shape crosses itself often, and even-odd is what every renderer
    /// this path will be drawn by does with `[[x, y], …]` and no fill rule stated.
    public static func contains(_ point: Point, in path: [Point]) -> Bool {
        guard path.count >= 3 else { return false }
        var inside = false
        var j = path.count - 1
        for i in 0..<path.count {
            let a = path[i], b = path[j]
            if (a.y > point.y) != (b.y > point.y) {
                let crossing = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < crossing { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    private static func perpendicularDistance(_ point: Point,
                                              from start: Point,
                                              to end: Point) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        // A closed shape starts and ends in the same place, so the "line" through the
        // ends is a single point and the formula below divides by zero. Fall back to
        // plain distance from it, which is the right answer for that case.
        guard dx != 0 || dy != 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let area = abs(dy * point.x - dx * point.y + end.x * start.y - end.y * start.x)
        return area / hypot(dx, dy)
    }
}
