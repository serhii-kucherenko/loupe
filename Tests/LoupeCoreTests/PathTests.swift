import XCTest
@testable import LoupeCore

/// A drawn shape is the one pick that says "these things, and not the things between
/// them". Everything here is about it still meaning that after it has been thinned,
/// stored, and read back by something that has never heard of a path.
final class PathTests: XCTestCase {

    private func line(from a: Point, to b: Point, steps: Int) -> [Point] {
        (0...steps).map { i in
            let t = Double(i) / Double(steps)
            return Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    /// A circle, the way a finger actually draws one: a point per frame.
    private func circle(centre: Point, radius: Double, points: Int) -> [Point] {
        (0..<points).map { i in
            let angle = 2 * Double.pi * Double(i) / Double(points)
            return Point(x: centre.x + radius * cos(angle),
                         y: centre.y + radius * sin(angle))
        }
    }

    // MARK: - Thinning

    func testAStraightRunCollapsesToItsEnds() {
        let drawn = line(from: Point(x: 0, y: 0), to: Point(x: 300, y: 0), steps: 200)
        let kept = LoupePath.simplified(drawn)

        XCTAssertEqual(kept.count, 2, "201 points on one line say nothing 2 do not")
        XCTAssertEqual(kept.first, drawn.first)
        XCTAssertEqual(kept.last, drawn.last)
    }

    func testACornerSurvives() {
        let down = line(from: Point(x: 0, y: 0), to: Point(x: 0, y: 100), steps: 50)
        let across = line(from: Point(x: 0, y: 100), to: Point(x: 100, y: 100), steps: 50)
        let kept = LoupePath.simplified(down + across.dropFirst())

        XCTAssertEqual(kept.count, 3, "two ends and the corner between them")
        XCTAssertTrue(kept.contains(Point(x: 0, y: 100)), "the corner is the shape")
    }

    /// The point of thinning is bytes, and it has to buy them without changing what
    /// the person drew.
    func testAHandDrawnShapeLosesPointsAndKeepsItsShape() {
        let drawn = circle(centre: Point(x: 200, y: 200), radius: 80, points: 400)
        let kept = LoupePath.simplified(drawn)

        XCTAssertLessThan(kept.count, drawn.count / 4, "most of those points were noise")
        XCTAssertGreaterThan(kept.count, 8, "and it is still recognisably a circle")

        // Two points of tolerance means the box may shrink by about that much, and
        // no more. A shape that moved further than the stroke is drawn with is a
        // different shape.
        let before = LoupePath.bounds(drawn)
        let after = LoupePath.bounds(kept)
        XCTAssertEqual(after.width, before.width, accuracy: 4)
        XCTAssertEqual(after.height, before.height, accuracy: 4)
    }

    func testTheEndsAreNeverDropped() {
        let drawn = circle(centre: Point(x: 50, y: 50), radius: 30, points: 60)
        let kept = LoupePath.simplified(drawn)

        XCTAssertEqual(kept.first, drawn.first)
        XCTAssertEqual(kept.last, drawn.last)
    }

    /// A closed shape ends where it started, so the line through its two ends has no
    /// length at all and the usual distance formula divides by zero. It is also the
    /// normal case here, not an edge case.
    func testAShapeThatEndsWhereItStartedIsNotThrownAway() {
        var drawn = circle(centre: Point(x: 100, y: 100), radius: 40, points: 80)
        drawn.append(drawn[0])

        let kept = LoupePath.simplified(drawn)
        XCTAssertGreaterThan(kept.count, 6)
        XCTAssertTrue(kept.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    func testTooFewPointsToThinAreLeftAlone() {
        let two = [Point(x: 0, y: 0), Point(x: 10, y: 10)]
        XCTAssertEqual(LoupePath.simplified(two), two)
        XCTAssertEqual(LoupePath.simplified([]), [])
    }

    // MARK: - The bounding box, which is what everything else reads

    func testBoundsIsTheSmallestBoxHoldingEveryPoint() {
        let drawn = [Point(x: 10, y: 40), Point(x: 90, y: 20), Point(x: 50, y: 100)]
        XCTAssertEqual(LoupePath.bounds(drawn),
                       Rect(x: 10, y: 20, width: 80, height: 80))
    }

    func testBoundsOfNothingIsEmptyRatherThanACrash() {
        XCTAssertEqual(LoupePath.bounds([]), Rect(x: 0, y: 0, width: 0, height: 0))
    }

    // MARK: - Telling a shape from a slipped finger

    func testATapThatMovedALittleIsNotAShape() {
        let slip = [Point(x: 100, y: 100), Point(x: 103, y: 101), Point(x: 104, y: 104)]
        XCTAssertFalse(LoupePath.isUsable(slip), "4pt across is a tap, not a lasso")
    }

    func testTwoPointsAreNeverAShape() {
        XCTAssertFalse(LoupePath.isUsable([Point(x: 0, y: 0), Point(x: 200, y: 200)]))
    }

    /// A shape drawn down a column of rows is tall and narrow and completely valid,
    /// so neither side can carry a minimum. What it must have is an inside.
    func testALongThinShapeIsAShape() {
        let column = [Point(x: 100, y: 0), Point(x: 130, y: 10), Point(x: 128, y: 400),
                      Point(x: 98, y: 390)]
        XCTAssertTrue(LoupePath.isUsable(column))
    }

    /// The one every single-segment gesture produces, and therefore most accidents.
    /// Its bounding box is a hundred points wide and it encloses nothing at all, so
    /// any box measure calls it a fine shape and the crop comes out blank.
    func testAStraightSwipeEnclosesNothingAndIsNotAShape() {
        let swipe = line(from: Point(x: 40, y: 300), to: Point(x: 340, y: 300), steps: 30)
        XCTAssertFalse(LoupePath.isUsable(swipe))

        let diagonal = line(from: Point(x: 0, y: 0), to: Point(x: 200, y: 200), steps: 30)
        XCTAssertFalse(LoupePath.isUsable(diagonal),
                       "a diagonal has a big box and no inside either")
    }

    func testAreaIsTheSameWhicheverWayRoundItWasDrawn() {
        let clockwise = [Point(x: 0, y: 0), Point(x: 100, y: 0),
                         Point(x: 100, y: 50), Point(x: 0, y: 50)]
        XCTAssertEqual(LoupePath.area(clockwise), 5000, accuracy: 0.001)
        XCTAssertEqual(LoupePath.area(clockwise.reversed()), 5000, accuracy: 0.001)
    }

    /// A hand-drawn circle is the actual case, and it must clear the bar comfortably
    /// rather than by a hair.
    func testACircleSomebodyDrewIsAShape() {
        XCTAssertTrue(LoupePath.isUsable(
            circle(centre: Point(x: 200, y: 200), radius: 30, points: 60)))
        XCTAssertFalse(LoupePath.isUsable(
            circle(centre: Point(x: 200, y: 200), radius: 8, points: 60)),
            "a circle the size of a fingertip is a tap that wobbled")
    }

    // MARK: - Which things were circled

    func testAPointInsideTheShapeIsInside() {
        let square = [Point(x: 0, y: 0), Point(x: 100, y: 0),
                      Point(x: 100, y: 100), Point(x: 0, y: 100)]
        XCTAssertTrue(LoupePath.contains(Point(x: 50, y: 50), in: square))
        XCTAssertFalse(LoupePath.contains(Point(x: 150, y: 50), in: square))
        XCTAssertFalse(LoupePath.contains(Point(x: 50, y: -1), in: square))
    }

    /// The whole reason a rectangle is not enough. A C-shape drawn around two things
    /// must not claim the gap it deliberately went around.
    func testTheGapAShapeGoesAroundIsNotInsideIt() {
        let cShape = [
            Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 20),
            Point(x: 20, y: 20), Point(x: 20, y: 80), Point(x: 100, y: 80),
            Point(x: 100, y: 100), Point(x: 0, y: 100),
        ]
        XCTAssertTrue(LoupePath.contains(Point(x: 10, y: 50), in: cShape),
                      "the spine of the C")
        XCTAssertFalse(LoupePath.contains(Point(x: 60, y: 50), in: cShape),
                       "the mouth of the C is exactly what was excluded")
    }
}
