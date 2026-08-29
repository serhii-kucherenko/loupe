#if canImport(UIKit)
import XCTest
import UIKit
import LoupeCore
@testable import LoupeUI

/// The UIKit half of the correctness core.
///
/// It had none. The AppKit tests prove the walk against `NSView`, which shares no
/// hit-testing behaviour with UIKit at all - UIKit skips views with user interaction
/// switched off, which changes which element the walk even starts from.
@MainActor
final class ElementPickerUIKitTests: XCTestCase {

    private func makeWindow(_ build: (UIView) -> Void) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let root = UIViewController()
        root.view.frame = window.bounds
        window.rootViewController = root
        window.isHidden = false
        build(root.view)
        return window
    }

    func testItLandsOnTheNamedCardRatherThanTheLabelInsideIt() {
        var card: UIView!
        let window = makeWindow { root in
            card = UIView(frame: CGRect(x: 20, y: 100, width: 300, height: 80))
            card.accessibilityIdentifier = "product.card"

            let title = UILabel(frame: CGRect(x: 10, y: 10, width: 200, height: 24))
            title.text = "Wool overshirt"
            card.addSubview(title)
            root.addSubview(card)
        }

        let picked = ElementPicker.pick(at: CGPoint(x: 100, y: 125), in: window)
        XCTAssertEqual(picked?.ref.accessibilityID, "product.card")
        XCTAssertIdentical(picked?.view, card)
    }

    /// UIKit will not hit-test a label at all, because `isUserInteractionEnabled`
    /// defaults to false on `UILabel`. So the walk usually starts a level above -
    /// which is why the AppKit bug (a static label being an `NSControl`) has no
    /// counterpart here, and why this needs its own test rather than an assumption.
    func testALabelIsNotEvenHitTestedUnlessTheAppAsksForIt() {
        let window = makeWindow { root in
            let label = UILabel(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
            label.text = "just text"
            label.accessibilityIdentifier = "the.label"
            root.addSubview(label)
        }

        let picked = ElementPicker.pick(at: CGPoint(x: 50, y: 20), in: window)
        XCTAssertNotEqual(picked?.ref.accessibilityID, "the.label")

        let interactive = makeWindow { root in
            let label = UILabel(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
            label.isUserInteractionEnabled = true
            label.accessibilityIdentifier = "the.label"
            root.addSubview(label)
        }
        XCTAssertEqual(ElementPicker.pick(at: CGPoint(x: 50, y: 20), in: interactive)?
            .ref.accessibilityID, "the.label")
    }

    func testItStopsAtAControlWithoutAName() {
        let window = makeWindow { root in
            let button = UIButton(type: .system)
            button.frame = CGRect(x: 20, y: 200, width: 120, height: 44)
            button.setTitle("Buy", for: .normal)
            root.addSubview(button)
        }

        let picked = ElementPicker.pick(at: CGPoint(x: 80, y: 222), in: window)
        XCTAssertTrue(picked?.view is UIButton)
        XCTAssertEqual(picked?.ref.label, "Buy")
    }

    func testItNeverClimbsIntoAScreenSizedContainer() {
        let window = makeWindow { root in
            let full = UIView(frame: root.bounds)
            full.accessibilityIdentifier = "root"
            let plain = UIView(frame: CGRect(x: 10, y: 10, width: 60, height: 60))
            full.addSubview(plain)
            root.addSubview(full)
        }

        let picked = ElementPicker.pick(at: CGPoint(x: 40, y: 40), in: window)
        XCTAssertNotEqual(picked?.ref.accessibilityID, "root")
    }

    func testBoundsAreTopLeftAndInWindowPoints() {
        let window = makeWindow { root in
            let box = UIView(frame: CGRect(x: 40, y: 220, width: 100, height: 50))
            box.accessibilityIdentifier = "box"
            root.addSubview(box)
        }

        guard let bounds = ElementPicker.pick(at: CGPoint(x: 90, y: 245), in: window)?
            .ref.bounds else { return XCTFail("nothing was picked") }
        XCTAssertEqual(bounds.x, 40, accuracy: 0.5)
        XCTAssertEqual(bounds.y, 220, accuracy: 0.5)
        XCTAssertEqual(bounds.width, 100, accuracy: 0.5)
    }

    func testTheCropIsTheElementAndTheContextShotIsTheScreen() async {
        var card: UIView!
        let window = makeWindow { root in
            card = UIView(frame: CGRect(x: 20, y: 100, width: 300, height: 80))
            card.backgroundColor = .systemBlue
            card.accessibilityIdentifier = "card"
            root.addSubview(card)
        }
        window.layoutIfNeeded()

        // `UIImage(data:)` reports **pixels**, and the renderer draws at the screen
        // scale, so a 300pt card is 900px wide on a 3x device. AppKit's NSImage
        // reports points, which is why the macOS test compares different numbers.
        let scale = window.screen.scale

        guard let crop = await ElementPicker.screenshotPNG(of: card),
              let cropped = UIImage(data: crop) else { return XCTFail("no crop") }
        XCTAssertEqual(cropped.size.width, 300 * scale, accuracy: scale)
        XCTAssertEqual(cropped.size.height, 80 * scale, accuracy: scale)

        guard let context = await ElementPicker.contextPNG(of: card, in: window),
              let whole = UIImage(data: context) else { return XCTFail("no context shot") }
        XCTAssertEqual(whole.size.width, 400 * scale, accuracy: scale, "the screen, not the card")
        XCTAssertEqual(whole.size.height, 600 * scale, accuracy: scale)
    }

    func testAPickOnEmptySpaceIsNotAnError() {
        let window = makeWindow { _ in }
        XCTAssertNil(ElementPicker.pick(at: CGPoint(x: 200, y: 300), in: window)?
            .ref.accessibilityID)
    }
}

/// The platform the region fallback exists for. SwiftUI backs almost nothing on iOS
/// with a real view, so without this most of a screen could not be annotated at all.
@MainActor
final class ElementRegionUIKitTests: XCTestCase {

    private func makeWindow() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let root = UIViewController()
        root.view.frame = window.bounds
        window.rootViewController = root
        window.isHidden = false
        return window
    }

    func testAPointOverNothingStillCaptures() async {
        let window = makeWindow()

        let shot = await ElementPicker.capture(at: CGPoint(x: 200, y: 300), in: window)

        XCTAssertNotNil(shot)
        XCTAssertNil(shot?.ref.className, "a region has no element to name")
        XCTAssertEqual(shot?.ref.bounds.width, ElementPicker.regionSize)
        XCTAssertNotNil(shot?.screenshotPNG)
        XCTAssertNotNil(shot?.contextScreenshotPNG)
    }

    func testTheRegionIsCentredOnThePoint() {
        let window = makeWindow()
        let half = ElementPicker.regionSize / 2

        let ref = ElementPicker.regionRef(at: CGPoint(x: 200, y: 300), in: window)

        XCTAssertEqual(ref?.bounds.x, 200 - half)
        XCTAssertEqual(ref?.bounds.y, 300 - half)
    }

    func testARealElementIsStillPreferredOverARegion() async {
        let window = makeWindow()
        let card = UIView(frame: CGRect(x: 150, y: 250, width: 100, height: 100))
        card.accessibilityIdentifier = "product.card"
        window.rootViewController?.view.addSubview(card)

        let shot = await ElementPicker.capture(at: CGPoint(x: 200, y: 300), in: window)

        XCTAssertEqual(shot?.ref.accessibilityID, "product.card")
        XCTAssertEqual(shot?.ref.bounds.width, 100)
    }
}

