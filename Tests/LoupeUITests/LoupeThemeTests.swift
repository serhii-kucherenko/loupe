import XCTest
import LoupeCore
@testable import LoupeUI

/// `DESIGN.md` promises contrast out loud. A promise you cannot measure is a
/// promise you will break, so these tests hold the tokens to it.
final class LoupeThemeTests: XCTestCase {

    private func surface(dark: Bool) -> LoupeTheme.RGBA {
        // Every panel is translucent, so the contrast that matters is the one
        // after it has been composited onto whatever sits behind it.
        LoupeTheme.Colors.surface.value(dark: dark)
            .composited(over: LoupeTheme.Colors.backdrop.value(dark: dark))
    }

    func testPrimaryTextClears4point5OnSurfaceInBothThemes() {
        for dark in [false, true] {
            let ratio = LoupeTheme.Colors.ink.value(dark: dark)
                .contrastRatio(against: surface(dark: dark))
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "loupe.ink on loupe.surface is \(ratio) in \(dark ? "dark" : "light")")
        }
    }

    func testSecondaryTextClears4point5OnSurfaceInBothThemes() {
        for dark in [false, true] {
            let ratio = LoupeTheme.Colors.inkSoft.value(dark: dark)
                .contrastRatio(against: surface(dark: dark))
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "loupe.ink.soft on loupe.surface is \(ratio) in \(dark ? "dark" : "light")")
        }
    }

    /// The focus ring reuses `loupe.highlight`. A ring under 3:1 is decoration.
    func testTheFocusRingClears3OnSurfaceInBothThemes() {
        for dark in [false, true] {
            let ratio = LoupeTheme.Colors.highlight.value(dark: dark)
                .contrastRatio(against: surface(dark: dark))
            XCTAssertGreaterThanOrEqual(ratio, 3.0,
                                        "the focus ring is \(ratio) in \(dark ? "dark" : "light")")
        }
    }

    func testTheSendButtonColourClears3OnSurfaceInBothThemes() {
        for dark in [false, true] {
            let ratio = LoupeTheme.Colors.action.value(dark: dark)
                .contrastRatio(against: surface(dark: dark))
            XCTAssertGreaterThanOrEqual(ratio, 3.0)
        }
    }

    func testKnownContrastMathsIsRight() {
        let white = LoupeTheme.RGBA(hex: 0xFFFFFF)
        let black = LoupeTheme.RGBA(hex: 0x000000)
        XCTAssertEqual(white.contrastRatio(against: black), 21, accuracy: 0.01)
        XCTAssertEqual(white.contrastRatio(against: white), 1, accuracy: 0.01)
    }

    func testCompositingATranslucentColourLandsBetweenTheTwo() {
        let half = LoupeTheme.RGBA(hex: 0x000000, alpha: 0.5)
        let over = half.composited(over: LoupeTheme.RGBA(hex: 0xFFFFFF))
        XCTAssertEqual(over.red, 0.5, accuracy: 0.001)
        XCTAssertEqual(over.alpha, 1, accuracy: 0.001)
    }

    /// `DESIGN.md` allows exactly six spacing steps. A seventh is a bug, not a nuance.
    func testSpacingIsThe4ptScaleAndNothingElse() {
        XCTAssertEqual(LoupeTheme.Space.all, [4, 8, 12, 16, 24, 32])
        for step in LoupeTheme.Space.all {
            XCTAssertEqual(step.truncatingRemainder(dividingBy: 4), 0)
        }
    }

    func testEveryTagResolvesToAPaletteColourRatherThanANewOne() {
        let palette = [LoupeTheme.Colors.highlight,
                       LoupeTheme.Colors.inkSoft,
                       LoupeTheme.Colors.action]
        for tag in AnnotationTag.allCases {
            XCTAssertTrue(palette.contains(LoupeTheme.color(for: tag)),
                          "\(tag) invented a colour instead of reusing one")
        }
    }

    func testReduceMotionReplacesEverySpatialTransitionWithACrossFade() {
        let crossFade = LoupeTheme.Motion.resolved(.easeOut(duration: LoupeTheme.Motion.hoverDuration),
                                                   reduceMotion: true)
        XCTAssertEqual(LoupeTheme.Motion.resolved(LoupeTheme.Motion.panel, reduceMotion: true),
                       crossFade)
        XCTAssertEqual(LoupeTheme.Motion.resolved(LoupeTheme.Motion.commit, reduceMotion: true),
                       crossFade)
        XCTAssertEqual(LoupeTheme.Motion.resolved(LoupeTheme.Motion.panel, reduceMotion: false),
                       LoupeTheme.Motion.panel)
    }

    func testHitTargetsMeetThePlatformMinimums() {
        XCTAssertGreaterThanOrEqual(LoupeTheme.Hit.touch, 44)
        XCTAssertGreaterThanOrEqual(LoupeTheme.Hit.pointer, 28)
    }
}

/// The Send button paints its label in `loupe.surface` on `loupe.action`. That is
/// text, so it owes 4.5:1, not the 3:1 a plain shape would.
extension LoupeThemeTests {
    func testTheSendButtonLabelClears4point5OnItsOwnFill() {
        for dark in [false, true] {
            let fill = LoupeTheme.Colors.action.value(dark: dark)
            let label = LoupeTheme.Colors.surface.value(dark: dark).composited(over: fill)
            let ratio = label.contrastRatio(against: fill)
            XCTAssertGreaterThanOrEqual(
                ratio, 4.5,
                "the Send label is \(ratio) on its own fill in \(dark ? "dark" : "light")")
        }
    }
}
