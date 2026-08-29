import XCTest
import ImageIO
import CoreGraphics
import LoupeCore
@testable import LoupeUI

/// The crop is the whole point of drawing a shape instead of dragging a box.
///
/// A shape around two things says *these, and not what is between them*. If the
/// picture that reaches the issue is the bounding box, it says the opposite - and the
/// person reading it has no way to know the gesture ever happened. So this asserts
/// pixels, not intent.
final class MaskedCropTests: XCTestCase {

    private let size = 100

    /// A solid red square, standing in for a screenshot.
    private func redPNG() throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let image = try XCTUnwrap(context.makeImage())
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            out, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    /// The colour at a point, in top-left coordinates like everything else the picker
    /// deals in.
    private func colour(_ png: Data, atX x: Int, y: Int) throws -> (r: Int, g: Int, b: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        })
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        // A bitmap context's *memory* starts at the top row even though its
        // *coordinates* start at the bottom, so a top-left pixel is simply row y.
        // Flipping here as well was how this helper first read 0xE8 - the cutaway's
        // own red channel - and blamed the mask for being upside down.
        let offset = (y * image.width + x) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    private var box: CGRect { CGRect(x: 0, y: 0, width: Double(size), height: Double(size)) }

    // MARK: -

    /// The left half is inside the shape and stays the app; the right half is what
    /// the person went around, and must not.
    func testWhatWasCircledIsKeptAndWhatWasNotIsReplaced() throws {
        let leftHalf = [Point(x: 0, y: 0), Point(x: 50, y: 0),
                        Point(x: 50, y: 100), Point(x: 0, y: 100)]
        let masked = try XCTUnwrap(
            ElementPicker.masked(try redPNG(), to: leftHalf, box: box))

        let inside = try colour(masked, atX: 20, y: 50)
        XCTAssertEqual(inside.r, 255, accuracy: 4, "the app survives inside the shape")
        XCTAssertEqual(inside.g, 0, accuracy: 4)

        let outside = try colour(masked, atX: 80, y: 50)
        XCTAssertNotEqual(outside.r, 255,
                          "the gap the shape went around must not read as app content")
    }

    /// Not transparent, and not white. A PNG with an alpha channel reads as broken on
    /// one viewer and as white on another, and neither says "left out on purpose".
    func testTheGroundIsTheCutawayTokenRatherThanAHole() throws {
        let triangle = [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 0, y: 100)]
        let masked = try XCTUnwrap(
            ElementPicker.masked(try redPNG(), to: triangle, box: box))

        let ground = LoupeTheme.Colors.cutaway.value(
            dark: ElementPicker.isDarkAppearance())
        let corner = try colour(masked, atX: 95, y: 95)
        XCTAssertEqual(Double(corner.r) / 255, ground.red, accuracy: 0.02)
        XCTAssertEqual(Double(corner.g) / 255, ground.green, accuracy: 0.02)
        XCTAssertEqual(Double(corner.b) / 255, ground.blue, accuracy: 0.02)
    }

    /// The shape is in window points and the picture is at device scale, so the two
    /// have to be brought into the same space. Get this wrong and the mask lands in
    /// the wrong place, which looks like a rendering glitch rather than a bug.
    func testTheShapeIsScaledToThePicture() throws {
        // A box twice the pixel size: one window point is half a pixel.
        let wide = CGRect(x: 0, y: 0, width: 200, height: 200)
        let leftHalf = [Point(x: 0, y: 0), Point(x: 100, y: 0),
                        Point(x: 100, y: 200), Point(x: 0, y: 200)]
        let masked = try XCTUnwrap(
            ElementPicker.masked(try redPNG(), to: leftHalf, box: wide))

        XCTAssertEqual(try colour(masked, atX: 20, y: 50).r, 255, accuracy: 4,
                       "still the left half of the picture, not a quarter of it")
        XCTAssertNotEqual(try colour(masked, atX: 80, y: 50).r, 255)
    }

    /// The shape is drawn top-left down, the bitmap counts bottom-left up. A missing
    /// flip masks the mirror image of what was drawn, which is worse than no mask:
    /// it hides the thing that was pointed at.
    func testTheShapeIsNotUpsideDown() throws {
        let topHalf = [Point(x: 0, y: 0), Point(x: 100, y: 0),
                       Point(x: 100, y: 50), Point(x: 0, y: 50)]
        let masked = try XCTUnwrap(
            ElementPicker.masked(try redPNG(), to: topHalf, box: box))

        XCTAssertEqual(try colour(masked, atX: 50, y: 10).r, 255, accuracy: 4,
                       "the top was circled, so the top is what is kept")
        XCTAssertNotEqual(try colour(masked, atX: 50, y: 90).r, 255,
                          "and the bottom is not")
    }

    func testNonsenseInGivesNothingBackRatherThanACrash() throws {
        XCTAssertNil(ElementPicker.masked(Data("not a png".utf8),
                                          to: [Point(x: 0, y: 0)], box: box))
        XCTAssertNil(ElementPicker.masked(try redPNG(),
                                          to: [Point(x: 0, y: 0), Point(x: 1, y: 1)],
                                          box: .zero))
    }
}
