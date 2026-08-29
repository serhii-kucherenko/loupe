import XCTest
@testable import LoupeLinear

final class LinearSettingsTests: XCTestCase {

    private let account = "test-\(UUID().uuidString)"
    private var settings: LinearSettings!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: account)!
        settings = LinearSettings(account: account, defaults: defaults)
    }

    override func tearDown() {
        settings.clearCredential()
        defaults.removePersistentDomain(forName: account)
        super.tearDown()
    }

    func testACredentialSurvivesARoundTrip() throws {
        try skipIfKeychainRefuses { try settings.save(.apiKey("lin_api_secret")) }

        XCTAssertEqual(settings.credential(), .apiKey("lin_api_secret"))
    }

    // The prefix is Linear's own, and it decides whether the header says `Bearer`.
    // Getting it wrong is a 401 that looks like a bad key.
    func testAnOAuthTokenIsNotMistakenForAPersonalKey() throws {
        try skipIfKeychainRefuses { try settings.save(.accessToken("oauth-token")) }

        XCTAssertEqual(settings.credential(), .accessToken("oauth-token"))
    }

    func testThereIsNoCredentialUntilOneIsSaved() {
        settings.clearCredential()
        XCTAssertNil(settings.credential())
    }

    func testClearingTheCredentialKeepsTheTeamSoNobodyHasToPickItTwice() throws {
        settings.destination = LinearDestination(teamID: "TEAM", projectID: "PROJ")
        try skipIfKeychainRefuses { try settings.save(.apiKey("lin_api_secret")) }

        settings.clearCredential()

        XCTAssertNil(settings.credential())
        XCTAssertEqual(settings.destination?.teamID, "TEAM")
    }

    func testItRefusesToBuildATransportWithoutACredential() {
        settings.clearCredential()
        XCTAssertThrowsError(try settings.transport()) { error in
            XCTAssertEqual(error as? LinearError, .notConfigured)
        }
    }

    func testItRefusesToBuildATransportWithoutATeam() throws {
        settings.destination = nil
        try skipIfKeychainRefuses { try settings.save(.apiKey("lin_api_secret")) }

        XCTAssertThrowsError(try settings.transport())
    }

    // Whatever else changes, this must not: the credential is not in UserDefaults.
    func testTheCredentialIsNeverInUserDefaults() throws {
        try skipIfKeychainRefuses { try settings.save(.apiKey("lin_api_secret")) }

        let dumped = defaults.dictionaryRepresentation()
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        XCTAssertFalse(dumped.contains("lin_api_secret"))
    }

    /// A Keychain write can be refused outright by the environment - a CI runner with
    /// no keychain, an app with no entitlement - and that is not this test failing.
    private func skipIfKeychainRefuses(_ write: () throws -> Void) throws {
        do {
            try write()
        } catch LinearError.couldNotStore(let status) {
            throw XCTSkip("the Keychain refused the write (OSStatus \(status))")
        }
    }
}
