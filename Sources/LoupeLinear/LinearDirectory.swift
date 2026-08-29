import Foundation

/// The teams and projects someone can choose from.
///
/// Pickers rather than UUID fields, because the person configuring this is standing
/// in front of an iPad with no keyboard and is not going to type
/// `a1b2c3d4-...` from memory.
public struct LinearDirectory: Sendable {

    public struct Team: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let key: String
    }

    public struct Project: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
    }

    public struct Whoami: Equatable, Sendable {
        public let name: String
        public let organisation: String
    }

    private let credential: LinearCredential
    private let endpoint: URL
    private let fetch: LinearTransport.Fetch

    public init(credential: LinearCredential,
                endpoint: URL = URL(string: "https://api.linear.app/graphql")!,
                fetch: @escaping LinearTransport.Fetch = {
                    try await URLSession.shared.data(for: $0)
                }) {
        self.credential = credential
        self.endpoint = endpoint
        self.fetch = fetch
    }

    /// Proves the credential before anything is annotated, and says who it belongs
    /// to - "connected" is less reassuring than "connected as you, in your workspace".
    public func whoami() async throws -> Whoami {
        let data = try await query("{ viewer { name } organization { name } }")
        let viewer = (data["viewer"] as? [String: Any])?["name"] as? String
        let organisation = (data["organization"] as? [String: Any])?["name"] as? String
        guard let viewer, let organisation else {
            throw LinearError.api("Linear did not say who this credential belongs to")
        }
        return Whoami(name: viewer, organisation: organisation)
    }

    public func teams() async throws -> [Team] {
        let data = try await query("{ teams(first: 100) { nodes { id name key } } }")
        let nodes = (data["teams"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return nodes.compactMap {
            guard let id = $0["id"] as? String, let name = $0["name"] as? String,
                  let key = $0["key"] as? String else { return nil }
            return Team(id: id, name: name, key: key)
        }
    }

    public func projects(teamID: String) async throws -> [Project] {
        let data = try await query("""
        query Projects($team: String!) {
          team(id: $team) { projects(first: 100) { nodes { id name } } }
        }
        """, ["team": teamID])
        let team = data["team"] as? [String: Any]
        let nodes = (team?["projects"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return nodes.compactMap {
            guard let id = $0["id"] as? String, let name = $0["name"] as? String else {
                return nil
            }
            return Project(id: id, name: name)
        }
    }

    /// Makes a project, or hands back the one that is already there.
    ///
    /// Somebody annotating an app for the first time is exactly the person whose
    /// project does not exist yet, and sending them to a browser mid-annotation is
    /// where the session ends.
    ///
    /// It looks before it creates, because `projectCreate` is not idempotent the way
    /// `issueCreate` is: a retry after a dropped connection would otherwise leave two
    /// projects with the same name and no way to tell which one the notes went to.
    /// Matching is case- and whitespace-insensitive, since "Reco" and "reco " are the
    /// same project to the person typing them and two different ones to Linear.
    ///
    /// - Throws: `.notPermitted` when the credential cannot create projects. An OAuth
    ///   token scoped `issues:create` files issues perfectly well and is refused here,
    ///   which is a confusing thing to meet without being told why.
    public func createProject(named name: String, teamID: String) async throws -> Project {
        let wanted = Self.comparable(name)
        guard !wanted.isEmpty else {
            throw LinearError.api("A project needs a name.")
        }

        if let existing = try await projects(teamID: teamID)
            .first(where: { Self.comparable($0.name) == wanted }) {
            return existing
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let data: [String: Any]
        do {
            data = try await query("""
            mutation CreateProject($name: String!, $teams: [String!]!) {
              projectCreate(input: { name: $name, teamIds: $teams }) {
                success
                project { id name }
              }
            }
            """, ["name": trimmed, "teams": [teamID]])
        } catch let error as LinearError {
            throw Self.readableCreateFailure(error)
        }

        let result = data["projectCreate"] as? [String: Any]
        guard result?["success"] as? Bool == true,
              let project = result?["project"] as? [String: Any],
              let id = project["id"] as? String,
              let created = project["name"] as? String
        else {
            throw LinearError.api("Linear did not create the project and did not say why.")
        }
        return Project(id: id, name: created)
    }

    /// Linear refuses a too-narrow token the same way it refuses a wrong one, so the
    /// message has to name the likely cause rather than repeat "no permission".
    private static func readableCreateFailure(_ error: LinearError) -> LinearError {
        switch error {
        case .notPermitted, .credentialRejected:
            return .notPermitted(
                "creating projects. A Linear sign-in only asks to create issues. "
                + "Sign in again to grant write access, or paste a personal API key.")
        case .api(let message) where Self.readsAsScopeRefusal(message):
            return .notPermitted(
                "creating projects. A Linear sign-in only asks to create issues. "
                + "Sign in again to grant write access, or paste a personal API key.")
        default:
            return error
        }
    }

    /// GraphQL puts an access failure in the errors array with a 200, so the status
    /// code cannot be relied on to tell a refusal from anything else.
    private static func readsAsScopeRefusal(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("access denied")
            || lowered.contains("not authorized")
            || lowered.contains("scope")
            || lowered.contains("permission")
    }

    /// Two names are the same project when a person would call them the same.
    static func comparable(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func query(_ text: String,
                       _ variables: [String: Any] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credential.headerValue, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["query": text, "variables": variables])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(request)
        } catch {
            throw LinearError.unreachable((error as NSError).localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401: throw LinearError.credentialRejected
            case 403: throw LinearError.notPermitted("this workspace")
            case 429: throw LinearError.rateLimited(retryAfter: nil)
            default: throw LinearError.api("Linear returned \(http.statusCode)")
            }
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LinearError.api("Linear returned something that is not JSON")
        }
        if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
            throw LinearError.api(errors.first?["message"] as? String ?? "unknown error")
        }
        return json["data"] as? [String: Any] ?? [:]
    }
}
