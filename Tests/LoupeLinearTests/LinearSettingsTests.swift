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
        try XCTSkipUnless(settings.save(.apiKey("lin_api_secret")),
                          "no Keychain on this runner")

        XCTAssertEqual(settings.credential(), .apiKey("lin_api_secret"))
    }

    // The prefix is Linear's own, and it decides whether the header says `Bearer`.
    // Getting it wrong is a 401 that looks like a bad key.
    func testAnOAuthTokenIsNotMistakenForAPersonalKey() throws {
        try XCTSkipUnless(settings.save(.accessToken("oauth-token")),
                          "no Keychain on this runner")

        XCTAssertEqual(settings.credential(), .accessToken("oauth-token"))
    }

    func testThereIsNoCredentialUntilOneIsSaved() {
        settings.clearCredential()
        XCTAssertNil(settings.credential())
    }

    func testClearingTheCredentialKeepsTheTeamSoNobodyHasToPickItTwice() throws {
        settings.destination = LinearDestination(teamID: "TEAM", projectID: "PROJ")
        try XCTSkipUnless(settings.save(.apiKey("lin_api_secret")),
                          "no Keychain on this runner")

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
        try XCTSkipUnless(settings.save(.apiKey("lin_api_secret")),
                          "no Keychain on this runner")

        XCTAssertThrowsError(try settings.transport())
    }

    // Whatever else changes, this must not: the credential is not in UserDefaults.
    func testTheCredentialIsNeverInUserDefaults() throws {
        try XCTSkipUnless(settings.save(.apiKey("lin_api_secret")),
                          "no Keychain on this runner")

        let dumped = defaults.dictionaryRepresentation()
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
        XCTAssertFalse(dumped.contains("lin_api_secret"))
    }
}
