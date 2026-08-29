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
        // Best effort: a Keychain that refuses the delete is not this test failing,
        // and there may be nothing there to delete in the first place.
        try? settings().clearCredential()
        UserDefaults().removePersistentDomain(forName: account)
        super.tearDown()
    }

    /// This test used to assert the opposite, and the opposite was the bug.
    ///
    /// Serhii, after two notes were reported as sent and neither existed in Linear:
    /// *"No that's bad. If linear is not connected then what is sent? send should
    /// throw you an error like 'show toast'. With the reason"*. Nothing was sent. The
    /// local file is a safety net, not the delivery, and reporting a send is a lie
    /// about the only thing this tool does.
    func testNotBeingConnectedIsAFailure() async {
        let local = Spy()
        let delivery = LinearDelivery(keeping: local, settings: settings())

        do {
            try await delivery.send(bundle())
            XCTFail("a send that never reached Linear must not report success")
        } catch {
            XCTAssertEqual(error as? LinearError, .notConfigured)
            XCTAssertEqual(local.sent, 1,
                           "and the note is still safe - only the reporting was wrong")
        }
    }

    /// "With the reason": the message has to name what is missing, and the tray must
    /// not offer a Try again that cannot possibly work.
    func testTheReasonIsSomethingSomebodyCanActOn() async {
        let delivery = LinearDelivery(keeping: Spy(), settings: settings())

        do {
            try await delivery.send(bundle())
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "No Linear credential yet. Open Linear settings and add one.")
            XCTAssertFalse((error as? RetryableError)?.isWorthRetrying ?? true,
                           "sending it again cannot help - the settings panel can")
        }
    }

    /// A credential with nowhere to send to is the other half of the same bug: it was
    /// skipped just as silently, and it is not a missing credential.
    func testACredentialWithNoTeamAlsoFails() async throws {
        let store = settings()
        try skipIfKeychainRefuses { try store.save(.apiKey("lin_api_test")) }
        store.destination = nil

        let local = Spy()
        do {
            try await LinearDelivery(keeping: local, settings: store).send(bundle())
            XCTFail("no team means nowhere to send")
        } catch {
            // Its own case, not `.notPermitted`. The old one rendered as "No
            // permission for no team chosen yet", which said Linear had refused him
            // when the truth was that nothing had been chosen - and those want
            // opposite actions from the person reading it.
            XCTAssertEqual(error as? LinearError, .noDestination)
            XCTAssertEqual(error.localizedDescription,
                           "No team chosen yet. Open Linear settings and pick one.")
            XCTAssertEqual(local.sent, 1)
        }
    }

    /// A Keychain that refuses the write is the environment, not this test failing.
    private func skipIfKeychainRefuses(_ write: () throws -> Void) throws {
        do {
            try write()
        } catch LinearError.couldNotStore(let status) {
            throw XCTSkip("the Keychain refused the write (OSStatus \(status))")
        }
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
