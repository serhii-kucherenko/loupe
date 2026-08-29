import XCTest
@testable import LoupeLinear

/// The settings panel's behaviour, which used to live inside a SwiftUI view where
/// nothing could reach it. Three bugs shipped together in that view, and the first
/// three tests here are each one of them stated as a fact about what should happen.
/// They cannot be run against the old code - it had no type to call - which is the
/// point: the behaviour was untestable where it was, so it went unchecked.
@MainActor
final class LinearSettingsFlowTests: XCTestCase {

    /// A fresh, empty store, made inside the test rather than in `setUp`.
    ///
    /// `setUp` is nonisolated and this case is `@MainActor`, so Swift 6 refuses to let
    /// it touch anything the class owns. Making it here, in a method the tests already
    /// call from the main actor, avoids the whole question - and each call wipes its
    /// own suite first, so nothing carries over even when a run is interrupted.
    private func settings() -> LinearSettings {
        let account = "flow-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: account)!
        defaults.removePersistentDomain(forName: account)
        return LinearSettings(account: account, defaults: defaults)
    }

    /// A Keychain write that the environment may simply refuse - a CI runner with no
    /// keychain, an app with no entitlement - which is not this test failing. The iOS
    /// simulator refuses every one of them, and three tests went red in CI for
    /// exactly that reason after `save` started throwing.
    private func skipIfKeychainRefuses(_ write: () throws -> Void) throws {
        do {
            try write()
        } catch LinearError.couldNotStore(let status) {
            throw XCTSkip("the Keychain refused the write (OSStatus \(status))")
        }
    }

    /// A Keychain that will not have it, which is what an app with no entitlement
    /// meets on Mac Catalyst.
    private func refuses(_ credential: LinearCredential) throws {
        throw LinearError.couldNotStore(errSecMissingEntitlement)
    }

    /// A directory that answers every query from canned JSON, and counts what it was
    /// asked with, so "which credential did it actually use" is checkable.
    private final class Recorder: @unchecked Sendable {
        var authorizations: [String] = []
        var queries: [String] = []
        var teams = [("t1", "Core Team", "CORE")]
        var projects = [("p1", "Loupe")]
        var failWith: Int?
    }

