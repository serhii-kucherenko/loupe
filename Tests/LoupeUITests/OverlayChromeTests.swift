import XCTest
import LoupeCore
@testable import LoupeUI

/// Where Loupe's own controls are, and when the tray is on screen.
///
/// Both were reported repeatedly and neither had a test. "annotate sidepanel doesn't
/// appear when I enter annotate mode unless I create/save a new annotation" went out
/// four times, and "Button done isn't draggle too - which is bad, for when I want to
/// annotate smth that overlays with that button" twice.
@MainActor
final class OverlayChromeTests: XCTestCase {

    private func model() -> OverlayModel {
        OverlayModel(session: AnnotationSession(
            app: AppInfo(name: "Test", version: "1", platform: "test"),
            transport: NullTransport()))
    }

    private struct NullTransport: Transport {
        func send(_ bundle: AnnotationBundle) async throws {}
    }

    private func ref(_ id: String) -> ElementRef {
        ElementRef(accessibilityID: id, bounds: Rect(x: 0, y: 0, width: 10, height: 10))
    }

    private func saveANote(_ m: OverlayModel, _ text: String = "a note") {
        m.pick(ref("row"))
        m.saveComment(text, tag: nil)
    }

    // MARK: - The tray is opened, and never opens itself

    func testTheTrayStartsCollapsed() {
        let m = model()
        m.beginAnnotating()
        XCTAssertFalse(m.trayExpanded)
    }

    /// The whole complaint. Saving a note used to be the only thing that put the tray
    /// on screen, and it did so without being asked.
    func testSavingANoteDoesNotOpenTheTray() {
        let m = model()
        m.beginAnnotating()
        saveANote(m)

        XCTAssertEqual(m.mode, .browsing)
        XCTAssertFalse(m.trayExpanded, "the layout must not change under someone's hands")
        XCTAssertEqual(m.annotations.count, 1, "only the count moves")
    }

    /// The other half: it has to be reachable before there is anything in it.
    func testTheTrayCanBeOpenedWithNoNotesAtAll() {
        let m = model()
        m.beginAnnotating()
        m.toggleTray()

        XCTAssertTrue(m.trayExpanded)
        XCTAssertTrue(m.annotations.isEmpty)
    }

    func testTheTrayClosesAgain() {
        let m = model()
        m.beginAnnotating()
        m.toggleTray()
        m.toggleTray()
        XCTAssertFalse(m.trayExpanded)
    }

    /// A session that ended with the tray open must not begin with it open, or the
    /// first thing the next session does is change the layout.
    func testANewSessionStartsCollapsed() {
        let m = model()
        m.beginAnnotating()
        m.toggleTray()
        m.endAnnotating()
        XCTAssertFalse(m.trayExpanded)

        m.beginAnnotating()
        XCTAssertFalse(m.trayExpanded)
    }

    func testLeavingAnnotateModeClosesTheTray() {
        let m = model()
        m.beginAnnotating()
        m.toggleTray()
        m.toggleAnnotating()

        XCTAssertEqual(m.mode, .off)
        XCTAssertFalse(m.trayExpanded)
    }

    // MARK: - The pull moves along the edge

    func testThePullStartsHalfwayDownAndStaysWhereItIsPut() {
        let m = model()
        XCTAssertEqual(m.handle.fraction, 0.5, accuracy: 0.001)

        m.moveHandle(toFraction: 0.2)
        XCTAssertEqual(m.handle.fraction, 0.2, accuracy: 0.001)
    }

    /// Someone who moved it off the thing they were annotating should not have to
    /// move it again on the next pick, or on the next session.
    func testTheHandlePositionSurvivesPicksAndSessions() {
        let m = model()
        m.beginAnnotating()
        m.moveHandle(toFraction: 0.25)

        saveANote(m)
        XCTAssertEqual(m.handle.fraction, 0.25, accuracy: 0.001)

        m.endAnnotating()
        m.beginAnnotating()
        XCTAssertEqual(m.handle.fraction, 0.25, accuracy: 0.001,
                       "moving it once should be enough")
    }

    /// It must not slide under a notch or a home indicator, neither of which it can
    /// see from where it is.
    func testThePullCannotBeDraggedOffEitherEndOfTheEdge() {
        let m = model()
        m.moveHandle(toFraction: -5)
        XCTAssertEqual(m.handle.fraction, DrawerHandle.margin, accuracy: 0.001)

        m.moveHandle(toFraction: 5)
        XCTAssertEqual(m.handle.fraction, 1 - DrawerHandle.margin, accuracy: 0.001)
    }

    func testAPointOnTheEdgeBecomesAFraction() {
        XCTAssertEqual(DrawerHandle.fraction(forY: 400, in: 800), 0.5, accuracy: 0.001)
        XCTAssertEqual(DrawerHandle.fraction(forY: 200, in: 800), 0.25, accuracy: 0.001)
        // Clamped on the way in, not only on the way out.
        XCTAssertEqual(DrawerHandle.fraction(forY: 0, in: 800),
                       DrawerHandle.margin, accuracy: 0.001)
    }

    /// A view reports a zero size for one frame before layout has happened, and a
    /// drag that ended in that frame must still resolve to something usable.
    func testAZeroHeightWindowStillResolves() {
        XCTAssertEqual(DrawerHandle.fraction(forY: 10, in: 0), 0.5, accuracy: 0.001)
        XCTAssertEqual(DrawerHandle().centreY(in: 0), 0)
    }

    func testTheCentreFollowsTheWindowHeight() {
        let handle = DrawerHandle(fraction: 0.25)
        XCTAssertEqual(handle.centreY(in: 800), 200, accuracy: 0.001)
        // The same fraction, a rotated window: proportional, so it cannot end up off
        // screen the way a stored point would.
        XCTAssertEqual(handle.centreY(in: 1200), 300, accuracy: 0.001)
    }
}
