#if canImport(AppKit)
import XCTest
import AppKit
import LoupeCore
@testable import LoupeUI

/// The tight crop answers "what is this element". The context shot answers "where is
/// it, and what is around it". They are different questions, so both are kept.
@MainActor
final class ContextShotTests: XCTestCase {

    private func window(width: CGFloat = 400, height: CGFloat = 300) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.white.cgColor
        window.contentView = content

        let card = NSView(frame: NSRect(x: 40, y: 200, width: 120, height: 40))
        card.identifier = NSUserInterfaceItemIdentifier("card")
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.systemBlue.cgColor
        content.addSubview(card)
        return (window, card)
    }

    func testTheContextShotIsTheWholeWindowNotTheElement() {
        let (window, card) = window()
        guard let data = ElementPicker.contextPNG(of: card, in: window),
              let image = NSImage(data: data) else {
            return XCTFail("no context shot")
        }

        XCTAssertEqual(image.size.width, 400, accuracy: 1, "the whole window, not the card")
        XCTAssertEqual(image.size.height, 300, accuracy: 1)
        XCTAssertNotEqual(image.size, CGSize(width: 120, height: 40))
    }

    func testTheTightCropIsStillJustTheElement() {
        let (_, card) = window()
        guard let data = ElementPicker.screenshotPNG(of: card),
              let image = NSImage(data: data) else {
            return XCTFail("no crop")
        }
        XCTAssertEqual(image.size.width, 120, accuracy: 1)
        XCTAssertEqual(image.size.height, 40, accuracy: 1)
    }

    /// The point of the shot is that you can see *which* element it is about, so the
    /// outline has to actually be drawn, not merely intended.
    func testTheElementIsOutlinedInTheContextShot() throws {
        let (window, card) = window()
        guard let data = ElementPicker.contextPNG(of: card, in: window),
              let source = NSBitmapImageRep(data: data) else {
            return XCTFail("no context shot")
        }

        // loupe.highlight is a warm orange; the window is white and the card blue.
        // Somewhere on the card's outline there must be a pixel that is neither.
        let highlight = LoupeTheme.Colors.highlight.value(dark: false)
        var found = false
        let top = 300 - 240   // the card's top edge, in top-left coordinates
        for x in 40...160 {
            for y in max(0, top - 3)...(top + 3) {
                guard let pixel = source.colorAt(x: Int(Double(x) * Double(source.pixelsWide) / 400),
                                                 y: Int(Double(y) * Double(source.pixelsHigh) / 300))
                else { continue }
                if abs(Double(pixel.redComponent) - highlight.red) < 0.15,
                   abs(Double(pixel.greenComponent) - highlight.green) < 0.15,
                   abs(Double(pixel.blueComponent) - highlight.blue) < 0.15 {
                    found = true
                }
            }
        }
        XCTAssertTrue(found, "the picked element is not outlined, so the shot says nothing")
    }

    func testAZeroSizedWindowIsNotAnError() {
        let empty = NSWindow(contentRect: .zero, styleMask: [.titled],
                             backing: .buffered, defer: false)
        empty.contentView = NSView(frame: .zero)
        XCTAssertNil(ElementPicker.contextPNG(of: empty.contentView!, in: empty))
    }

    /// The same job for a drawn shape: the crop says what was circled, and this says
    /// where on the screen it was. Stroked as the shape, not as its bounding box -
    /// a rectangle here would be the picture contradicting the gesture.
    func testTheDrawnShapeIsStrokedInTheContextShot() throws {
        let (window, _) = window()
        // A triangle over the card, in top-left coordinates like every rectangle the
        // picker deals in.
        let drawn = [Point(x: 40, y: 60), Point(x: 160, y: 60), Point(x: 100, y: 100)]

        guard let data = ElementPicker.contextPNG(ofPath: drawn, in: window),
              let source = NSBitmapImageRep(data: data) else {
            return XCTFail("no context shot")
        }

        // The top edge of the triangle runs from x=40 to x=160 at y=60. Somewhere
        // along it there must be highlight-coloured pixels on a white window.
        let highlight = LoupeTheme.Colors.highlight.value(dark: false)
        var found = 0
        for x in 50...150 {
            for y in 57...63 {
                guard let pixel = source.colorAt(
                    x: Int(Double(x) * Double(source.pixelsWide) / 400),
                    y: Int(Double(y) * Double(source.pixelsHigh) / 300)) else { continue }
                if abs(Double(pixel.redComponent) - highlight.red) < 0.15,
                   abs(Double(pixel.greenComponent) - highlight.green) < 0.15,
                   abs(Double(pixel.blueComponent) - highlight.blue) < 0.15 {
                    found += 1
                }
            }
        }
        XCTAssertGreaterThan(found, 10, "the shape is not drawn, so the shot says nothing")
    }

    /// And it must be the *shape*. A stroked bounding box would put a line along the
    /// bottom edge, where this triangle has only its apex.
    func testTheContextShotStrokesTheShapeRatherThanItsBox() throws {
        let (window, _) = window()
        let drawn = [Point(x: 40, y: 60), Point(x: 160, y: 60), Point(x: 100, y: 100)]

        guard let data = ElementPicker.contextPNG(ofPath: drawn, in: window),
              let source = NSBitmapImageRep(data: data) else {
            return XCTFail("no context shot")
        }

        let highlight = LoupeTheme.Colors.highlight.value(dark: false)
        var onTheBottomEdge = 0
        // The bounding box's bottom edge is y=100, from x=40 to x=160. The triangle
        // touches it only at x=100, so the corners must be clean.
        for x in 45...70 {
            for y in 97...103 {
                guard let pixel = source.colorAt(
                    x: Int(Double(x) * Double(source.pixelsWide) / 400),
                    y: Int(Double(y) * Double(source.pixelsHigh) / 300)) else { continue }
                if abs(Double(pixel.redComponent) - highlight.red) < 0.15,
                   abs(Double(pixel.greenComponent) - highlight.green) < 0.15,
                   abs(Double(pixel.blueComponent) - highlight.blue) < 0.15 {
                    onTheBottomEdge += 1
                }
            }
        }
        XCTAssertEqual(onTheBottomEdge, 0,
                       "a line along the box's bottom edge means the box was drawn, "
                       + "which is the one thing the gesture said it was not")
    }
}

#endif