    private func directory(_ recorder: Recorder) -> (LinearCredential) -> LinearDirectory {
        { credential in
            LinearDirectory(credential: credential,
                            endpoint: URL(string: "https://example.invalid/graphql")!) { request in
                recorder.authorizations.append(
                    request.value(forHTTPHeaderField: "Authorization") ?? "")
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                recorder.queries.append(body)

                if let code = recorder.failWith {
                    return (Data("{}".utf8),
                            HTTPURLResponse(url: request.url!, statusCode: code,
                                            httpVersion: nil, headerFields: nil)!)
                }

                let payload: String
                if body.contains("viewer") {
                    payload = #"{"data":{"viewer":{"name":"Serhii"},"organization":{"name":"Skailex"}}}"#
                } else if body.contains("projects") {
                    let nodes = recorder.projects
                        .map { #"{"id":"\#($0.0)","name":"\#($0.1)"}"# }
                        .joined(separator: ",")
                    payload = #"{"data":{"team":{"projects":{"nodes":[\#(nodes)]}}}}"#
                } else {
                    let nodes = recorder.teams
                        .map { #"{"id":"\#($0.0)","name":"\#($0.1)","key":"\#($0.2)"}"# }
                        .joined(separator: ",")
                    payload = #"{"data":{"teams":{"nodes":[\#(nodes)]}}}"#
                }
                return (Data(payload.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    // MARK: - The three that shipped together

    /// The Project picker never appeared on any path, because `loadProjects` returned
    /// early unless the connection was already `.connected` - and its only caller ran
    /// while it was still `.testing`.
    func testConnectingLoadsProjectsAndNotJustTeams() async {
        let recorder = Recorder()
        let flow = LinearSettingsFlow(settings: settings(), makeDirectory: directory(recorder))

        await flow.test(key: "lin_api_abc")

        XCTAssertEqual(flow.teams.map(\.id), ["t1"])
        XCTAssertEqual(flow.projects.map(\.name), ["Loupe"],
                       "a team with projects must fill the Project picker")
    }

    /// Re-opening the panel said "connected" and showed no pickers, so Save stayed
    /// disabled with a perfectly good credential and nothing saying why.
    func testReopeningWithASavedCredentialFillsThePickers() async throws {
        let saved = settings()
        try skipIfKeychainRefuses { try saved.save(.apiKey("lin_api_abc")) }

        let recorder = Recorder()
        let flow = LinearSettingsFlow(settings: saved, makeDirectory: directory(recorder))

        await flow.load()

        XCTAssertEqual(flow.connection, .connected("Serhii"))
        XCTAssertFalse(flow.teams.isEmpty, "the panel must ask Linear again on open")
        XCTAssertTrue(flow.canSave)
    }

    /// The sign-in path rebuilt its credential from the key field, which is empty
    /// after signing in - so the project query went out with an empty bearer token.
    func testAProvedTokenIsReusedRatherThanRebuiltFromAnEmptyField() async {
        let recorder = Recorder()
        let flow = LinearSettingsFlow(settings: settings(), makeDirectory: directory(recorder))

        await flow.connect(.accessToken("oauth-token"))

        XCTAssertFalse(recorder.authorizations.isEmpty)
        XCTAssertTrue(recorder.authorizations.allSatisfy { $0 == "Bearer oauth-token" },
                      "every call must use the token that was proved, got \(recorder.authorizations)")
        XCTAssertFalse(flow.projects.isEmpty)
    }

    // MARK: - The rest of the contract

    /// The workspace is shown, never chosen: a credential is issued by exactly one, so
    /// there is no list to pick from. Somebody has to be able to see which one it is,
    /// because a key for the wrong workspace is the common mistake and "connected"
    /// would hide it completely.
    func testTheWorkspaceIsReportedAlongsideTheTeamAndProject() async {
        let recorder = Recorder()
        let flow = LinearSettingsFlow(settings: settings(), makeDirectory: directory(recorder))

        await flow.test(key: "lin_api_abc")

        XCTAssertEqual(flow.workspace, "Skailex")
        XCTAssertEqual(flow.person, "Serhii")
        XCTAssertEqual(flow.teams.map(\.name), ["Core Team"])
        XCTAssertEqual(flow.projects.map(\.name), ["Loupe"])
    }

    func testARejectedCredentialForgetsTheWorkspaceToo() async {
        let recorder = Recorder()
        let flow = LinearSettingsFlow(settings: settings(), makeDirectory: directory(recorder))
        await flow.test(key: "lin_api_abc")
        XCTAssertNotNil(flow.workspace)

        recorder.failWith = 401
        await flow.test(key: "lin_api_wrong")

        XCTAssertNil(flow.workspace, "a stale workspace beside a dead key is a lie")
        XCTAssertNil(flow.person)
    }

    func testSaveIsRefusedUntilThereIsSomewhereToSend() async {
        let flow = LinearSettingsFlow(settings: settings(), makeDirectory: directory(Recorder()))
        XCTAssertFalse(flow.canSave, "a note with no team has nowhere to go")

        await flow.test(key: "lin_api_abc")
        XCTAssertTrue(flow.canSave)
    }

    func testATeamAlreadyChosenIsNotQuietlyMoved() async throws {
        let saved = settings()
        try skipIfKeychainRefuses { try saved.save(.apiKey("lin_api_abc")) }
        saved.destination = LinearDestination(teamID: "t2", projectID: nil)

        let recorder = Recorder()
        recorder.teams = [("t1", "Core Team", "CORE"), ("t2", "Design", "DES")]
        let flow = LinearSettingsFlow(settings: saved, makeDirectory: directory(recorder))

        await flow.load()

        XCTAssertEqual(flow.teamID, "t2", "re-opening must not move where notes go")
    }

    /// The saved team is honoured, but only if it still exists. Otherwise someone is
    /// sending into a team that was deleted and nothing says so.
    func testATeamThatNoLongerExistsFallsBack() async throws {
        let saved = settings()
        try skipIfKeychainRefuses { try saved.save(.apiKey("lin_api_abc")) }
        saved.destination = LinearDestination(teamID: "gone", projectID: nil)

        let flow = LinearSettingsFlow(settings: saved, makeDirectory: directory(Recorder()))
        await flow.load()

        XCTAssertEqual(flow.teamID, "t1")
    }

    func testAFailedConnectionClearsThePickersAndTheCredential() async {
        let recorder = Recorder()
        recorder.failWith = 401
        let flow = LinearSettingsFlow(settings: settings(), makeDirectory: directory(recorder))

        await flow.test(key: "lin_api_wrong")

        XCTAssertEqual(flow.connection, .failed(LinearError.credentialRejected.description))
        XCTAssertTrue(flow.teams.isEmpty)
        XCTAssertTrue(flow.projects.isEmpty)
        XCTAssertFalse(flow.canSave, "a rejected key must not leave Save enabled")
    }

    /// Nothing is asked of Linear when there is no credential at all, and the panel
    /// stays idle rather than reporting a failure someone did not cause.
    func testNoSavedCredentialAsksNothing() async {
        let recorder = Recorder()
        let flow = LinearSettingsFlow(settings: settings(), makeDirectory: directory(recorder))

        await flow.load()

        XCTAssertEqual(flow.connection, .idle)
        XCTAssertTrue(recorder.queries.isEmpty)
    }

    // MARK: - A write that did not happen must not look like one that did

    /// The bug this replaced, in one sentence: `save` returned a `Bool`, the panel
    /// discarded it, and a Keychain that refused the write outright looked exactly
    /// like one that took it. Somebody typed a key, saw Test connection pass,
    /// relaunched, and found nothing there.
    func testARefusedKeychainWriteIsReportedAndSaveSaysNo() async {
        let flow = LinearSettingsFlow(settings: settings(),
                                      makeDirectory: directory(Recorder()),
                                      store: refuses)
        await flow.test(key: "lin_api_abc")
        XCTAssertTrue(flow.canSave)

        XCTAssertFalse(flow.save(key: "lin_api_abc"),
                       "a refused write must not report success")
        XCTAssertEqual(flow.connection,
                       .failed(LinearError.couldNotStore(errSecMissingEntitlement).description))
    }

    /// And the reason has to be actionable, because the fix is in the host's build
    /// settings and nobody guesses "add a Keychain entitlement" from a blank field.
    func testTheMissingEntitlementSaysWhatToDoAboutIt() {
        let message = LinearError.couldNotStore(errSecMissingEntitlement).description
        XCTAssertTrue(message.contains("Keychain Sharing"), message)
        XCTAssertTrue(message.contains("keychain-access-groups"), message)

        // Anything else at least carries the status, so it can be looked up.
        XCTAssertTrue(LinearError.couldNotStore(-25300).description.contains("-25300"))
    }

    /// Nothing is worth retrying here: the Keychain will refuse it again for exactly
    /// the same reason until somebody changes the build.
    func testAKeychainRefusalIsNotRetried() {
        XCTAssertFalse(LinearError.couldNotStore(errSecMissingEntitlement).isWorthRetrying)
    }

    func testAPersonalKeyIsSentBareAndAnythingElseAsABearer() {
        XCTAssertEqual(LinearSettingsFlow.credential(forTypedKey: "lin_api_abc"),
                       .apiKey("lin_api_abc"))
        XCTAssertEqual(LinearSettingsFlow.credential(forTypedKey: "other"),
                       .accessToken("other"))
    }

    /// An error that is not a `LinearError` used to reach the panel as a struct dump.
    func testAnUnknownErrorIsReadable() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(LinearSettingsFlow.readable(error), error.localizedDescription)
        XCTAssertEqual(LinearSettingsFlow.readable(LinearError.credentialRejected),
                       LinearError.credentialRejected.description)
    }

    func testSaveStoresTheDestinationAndTreatsNoProjectAsNone() async {
        let store = settings()
        let flow = LinearSettingsFlow(settings: store, makeDirectory: directory(Recorder()))
        await flow.test(key: "lin_api_abc")

        flow.projectID = ""
        flow.save(key: "lin_api_abc")

        XCTAssertEqual(store.destination?.teamID, "t1")
        XCTAssertNil(store.destination?.projectID)
    }
}
