import XCTest
import CryptoKit
@testable import LoupeLinear

/// PKCE is the reason a mobile app can do this at all, so the parts that make it
/// safe are worth asserting rather than assuming.
final class LinearOAuthTests: XCTestCase {

    private let oauth = LinearOAuth(clientID: "client-123",
                                    redirectURI: "loupe://linear")

    private func items(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name] = item.value
        }
        return out
    }

    func testTheChallengeIsTheSha256OfTheVerifierInBase64url() {
        let proof = LinearOAuth.Proof(verifier: "abc123")
        let expected = Data(SHA256.hash(data: Data("abc123".utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        XCTAssertEqual(proof.challenge, expected)
    }

    // Plain base64 is not base64url, and the difference is a rejected challenge.
    func testTheChallengeCarriesNoCharactersThatNeedEscaping() {
        for _ in 0..<20 {
            let challenge = LinearOAuth.Proof().challenge
            XCTAssertFalse(challenge.contains("+"))
            XCTAssertFalse(challenge.contains("/"))
            XCTAssertFalse(challenge.contains("="))
        }
    }

    func testEveryVerifierIsDifferent() {
        let made = Set((0..<50).map { _ in LinearOAuth.Proof().verifier })
        XCTAssertEqual(made.count, 50)
    }

    func testTheAuthorizationURLAsksForOnlyWhatLoupeNeeds() {
        let query = items(oauth.authorizationURL(proof: LinearOAuth.Proof(), state: "s"))

        XCTAssertEqual(query["scope"], "issues:create",
                       "Loupe files issues; it has no business deleting them")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertNotNil(query["code_challenge"])
        XCTAssertNil(query["client_secret"], "a secret in a public client is not a secret")
    }

    func testTheVerifierItselfNeverGoesOutInTheAuthorizationURL() {
        let proof = LinearOAuth.Proof()
        let url = oauth.authorizationURL(proof: proof, state: "s").absoluteString

        XCTAssertFalse(url.contains(proof.verifier), "then an intercepted code is useless")
    }

    // A mismatched state is somebody else's redirect arriving.
    func testAMismatchedStateIsRefused() {
        let callback = URL(string: "loupe://linear?code=abc&state=elsewhere")!
        XCTAssertThrowsError(try oauth.code(from: callback, expecting: "mine"))
    }

    func testAnErrorInTheCallbackIsReportedRatherThanIgnored() {
        let callback = URL(string: "loupe://linear?error=access_denied&state=mine")!
        XCTAssertThrowsError(try oauth.code(from: callback, expecting: "mine"))
    }

    func testAGoodCallbackYieldsTheCode() throws {
        let callback = URL(string: "loupe://linear?code=abc123&state=mine")!
        XCTAssertEqual(try oauth.code(from: callback, expecting: "mine"), "abc123")
    }

    func testTheExchangeSendsTheVerifierAndNoSecret() async throws {
        let proof = LinearOAuth.Proof()
        let body = Box()

        let credential = try await oauth.exchange(code: "abc", proof: proof, fetch: { request in
            body.first(request.httpBody.map { String(decoding: $0, as: UTF8.self) })
            let json = ["access_token": "token-xyz"]
            return (try JSONSerialization.data(withJSONObject: json),
                    HTTPURLResponse(url: request.url!, statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!)
        })

        XCTAssertEqual(credential, .accessToken("token-xyz"))
        let sent = body.value ?? ""
        XCTAssertTrue(sent.contains("code_verifier="))
        XCTAssertFalse(sent.contains("client_secret"))
    }

    // MARK: - The verifier is the whole security of PKCE

    /// The buffer starts as 64 zeroes and `SecRandomCopyBytes`'s status used to be
    /// discarded, so a failure produced a constant, publicly guessable verifier while
    /// everything else carried on working.
    ///
    /// `testEveryVerifierIsDifferent` above would already have caught a *total*
    /// failure, since 50 identical verifiers is 50 identical verifiers. This names
    /// the specific value, so an intermittent failure that still happened to produce
    /// distinct values cannot slip past - and so the reason is written down next to
    /// the assertion rather than inferred from a set count.
    func testAVerifierIsNeverTheEmptyBuffer() {
        // 64 zero bytes, base64url, unpadded. Spelled out rather than reached for
        // through the fileprivate encoder, so a change there cannot make this test
        // quietly agree with itself.
        let zeroes = String(repeating: "A", count: 86)
        for _ in 0..<32 {
            XCTAssertNotEqual(LinearOAuth.Proof.randomVerifier(), zeroes)
        }
    }

    /// The challenge's character set is checked above; the verifier's is not, and it
    /// travels in a form body where padding and `+` would be just as wrong.
    func testTheVerifierIsLongEnoughAndCarriesNothingThatNeedsEscaping() {
        let verifier = LinearOAuth.Proof.randomVerifier()
        // RFC 7636 puts the floor at 43 characters.
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertFalse(verifier.contains("="))
        XCTAssertFalse(verifier.contains("+"))
        XCTAssertFalse(verifier.contains("/"))
    }

}

private final class Box: @unchecked Sendable {
    private(set) var value: String?
    func first(_ candidate: String?) { if value == nil { value = candidate } }
}
