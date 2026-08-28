import XCTest
@testable import LoupeCore

private func makeAnnotation(_ comment: String) -> Annotation {
    Annotation(
        comment: comment,
        element: ElementRef(bounds: Rect(x: 0, y: 0, width: 100, height: 40))
    )
}

private struct CapturingTransport: Transport {
    final class Box: @unchecked Sendable { var bundles: [AnnotationBundle] = [] }
    let box = Box()
    func send(_ bundle: AnnotationBundle) async throws { box.bundles.append(bundle) }
}

private struct FailingTransport: Transport {
    func send(_ bundle: AnnotationBundle) async throws {
        throw LoupeError.transportFailed("nope")
    }
}

private let testApp = AppInfo(name: "Demo", platform: "macOS")

final class AnnotationSessionTests: XCTestCase {

    func testTrayCollectsAcrossPicks() {
        let session = AnnotationSession(app: testApp, transport: CapturingTransport())
        session.add(makeAnnotation("stale results"))
        session.add(makeAnnotation("empty state is ugly"))
        XCTAssertEqual(session.count, 2)
        XCTAssertEqual(session.makeBundle().annotations.map(\.comment),
                       ["stale results", "empty state is ugly"])
    }

    func testSendShipsBatchThenStartsFreshSession() async throws {
        let transport = CapturingTransport()
        let session = AnnotationSession(app: testApp, transport: transport)
        let firstID = session.id
        session.add(makeAnnotation("a"))
        session.add(makeAnnotation("b"))

        try await session.send()

        XCTAssertEqual(transport.box.bundles.count, 1)
        XCTAssertEqual(transport.box.bundles[0].annotations.count, 2)
        XCTAssertTrue(session.isEmpty)
        XCTAssertNotEqual(session.id, firstID, "a new session starts after send")
    }

    func testSendKeepsTrayWhenTransportFails() async {
        let session = AnnotationSession(app: testApp, transport: FailingTransport())
        session.add(makeAnnotation("keep me"))

        do {
            try await session.send()
            XCTFail("expected the send to throw")
        } catch {
            XCTAssertEqual(session.count, 1, "a failed send must not lose annotations")
        }
    }

    func testSendingAnEmptyTrayIsRejected() async {
        let session = AnnotationSession(app: testApp, transport: CapturingTransport())
        do {
            try await session.send()
            XCTFail("expected the send to throw")
        } catch {
            XCTAssertEqual(error as? LoupeError, .emptySession)
        }
    }
}

final class NetworkRecorderTests: XCTestCase {

    func testRingBufferDropsOldestBeyondCapacity() {
        let recorder = NetworkRecorder(capacity: 3)
        for i in 0..<5 {
            recorder.record(NetworkEvent(method: "GET", url: "/\(i)",
                                         statusCode: 200, durationMs: 1, at: Date()))
        }
        XCTAssertEqual(recorder.recent().map(\.url), ["/2", "/3", "/4"])
    }

    func testRecentKeepsOnlyTheWindowAroundThePick() {
        let recorder = NetworkRecorder(capacity: 10)
        let now = Date()
        recorder.record(NetworkEvent(method: "GET", url: "/old", statusCode: 200,
                                     durationMs: 1, at: now.addingTimeInterval(-120)))
        recorder.record(NetworkEvent(method: "GET", url: "/fresh", statusCode: 200,
                                     durationMs: 1, at: now.addingTimeInterval(-2)))

        XCTAssertEqual(recorder.recent(within: 30, now: now).map(\.url), ["/fresh"])
    }
}

final class FileTransportTests: XCTestCase {

    // Regression: `homeDirectoryForCurrentUser` is unavailable on iOS, so this
    // used to fail to compile for the platform Loupe targets first.
    func testDefaultDirectoryResolvesOnEveryPlatform() {
        let dir = FileTransport.defaultDirectory(appName: "Demo")
        XCTAssertTrue(dir.path.hasSuffix("Demo"))
        XCTAssertTrue(dir.isFileURL)
    }

    func testWritesJSONAndScreenshotsSideBySide() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        var annotation = makeAnnotation("with a crop")
        annotation.screenshotPNG = Data([0x89, 0x50, 0x4E, 0x47])

        let session = AnnotationSession(app: testApp, transport: FileTransport(directory: dir))
        session.add(annotation)
        let bundle = try await session.send()

        let folder = dir.appendingPathComponent(bundle.sessionID.uuidString)
        let json = folder.appendingPathComponent("bundle.json")
        let png = folder.appendingPathComponent("\(annotation.id.uuidString).png")

        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path))

        // The image is written beside the JSON, not embedded in it.
        let text = try String(contentsOf: json, encoding: .utf8)
        XCTAssertFalse(text.contains("screenshotPNG"))
        XCTAssertTrue(text.contains("with a crop"))
    }
}
