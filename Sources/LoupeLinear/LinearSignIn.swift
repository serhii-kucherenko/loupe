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
    /// The window the sheet is presented from, resolved before anything starts.
    private var anchor: ASPresentationAnchor?

    public init(oauth: LinearOAuth) {
        self.oauth = oauth
    }

    /// - Returns: an access token, ready for the Keychain.
    public func run() async throws -> LinearCredential {
        // Resolved up front so a missing window is an error, not a sheet that never
        // appears. It used to fall back to `ASPresentationAnchor()`, which is a fresh
        // unattached `UIWindow` - nothing can be presented from one.
        guard let anchor = Self.window() else {
            throw LinearError.api("No window to sign in from. Try again once the app "
                                  + "is on screen.")
        }
        self.anchor = anchor

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

            // **The result is the whole bug.** `start()` returns false when it cannot
            // present, and then the completion handler never runs - so the
            // continuation never resumed and the task hung forever with nothing
            // thrown and nothing logged. The panel simply sat there. Reported as "it
            // only signs you in after the second try": by the second tap the window
            // had settled and `start()` succeeded.
            guard session.start() else {
                self.session = nil
                continuation.resume(
                    throwing: LinearError.api("Could not open the Linear sign-in. "
                                              + "Try again in a moment."))
                return
            }
        }

        let code = try oauth.code(from: callback, expecting: state)
        return try await oauth.exchange(code: code, proof: proof)
    }

    /// A real, attached window to present from.
    ///
    /// The foreground-active scene first, because an app with several scenes on an
    /// iPad can have more than one and only one of them is being looked at. Never a
    /// freshly made `ASPresentationAnchor()`: it belongs to no scene, so presenting
    /// from it silently does nothing.
    static func window() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let active else { return nil }
        return active.keyWindow
            ?? active.windows.first { $0.isKeyWindow }
            ?? active.windows.first { !$0.isHidden }
    }
}

extension LinearSignIn: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Resolved in `run()` before the session was made, and `run()` refuses to
        // start without one - so this is never the empty fallback it used to be.
        anchor ?? ASPresentationAnchor()
    }
}
#endif
