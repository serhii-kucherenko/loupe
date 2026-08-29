import XCTest

/// The lasso, driven by a real finger.
///
/// The maths of a drawn shape is covered by unit tests, which is the right place for
/// it. What no unit test can ask is whether the touch ever arrives, and whether the
/// tool control in front of it actually changes what a drag does - the two things
/// that have gone wrong on this overlay before, both times with a green suite.
///
/// What XCUITest cannot do is trace a curve: a synthetic drag is one straight
/// segment. That turns out to be the useful case anyway, because a straight segment
/// encloses nothing, and "a gesture that selected nothing must still pick something"
/// is the rule that makes Draw safe to be stuck in.
final class DrawToolUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["scene=zero"]
        app.launch()
    }

    private var point: XCUIElement { app.buttons["Point: tap an element"] }
    private var box: XCUIElement { app.buttons["Box: drag a rectangle"] }
    private var draw: XCUIElement { app.buttons["Draw: trace a shape around several things"] }

    /// Somewhere in the app, well clear of the drawer's pull on the trailing edge.
    private func inTheApp(_ dx: Double, _ dy: Double) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
    }

    // MARK: - The control is the feature

    /// SER-696 raised itself to urgent for this: "also, no way to switch selection
    /// modes". Two of the three gestures already worked and nothing on screen said
    /// so, which reads as one mode with a hidden second one.
    func testAllThreeToolsAreOnScreenWhilePicking() {
        XCTAssertTrue(point.waitForExistence(timeout: 5))
        XCTAssertTrue(box.exists)
        XCTAssertTrue(draw.exists, "the lasso is not findable if it is not drawn")
    }

    func testPointIsLitToBeginWith() {
        XCTAssertTrue(point.waitForExistence(timeout: 5))
        XCTAssertTrue(point.isSelected, "and it stays the default")
        XCTAssertFalse(draw.isSelected)
    }

    func testChoosingDrawLightsItAndNothingElse() {
        XCTAssertTrue(draw.waitForExistence(timeout: 5))
        draw.tap()

        XCTAssertTrue(draw.isSelected)
        XCTAssertFalse(point.isSelected)
        XCTAssertFalse(box.isSelected)
    }

    // MARK: - Draw locks the drag, and a tap is the way out

    /// A swipe has a bounding box a hundred points wide and encloses nothing at all,
    /// so it is not a shape however far it travelled. It must still produce a note -
    /// refusing would lose the gesture and explain nothing - and it must not be
    /// recorded as a shape, because the crop of a shape with no inside is a rectangle
    /// of blank ground.
    ///
    /// What this cannot tell you is *which* fallback ran. In Draw the swipe becomes a
    /// tap-pick at its start; under Box the same swipe is refused for being too thin
    /// and also becomes a tap-pick. The two converge here, and on this demo a tap
    /// often resolves to a region anyway - SwiftUI on iOS backs almost nothing with a
    /// real view. The positive case, a shape that does enclose something, is covered
    /// in `PathTests` and `MaskedCropTests`, because XCUITest cannot trace a curve:
    /// a synthetic drag is one straight segment.
    func testASwipeThatEnclosesNothingIsNeverRecordedAsAShape() {
        XCTAssertTrue(draw.waitForExistence(timeout: 5))
        draw.tap()

        let from = inTheApp(0.25, 0.45)
        from.press(forDuration: 0.1,
                   thenDragTo: inTheApp(0.7, 0.45),
                   withVelocity: .slow,
                   thenHoldForDuration: 0.1)

        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5),
                      "a gesture that selected nothing must still leave a note open")
        XCTAssertFalse(app.staticTexts["Shape"].exists,
                       "and it must not be recorded as a shape it never was")
    }

    /// The escape. Draw is the one tool somebody can be stuck in, so a tap has to
    /// keep working and has to actually leave - a Draw still lit after a tap-pick
    /// would put the very next drag back into a shape nobody asked for.
    func testATapPicksAnElementAndLeavesDraw() {
        XCTAssertTrue(draw.waitForExistence(timeout: 5))
        draw.tap()
        XCTAssertTrue(draw.isSelected)

        inTheApp(0.4, 0.45).tap()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5),
                      "a tap picks in every tool")

        app.buttons["Cancel"].tap()
        XCTAssertTrue(point.waitForExistence(timeout: 3))
        XCTAssertTrue(point.isSelected, "the tap said which tool was meant")
        XCTAssertFalse(draw.isSelected)
    }

    /// Box must be unaffected by any of this. A drag with Box lit is still a
    /// rectangle, and the tool that locks must lock only itself.
    func testADragWithBoxLitIsStillARectangle() {
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        box.tap()

        inTheApp(0.25, 0.4).press(forDuration: 0.1,
                                  thenDragTo: inTheApp(0.65, 0.6),
                                  withVelocity: .slow,
                                  thenHoldForDuration: 0.1)

        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Region"].exists,
                      "a dragged rectangle is a region, not a shape")
    }
}
