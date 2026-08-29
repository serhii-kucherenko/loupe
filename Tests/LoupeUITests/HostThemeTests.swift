import XCTest
import SwiftUI
import LoupeCore
@testable import LoupeUI

/// Loupe stands inside somebody else's app. These hold it to the one promise that
/// makes that bearable: it wears the host's tokens if the host has any, and its own
/// if not.
///
/// "the button is not following design system buttons that I already have in the
/// app" - Serhii, 2026-08-29, looking at Loupe on top of Reco.
final class HostThemeTests: XCTestCase {

    private let blue = LoupeTheme.ColorToken(light: LoupeTheme.RGBA(hex: 0x2563EB),
                                             dark: LoupeTheme.RGBA(hex: 0x7AA5F5))

    // The theme is global by design - one overlay, one app - so a test that changes
    // it has to put it back, or every later test is reading this one's opinion.
    override func tearDown() {
        LoupeTheme.appearance = .stock
        super.tearDown()
    }

    @MainActor
    private func startLoupe(theme: LoupeTheme.Appearance) {
        Loupe.start(app: AppInfo(name: "Demo", platform: "macOS"),
                    transport: FileTransport(directory: URL(fileURLWithPath:
                        NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)),
                    theme: theme)
    }

    // MARK: - What a host supplies is what gets drawn

    func testAHostsAccentBecomesTheHighlight() {
        LoupeTheme.appearance = LoupeTheme.Appearance(accent: blue)

        XCTAssertEqual(LoupeTheme.Colors.highlight, blue)
    }

    /// A host names one accent. Having to also state the wash, at the right two
    /// alphas, in both appearances, is exactly the kind of homework that makes a
    /// theming hook go unused.
    func testTheWashFollowsTheAccentWithoutBeingAsked() {
        LoupeTheme.appearance = LoupeTheme.Appearance(accent: blue)

        let fill = LoupeTheme.Colors.highlightFill
        XCTAssertEqual(fill.light.red, blue.light.red, accuracy: 0.001)
        XCTAssertEqual(fill.light.alpha, 0.10, accuracy: 0.001)
        XCTAssertEqual(fill.dark.alpha, 0.14, accuracy: 0.001)
    }

    func testAHostWithItsOwnWashKeepsIt() {
        let wash = LoupeTheme.ColorToken(light: LoupeTheme.RGBA(hex: 0x00FF00, alpha: 0.5),
                                         dark: LoupeTheme.RGBA(hex: 0x00FF00, alpha: 0.5))
        LoupeTheme.appearance = LoupeTheme.Appearance(accent: blue, accentFill: wash)

        XCTAssertEqual(LoupeTheme.Colors.highlightFill, wash)
    }

    func testAHostsFontsReachTheLabels() {
        LoupeTheme.appearance = LoupeTheme.Appearance(label: .largeTitle, note: .footnote)

        XCTAssertEqual(LoupeTheme.Typography.label, Font.largeTitle)
        XCTAssertEqual(LoupeTheme.Typography.note, Font.footnote)
    }

    func testAHostsRadiiReachThePanelAndTheControls() {
        LoupeTheme.appearance = LoupeTheme.Appearance(panelRadius: 4, controlRadius: 2)

        XCTAssertEqual(LoupeTheme.Radius.panel, 4)
        XCTAssertEqual(LoupeTheme.Radius.control, 2)
    }

    /// The tag chips read the palette rather than holding colours of their own, so
    /// they have to follow a host's accent too. A chip in Loupe's orange on top of a
    /// blue app is the whole complaint in miniature.
    func testTagColoursFollowTheHostToo() {
        LoupeTheme.appearance = LoupeTheme.Appearance(accent: blue)

        XCTAssertEqual(LoupeTheme.color(for: .bug), blue)
    }

    // MARK: - And what it does not supply stays Loupe's

    func testOmittingAFieldKeepsLoupesOwnValue() {
        LoupeTheme.appearance = LoupeTheme.Appearance(accent: blue)

        XCTAssertEqual(LoupeTheme.Colors.ink, LoupeTheme.Appearance.stock.ink)
        XCTAssertEqual(LoupeTheme.Colors.surface, LoupeTheme.Appearance.stock.surface)
        XCTAssertEqual(LoupeTheme.Radius.panel, LoupeTheme.Appearance.stock.panelRadius)
    }

    /// An SDK that changes how the app looks the moment it is linked is an SDK
    /// nobody ships. Starting without a theme has to be the same picture as before
    /// the theming hook existed.
    @MainActor
    func testStartingWithNoThemeIsExactlyLoupesOwnLook() {
        LoupeTheme.appearance = LoupeTheme.Appearance(accent: blue)

        Loupe.start(app: AppInfo(name: "Demo", platform: "macOS"))

        XCTAssertEqual(LoupeTheme.appearance, .stock)
    }

    @MainActor
    func testStartAppliesTheHostsThemeAndStopPutsLoupesBack() {
        startLoupe(theme: LoupeTheme.Appearance(accent: blue))
        XCTAssertEqual(LoupeTheme.Colors.highlight, blue)

        Loupe.stop()

        XCTAssertEqual(LoupeTheme.appearance, .stock,
                       "a second start with no theme must not wear the last host's")
    }
}
