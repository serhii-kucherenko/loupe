import XCTest

/// SER-718, in a real app.
///
/// A `WKWebView` renders its content in a separate process and hands the result to
/// the compositor. `drawHierarchy(in:afterScreenUpdates:)` draws what *this* process
/// knows how to draw, so the web content is not in it - what comes back is whatever
/// was last composited into our own layers. On a screen somebody has just navigated
/// to, that is the screen they came from. Annotating inside a book produced a
/// picture of the shelf.
///
/// **A picture of the wrong screen is worse than no picture.** It is confidently
/// wrong and whoever reads the ticket has no way to tell.
///
/// This has to be a UI test, and the first attempt at it was not. A unit-test bundle
/// with no app host has no render server: a plain blue view came back empty there
/// too, so the failure said nothing about web views at all. A test that fails for
/// the wrong reason is not a reproduction.
final class WebViewCaptureTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--capture-readout", "--fresh-session"]
        app.launch()
    }

    /// **SER-718, reproduced.** The Reco session read it off a real bundle: annotate
    /// a page inside an open book and the context shot is the library, with the
    /// highlight over empty space below the last row of covers.
    ///
    /// It is not a web view problem, which is where two nights of theory went. The
    /// hit test asks `window.hitTest` and sees the presented screen; the render drew
    /// `window.rootViewController.view`, which does not contain a view controller
    /// presented over it. So the walk and the render disagreed about which screen was
    /// on screen, and only the render was wrong.
    ///
    /// Here the book is a `fullScreenCover` over the reader, and its page is flat
    /// blue. If the capture comes back anything else, it is the screen underneath.
    func testCapturingInsideAPresentedScreenGetsThatScreen() {
        app.buttons["Reader"].tap()
        app.buttons["Open the book"].tap()
        XCTAssertTrue(app.staticTexts["book.chapter"].waitForExistence(timeout: 5),
                      "the book has to actually be open")

        let readout = app.staticTexts["book.capture"]
        XCTAssertTrue(readout.waitForExistence(timeout: 5))
        let done = NSPredicate(format: "label BEGINSWITH 'context '")
        expectation(for: done, evaluatedWith: readout)
        waitForExpectations(timeout: 20)

        let label = readout.label
        XCTAssertTrue(label.contains("0,0,255") || label.contains("0,0,254"),
                      "the picture is the screen underneath, not the one being read "
                      + "- got \(label)")
    }

    /// The web view case, kept and skipped.
    ///
    /// A flat red page cannot tell a fixed capture from a broken one: change it and
    /// capture at once and `drawHierarchy`, `takeSnapshot` and Loupe's own capture all
    /// return the old colour while JavaScript reports the new one. That is a real
    /// thing worth understanding, and it is not what SER-718 was.
    func testCapturingAWebViewGetsTheWebViewsCurrentPixels() throws {
        throw XCTSkip("a flat page cannot tell a fixed capture from a broken one")
    }
}
