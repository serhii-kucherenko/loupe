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
    /// A credential that works, and nowhere to send to.
    ///
    /// Its own case rather than `.notPermitted("no team chosen yet")`, which rendered
    /// as "No permission for no team chosen yet" - not English, and it said
    /// *permission* when the truth is *unconfigured*. The person read it as Linear
    /// refusing them. Those want opposite actions: one is re-authorise, the other is
    /// pick a team from a list already on screen.
    case noDestination
    case credentialRejected
    case notPermitted(String)
    /// The credential works, and is not allowed to do this.
    ///
    /// Separate from `.credentialRejected`, which is a 401 and means the key itself
    /// is wrong. This one authenticated fine and was refused the *action*, so the
    /// fix is a wider credential rather than a different one - and "Access denied"
    /// on its own never says that. Carries Linear's own words as well, because the
    /// advice is a guess and the words are not.
    case credentialTooNarrow(String)
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
            return "No Linear credential yet. Open Linear settings and add one."
        case .noDestination:
            return "No team chosen yet. Open Linear settings and pick one."
        case .credentialRejected:
            return "Linear rejected the credential. Check the key, or sign in again."
        case .notPermitted(let what):
            return "No permission for \(what)."
        case .credentialTooNarrow(let said):
            return "Linear refused this: \(said). The credential is probably too "
                + "narrow - sign in again to grant issue creation, or paste a "
                + "personal API key."
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

    /// What actually came back, not just the number.
    ///
    /// This threw away the body, and the body is the answer: Linear names the field
    /// or the argument it did not like, and a signed upload URL says which header
    /// broke the signature. "Linear returned 400" was true and useless - the ninth
    /// failure on this project to know exactly what went wrong and say nothing.
    ///
    /// The host is named because `perform` is shared. An upload goes to a signed
    /// storage URL rather than to Linear, so "Linear returned 400" was misdirecting
    /// as well as empty, and the two have completely different causes.
    static func fromHTTP(status: Int, body: Data, request: URLRequest) -> LinearError {
        let who = request.url?.host.map { $0.contains("linear.app") ? "Linear" : $0 }
            ?? "The server"
        let text = String(decoding: body, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .api("\(who) returned \(status) and said nothing.") }

        // The words decide, not the status. Linear answered the first real send with
        // HTTP 400 carrying `Invalid scope: 'write' required` and an inner
        // `"statusCode": 403` - so the refusal was there in plain English and the
        // status code disagreed with it. Reading only the status sent that down the
        // generic path and printed a scope problem as an unexplained 400.
        if case .credentialTooNarrow = fromGraphQL(text) {
            return .credentialTooNarrow("\(who) returned \(status): \(trimmed(text))")
        }

        return .api("\(who) returned \(status): \(trimmed(text))")
    }

    /// Bounded: some servers answer an error with a page. Enough to name a field, a
    /// header or a scope, short enough to read in a row in the tray on a phone.
    private static func trimmed(_ text: String, limit: Int = 400) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\u{2026}" : text
    }

    /// A GraphQL failure, read for whether it is about access.
    ///
    /// Linear returns an access refusal in the `errors` array with HTTP 200, so the
    /// status code cannot tell a refusal from a typo in a field name. The words are
    /// the only signal there is.
    ///
    /// **The `default` is the load-bearing half.** Anything that is not plainly
    /// about access stays exactly what it was. Sending somebody to re-authenticate
    /// over a missing team or a dropped connection is worse than a vague message,
    /// because it is confidently wrong and costs them an evening on the wrong fix.
    static func fromGraphQL(_ message: String, during operation: String? = nil) -> LinearError {
        let said = message.lowercased()
        let aboutAccess = ["access denied", "not authorized", "unauthorized",
                           "forbidden", "permission", "scope"]
        // Substrings, not whole words: Linear phrases these several ways and the
        // list is a heuristic either way. Being wrong here costs a sentence of
        // advice; being silent costs the evening.
        if aboutAccess.contains(where: said.contains) {
            return .credentialTooNarrow(prefixed(message, with: operation))
        }
        return .api(prefixed(message, with: operation))
    }

    /// Which call this was, when the caller knows.
    ///
    /// A send is three requests with three different permission needs, and a refusal
    /// that names none of them can only be narrowed by changing something and trying
    /// again. Each of those rounds costs somebody a reinstall.
    private static func prefixed(_ message: String, with operation: String?) -> String {
        guard let operation else { return message }
        return "\(operation): \(message)"
    }

    /// Puts the operation's name on an error thrown from deeper down.
    ///
    /// The HTTP layer is shared by all three calls and cannot know which it is
    /// serving, so the naming happens on the way back out. Only `LinearError`s that
    /// carry a message are touched: a rate limit or a rejected key means the same
    /// thing whichever call hit it, and adding a label there would be noise.
    static func naming(_ operation: String, in error: Error) -> Error {
        switch error {
        case LinearError.api(let message):
            return LinearError.api(prefixed(message, with: operation))
        case LinearError.credentialTooNarrow(let said):
            return LinearError.credentialTooNarrow(prefixed(said, with: operation))
        default:
            return error
        }
    }

    /// Whether leaving it in the queue could plausibly help. A rejected key will be
    /// rejected again; a flat network will not be flat forever.
    public var isWorthRetrying: Bool {
        switch self {
        case .rateLimited, .unreachable: return true
        case .notConfigured, .noDestination, .credentialRejected, .notPermitted,
             .credentialTooNarrow, .api, .couldNotStore:
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
