import XCTest
@testable import LoupeCore

/// Fails on demand, so a test can make the network come back.
private final class FlakyTransport: Transport, @unchecked Sendable {
    var shouldFail: Bool
    var sent: [AnnotationBundle] = []

    init(shouldFail: Bool) { self.shouldFail = shouldFail }

    func send(_ bundle: AnnotationBundle) async throws {
        if shouldFail { throw LoupeError.transportFailed("offline") }
        sent.append(bundle)
    }
}

private func makeBundle(_ comment: String, sentAt: Date = Date()) -> AnnotationBundle {
    AnnotationBundle(
        sessionID: UUID(),
        app: AppInfo(name: "Demo", platform: "macOS"),
        annotations: [
            Annotation(comment: comment,
                       element: ElementRef(bounds: Rect(x: 0, y: 0, width: 10, height: 10)))
        ],
        sentAt: sentAt
    )
}

final class QueuedTransportTests: XCTestCase {

    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testASuccessfulSendLeavesNothingPending() async throws {
        let inner = FlakyTransport(shouldFail: false)
        let queue = QueuedTransport(wrapping: inner, directory: directory)

        try await queue.send(makeBundle("goes straight out"))

        XCTAssertEqual(inner.sent.count, 1)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testAFailedSendKeepsTheBundleOnDiskAndRethrows() async {
        let inner = FlakyTransport(shouldFail: true)
        let queue = QueuedTransport(wrapping: inner, directory: directory)

        do {
            try await queue.send(makeBundle("survives a crash"))
            XCTFail("expected the send to throw")
        } catch {
            XCTAssertEqual(queue.pendingCount, 1,
                           "a failed send must leave the bundle on disk")
        }
    }

    func testDrainShipsWhatWasPendingOnceTheNetworkComesBack() async throws {
        let inner = FlakyTransport(shouldFail: true)
        let queue = QueuedTransport(wrapping: inner, directory: directory)

        try? await queue.send(makeBundle("first"))
        XCTAssertEqual(queue.pendingCount, 1)

        inner.shouldFail = false
        try await queue.drain()

        XCTAssertEqual(inner.sent.map { $0.annotations[0].comment }, ["first"])
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testPendingBundlesDrainOldestFirst() async throws {
        let inner = FlakyTransport(shouldFail: true)
        let queue = QueuedTransport(wrapping: inner, directory: directory)
        let base = Date(timeIntervalSince1970: 1_000_000)

        try? await queue.send(makeBundle("oldest", sentAt: base))
        try? await queue.send(makeBundle("middle", sentAt: base.addingTimeInterval(60)))
        try? await queue.send(makeBundle("newest", sentAt: base.addingTimeInterval(120)))

        inner.shouldFail = false
        try await queue.drain()

        XCTAssertEqual(inner.sent.map { $0.annotations[0].comment },
                       ["oldest", "middle", "newest"])
    }

    // A fresh process must see what the previous one could not deliver. Nothing is
    // held in memory, so a new instance over the same folder finds the backlog.
    func testABacklogSurvivesAcrossInstances() async throws {
        let offline = QueuedTransport(wrapping: FlakyTransport(shouldFail: true),
                                      directory: directory)
        try? await offline.send(makeBundle("written before the crash"))

        let inner = FlakyTransport(shouldFail: false)
        let afterRestart = QueuedTransport(wrapping: inner, directory: directory)

        XCTAssertEqual(afterRestart.pendingCount, 1)
        try await afterRestart.drain()
        XCTAssertEqual(inner.sent.map { $0.annotations[0].comment },
                       ["written before the crash"])
    }

    func testDrainStopsAtTheFirstFailureSoOrderIsKept() async {
        let inner = FlakyTransport(shouldFail: true)
        let queue = QueuedTransport(wrapping: inner, directory: directory)

        try? await queue.send(makeBundle("a"))
        try? await queue.send(makeBundle("b"))

        do {
            try await queue.drain()
            XCTFail("expected the drain to throw")
        } catch {
            XCTAssertEqual(queue.pendingCount, 2, "nothing is dropped on a failed drain")
        }
    }

    func testScreenshotsSurviveTheRoundTripThroughDisk() async throws {
        let inner = FlakyTransport(shouldFail: true)
        let queue = QueuedTransport(wrapping: inner, directory: directory)

        var bundle = makeBundle("with a crop")
        bundle.annotations[0].screenshotPNG = Data([0x89, 0x50, 0x4E, 0x47])
        try? await queue.send(bundle)

        inner.shouldFail = false
        try await queue.drain()

        XCTAssertEqual(inner.sent.first?.annotations[0].screenshotPNG,
                       Data([0x89, 0x50, 0x4E, 0x47]))
    }
}
