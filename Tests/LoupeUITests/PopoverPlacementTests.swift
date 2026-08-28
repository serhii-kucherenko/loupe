import XCTest
import SwiftUI
@testable import LoupeUI

/// The popover must never cover the element it is about. That is the whole rule.
final class PopoverPlacementTests: XCTestCase {

    private let container = CGSize(width: 1000, height: 800)
    private let popover = CGSize(width: 320, height: 240)

    private func frame(for element: CGRect) -> CGRect {
        PopoverPlacement.frame(for: element, popover: popover, in: container)
    }

    func testItSitsBelowTheElementWhenThereIsRoom() {
        let element = CGRect(x: 100, y: 100, width: 200, height: 40)
        let placed = frame(for: element)
        XCTAssertGreaterThanOrEqual(placed.minY, element.maxY)
        XCTAssertFalse(placed.intersects(element))
    }

    func testItFlipsAboveWhenTheElementIsNearTheBottom() {
        let element = CGRect(x: 100, y: 700, width: 200, height: 40)
        let placed = frame(for: element)
        XCTAssertLessThanOrEqual(placed.maxY, element.minY)
        XCTAssertFalse(placed.intersects(element))
    }

    func testItStaysInsideTheContainerOnEveryEdge() {
        let elements = [
            CGRect(x: 0, y: 0, width: 40, height: 40),
            CGRect(x: 960, y: 0, width: 40, height: 40),
            CGRect(x: 0, y: 760, width: 40, height: 40),
            CGRect(x: 960, y: 760, width: 40, height: 40),
        ]
        for element in elements {
            let placed = frame(for: element)
            XCTAssertGreaterThanOrEqual(placed.minX, 0, "\(element)")
            XCTAssertGreaterThanOrEqual(placed.minY, 0, "\(element)")
            XCTAssertLessThanOrEqual(placed.maxX, container.width, "\(element)")
            XCTAssertLessThanOrEqual(placed.maxY, container.height, "\(element)")
        }
    }

    func testItCentresOnTheElementWhenNothingPushesItAside() {
        let element = CGRect(x: 400, y: 100, width: 200, height: 40)
        XCTAssertEqual(frame(for: element).midX, element.midX, accuracy: 0.5)
    }

    /// A tall element leaves no room on either side. Some overlap is then
    /// unavoidable, so the rule becomes: take whichever side has more space.
    func testATallElementTakesWhicheverSideHasMoreRoom() {
        let moreRoomBelow = CGRect(x: 100, y: 40, width: 200, height: 700)
        XCTAssertGreaterThan(frame(for: moreRoomBelow).minY, moreRoomBelow.minY,
                             "60pt below beats 40pt above")

        let moreRoomAbove = CGRect(x: 100, y: 60, width: 200, height: 700)
        XCTAssertLessThan(frame(for: moreRoomAbove).minY, moreRoomAbove.minY,
                          "60pt above beats 40pt below")
    }
}
