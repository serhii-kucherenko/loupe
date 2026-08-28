import XCTest
import LoupeCore
@testable import LoupeLinear

private final class Spy: Transport, @unchecked Sendable {
    var sent = 0
    var failWith: Error?
    func send(_ bundle: AnnotationBundle) async throws {
        if let failWith { throw failWith }
        sent += 1
    }
}

private func bundle() -> AnnotationBundle {
    AnnotationBundle(sessionID: UUID(),
                     app: AppInfo(name: "Demo", platform: "iOS"),
                     annotations: [Annotation(
                        comment: "a note",
                        element: ElementRef(bounds: Rect(x: 0, y: 0, width: 1, height: 1)))],
                     sentAt: Date())
}

final class LinearDeliveryTests: XCTestCase {

    private let account = "test-\(UUID().uuidString)"

    private func settings() -> LinearSettings {
        LinearSettings(account: account, defaults: UserDefaults(suiteName: account)!)
    }

    override func tearDown() {
        settings().clearCredential()
        UserDefaults().removePersistentDomain(forName: account)
        super.tearDown()
    }

    // Someone who has not set Linear up yet is still annotating perfectly well.
    func testNotConfiguredIsNotAFailure() async throws {
        let local = Spy()
        let delivery = LinearDelivery(keeping: local, settings: settings())

        try await delivery.send(bundle())

        XCTAssertEqual(local.sent, 1, "the local copy is always kept")
    }

    // A Linear outage must never cost somebody their note.
    func testTheLocalCopyIsWrittenBeforeAnythingTouchesTheNetwork() async {
        let local = Spy()
        local.failWith = LoupeError.transportFailed("disk full")
        let delivery = LinearDelivery(keeping: local, settings: settings())

        do {
            try await delivery.send(bundle())
            XCTFail("a failed local write must not be swallowed")
        } catch {
            XCTAssertEqual(local.sent, 0)
        }
    }
}
