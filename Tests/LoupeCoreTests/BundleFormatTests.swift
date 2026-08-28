import XCTest
@testable import LoupeCore

/// The format is the contract with every other language. These tests hold the
/// documentation to it: the example in `docs/` must decode, and a bundle written
/// before a field existed must still read.
final class BundleFormatTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LoupeCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func testTheDocumentedExampleDecodes() throws {
        let url = repoRoot.appendingPathComponent("docs/bundle-format.example.json")
        let bundle = try decoder().decode(AnnotationBundle.self, from: Data(contentsOf: url))

        XCTAssertEqual(bundle.formatVersion, 1)
        XCTAssertEqual(bundle.app.platform, "iPadOS")
        XCTAssertEqual(bundle.annotations.count, 2)
        XCTAssertEqual(bundle.annotations[0].element.accessibilityID, "search.results.list")
        XCTAssertEqual(bundle.annotations[0].trace.last?.statusCode, 500)
        XCTAssertEqual(bundle.annotations[0].logs.first?.level, .error)
        XCTAssertEqual(bundle.annotations[0].viewport?.width, 1024)
        XCTAssertEqual(bundle.annotations[1].element.selector, "main > .cart > .empty-state")
    }

    /// The rule the doc states plainly: adding a field is safe. Prove it against a
    /// bundle shaped the way the very first release wrote them.
    func testABundleFromBeforeTheseFieldsExistedStillDecodes() throws {
        let legacy = """
        {
          "sessionID": "6F9619FF-8B86-D011-B42D-00CF4FC964FF",
          "sentAt": "2026-08-27T10:00:00Z",
          "app": { "name": "Old", "platform": "macOS" },
          "annotations": [{
            "id": "1D2C3B4A-0000-4000-8000-000000000001",
            "comment": "written by v0",
            "capturedAt": "2026-08-27T09:59:00Z",
            "element": { "bounds": { "x": 0, "y": 0, "width": 8, "height": 8 } }
          }]
        }
        """.data(using: .utf8)!

        let bundle = try decoder().decode(AnnotationBundle.self, from: legacy)

        XCTAssertEqual(bundle.formatVersion, 1, "a bundle with no version is version 1")
        XCTAssertEqual(bundle.app.environment, "staging")
        XCTAssertEqual(bundle.annotations[0].logs, [])
        XCTAssertEqual(bundle.annotations[0].trace, [])
        XCTAssertNil(bundle.annotations[0].viewport)
    }

    func testAReaderIgnoresFieldsItDoesNotKnow() throws {
        let fromTheFuture = """
        {
          "formatVersion": 1,
          "sessionID": "6F9619FF-8B86-D011-B42D-00CF4FC964FF",
          "sentAt": "2026-08-27T10:00:00Z",
          "somethingAddedLater": { "nested": true },
          "app": { "name": "New", "platform": "visionOS", "unknownField": 3 },
          "annotations": [{
            "id": "1D2C3B4A-0000-4000-8000-000000000001",
            "comment": "hello",
            "capturedAt": "2026-08-27T09:59:00Z",
            "gazeTarget": "not a thing yet",
            "element": { "bounds": { "x": 0, "y": 0, "width": 8, "height": 8 } }
          }]
        }
        """.data(using: .utf8)!

        let bundle = try decoder().decode(AnnotationBundle.self, from: fromTheFuture)
        XCTAssertEqual(bundle.app.platform, "visionOS")
        XCTAssertEqual(bundle.annotations.count, 1)
    }

    func testANewBundleIsStampedWithTheCurrentVersion() {
        let bundle = AnnotationBundle(
            sessionID: UUID(),
            app: AppInfo(name: "Demo", platform: "web"),
            annotations: [])
        XCTAssertEqual(bundle.formatVersion, AnnotationBundle.currentFormatVersion)
    }

    /// On disk the PNG sits beside the JSON. An agent has to be able to find it by
    /// annotation id, so that id must survive the write.
    func testTheOnDiskShapeNamesScreenshotsByAnnotationId() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let annotation = Annotation(
            comment: "with a crop",
            element: ElementRef(bounds: Rect(x: 0, y: 0, width: 4, height: 4)),
            screenshotPNG: Data([0x89, 0x50, 0x4E, 0x47]))
        let bundle = AnnotationBundle(sessionID: UUID(),
                                      app: AppInfo(name: "Demo", platform: "macOS"),
                                      annotations: [annotation])

        try await FileTransport(directory: directory).send(bundle)

        let folder = directory.appendingPathComponent(bundle.sessionID.uuidString)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("\(annotation.id.uuidString).png").path))

        let written = try decoder().decode(
            AnnotationBundle.self,
            from: Data(contentsOf: folder.appendingPathComponent("bundle.json")))
        XCTAssertNil(written.annotations[0].screenshotPNG,
                     "on disk the bytes live in the png, not in the json")
        XCTAssertEqual(written.formatVersion, 1)
    }
}
