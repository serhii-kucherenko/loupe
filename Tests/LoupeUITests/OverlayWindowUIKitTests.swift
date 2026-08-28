#if canImport(UIKit)
import XCTest
import UIKit
import SwiftUI
import LoupeCore
@testable import LoupeUI

/// Reported from an iPad: with a dialog open, tapping Annotate dismissed the dialog
/// instead of entering annotate mode.
///
/// Three separate faults compound into that one symptom, and each gets a test. None
/// of them may depend on a live `UIWindowScene`: a SwiftPM test bundle runs with no
/// app host, so a test that needs one can only ever skip, and a skipped test protects
/// nothing.
@MainActor
final class OverlayWindowUIKitTests: XCTestCase {

    private func window(level: UIWindow.Level, id: String? = nil) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        window.windowLevel = level
        window.isHidden = false
        if let id {
            let controller = UIViewController()
            controller.view.frame = window.bounds
            let card = UIView(frame: CGRect(x: 20, y: 100, width: 200, height: 80))
            card.accessibilityIdentifier = id
            controller.view.addSubview(card)
            window.rootViewController = controller
        }
        return window
    }

    /// A dialog gets its own window at `.alert`. An overlay at `host.windowLevel + 1`
    /// therefore sat *underneath* it: the pill was behind the dialog, and a tap where
    /// it appeared landed on the dialog's dimming view, which dismissed the dialog.
    func testTheOverlaySitsAboveAlertWindows() {
        XCTAssertGreaterThan(OverlayHost.windowLevel.rawValue, UIWindow.Level.alert.rawValue,
                             "a dialog would sit on top of the overlay and eat the tap")
        XCTAssertGreaterThan(OverlayHost.windowLevel.rawValue, UIWindow.Level.normal.rawValue)
    }

    /// The pick used to hit-test the window captured at `attach` time. A dialog lives
    /// in a different one, so even with the pill reachable you would have annotated
    /// whatever sits behind the thing you were looking at.
    func testPickingFindsTheWindowInFrontRatherThanTheAttachedOne() {
        let behind = window(level: .normal, id: "app.screen")
        let dialog = window(level: .alert, id: "dialog.card")
        let overlay = window(level: OverlayHost.windowLevel)

        let found = WindowFinder.topmost(among: [behind, dialog, overlay], excluding: overlay)
        XCTAssertIdentical(found, dialog,
                           "the person is looking at the dialog, so that is what a pick means")
    }

    /// Loupe's own overlay is never the answer, or a pick would annotate the tool.
    func testTheOverlaysOwnWindowIsNeverPicked() {
        let app = window(level: .normal)
        let overlay = window(level: OverlayHost.windowLevel)
        XCTAssertIdentical(WindowFinder.topmost(among: [app, overlay], excluding: overlay), app)
        XCTAssertNil(WindowFinder.topmost(among: [overlay], excluding: overlay))
    }

    /// Reported from an iPad running a real app: with a context menu open, a tap on
    /// a menu item produced no note at all.
    ///
    /// `UITextEffectsWindow` sits above the app at level 1 and is empty. On any
    /// scene where text interaction has happened it wins on level, so the pick
    /// hit-tested a blank pane instead of the window holding the menu. A window with
    /// nothing under the point is not what anyone pointed at.
    func testAWindowWithNothingUnderThePointIsSkipped() {
        let app = window(level: .normal, id: "app.screen")
        // Empty, above the app, and it accepts no touch anywhere - which is exactly
        // how the system's text-effects window behaves.
        let effects = window(level: UIWindow.Level(rawValue: 1))
        effects.isUserInteractionEnabled = false

        let inTheCard = CGPoint(x: 100, y: 140)
        XCTAssertIdentical(
            WindowFinder.topmost(among: [app, effects], excluding: nil, at: inTheCard),
            app,
            "the empty pane above the app is not what the person is looking at")
    }

    /// A pick somewhere imperfect still beats a tap that does nothing, so an empty
    /// point falls back to the plain topmost rule rather than returning nothing.
    func testAPointWithNothingAnywhereFallsBackRatherThanGivingUp() {
        let app = window(level: .normal, id: "app.screen")
        let outsideEveryWindow = CGPoint(x: 5_000, y: 5_000)

        XCTAssertNotNil(
            WindowFinder.topmost(among: [app], excluding: nil, at: outsideEveryWindow))
    }

    func testAHiddenWindowIsNotWhatSomeoneIsLookingAt() {
        let visible = window(level: .normal, id: "visible")
        let dismissed = window(level: .alert, id: "dismissed")
        dismissed.isHidden = true

        XCTAssertIdentical(WindowFinder.topmost(among: [visible, dismissed], excluding: nil),
                           visible)
    }

    /// While not annotating, the overlay must be invisible to touch everywhere it
    /// draws nothing. An idle overlay that swallows taps makes the host app unusable.
    func testATapPassesThroughWhereTheOverlayDrawsNothing() {
        let model = OverlayModel(session: AnnotationSession(
            app: AppInfo(name: "T", platform: "iOS"), transport: NoopTransport()))

        let overlay = PassthroughWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        overlay.windowLevel = OverlayHost.windowLevel
        overlay.backgroundColor = .clear
        let controller = UIHostingController(rootView: OverlayRoot(model: model))
        controller.view.backgroundColor = .clear
        controller.view.frame = overlay.bounds
        overlay.rootViewController = controller
        overlay.isHidden = false
        overlay.layoutIfNeeded()

        overlay.isPassthrough = { !model.mode.swallowsInput }
        XCTAssertNil(overlay.hitTest(CGPoint(x: 8, y: 8), with: nil),
                     "an idle overlay must let the app underneath have the touch")

        // And while picking it must take them, or nothing can be pointed at.
        model.beginAnnotating()
        overlay.layoutIfNeeded()
        XCTAssertTrue(model.mode.swallowsInput)
    }
}

private final class NoopTransport: Transport {
    func send(_ bundle: AnnotationBundle) async throws {}
}

/// SER-690, found in a real app: the overlay held key status in every mode, so the
/// host's own `UIKeyCommand` fired on some runs and not others depending on which
/// window happened to be key.
@MainActor
final class OverlayKeyWindowTests: XCTestCase {

    private func overlay(wantsKeyboard: Bool) -> PassthroughWindow {
        let window = PassthroughWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        window.wantsKeyboard = wantsKeyboard
        return window
    }

    func testTheOverlayRefusesTheKeyboardWhileTheAppIsInCharge() {
        // `.off` and `.browsing`, the modes that promise the app behaves normally.
        XCTAssertFalse(overlay(wantsKeyboard: false).canBecomeKey)
    }

    func testTheOverlayTakesTheKeyboardWhileCommenting() {
        // The comment field has to be typeable, and refusing key status here would
        // have traded one bug for a worse one.
        XCTAssertTrue(overlay(wantsKeyboard: true).canBecomeKey)
    }
}
#endif

