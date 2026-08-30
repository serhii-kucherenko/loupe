import XCTest
@testable import LoupeCore

/// `platform: "iPadOS"` does not say which iPad, at what scale, on which point
/// release, or whether the window was the whole screen - and a layout bug is not
/// reproducible without those.
final class DeviceInfoTests: XCTestCase {

    private func screen(_ w: Double, _ h: Double, scale: Double = 2) -> DeviceInfo.Screen {
        DeviceInfo.Screen(width: w, height: h, scale: scale)
    }

    // MARK: - Split View, the field that earns the rest

    func testAWindowNarrowerThanTheScreenIsOnlyPartOfIt() {
        let device = DeviceInfo(screen: screen(1194, 834))
        let split = Rect(x: 0, y: 0, width: 507, height: 834)

        XCTAssertEqual(device.isPartOfTheScreen(viewport: split), true)
    }

    func testAFullScreenWindowIsNotSplit() {
        let device = DeviceInfo(screen: screen(1194, 834))
        let whole = Rect(x: 0, y: 0, width: 1194, height: 834)

        XCTAssertEqual(device.isPartOfTheScreen(viewport: whole), false)
    }

    /// A window inset by a hairline is still the whole screen as far as anybody
    /// reading a bug report cares. Reporting Split View for it would be noise, and
    /// noise in a field like this is how people learn to skip it.
    func testAHairlineInsetIsStillTheWholeScreen() {
        let device = DeviceInfo(screen: screen(1194, 834))
        let almost = Rect(x: 0, y: 0, width: 1193.5, height: 834)

        XCTAssertEqual(device.isPartOfTheScreen(viewport: almost), false)
    }

    /// nil, not false. "Not split" and "we do not know" are different answers, and a
    /// caller that cannot tell them apart writes a confident sentence about neither.
    func testNothingToCompareIsNotAnAnswer() {
        XCTAssertNil(DeviceInfo(screen: screen(1194, 834)).isPartOfTheScreen(viewport: nil))
        XCTAssertNil(DeviceInfo().isPartOfTheScreen(
            viewport: Rect(x: 0, y: 0, width: 100, height: 100)))
    }

    // MARK: - Reading it off this machine

    func testThisMachineAnswersWithSomethingUsable() {
        let device = DeviceInfo.current()

        XCTAssertNotNil(device.osVersion, "every platform can say its own version")
        XCTAssertFalse(device.osVersion?.isEmpty ?? true)
        // A model identifier is `Family<major>,<minor>`. Asserting the shape rather
        // than a value, because the value depends on whose machine this runs on.
        if let identifier = device.identifier {
            XCTAssertTrue(identifier.contains(","), "a model identifier, got \(identifier)")
        }
    }

    /// Loupe never guesses a name from a prefix. A wrong device in a bug report sends
    /// somebody to reproduce a layout bug on hardware that is not the hardware, which
    /// is worse than a blank field.
    func testAnUnknownModelHasNoNameRatherThanAGuessedOne() {
        XCTAssertNil(DeviceInfo.names["iPad99,9"])
        XCTAssertNil(DeviceInfo.names["iPad8"])
        XCTAssertEqual(DeviceInfo.names["iPad8,3"], "iPad Pro 11-inch")
    }

    // MARK: - The format stays additive

    func testABundleFromBeforeTheDeviceFieldStillDecodes() throws {
        let legacy = """
        {
          "sessionID": "6F9619FF-8B86-D011-B42D-00CF4FC964FF",
          "sentAt": "2026-08-27T10:00:00Z",
          "app": { "name": "Old", "platform": "iPadOS" },
          "annotations": []
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(AnnotationBundle.self, from: legacy)

        XCTAssertNil(bundle.app.device, "absent is a real answer, not a decode failure")
        XCTAssertEqual(bundle.app.platform, "iPadOS")
    }

    func testTheDeviceSurvivesARoundTrip() throws {
        let app = AppInfo(name: "Demo", platform: "iPadOS",
                          device: DeviceInfo(identifier: "iPad8,3",
                                             name: "iPad Pro 11-inch",
                                             osVersion: "26.5",
                                             screen: screen(834, 1194)))
        let bundle = AnnotationBundle(sessionID: UUID(), app: app, annotations: [])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(AnnotationBundle.self,
                                      from: try encoder.encode(bundle))

        XCTAssertEqual(back.app.device, app.device)
    }

    /// The rule that keeps a bundle safe to paste into a public repository. Asserted
    /// on the encoded JSON rather than on the type, because the JSON is what travels.
    func testTheEncodedDeviceCarriesNothingIdentifying() throws {
        let app = AppInfo(name: "Demo", platform: "iPadOS", device: DeviceInfo.current())
        let json = String(decoding: try JSONEncoder().encode(app), as: UTF8.self)

        for forbidden in ["identifierForVendor", "advertisingIdentifier", "deviceName",
                          "serial", "udid", "locale"] {
            XCTAssertFalse(json.lowercased().contains(forbidden.lowercased()),
                           "a bundle gets pasted into tickets: \(forbidden) in \(json)")
        }
    }
}
