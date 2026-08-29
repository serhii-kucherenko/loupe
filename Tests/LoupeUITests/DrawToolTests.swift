import XCTest
import LoupeCore
@testable import LoupeUI

/// The lasso, in the parts that do not need a window.
///
/// The interesting rule here is that Draw is the *only* tool allowed to decide what a
/// gesture means. Point and Box are reflections - drag a box with Point lit and you
/// get a box - because a tap and a drag cannot be mistaken for each other. A drawn
/// shape and a dragged rectangle are the same gesture, so something has to choose,
/// and that makes Draw the one tool somebody can be stuck in.
@MainActor
final class DrawToolTests: XCTestCase {

    private func makeModel() -> OverlayModel {
        OverlayModel(session: AnnotationSession(
            app: AppInfo(name: "Demo", platform: "macOS"),
            transport: DiscardingTransport()))
    }

    private func picking() -> OverlayModel {
        let model = makeModel()
        model.beginAnnotating()
        return model
    }

    private let square = [Point(x: 0, y: 0), Point(x: 40, y: 0),
                          Point(x: 40, y: 40), Point(x: 0, y: 40)]

    // MARK: - Only one tool locks

    func testDrawIsTheOnlyToolThatDecidesWhatADragMeans() {
        XCTAssertTrue(PickTool.draw.locksTheDrag)
        XCTAssertFalse(PickTool.point.locksTheDrag)
        XCTAssertFalse(PickTool.box.locksTheDrag)
    }

    func testEveryToolSaysWhatItIsAndWhatToDo() {
        for tool in PickTool.allCases {
            XCTAssertFalse(tool.title.isEmpty)
            XCTAssertFalse(tool.symbol.isEmpty)
            XCTAssertGreaterThan(tool.hint.count, 8, "\(tool) explains nothing")
            XCTAssertGreaterThan(tool.accessibilityLabel.count, 8)
        }
    }

    /// Draw is the one tool somebody can be stuck in, so the way out has to be on
    /// screen rather than in a changelog.
    func testTheDrawHintSaysHowToLeaveIt() {
        XCTAssertTrue(PickTool.draw.hint.lowercased().contains("tap"),
                      "the escape has to be written down: \(PickTool.draw.hint)")
    }

    // MARK: - Live feedback

    func testDrawingPublishesTheShapeAndClearsAnyRectangle() {
        let model = picking()
        model.drag(to: Rect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertNotNil(model.dragRegion)

        model.draw(to: square)
        XCTAssertEqual(model.dragPath, square)
        XCTAssertNil(model.dragRegion, "only one of them can be true at a time")
    }

    func testDraggingARectangleClearsAnyShape() {
        let model = picking()
        model.draw(to: square)
        model.drag(to: Rect(x: 0, y: 0, width: 10, height: 10))

        XCTAssertNil(model.dragPath)
        XCTAssertNotNil(model.dragRegion)
    }

    /// Same contract `drag(to:)` has. A stroke that arrives after annotate mode was
    /// left must not draw itself over the app.
    func testNothingIsDrawnWhenTheOverlayIsNotTakingInput() {
        let model = makeModel()
        model.draw(to: square)
        XCTAssertNil(model.dragPath)
    }

    // MARK: - The control follows the gesture

    func testAPathPickLightsDraw() {
        let model = picking()
        model.pick(ElementRef(kind: .path,
                              bounds: LoupePath.bounds(square),
                              path: square))
        XCTAssertEqual(model.tool, .draw)
    }

    /// The escape, and it has to actually work: leaving Draw lit after a tap-pick
    /// would put the very next drag back into a shape nobody asked for.
    func testATapPickLeavesDraw() {
        let model = picking()
        model.use(.draw)
        model.pick(ElementRef(bounds: Rect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertEqual(model.tool, .point)
    }

    func testARegionPickStillLightsBox() {
        let model = picking()
        model.use(.draw)
        model.pick(ElementRef(kind: .region,
                              bounds: Rect(x: 0, y: 0, width: 30, height: 30)))
        XCTAssertEqual(model.tool, .box)
    }

    /// A shape in flight belongs to the gesture that owns it. Any change of mode ends
    /// it, or a stroke would survive into a screen it was never drawn on.
    func testChangingModeEndsAShapeInFlight() {
        let model = picking()
        model.draw(to: square)
        model.pick(ElementRef(bounds: Rect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertNil(model.dragPath)
    }

    // MARK: - What ends up in the note

    func testAShapeBecomesAPathReferenceWithItsBoxAsBounds() {
        let ref = ElementPicker.pathRef(square)
        XCTAssertEqual(ref.kind, .path)
        XCTAssertEqual(ref.path, square)
        XCTAssertEqual(ref.bounds, Rect(x: 0, y: 0, width: 40, height: 40),
                       "a reader that ignores the path gets the rectangle it expects")
    }
}

/// The tests here are about the overlay, never about delivery.
private struct DiscardingTransport: Transport {
    func send(_ bundle: AnnotationBundle) async throws {}
}
