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
/// The default scope is `issues:create`, not `write`. Loupe files issues; it has no
/// business being able to delete them.
public struct LinearOAuth: Sendable {

    public static let authorizeURL = URL(string: "https://linear.app/oauth/authorize")!
    public static let tokenURL = URL(string: "https://api.linear.app/oauth/token")!

    /// What Loupe needs to do its job, and nothing else.
    public static let defaultScopes = ["issues:create"]

    /// What it takes to also create a project from the settings panel.
    ///
    /// Linear has no targeted project scope - the list is `read`, `write`,
    /// `issues:create`, `comments:create`, `timeSchedule:write` and `admin` - so
    /// creating a project means asking for `write`, which is write access to the
    /// whole account. That is a real widening and it is why it is a separate
    /// constant a host has to reach for, rather than the default.
    ///
    /// It is not silent: Linear's own consent screen lists what is being granted,
    /// so whoever signs in sees the difference before agreeing to it.
    public static let projectScopes = ["issues:create", "write"]

    /// From the OAuth application someone registers in their own workspace. Public
    /// by design - a client id is not a credential.
    public let clientID: String
    public let redirectURI: String
    public let scopes: [String]

    public init(clientID: String, redirectURI: String,
                scopes: [String] = LinearOAuth.defaultScopes) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    /// Whether a token from this application could create a project.
    ///
    /// The panel asks before offering the control, so somebody is not handed a
    /// button that can only fail.
    public var canCreateProjects: Bool { scopes.contains("write") }

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

        public static func randomVerifier() -> String {
            var bytes = [UInt8](repeating: 0, count: 64)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return Data(bytes).base64URLEncoded
        }
    }

    public func authorizationURL(proof: Proof, state: String) -> URL {
        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: ",")),
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
