import XCTest

/// The drawer's pull, driven by a real finger.
///
/// Everything else about the overlay is checked by pushing the model around, which
/// proves the model and nothing else. That is exactly how the pill and the whole tray
/// came to be untappable on iOS with a green suite (SER-682): a `UIHostingController`
/// is one `UIView`, so whether a touch ever arrives is a question no unit test can
/// ask. These tests use the touch.
final class DrawerPullTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(scene: String) {
        app.launchArguments = ["scene=\(scene)"]
        app.launch()
    }

    /// The pull, by the label it carries for VoiceOver. Matching on the label rather
    /// than an identifier keeps the two honest: if the label stops describing the
    /// thing, this stops finding it.
    private func pull(notes: Int, open: Bool = false) -> XCUIElement {
        let count = notes == 1 ? "1 note" : "\(notes) notes"
        return app.buttons["\(open ? "Hide" : "Show") notes, \(count)"]
    }

    // MARK: - It is there

    /// The whole of SER-700 and half of SER-693: it has to be on screen before there
    /// is anything in it, because the way to the settings that decide where notes go
    /// is inside it.
    func testThePullIsOnScreenAtZeroNotes() {
        launch(scene: "zero")
        XCTAssertTrue(pull(notes: 0).waitForExistence(timeout: 5),
                      "annotate mode must leave a way into the drawer")
    }

    func testTappingThePullOpensAndClosesTheDrawer() {
        launch(scene: "zero")
        let shut = pull(notes: 0)
        XCTAssertTrue(shut.waitForExistence(timeout: 5))
        shut.tap()

        XCTAssertTrue(app.buttons["Finish annotating"].waitForExistence(timeout: 3),
                      "the drawer carries the way out of annotate mode")

        pull(notes: 0, open: true).tap()
        XCTAssertTrue(app.buttons["Finish annotating"].waitForNonExistence(timeout: 3),
                      "and it shuts again")
    }

    // MARK: - It moves

    /// "also that handler should be draggeble as sometimes I might need to move it as
    /// it might be blocking element I need to annotate". This is the only kind of test
    /// that can answer that, because the question is whether the touch arrives.
    func testDraggingThePullAlongTheEdgeMovesIt() {
        launch(scene: "zero")
        let handle = pull(notes: 0)
        XCTAssertTrue(handle.waitForExistence(timeout: 5))

        let before = handle.frame
        handle.drag(dy: -260)

        let after = pull(notes: 0).frame
        XCTAssertLessThan(after.midY, before.midY - 100,
                          "the pull must follow the finger up the edge")
        XCTAssertEqual(after.midX, before.midX, accuracy: 2,
                       "and must not wander off the edge while doing it")
    }

    func testDraggingItBackDownMovesItBack() {
        launch(scene: "zero")
        let handle = pull(notes: 0)
        XCTAssertTrue(handle.waitForExistence(timeout: 5))

        let start = handle.frame
        handle.drag(dy: -240)
        let up = pull(notes: 0).frame
        XCTAssertLessThan(up.midY, start.midY - 80)

        pull(notes: 0).drag(dy: 240)
        let back = pull(notes: 0).frame
        XCTAssertGreaterThan(back.midY, up.midY + 80, "it has to come back down too")
    }

    /// It must not slide under a home indicator or a notch, neither of which it can
    /// see from where it is.
    func testThePullCannotBeDraggedOffTheScreen() {
        launch(scene: "zero")
        let handle = pull(notes: 0)
        XCTAssertTrue(handle.waitForExistence(timeout: 5))

        handle.drag(dy: -900)
        let top = pull(notes: 0).frame
        XCTAssertGreaterThan(top.minY, 0, "still on screen")

        pull(notes: 0).drag(dy: 1800)
        let bottom = pull(notes: 0).frame
        XCTAssertLessThan(bottom.maxY, app.frame.height, "still on screen")
    }

    /// A drag away from the edge is the gesture the shape suggests, so it opens.
    func testDraggingAwayFromTheEdgeOpensTheDrawer() {
        launch(scene: "zero")
        let handle = pull(notes: 0)
        XCTAssertTrue(handle.waitForExistence(timeout: 5))

        handle.drag(dx: -200)
        XCTAssertTrue(app.buttons["Finish annotating"].waitForExistence(timeout: 3),
                      "pulling the drawer out should open it")
    }

    // MARK: - It does not eat the app

    /// The pull is small, but `.loupeInteractive()` means it takes every touch that
    /// lands on it. Whatever is beside it must still be reachable, or moving it would
    /// be pointless.
    func testTheAppBesideThePullIsStillUsable() {
        launch(scene: "zero")
        XCTAssertTrue(pull(notes: 0).waitForExistence(timeout: 5))

        // In `.picking` the overlay swallows input on purpose, so this leaves
        // annotate mode and checks the resting state, where it must not. The way out
        // is inside the drawer, which is the point of the pull being the way in.
        pull(notes: 0).tap()
        let done = app.buttons["Finish annotating"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        done.tap()
        let annotate = app.buttons["Start annotating"]
        XCTAssertTrue(annotate.waitForExistence(timeout: 3))

        let search = app.textFields["Search stock"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        XCTAssertTrue(search.hasKeyboardFocus, "the app underneath must still work")
    }
}

private extension XCUIElement {
    /// A drag in points from this element's centre.
    ///
    /// The velocity is named rather than left to XCUITest, which otherwise moves the
    /// touch in so few events that SwiftUI can miss the gesture entirely - the same
    /// drag passed and failed on consecutive runs before this was pinned down. A
    /// person's finger produces many more events than the default synthetic one does.
    func drag(dx: CGFloat = 0, dy: CGFloat = 0) {
        let start = coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1,
                    thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)),
                    withVelocity: .slow,
                    thenHoldForDuration: 0.1)
    }

    var hasKeyboardFocus: Bool {
        (value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }
}
