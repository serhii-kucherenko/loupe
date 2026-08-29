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

    /// Whether the panel has been to the Keychain yet.
    ///
    /// Separate from `connection`, because "I have not looked" and "I looked and
    /// there is nothing" are different facts and the panel has to draw them
    /// differently. They were the same value, so a panel opened by somebody already
    /// signed in showed "Sign in with Linear" until the answer came back - telling
    /// him he was signed out, in the moment he was least able to tell it was wrong.
    ///
    /// Not folded into `connection` as a case: a manual Test connection also passes
    /// through `.testing`, and hiding the key field out from under somebody mid-test
    /// would be its own bug.
    @Published public private(set) var isRestoring = true

    /// The workspace the credential belongs to, and who it belongs to.
    ///
    /// The workspace is shown but never chosen. A Linear credential - personal key or
    /// OAuth token alike - is issued by exactly one workspace, so there is no list to
    /// pick from: changing workspace means changing credential. Showing it beside the
    /// team and the project is what makes that obvious, rather than leaving somebody
    /// hunting for a picker that cannot exist.
    @Published public private(set) var workspace: String?
    @Published public private(set) var person: String?
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
    /// How the credential is stored.
    ///
    /// A seam, so the one failure that matters can be tested without a machine that
    /// refuses Keychain writes: an app with no Keychain entitlement is refused
    /// outright on Mac Catalyst, and that used to be entirely silent.
    private let store: (LinearCredential) throws -> Void
    /// The other half of the same seam. Symmetric with `store` on purpose: a test
    /// that can inject a write and not a delete ends up asserting through a real
    /// Keychain for half its work, which on the iOS simulator means refusing.
    private let clear: () throws -> Void

    public init(settings: LinearSettings = LinearSettings(),
                makeDirectory: @escaping (LinearCredential) -> LinearDirectory = {
                    LinearDirectory(credential: $0)
                },
                store: ((LinearCredential) throws -> Void)? = nil,
                clear: (() throws -> Void)? = nil) {
        self.settings = settings
        self.makeDirectory = makeDirectory
        self.store = store ?? { try settings.save($0) }
        self.clear = clear ?? { try settings.clearCredential() }
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
        let saved = settings.credential()

        // Here, not after `connect`. The Keychain read is synchronous and instant;
        // proving the credential is a network round trip. Holding the flag across
        // both would show only a spinner to anybody offline or holding a stale
        // credential - no key field to paste a new one into, and no message saying
        // what is happening - for as long as the request took to give up.
        isRestoring = false

        guard let saved else { return }
        // `connect` sets `.testing`, which the panel already draws as "Checking…",
        // so the network stretch stays visible without hiding the way out of it.
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
            person = who.name
            workspace = who.organisation
            connection = .connected(who.name)
            await loadProjects()
        } catch {
            credential = nil
            person = nil
            workspace = nil
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
        do {
            let found = try await makeDirectory(credential).projects(teamID: teamID)
            projects = found
            // A project that is genuinely gone must not stay chosen, the same rule
            // teams already follow. Only on an answer, though: `try?` used to turn a
            // dropped call into an empty list, so a blocked network read exactly like
            // "your project no longer exists" and quietly moved where notes go.
            if !projectID.isEmpty, !found.contains(where: { $0.id == projectID }) {
                projectID = ""
            }
        } catch {
            // The list belongs to a team that may have just changed, so it cannot be
            // kept - but the chosen project is the person's, not Linear's, and one
            // failed request is no reason to throw it away.
            projects = []
        }
    }

    /// Asks Linear again with the credential already proved.
    ///
    /// The way to see a project made in Linear a moment ago. Loupe deliberately
    /// cannot create one - Linear has no scope for it short of `write`, which is
    /// write access to an entire account, and that is not a trade an annotation tool
    /// should ask anybody to make. So the answer is to make it in Linear and have
    /// this pick it up, which has to be one obvious button rather than quitting the
    /// app.
    ///
    /// - Returns: `false` when there is nothing to refresh with yet.
    @discardableResult
    public func refresh() async -> Bool {
        guard let credential else { return false }
        await connect(credential)
        return true
    }

    /// Forgets the credential and everything that depended on it.
    ///
    /// The destination goes too. A team id left behind a credential that no longer
    /// exists is the same lie as one left behind a credential that was refused: the
    /// panel reopens looking configured.
    /// - Returns: `false` when the credential could not actually be removed, with
    ///   `connection` carrying the reason. The panel must not draw a signed-out state
    ///   on a `false`: a credential somebody believes they deleted and has not is
    ///   worse than one they never tried to delete.
    @discardableResult
    public func signOut() -> Bool {
        do {
            try clear()
        } catch {
            connection = .failed(Self.readable(error))
            return false
        }
        settings.destination = nil
        credential = nil
        person = nil
        workspace = nil
        teams = []
        projects = []
        teamID = ""
        projectID = ""
        connection = .idle
        return true
    }

    /// Stores whatever is now true, and says whether it took.
    ///
    /// - Returns: `true` when everything was written. `false` means the credential was
    ///   refused and `connection` now carries the reason - the panel must not close on
    ///   a `false`, because closing is what made the old silent failure look like
    ///   success.
    @discardableResult
    public func save(key: String) -> Bool {
        if !key.isEmpty {
            do {
                try store(Self.credential(forTypedKey: key))
            } catch {
                connection = .failed(Self.readable(error))
                return false
            }
        }
        // The destination is only useful with a credential behind it, so it is written
        // second and only once the credential is safely down.
        settings.destination = LinearDestination(
            teamID: teamID,
            projectID: projectID.isEmpty ? nil : projectID)
        return true
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
