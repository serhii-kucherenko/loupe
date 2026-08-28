#if canImport(AuthenticationServices) && !os(macOS)
import AuthenticationServices
import UIKit

/// Runs the Linear sign-in in the system's own browser sheet.
///
/// `ASWebAuthenticationSession` rather than an in-app web view on purpose: the
/// person is typing their Linear password, and they should be able to see it is
/// Linear asking. An embedded web view can be read by the app hosting it, which is
/// exactly what a credential prompt must not be.
@MainActor
public final class LinearSignIn: NSObject {

    private let oauth: LinearOAuth
    private var session: ASWebAuthenticationSession?

    public init(oauth: LinearOAuth) {
        self.oauth = oauth
    }

    /// - Returns: an access token, ready for the Keychain.
    public func run() async throws -> LinearCredential {
        let proof = LinearOAuth.Proof()
        let state = UUID().uuidString
        let scheme = URL(string: oauth.redirectURI)?.scheme

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: oauth.authorizationURL(proof: proof, state: state),
                callbackURLScheme: scheme
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: LinearError.api("Sign-in cancelled"))
                } else {
                    continuation.resume(
                        throwing: LinearError.unreachable(
                            error?.localizedDescription ?? "the sign-in did not finish"))
                }
            }
            session.presentationContextProvider = self
            // No shared cookies: signing in should not depend on, or disturb, whoever
            // is logged in to Linear in Safari.
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            session.start()
        }

        let code = try oauth.code(from: callback, expecting: state)
        return try await oauth.exchange(code: code, proof: proof)
    }
}

extension LinearSignIn: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}
#endif
