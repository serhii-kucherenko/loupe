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
        XCTAssertEqual(bundle.annotations.count, 3, "one of each kind")
        XCTAssertEqual(bundle.annotations[0].element.accessibilityID, "search.results.list")
        XCTAssertEqual(bundle.annotations[0].trace.last?.statusCode, 500)
        XCTAssertEqual(bundle.annotations[0].logs.first?.level, .error)
        XCTAssertEqual(bundle.annotations[0].viewport?.width, 1024)
        XCTAssertEqual(bundle.annotations[1].element.selector, "main > .cart > .empty-state")

        // The drawn shape. It is in the example precisely so a consumer author reads
        // one before writing code that assumes every element is a view.
        let drawn = bundle.annotations[2].element
        XCTAssertEqual(drawn.kind, .path)
        XCTAssertEqual(drawn.path?.count, 8)
        XCTAssertEqual(drawn.bounds, LoupePath.bounds(drawn.path ?? []),
                       "bounds must actually be the shape's box, not a number typed in")
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

/// Two pictures, two questions, and both optional. Added in the same change as the
/// field itself, so the doc and the on-disk layout cannot drift apart.
extension BundleFormatTests {

    func testTheContextShotIsWrittenBesideTheCropAndNamedForIt() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let annotation = Annotation(
            comment: "the row sits too close to the header",
            element: ElementRef(bounds: Rect(x: 0, y: 0, width: 4, height: 4)),
            screenshotPNG: Data([0x89, 0x50, 0x4E, 0x47]),
            contextScreenshotPNG: Data([0x89, 0x50, 0x4E, 0x47, 0x0D]))
        let bundle = AnnotationBundle(sessionID: UUID(),
                                      app: AppInfo(name: "Demo", platform: "macOS"),
                                      annotations: [annotation])

        try await FileTransport(directory: directory).send(bundle)

        let folder = directory.appendingPathComponent(bundle.sessionID.uuidString)
        let id = annotation.id.uuidString
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("\(id).png").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("\(id)-context.png").path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let written = try decoder.decode(
            AnnotationBundle.self,
            from: Data(contentsOf: folder.appendingPathComponent("bundle.json")))
        XCTAssertNil(written.annotations[0].screenshotPNG)
        XCTAssertNil(written.annotations[0].contextScreenshotPNG,
                     "on disk the bytes live in the pngs, not in the json")
    }

    func testABundleWithNeitherPictureIsStillValid() throws {
        let noPictures = """
        {
          "formatVersion": 1,
          "sessionID": "6F9619FF-8B86-D011-B42D-00CF4FC964FF",
          "sentAt": "2026-08-27T10:00:00Z",
          "app": { "name": "Web", "platform": "web" },
          "annotations": [{
            "id": "1D2C3B4A-0000-4000-8000-000000000001",
            "comment": "a cross-origin image tainted the canvas",
            "capturedAt": "2026-08-27T09:59:00Z",
            "element": { "selector": "main > .grid", "bounds": { "x": 0, "y": 0, "width": 8, "height": 8 } }
          }]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(AnnotationBundle.self, from: noPictures)
        XCTAssertNil(bundle.annotations[0].screenshotPNG)
        XCTAssertNil(bundle.annotations[0].contextScreenshotPNG)
        XCTAssertEqual(bundle.annotations[0].element.selector, "main > .grid",
                       "the reference still carries the annotation")
    }

    // MARK: - A drawn shape, and everything that has never heard of one

    /// The pair form is deliberate. A drawn shape is hundreds of points, and
    /// `{"x":…,"y":…}` spends four times the bytes saying the same thing in a payload
    /// that leaves a phone on whatever network is going.
    func testAPathIsWrittenAsPlainPairs() throws {
        let ref = ElementRef(kind: .path,
                             bounds: Rect(x: 10, y: 20, width: 80, height: 60),
                             path: [Point(x: 10, y: 20), Point(x: 90, y: 30),
                                    Point(x: 50, y: 80)])
        let written = String(decoding: try JSONEncoder().encode(ref), as: UTF8.self)

        XCTAssertTrue(written.contains("[[10,20],[90,30],[50,80]]"), written)
        // `bounds` legitimately writes `{"x":…}`; what must not appear is the object
        // form *inside the path array*, which is the one that costs the bytes.
        XCTAssertFalse(written.contains("[{"), "not a list of objects: \(written)")
        XCTAssertTrue(written.contains("\"kind\":\"path\""), written)
    }

    func testAPathSurvivesTheRoundTrip() throws {
        let drawn = [Point(x: 1, y: 2), Point(x: 3.5, y: 4.25), Point(x: 9, y: 0)]
        let ref = ElementRef(kind: .path,
                             bounds: LoupePath.bounds(drawn),
                             path: drawn)
        let back = try JSONDecoder().decode(
            ElementRef.self, from: try JSONEncoder().encode(ref))

        XCTAssertEqual(back.path, drawn)
        XCTAssertEqual(back.kind, .path)
        XCTAssertEqual(back.bounds, Rect(x: 1, y: 0, width: 8, height: 4.25))
    }

    /// The contract for every field added since v1: a consumer that has never heard
    /// of a path gets the rectangle it would have got from a drag. A missing field
    /// degrades quality, never correctness.
    func testAReaderThatOnlyKnowsBoundsStillGetsAUsableRectangle() throws {
        let json = """
        {
          "kind": "path",
          "bounds": { "x": 40, "y": 60, "width": 120, "height": 90 },
          "path": [[40,60],[160,70],[100,150]]
        }
        """.data(using: .utf8)!

        let ref = try JSONDecoder().decode(ElementRef.self, from: json)
        XCTAssertEqual(ref.bounds, Rect(x: 40, y: 60, width: 120, height: 90),
                       "the crop rectangle is there whether or not you read the path")
    }

    /// Additive, the same discipline `region` followed. Every bundle written before
    /// today still means what it meant.
    func testAnElementWithNoPathIsUnchangedAndStillAView() throws {
        let json = """
        { "label": "Save", "bounds": { "x": 0, "y": 0, "width": 10, "height": 10 } }
        """.data(using: .utf8)!

        let ref = try JSONDecoder().decode(ElementRef.self, from: json)
        XCTAssertEqual(ref.kind, .view)
        XCTAssertNil(ref.path)
    }
}
