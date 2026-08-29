import XCTest

/// `Loupe.stop()`, driven through a real app.
///
/// A `UIWindow` shown in a scene is retained by the scene, not by whoever made it -
/// so dropping the last reference to the overlay's host deallocated the host and left
/// the window exactly where it was, with nothing behind it driving it. Somebody
/// turned annotate mode off from their own app's menu and the pill stayed on screen.
///
/// No unit test can ask this. The overlay's host needs a real `UIWindowScene`, and
/// what went wrong was who was holding the window afterwards.
final class TeardownTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--offer-teardown", "--fresh-session"]
        app.launch()
    }

    func testTurningLoupeOffTakesTheOverlayWithIt() {
        let pill = app.buttons["Start annotating"]
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "the overlay should be up first")

        app.buttons["Turn Loupe off"].tap()

        XCTAssertTrue(pill.waitForNonExistence(timeout: 5),
                      "stop() has to take the window down, not just drop its owner")
    }

    /// And the app underneath must be usable afterwards. A hidden window that still
    /// belongs to the scene can keep swallowing touches.
    func testTheAppStillWorksOnceLoupeIsGone() {
        XCTAssertTrue(app.buttons["Start annotating"].waitForExistence(timeout: 5))
        app.buttons["Turn Loupe off"].tap()
        XCTAssertTrue(app.buttons["Start annotating"].waitForNonExistence(timeout: 5))

        let search = app.textFields["Search stock"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        XCTAssertTrue(search.hasKeyboardFocus, "the app is theirs again")
    }
}

private extension XCUIElement {
    var hasKeyboardFocus: Bool {
        (value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }
}
