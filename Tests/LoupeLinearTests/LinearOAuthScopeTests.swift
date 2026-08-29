import XCTest
@testable import LoupeLinear

final class LinearOAuthScopeTests: XCTestCase {

    private func scope(of oauth: LinearOAuth) -> String? {
        let url = oauth.authorizationURL(proof: LinearOAuth.Proof(verifier: "v"), state: "s")
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "scope" }?.value
    }

    /// The default has to stay narrow. An annotation tool that can delete a
    /// workspace's projects is not a trade to make on somebody's behalf.
    func testTheDefaultAsksOnlyToCreateIssues() {
        let oauth = LinearOAuth(clientID: "c", redirectURI: "loupe://linear")
        XCTAssertEqual(scope(of: oauth), "issues:create")
        XCTAssertFalse(oauth.canCreateProjects)
    }

    /// Linear has no targeted project scope, so this is the only way to offer it -
    /// which is exactly why a host has to ask for it by name.
    func testProjectCreationHasToBeAskedForByName() {
        let oauth = LinearOAuth(clientID: "c", redirectURI: "loupe://linear",
                                scopes: LinearOAuth.projectScopes)
        XCTAssertEqual(scope(of: oauth), "issues:create,write")
        XCTAssertTrue(oauth.canCreateProjects)
    }
}
