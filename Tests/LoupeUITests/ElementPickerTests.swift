#if canImport(AppKit)
import XCTest
import AppKit
import LoupeCore
@testable import LoupeUI

/// The meaningful-ancestor walk is the correctness core of the whole tool: a wrong
/// crop makes every downstream step reason about the wrong element. It gets a real
/// window and real views, not a mock.
@MainActor
final class ElementPickerTests: XCTestCase {

    private func window(_ build: (NSView) -> Void) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = content
        build(content)
        return window
    }

    func testItClimbsPastAnInnerLabelToTheNamedContainer() {
        var card: NSView!
        let window = window { content in
            card = NSView(frame: NSRect(x: 50, y: 50, width: 200, height: 100))
            card.identifier = NSUserInterfaceItemIdentifier("product.card")

            let title = NSTextField(labelWithString: "Blue jacket")
            title.frame = NSRect(x: 10, y: 10, width: 100, height: 20)
            card.addSubview(title)
            content.addSubview(card)
        }

        // Top-left coordinates: the label sits 60..80 from the bottom, so
        // 300 - 70 = 230 from the top.
        let picked = ElementPicker.pick(at: CGPoint(x: 110, y: 230), in: window)

        XCTAssertEqual(picked?.ref.accessibilityID, "product.card",
                       "the label inside is not what a person means by 'this card'")
        XCTAssertIdentical(picked?.view, card)
    }

    func testItStopsAtAnInteractiveControlWithoutAName() {
        let window = window { content in
            let button = NSButton(title: "Buy", target: nil, action: nil)
            button.frame = NSRect(x: 20, y: 20, width: 80, height: 30)
            content.addSubview(button)
        }

        let picked = ElementPicker.pick(at: CGPoint(x: 60, y: 265), in: window)
        XCTAssertTrue(picked?.view is NSButton, "a control is meaningful even unnamed")
    }

    /// The climb must stop before it swallows the screen. An ancestor covering most
    /// of the window is a container, not the thing you pointed at.
    func testItNeverClimbsIntoAScreenSizedContainer() {
        let window = window { content in
            let full = NSView(frame: content.bounds)
            full.identifier = NSUserInterfaceItemIdentifier("root")
            let plain = NSView(frame: NSRect(x: 10, y: 10, width: 50, height: 50))
            full.addSubview(plain)
            content.addSubview(full)
        }

        let picked = ElementPicker.pick(at: CGPoint(x: 30, y: 265), in: window)
        XCTAssertNotEqual(picked?.ref.accessibilityID, "root",
                          "a full-window container is never what you meant")
    }

    /// Bounds leave the picker top-left on every platform, because that is what
    /// `docs/bundle-format.md` promises and what the overlay draws in.
    func testBoundsComeBackTopLeftEvenThoughAppKitIsBottomLeft() {
        let window = window { content in
            let box = NSView(frame: NSRect(x: 40, y: 200, width: 100, height: 50))
            box.identifier = NSUserInterfaceItemIdentifier("box")
            content.addSubview(box)
        }

        // The box occupies y 200..250 from the bottom of a 300-tall window,
        // so it is 50..100 from the top.
        guard let bounds = ElementPicker.pick(at: CGPoint(x: 90, y: 75), in: window)?.ref.bounds
        else { return XCTFail("nothing was picked") }
        XCTAssertEqual(bounds.y, 50, accuracy: 0.5)
        XCTAssertEqual(bounds.x, 40, accuracy: 0.5)
        XCTAssertEqual(bounds.height, 50, accuracy: 0.5)
    }

    // Found on an iPad: pointing at empty space produced a note whose element was a
    // window-sized `UIView` and whose crop was blank. Nothing is a better answer.
    func testAPickOnEmptySpacePicksNothing() {
        let window = window { _ in }
        XCTAssertNil(ElementPicker.pick(at: CGPoint(x: 200, y: 150), in: window))
    }

    // Pointing at content the framework cannot resolve must still capture something.
    // On iOS this is the common case, not the edge one: SwiftUI draws headings and
    // stacks into a shared layer with no view behind them.
    func testAnUnresolvablePointStillCapturesTheRegionAroundIt() {
        let window = window { _ in }

        let shot = ElementPicker.capture(at: CGPoint(x: 200, y: 150), in: window)

        XCTAssertNotNil(shot, "a point inside the window always captures something")
        XCTAssertNil(shot?.ref.className, "a region has no element to name")
        XCTAssertEqual(shot?.ref.bounds.width, ElementPicker.regionSize)
        XCTAssertEqual(shot?.ref.bounds.height, ElementPicker.regionSize)
        XCTAssertNotNil(shot?.screenshotPNG)
        XCTAssertNotNil(shot?.contextScreenshotPNG)
    }

    // A point near an edge must not produce a box hanging off the window.
    func testARegionAtTheEdgeIsClippedToTheWindow() {
        let window = window { _ in }

        let ref = ElementPicker.regionRef(at: CGPoint(x: 10, y: 10), in: window)

        XCTAssertEqual(ref?.bounds.x, 0)
        XCTAssertEqual(ref?.bounds.y, 0)
        XCTAssertEqual(ref?.bounds.width, 10 + ElementPicker.regionSize / 2)
    }

    // The highlight has to follow the pointer over unresolvable content too, or the
    // overlay looks broken exactly where the fallback is doing its job.
    func testHoverFallsBackToTheRegionSoTheHighlightNeverDisappears() {
        let window = window { _ in }
        XCTAssertNotNil(ElementPicker.hoverRef(at: CGPoint(x: 200, y: 150), in: window))
    }

    // The other half of that rule: a full-screen element the app has named is a real
    // element, and someone pointing at it means it.
    func testAFullScreenElementTheAppNamedIsStillPickable() {
        let window = window { content in
            let canvas = NSView(frame: content.bounds)
            canvas.identifier = NSUserInterfaceItemIdentifier("map.canvas")
            content.addSubview(canvas)
        }

        let picked = ElementPicker.pick(at: CGPoint(x: 200, y: 150), in: window)
        XCTAssertEqual(picked?.ref.accessibilityID, "map.canvas")
    }
}