/// SER-684, measured in a real SwiftUI app on an iPad Pro 13-inch (1032x1376pt):
/// tapping one book on a shelf reported `PlatformGroupContainer` at
/// `{0, 32, 1032, 621}` - every book, the search field and the filter chips as one
/// element - and a second run gave `{-14, 50, 1046, 635}`, wider than the window
/// with a negative origin.
@MainActor
final class OversizedElementUIKitTests: XCTestCase {

    /// The real device size, so the fractions in these tests are the real fractions.
    private func iPad(_ build: (UIView) -> Void) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1032, height: 1376))
        let root = UIViewController()
        root.view.frame = window.bounds
        window.rootViewController = root
        window.isHidden = false
        build(root.view)
        return window
    }

    func testAShelfSizedContainerNobodyNamedIsNotAnElement() {
        // 45% of the window. The old ceiling was 80%, so this went straight through.
        let window = iPad { root in
            root.addSubview(UIView(frame: CGRect(x: 0, y: 32, width: 1032, height: 621)))
        }

        XCTAssertNil(ElementPicker.pick(at: CGPoint(x: 300, y: 200), in: window),
                     "a shelf is not one element")
    }

    /// And the tool still answers, because answering is the point.
    func testTheShelfStillCapturesAsARegion() async {
        let window = iPad { root in
            root.addSubview(UIView(frame: CGRect(x: 0, y: 32, width: 1032, height: 621)))
        }

        let shot = await ElementPicker.capture(at: CGPoint(x: 300, y: 200), in: window)

        XCTAssertNotNil(shot)
        XCTAssertNil(shot?.ref.className)
        XCTAssertEqual(shot?.ref.bounds.width, ElementPicker.regionSize)
    }

    func testBoundsNeverLeaveTheViewport() {
        let window = iPad { root in
            // Overhanging both edges, exactly as the device reported it.
            let scroller = UIView(frame: CGRect(x: -14, y: 50, width: 1046, height: 200))
            scroller.accessibilityIdentifier = "shelf.scroller"
            root.addSubview(scroller)
        }

        let picked = ElementPicker.pick(at: CGPoint(x: 300, y: 100), in: window)

        XCTAssertEqual(picked?.ref.accessibilityID, "shelf.scroller")
        XCTAssertEqual(picked?.ref.bounds.x, 0, "a negative origin is not a viewport coordinate")
        XCTAssertEqual(picked?.ref.bounds.width, 1032, "nothing is wider than the window")
    }

    /// The rule is about size, not about being unnamed: a row the app named is still
    /// the answer, which is what `docs/agent-install.md` asks hosts to do.
    func testANamedRowIsStillPickedWhateverIsAroundIt() {
        let window = iPad { root in
            let shelf = UIView(frame: CGRect(x: 0, y: 32, width: 1032, height: 621))
            let row = UIView(frame: CGRect(x: 16, y: 16, width: 1000, height: 96))
            row.accessibilityIdentifier = "shelf.row.4"
            shelf.addSubview(row)
            root.addSubview(shelf)
        }

        let picked = ElementPicker.pick(at: CGPoint(x: 300, y: 80), in: window)

        XCTAssertEqual(picked?.ref.accessibilityID, "shelf.row.4")
        XCTAssertEqual(picked?.ref.bounds.height, 96)
    }
}
#endif

