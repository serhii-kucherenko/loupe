import XCTest
import LoupeCore
@testable import LoupeUI

/// `docs/tokens.json` is what the Swift SDK and the web SDK are both tested against,
/// so a token cannot quietly come to mean two different things on two platforms.
/// This is the Swift half of that check.
final class TokenManifestTests: XCTestCase {

    private struct Manifest: Decodable {
        struct Colour: Decodable {
            let light: String, dark: String
            let lightAlpha: Double, darkAlpha: Double
        }
        let color: [String: Colour]
        let space: [String: Double]
        let radius: [String: Double]
        let stroke: [String: Double]
        let motion: [String: Double]
        let hit: [String: Double]
        let tag: [String: String]
    }

    private func manifest() throws -> Manifest {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/tokens.json")
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }

    private func hex(_ colour: LoupeTheme.RGBA) -> String {
        String(format: "#%02X%02X%02X",
               Int((colour.red * 255).rounded()),
               Int((colour.green * 255).rounded()),
               Int((colour.blue * 255).rounded()))
    }

    func testEveryColourMatchesTheManifest() throws {
        let m = try manifest()
        let tokens: [String: LoupeTheme.ColorToken] = [
            "highlight": LoupeTheme.Colors.highlight,
            "highlight.fill": LoupeTheme.Colors.highlightFill,
            "surface": LoupeTheme.Colors.surface,
            "ink": LoupeTheme.Colors.ink,
            "ink.soft": LoupeTheme.Colors.inkSoft,
            "line": LoupeTheme.Colors.line,
            "action": LoupeTheme.Colors.action,
            "scrim": LoupeTheme.Colors.scrim,
        ]

        XCTAssertEqual(Set(tokens.keys), Set(m.color.keys),
                       "the Swift palette and the manifest name different tokens")

        for (name, token) in tokens {
            guard let expected = m.color[name] else { continue }
            XCTAssertEqual(hex(token.light), expected.light, "\(name) light")
            XCTAssertEqual(hex(token.dark), expected.dark, "\(name) dark")
            XCTAssertEqual(token.light.alpha, expected.lightAlpha, accuracy: 0.001, "\(name) light alpha")
            XCTAssertEqual(token.dark.alpha, expected.darkAlpha, accuracy: 0.001, "\(name) dark alpha")
        }
    }

    func testEveryNumberMatchesTheManifest() throws {
        let m = try manifest()

        XCTAssertEqual(m.space["xs"], LoupeTheme.Space.xs)
        XCTAssertEqual(m.space["sm"], LoupeTheme.Space.sm)
        XCTAssertEqual(m.space["md"], LoupeTheme.Space.md)
        XCTAssertEqual(m.space["lg"], LoupeTheme.Space.lg)
        XCTAssertEqual(m.space["xl"], LoupeTheme.Space.xl)
        XCTAssertEqual(m.space["xxl"], LoupeTheme.Space.xxl)

        XCTAssertEqual(m.radius["panel"], LoupeTheme.Radius.panel)
        XCTAssertEqual(m.radius["control"], LoupeTheme.Radius.control)
        XCTAssertEqual(m.radius["highlight"], LoupeTheme.Radius.highlight)

        XCTAssertEqual(m.stroke["highlight"], LoupeTheme.Stroke.highlight)
        XCTAssertEqual(m.stroke["focus"], LoupeTheme.Stroke.focus)
        XCTAssertEqual(m.stroke["focusOffset"], LoupeTheme.Stroke.focusOffset)
        XCTAssertEqual(m.stroke["hairline"], LoupeTheme.Stroke.hairline)

        // The manifest is in milliseconds, because CSS is.
        XCTAssertEqual((m.motion["hover"] ?? 0) / 1000, LoupeTheme.Motion.hoverDuration, accuracy: 0.001)
        XCTAssertEqual((m.motion["panel"] ?? 0) / 1000, LoupeTheme.Motion.panelDuration, accuracy: 0.001)
        XCTAssertEqual((m.motion["commit"] ?? 0) / 1000, LoupeTheme.Motion.commitDuration, accuracy: 0.001)

        XCTAssertEqual(m.hit["touch"], LoupeTheme.Hit.touch)
        XCTAssertEqual(m.hit["pointer"], LoupeTheme.Hit.pointer)
    }

    func testTagsMapToTheSamePaletteEntriesOnBothPlatforms() throws {
        let m = try manifest()
        let names: [AnnotationTag: String] = [
            .bug: "highlight", .idea: "ink.soft", .polish: "ink.soft", .question: "action",
        ]
        for tag in AnnotationTag.allCases {
            XCTAssertEqual(m.tag[tag.rawValue], names[tag], "\(tag) in the manifest")
        }
        // And that the Swift side really resolves to that palette entry.
        XCTAssertEqual(LoupeTheme.color(for: .bug), LoupeTheme.Colors.highlight)
        XCTAssertEqual(LoupeTheme.color(for: .idea), LoupeTheme.Colors.inkSoft)
        XCTAssertEqual(LoupeTheme.color(for: .polish), LoupeTheme.Colors.inkSoft)
        XCTAssertEqual(LoupeTheme.color(for: .question), LoupeTheme.Colors.action)
    }
}
