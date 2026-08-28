import XCTest
@testable import LoupeCore

/// Fails a fixed number of times, then succeeds. Stands in for a network coming back.
private final class FailsNTimes: Transport, @unchecked Sendable {
    private let failures: Int
    private(set) var attempts = 0

    init(failures: Int) { self.failures = failures }

    func send(_ bundle: AnnotationBundle) async throws {
        attempts += 1
        if attempts <= failures { throw LoupeError.transportFailed("offline") }
    }
}

private func bundle() -> AnnotationBundle {
    AnnotationBundle(sessionID: UUID(),
                     app: AppInfo(name: "Demo", platform: "macOS"),
                     annotations: [Annotation(
                        comment: "x",
                        element: ElementRef(bounds: Rect(x: 0, y: 0, width: 1, height: 1)))])
}

final class RetryTests: XCTestCase {

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

    func testDrainRetriesUntilTheNetworkComesBack() async throws {
        let inner = FailsNTimes(failures: 2)
        let queue = QueuedTransport(wrapping: inner, directory: directory)
        _ = try? await queue.send(bundle())

        try await queue.drain(attempts: 4, initialDelay: 0.001)

        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertGreaterThan(inner.attempts, 1)
    }

    func testDrainGivesUpAfterTheLastAttemptAndKeepsTheBacklog() async {
        let inner = FailsNTimes(failures: 99)
        let queue = QueuedTransport(wrapping: inner, directory: directory)
        _ = try? await queue.send(bundle())

        do {
            try await queue.drain(attempts: 2, initialDelay: 0.001)
            XCTFail("expected the drain to give up")
        } catch {
            XCTAssertEqual(queue.pendingCount, 1, "the backlog is never dropped")
        }
    }
}
