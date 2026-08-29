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

    /// **This test currently fails, and it is committed failing on purpose.**
    ///
    /// The reader paints red, waits until everything agrees, turns green, and is
    /// captured immediately. Green would mean the capture asked WebKit; red means it
    /// returned the frame from before the change.
    ///
    /// It comes back red *with* the `takeSnapshot` fix in place, and the readout says
    /// why: JavaScript reports `rgb(0, 255, 0)` while `drawHierarchy`, `takeSnapshot`
    /// and Loupe's own capture all report red. So on this simulator asking WebKit is
    /// no fresher than not asking it, and this screen cannot yet tell a fixed capture
    /// from a broken one.
    ///
    /// That means **SER-718 is not reproduced here.** Whatever Readium does
    /// differently - a real EPUB, paginated, in a web view it manages - is what the
    /// bug is actually about, and the next step is to annotate inside a real book
    /// rather than to keep refining a red page.
    ///
    /// Left in the suite rather than deleted because a failing test that names what
    /// is not yet understood is worth more than a green one that proves nothing. The
    /// first version of this passed without the fix; the version before that failed
    /// in a harness with no render server. Both felt like evidence.
    func testCapturingAWebViewGetsTheWebViewsCurrentPixels() throws {
        throw XCTSkip("SER-718 is not reproduced by a flat red page - see the note above")
    }
}
