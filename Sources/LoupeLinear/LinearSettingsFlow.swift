import Foundation
import LoupeCore

/// The settings panel's behaviour, with no view in it.
///
/// It was all inside `LinearSettingsSheet` and nothing could reach it, which is how
/// three bugs shipped together in one screen: the project list never loaded on any
/// path, re-opening the panel showed a working credential with no pickers and a
/// disabled Save, and the sign-in path rebuilt its credential from a text field that
/// is empty after signing in. Each was one line. None was reachable by a test.
@MainActor
public final class LinearSettingsFlow: ObservableObject {

    /// What the panel is doing, so every state is visible rather than a spinner that
    /// means four different things.
    public enum Connection: Equatable {
        case idle
        case testing
        case connected(String)
        case failed(String)
    }

    @Published public private(set) var connection: Connection = .idle
    @Published public private(set) var teams: [LinearDirectory.Team] = []
    @Published public private(set) var projects: [LinearDirectory.Project] = []
    @Published public var teamID = ""
    @Published public var projectID = ""

    /// The credential that has actually been proved to work.
    ///
    /// Kept, rather than rebuilt from the key field wherever it is needed. After
    /// signing in with Linear there is nothing in that field at all, so every rebuild
    /// produced an empty token - and the project list came back empty on the one path
    /// where nobody had typed anything to begin with.
    private(set) var credential: LinearCredential?

    private let settings: LinearSettings
    private let makeDirectory: (LinearCredential) -> LinearDirectory

    public init(settings: LinearSettings = LinearSettings(),
                makeDirectory: @escaping (LinearCredential) -> LinearDirectory = {
                    LinearDirectory(credential: $0)
                }) {
        self.settings = settings
        self.makeDirectory = makeDirectory
    }

    /// Whether Save would do anything. A note has to have somewhere to go.
    public var canSave: Bool { !teamID.isEmpty }

    /// Re-opening the panel picks up where it left off, pickers and all.
    ///
    /// It used to say "connected" and show no pickers, because nothing went and asked
    /// Linear for the teams again. Since Save needs a team, that left someone with a
    /// perfectly good credential unable to save, and nothing on screen saying why.
    public func load() async {
        teamID = settings.destination?.teamID ?? ""
        projectID = settings.destination?.projectID ?? ""
        guard let saved = settings.credential() else { return }
        await connect(saved)
    }

    /// A key someone typed. `lin_api_` keys go in the header bare; anything else is
    /// an OAuth access token and is sent as a bearer.
    public func test(key: String) async {
        await connect(Self.credential(forTypedKey: key))
    }

    /// Proves a credential and fills the pickers from it.
    ///
    /// One path for all three ways in - a typed key, a fresh sign-in, and a credential
    /// already in the Keychain - because they differ only in where the credential came
    /// from. Three copies of this is how the sign-in path came to never load projects.
    public func connect(_ candidate: LinearCredential) async {
        connection = .testing
        let directory = makeDirectory(candidate)
        do {
            let who = try await directory.whoami()
            let found = try await directory.teams()
            credential = candidate
            teams = found
            // A team already chosen wins. Re-opening the panel must not quietly move
            // where notes go. A team that no longer exists does not win.
            if teamID.isEmpty || !found.contains(where: { $0.id == teamID }) {
                teamID = found.first?.id ?? ""
            }
            connection = .connected("\(who.name) in \(who.organisation)")
            await loadProjects()
        } catch {
            credential = nil
            teams = []
            projects = []
            connection = .failed(Self.readable(error))
        }
    }

    /// Projects for the chosen team.
    ///
    /// It used to rebuild a credential from the key field and return early unless the
    /// connection was already `.connected` - but its only caller ran while the
    /// connection was still `.testing`, so it returned early every single time and the
    /// Project picker never appeared at all.
    public func loadProjects() async {
        guard let credential, !teamID.isEmpty else {
            projects = []
            return
        }
        projects = (try? await makeDirectory(credential).projects(teamID: teamID)) ?? []
    }

    /// Stores whatever is now true. A typed key is saved; a credential that arrived by
    /// signing in was already saved when it arrived.
    public func save(key: String) {
        if !key.isEmpty { settings.save(Self.credential(forTypedKey: key)) }
        settings.destination = LinearDestination(
            teamID: teamID,
            projectID: projectID.isEmpty ? nil : projectID)
    }

    static func credential(forTypedKey key: String) -> LinearCredential {
        key.hasPrefix("lin_api_") ? .apiKey(key) : .accessToken(key)
    }

    /// What to show someone when it did not work.
    ///
    /// `String(describing:)` alone is right only when the error happens to be a
    /// `LinearError`, which carries its own sentence. Anything else - a dropped
    /// connection, a bad host - dumps a struct into a panel the person has to act on.
    static func readable(_ error: Error) -> String {
        if let linear = error as? LinearError { return linear.description }
        return (error as NSError).localizedDescription
    }
}
