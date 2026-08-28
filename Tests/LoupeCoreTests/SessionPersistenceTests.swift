import XCTest
@testable import LoupeCore

private final class NoopTransport: Transport {
    func send(_ bundle: AnnotationBundle) async throws {}
}

private func annotation(_ comment: String) -> Annotation {
    Annotation(comment: comment,
               element: ElementRef(bounds: Rect(x: 0, y: 0, width: 10, height: 10)))
}

/// Killing the app must not lose what someone already typed. The tray is written
/// to disk on every change, not only when Send is pressed.
@MainActor
final class SessionPersistenceTests: XCTestCase {

    // XCTest builds a fresh instance per test method, so this is already unique per
    // test. A `let` of a Sendable type is also readable from the nonisolated
    // tearDown, which a `var` on a main-actor class is not.
    private let file = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(UUID().uuidString)/tray.json")

    override func tearDown() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        super.tearDown()
    }

    private func makeSession() -> AnnotationSession {
        AnnotationSession(app: AppInfo(name: "Demo", platform: "macOS"),
                          transport: NoopTransport(),
                          persistingTo: file)
    }

    func testAnAddedAnnotationIsOnDiskImmediately() {
        let session = makeSession()
        session.add(annotation("typed before the crash"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(makeSession().annotations.map(\.comment), ["typed before the crash"])
    }

    func testTheSessionIdSurvivesSoOneTrayStaysOneBundle() {
        let session = makeSession()
        session.add(annotation("first"))
        XCTAssertEqual(makeSession().id, session.id)
    }

    func testRemovingAndEditingAreBothPersisted() {
        let session = makeSession()
        let keep = annotation("keep")
        let drop = annotation("drop")
        session.add(keep)
        session.add(drop)
        session.remove(id: drop.id)
        session.updateComment(id: keep.id, comment: "edited")

        XCTAssertEqual(makeSession().annotations.map(\.comment), ["edited"])
    }

    func testASuccessfulSendClearsTheSavedTray() async throws {
        let session = makeSession()
        session.add(annotation("goes out"))
        try await session.send()

        XCTAssertTrue(makeSession().isEmpty)
    }

    func testAFailedSendKeepsTheSavedTray() async {
        final class Failing: Transport {
            func send(_ bundle: AnnotationBundle) async throws {
                throw LoupeError.transportFailed("offline")
            }
        }
        let session = AnnotationSession(app: AppInfo(name: "Demo", platform: "macOS"),
                                        transport: Failing(),
                                        persistingTo: file)
        session.add(annotation("stays put"))
        _ = try? await session.send()

        XCTAssertEqual(makeSession().annotations.map(\.comment), ["stays put"])
    }

    func testASessionWithNoFileStillWorks() {
        let session = AnnotationSession(app: AppInfo(name: "Demo", platform: "macOS"),
                                        transport: NoopTransport())
        session.add(annotation("in memory only"))
        XCTAssertEqual(session.count, 1)
    }
}
