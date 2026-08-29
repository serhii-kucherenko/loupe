import Foundation
import LoupeCore

/// What went wrong, in terms someone can act on.
///
/// "Send failed" alone sends people to the wrong fix. A rejected key, a team you
/// have no rights to and a flat network are three different problems with three
/// different next steps, and only one of them is worth retrying.
/// - Note: `LocalizedError` as well as `CustomStringConvertible`, and that is not
///   belt and braces. A bare Swift enum bridged to `NSError` reports
///   `"The operation couldn't be completed. (LoupeLinear.LinearError error 3.)"` -
///   which is exactly what the first person to try a real send saw, in place of a
///   sentence saying what Linear had actually said. Every `description` here is
///   written to be read by somebody who has to do something about it, and
///   `localizedDescription` is what most of Apple's frameworks and most host code
///   will reach for. Conforming here fixes it everywhere at once, including the
///   places nobody has looked.
public enum LinearError: Error, Equatable, CustomStringConvertible, LocalizedError,
                         RetryableError, Sendable {
    case notConfigured
    case credentialRejected
    case notPermitted(String)
    case rateLimited(retryAfter: TimeInterval?)
    case unreachable(String)
    case api(String)
    /// The Keychain refused to store the credential.
    ///
    /// Its own case because it is the one failure whose fix is in the *host's* build
    /// settings rather than in anything somebody typed, and because it used to be
    /// silent: `save` returned a `Bool` that the panel discarded, so a key that was
    /// never stored looked exactly like a key that was. Somebody lost one to that.
    case couldNotStore(OSStatus)

    public var description: String {
        switch self {
        case .notConfigured:
            return "No Linear credential yet. Open Loupe settings and add one."
        case .credentialRejected:
            return "Linear rejected the credential. Check the key, or sign in again."
        case .notPermitted(let what):
            return "No permission for \(what)."
        case .rateLimited(let after):
            let when = after.map { " Retrying in \(Int($0))s." } ?? " It will retry."
            return "Linear is rate limiting this workspace." + when
        case .unreachable(let why):
            return "Could not reach Linear: \(why)"
        case .api(let message):
            return message
        case .couldNotStore(let status):
            // -34018. The only status worth naming, because it is both the likeliest
            // and the one nobody guesses: an app with no Keychain entitlement is
            // refused outright, and every other part of the panel looks like it
            // worked.
            if status == errSecMissingEntitlement {
                return "This app is not allowed to use the Keychain, so nothing was "
                    + "saved. Add the Keychain Sharing capability - or "
                    + "keychain-access-groups with $(AppIdentifierPrefix) and the "
                    + "bundle id - then try again."
            }
            return "The Keychain refused to store the credential (OSStatus \(status))."
        }
    }

    public var errorDescription: String? { description }

    /// Whether leaving it in the queue could plausibly help. A rejected key will be
    /// rejected again; a flat network will not be flat forever.
    public var isWorthRetrying: Bool {
        switch self {
        case .rateLimited, .unreachable: return true
        case .notConfigured, .credentialRejected, .notPermitted, .api, .couldNotStore:
            return false
        }
    }
}

/// How the app proves who it is.
public enum LinearCredential: Equatable, Sendable {
    /// A personal API key, `lin_api_…`. Sent as the bare `Authorization` value,
    /// which is Linear's own rule and not the usual `Bearer` form.
    case apiKey(String)
    /// An OAuth access token, which *is* `Bearer`.
    case accessToken(String)

    var headerValue: String {
        switch self {
        case .apiKey(let key): return key
        case .accessToken(let token): return "Bearer \(token)"
        }
    }
}

/// Where notes should land.
public struct LinearDestination: Equatable, Sendable {
    public var teamID: String
    public var projectID: String?
    /// An agent to hand the issue to, which is the last hop in the loop.
    public var delegateID: String?

    public init(teamID: String, projectID: String? = nil, delegateID: String? = nil) {
        self.teamID = teamID
        self.projectID = projectID
        self.delegateID = delegateID
    }
}
