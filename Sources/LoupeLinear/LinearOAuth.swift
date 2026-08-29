import Foundation
import CryptoKit
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif

/// Signing in to Linear from the device, with no server and no secret in the app.
///
/// Linear supports PKCE, and with it the client secret is optional at token
/// exchange - which is what makes this possible at all. A public client that had to
/// ship a secret could not do OAuth honestly: anything in the binary is not a
/// secret, and pretending otherwise is worse than an API key field.
///
/// The scope is `issues:create`, not `write`. Loupe files issues; it has no business
/// being able to delete them.
public struct LinearOAuth: Sendable {

    public static let authorizeURL = URL(string: "https://linear.app/oauth/authorize")!
    public static let tokenURL = URL(string: "https://api.linear.app/oauth/token")!
    public static let scope = "issues:create"

    /// From the OAuth application someone registers in their own workspace. Public
    /// by design - a client id is not a credential.
    public let clientID: String
    public let redirectURI: String

    public init(clientID: String, redirectURI: String) {
        self.clientID = clientID
        self.redirectURI = redirectURI
    }

    // MARK: - PKCE

    /// A fresh verifier, and the challenge derived from it.
    ///
    /// The verifier never leaves the device until the code has already been handed
    /// back, which is the whole trick: an intercepted authorization code is useless
    /// without it.
    public struct Proof: Sendable {
        public let verifier: String
        public var challenge: String {
            let digest = SHA256.hash(data: Data(verifier.utf8))
            return Data(digest).base64URLEncoded
        }

        public init(verifier: String = Proof.randomVerifier()) {
            self.verifier = verifier
        }

        /// - Important: the result of `SecRandomCopyBytes` is checked, and that is
        ///   not a formality. The buffer starts as 64 zeroes, so discarding the
        ///   status meant a failure produced a *constant, publicly guessable*
        ///   verifier while everything carried on working - and the verifier is the
        ///   entire security of PKCE. An intercepted authorization code is only
        ///   useless because the verifier cannot be guessed.
        ///
        ///   The fallback is Swift's own system generator rather than a throw. It
        ///   cannot fail, and refusing to sign in at all would be a worse answer than
        ///   using the other cryptographically secure source on the machine.
        public static func randomVerifier() -> String {
            var bytes = [UInt8](repeating: 0, count: 64)
            if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
                var generator = SystemRandomNumberGenerator()
                bytes = (0..<64).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            }
            return Data(bytes).base64URLEncoded
        }
    }

    public func authorizationURL(proof: Proof, state: String) -> URL {
        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: proof.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    /// The code from the redirect, once `state` has been checked.
    ///
    /// - Throws: when `state` does not match. A mismatched state is the signature of
    ///   somebody else's redirect arriving, and it is not something to shrug off.
    public func code(from callback: URL, expecting state: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
        if let error = items?.first(where: { $0.name == "error" })?.value {
            throw LinearError.api("Linear refused the sign-in: \(error)")
        }
        guard items?.first(where: { $0.name == "state" })?.value == state else {
            throw LinearError.api("The sign-in did not come back from where it went")
        }
        guard let code = items?.first(where: { $0.name == "code" })?.value else {
            throw LinearError.api("Linear returned no authorization code")
        }
        return code
    }

    public func exchange(code: String,
                         proof: Proof,
                         fetch: LinearTransport.Fetch = {
                             try await URLSession.shared.data(for: $0)
                         }) async throws -> LinearCredential {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            // No client_secret: that is what PKCE buys.
            URLQueryItem(name: "code_verifier", value: proof.verifier),
        ]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(request)
        } catch {
            throw LinearError.unreachable((error as NSError).localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw LinearError.credentialRejected
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String
        else { throw LinearError.api("Linear returned no access token") }

        return .accessToken(token)
    }
}

private extension Data {
    /// Base64url, which is what PKCE specifies and what plain base64 is not.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
