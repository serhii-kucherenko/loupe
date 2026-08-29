import XCTest
@testable import LoupeLinear

/// A one-shot latch that can be waited on from inside a `@Sendable` closure.
///
/// Not `XCTestExpectation`: waiting on one means calling `fulfillment(of:)` on the
/// test case, which captures a non-Sendable `self` and is a hard error in Swift 6
/// language mode. Nothing else in the suite had noticed, because the package
/// declares Swift 5 and only the dedicated CI job compiles the tests as v6.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiting: [() -> Void] = []

    func open() {
        lock.lock()
        opened = true
        let resume = waiting
        waiting = []
        lock.unlock()
        resume.forEach { $0() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append { continuation.resume() }
                lock.unlock()
            }
        }
    }
}

/// What the panel is allowed to claim before it has read the Keychain.
///
/// "I have not looked" and "I looked and there is nothing" were the same value, so
/// a panel opened by somebody already signed in told them they were signed out
/// until the answer came back.
@MainActor
final class LinearSettingsRestoreTests: XCTestCase {

    private func settings() -> LinearSettings {
        let account = "restore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: account)!
        defaults.removePersistentDomain(forName: account)
        return LinearSettings(account: account, defaults: defaults)
    }

    private func skipIfKeychainRefuses(_ write: () throws -> Void) throws {
        do {
            try write()
        } catch LinearError.couldNotStore(let status) {
            throw XCTSkip("the Keychain refused the write (OSStatus \(status))")
        }
    }

    private func directory(failing: Bool = false) -> (LinearCredential) -> LinearDirectory {
        { credential in
            LinearDirectory(credential: credential,
                            endpoint: URL(string: "https://example.invalid/graphql")!) { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: failing ? 401 : 200,
                    httpVersion: nil, headerFields: nil)!
                guard !failing else { return (Data("{}".utf8), response) }

                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                let payload: String
                if body.contains("viewer") {
                    payload = #"{"data":{"viewer":{"name":"Serhii"},"organization":{"name":"Skailex"}}}"#
                } else if body.contains("projects") {
                    payload = #"{"data":{"team":{"projects":{"nodes":[]}}}}"#
                } else {
                    payload = #"{"data":{"teams":{"nodes":[{"id":"t1","name":"Core","key":"C"}]}}}"#
                }
                return (Data(payload.utf8), response)
            }
        }
    }

    /// The panel must not draw either answer before it has one.
    func testItStartsOutHavingNotLookedYet() {
        let flow = LinearSettingsFlow(settings: settings(), makeDirectory: directory())
        XCTAssertTrue(flow.isRestoring,
                      "a fresh panel claims to know something it has not read yet")
    }

    /// The bug as he met it: signed in, panel opens, panel says sign in.
    func testASavedCredentialIsNeverReportedAsSignedOut() async throws {
        let saved = settings()
        try skipIfKeychainRefuses { try saved.save(.apiKey("lin_api_abc")) }

        let flow = LinearSettingsFlow(settings: saved, makeDirectory: directory())
        await flow.load()

        XCTAssertFalse(flow.isRestoring)
        guard case .connected = flow.connection else {
            return XCTFail("a saved credential did not come back connected: \(flow.connection)")
        }
    }

    /// The spinner covers the Keychain read, not the network call after it.
    ///
    /// Holding it across `connect` strands anybody offline or holding a stale
    /// credential at a spinner: the key field is hidden, so there is no way to paste
    /// a working one, and `status` is suppressed, so nothing says why.
    func testTheKeyFieldComesBackBeforeTheCredentialIsProved() async throws {
        let saved = settings()
        try skipIfKeychainRefuses { try saved.save(.apiKey("lin_api_slow")) }

        let started = Gate()
        let letItFinish = Gate()
        let flow = LinearSettingsFlow(settings: saved, makeDirectory: { credential in
            LinearDirectory(credential: credential,
                            endpoint: URL(string: "https://example.invalid/graphql")!) { _ in
                started.open()
                await letItFinish.wait()
                throw LinearError.unreachable("still trying")
            }
        })

        let loading = Task { await flow.load() }
        await started.wait()

        XCTAssertFalse(flow.isRestoring,
                       "the panel is still hiding the key field while it waits on Linear")
        XCTAssertEqual(flow.connection, .testing,
                       "the wait has to stay visible as Checking, not as nothing")

        letItFinish.open()
        await loading.value
    }

    /// Nothing in the Keychain is a real answer, and the panel has to be allowed to
    /// draw it - otherwise a first run spins forever.
    func testNoCredentialStillCountsAsHavingLooked() async {
        let flow = LinearSettingsFlow(settings: settings(), makeDirectory: directory())
        await flow.load()

        XCTAssertFalse(flow.isRestoring, "a first run would spin forever")
        XCTAssertEqual(flow.connection, .idle)
    }

    /// A credential Linear rejects is still an answer. Leaving the panel spinning
    /// would hide the one message that says what to do about it.
    func testARejectedCredentialStopsTheSpinner() async throws {
        let saved = settings()
        try skipIfKeychainRefuses { try saved.save(.apiKey("lin_api_dead")) }

        let flow = LinearSettingsFlow(settings: saved,
                                      makeDirectory: directory(failing: true))
        await flow.load()

        XCTAssertFalse(flow.isRestoring, "a rejected credential left the panel spinning")
        guard case .failed = flow.connection else {
            return XCTFail("expected a failure, got \(flow.connection)")
        }
    }
}
