import Foundation

/// What went wrong, in terms someone can act on.
///
/// "Send failed" alone sends people to the wrong fix. A rejected key, a team you
/// have no rights to and a flat network are three different problems with three
/// different next steps, and only one of them is worth retrying.
public enum LinearError: Error, Equatable, CustomStringConvertible, Sendable {
    case notConfigured
    case credentialRejected
    case notPermitted(String)
    case rateLimited(retryAfter: TimeInterval?)
    case unreachable(String)
    case api(String)

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
        }
    }

    /// Whether leaving it in the queue could plausibly help. A rejected key will be
    /// rejected again; a flat network will not be flat forever.
    public var isWorthRetrying: Bool {
        switch self {
        case .rateLimited, .unreachable: return true
        case .notConfigured, .credentialRejected, .notPermitted, .api: return false
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