/// The AppKit half of the same bug reported from an iPad: a sheet, a popover and a
/// modal are each their own `NSWindow`, so hit-testing only the window Loupe was
/// attached to annotates whatever sits behind the thing on screen.
@MainActor
final class WindowFinderTests: XCTestCase {

    private func window(_ frame: NSRect, title: String) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.title = title
        window.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        window.orderFront(nil)
        return window
    }

    func testItTakesTheFrontmostWindowUnderThePointer() {
        let behind = window(NSRect(x: 0, y: 0, width: 400, height: 300), title: "app")
        let sheet = window(NSRect(x: 50, y: 50, width: 200, height: 150), title: "sheet")

        // A point inside both. The sheet was ordered front last, so it is in front.
        let found = WindowFinder.topmost(among: [behind, sheet],
                                         at: CGPoint(x: 100, y: 100), excluding: nil)
        XCTAssertEqual(found?.title, "sheet")
    }

    func testAPointOutsideEveryWindowPicksNothing() {
        let app = window(NSRect(x: 0, y: 0, width: 400, height: 300), title: "app")
        XCTAssertNil(WindowFinder.topmost(among: [app],
                                          at: CGPoint(x: 9000, y: 9000), excluding: nil))
    }

    /// Loupe's own panel is never the answer, or a pick would annotate the tool.
    func testTheOverlayPanelIsNeverPicked() {
        let app = window(NSRect(x: 0, y: 0, width: 400, height: 300), title: "app")
        let overlay = window(NSRect(x: 0, y: 0, width: 400, height: 300), title: "overlay")

        let found = WindowFinder.topmost(among: [app, overlay],
                                         at: CGPoint(x: 100, y: 100), excluding: overlay)
        XCTAssertEqual(found?.title, "app")
    }

    func testAHiddenWindowIsNotWhatSomeoneIsLookingAt() {
        let visible = window(NSRect(x: 0, y: 0, width: 400, height: 300), title: "app")
        let closed = window(NSRect(x: 0, y: 0, width: 400, height: 300), title: "closed")
        closed.orderOut(nil)

        XCTAssertEqual(WindowFinder.topmost(among: [visible, closed],
                                            at: CGPoint(x: 100, y: 100),
                                            excluding: nil)?.title, "app")
    }
}

/// A container with no name of its own is the common case in a real UI, and
/// "ResultRow" tells an agent nothing that helps it find the row.
@MainActor
final class ElementLabelTests: XCTestCase {

    func testAContainerBorrowsTheTextInsideIt() {
        let card = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        for (index, text) in ["Wool overshirt, ink", "£96.00"].enumerated() {
            let field = NSTextField(labelWithString: text)
            field.frame = NSRect(x: 0, y: index * 20, width: 180, height: 18)
            card.addSubview(field)
        }

        XCTAssertEqual(ElementPicker.descendantText(of: card), "Wool overshirt, ink £96.00")
    }

    func testAnEmptyContainerBorrowsNothing() {
        let empty = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        XCTAssertNil(ElementPicker.descendantText(of: empty))
    }

    /// A whole screen of words in a bundle field helps nobody.
    func testItIsTrimmedRatherThanUnbounded() {
        let card = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        for index in 0..<20 {
            let field = NSTextField(labelWithString: "a rather long line of text \(index)")
            field.frame = NSRect(x: 0, y: index * 18, width: 380, height: 16)
            card.addSubview(field)
        }

        let text = ElementPicker.descendantText(of: card)
        XCTAssertNotNil(text)
        XCTAssertLessThanOrEqual(text?.count ?? 0, 80)
    }
}
#endif

