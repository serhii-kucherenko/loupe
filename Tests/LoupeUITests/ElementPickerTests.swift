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

    func testAPickOnEmptySpaceIsNotAnError() {
        let window = window { _ in }
        let picked = ElementPicker.pick(at: CGPoint(x: 200, y: 150), in: window)
        // The content view itself is the only thing there; it must not crash, and it
        // must not report a name it does not have.
        XCTAssertNil(picked?.ref.accessibilityID)
    }
}
#endif
