import SwiftUI
import LoupeCore
import LoupeUI

/// Where someone puts their Linear credential in, on the device they are holding.
///
/// It lives here rather than in `LoupeUI` on purpose: a host that wants capture only
/// takes `LoupeUI` and never compiles a line of Linear. The dependency that matters
/// is the one that does not exist.
@MainActor
public struct LinearSettingsSheet: View {

    /// What the panel is doing, so every one of these has a visible state rather
    /// than a spinner that means four different things.
    enum Connection: Equatable {
        case idle
        case testing
        case connected(String)
        case failed(String)
    }

    private let settings: LinearSettings
    private let makeDirectory: (LinearCredential) -> LinearDirectory
    private let onClose: () -> Void
    /// Present when the host has registered an OAuth application. Absent is normal:
    /// the API key path needs no setup at all, and asking someone to register an app
    /// before they can try the tool is a worse first five minutes.
    private let oauth: LinearOAuth?

    @State private var key = ""
    @State private var connection: Connection = .idle
    @State private var teams: [LinearDirectory.Team] = []
    @State private var projects: [LinearDirectory.Project] = []
    @State private var teamID = ""
    @State private var projectID = ""

    public init(settings: LinearSettings = LinearSettings(),
                oauth: LinearOAuth? = nil,
                makeDirectory: @escaping (LinearCredential) -> LinearDirectory = {
                    LinearDirectory(credential: $0)
                },
                onClose: @escaping () -> Void) {
        self.settings = settings
        self.oauth = oauth
        self.makeDirectory = makeDirectory
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LoupeTheme.Space.md) {
            header
            Divider().overlay(LoupeTheme.Colors.line.color)

            if let oauth {
                // Full width, because it is the recommended path and a button that
                // hugs its label reads as one option among several rather than as
                // the one to take.
                signIn(with: oauth)
                    .frame(maxWidth: .infinity)
                Text("or paste a key")
                    .font(LoupeTheme.Typography.note)
                    .foregroundStyle(LoupeTheme.Colors.inkSoft.color)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            credentialField
            status

            if !teams.isEmpty {
                picker("Team", selection: $teamID,
                       options: teams.map { ($0.id, "\($0.name) · \($0.key)") })
                    .onChange(of: teamID) { _ in Task { await loadProjects() } }

                if !projects.isEmpty {
                    picker("Project", selection: $projectID,
                           options: [("", "None")] + projects.map { ($0.id, $0.name) })
                }
            }

            footer
        }
        .padding(LoupeTheme.Space.md)
        .frame(width: 360)
        .loupePanel()
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack {
            Text("Send notes to Linear")
                .font(LoupeTheme.Typography.label)
                .foregroundStyle(LoupeTheme.Colors.ink.color)
            Spacer()
            Button("Close", action: onClose)
                .buttonStyle(LoupeButtonStyle(kind: .quiet))
        }
    }

    private var credentialField: some View {
        VStack(alignment: .leading, spacing: LoupeTheme.Space.xs) {
            Text("Personal API key")
                .font(LoupeTheme.Typography.note)
                .foregroundStyle(LoupeTheme.Colors.inkSoft.color)
            // Secure, because it is over someone's shoulder on an iPad.
            SecureField("lin_api_\u{2026}", text: $key)
                .textFieldStyle(.plain)
                .padding(LoupeTheme.Space.sm)
                .background(
                    RoundedRectangle(cornerRadius: LoupeTheme.Radius.control,
                                     style: .continuous)
                        .strokeBorder(LoupeTheme.Colors.line.color,
                                      lineWidth: LoupeTheme.Stroke.hairline))
                .accessibilityLabel("Linear personal API key")
            Text("linear.app \u{2192} Settings \u{2192} API \u{2192} Personal API keys")
                .font(LoupeTheme.Typography.note)
                .foregroundStyle(LoupeTheme.Colors.inkSoft.color)
        }
    }

    #if canImport(AuthenticationServices) && !os(macOS)
    private func signIn(with oauth: LinearOAuth) -> some View {
        Button("Sign in with Linear") {
            Task {
                connection = .testing
                do {
                    let credential = try await LinearSignIn(oauth: oauth).run()
                    settings.save(credential)
                    key = ""
                    await testSaved(credential)
                } catch {
                    connection = .failed(Self.readable(error))
                }
            }
        }
        .buttonStyle(LoupeButtonStyle(kind: .primary))
        .accessibilityLabel("Sign in with Linear")
    }
    #else
    private func signIn(with oauth: LinearOAuth) -> some View { EmptyView() }
    #endif

    /// What to show someone when it did not work.
    ///
    /// `String(describing:)` alone is right only when the error happens to be a
    /// `LinearError`, which carries its own sentence. Anything else - a dropped
    /// connection, a bad host - dumps a struct into a panel the person has to act on.
    static func readable(_ error: Error) -> String {
        if let linear = error as? LinearError { return linear.description }
        return (error as NSError).localizedDescription
    }

    /// After signing in there is no key in the field to test with, so the saved
    /// credential is what gets checked.
    private func testSaved(_ credential: LinearCredential) async {
        let directory = makeDirectory(credential)
        do {
            let who = try await directory.whoami()
            teams = try await directory.teams()
            if teamID.isEmpty { teamID = teams.first?.id ?? "" }
            connection = .connected("\(who.name) in \(who.organisation)")
        } catch {
            connection = .failed(Self.readable(error))
        }
    }

    @ViewBuilder
    private var status: some View {
        switch connection {
        case .idle:
            EmptyView()
        case .testing:
            Text("Checking\u{2026}")
                .font(LoupeTheme.Typography.note)
                .foregroundStyle(LoupeTheme.Colors.inkSoft.color)
        case .connected(let who):
            // Who and where, not just "connected": the common mistake is a key for
            // the wrong workspace, and "connected" would hide it.
            Text("Connected as \(who)")
                .font(LoupeTheme.Typography.note)
                .foregroundStyle(LoupeTheme.Colors.action.color)
        case .failed(let why):
            Text(why)
                .font(LoupeTheme.Typography.note)
                .foregroundStyle(LoupeTheme.Colors.highlight.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            // Bordered, not quiet: a quiet button has no outline until it is
            // hovered, and there is no hover on a touch screen - so on the device
            // this read as a label rather than something to press.
            Button("Test connection") { Task { await test() } }
                .buttonStyle(LoupeButtonStyle(kind: .secondary))
                .disabled(key.isEmpty || connection == .testing)
            Spacer()
            Button("Save") { save() }
                .buttonStyle(LoupeButtonStyle(kind: .primary))
                .disabled(teamID.isEmpty)
        }
    }

    private func picker(_ title: String, selection: Binding<String>,
                        options: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: LoupeTheme.Space.xs) {
            Text(title)
                .font(LoupeTheme.Typography.note)
                .foregroundStyle(LoupeTheme.Colors.inkSoft.color)
            Picker(title, selection: selection) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .accessibilityLabel(title)
        }
    }

    // MARK: - Behaviour

    private func load() {
        teamID = settings.destination?.teamID ?? ""
        projectID = settings.destination?.projectID ?? ""
        // The key itself is never read back into the field. It is in the Keychain,
        // and showing it again would only give it somewhere else to leak from.
        if settings.credential() != nil { connection = .connected("a saved credential") }
    }

    private func test() async {
        connection = .testing
        let credential: LinearCredential =
            key.hasPrefix("lin_api_") ? .apiKey(key) : .accessToken(key)
        let directory = makeDirectory(credential)
        do {
            let who = try await directory.whoami()
            teams = try await directory.teams()
            if teamID.isEmpty { teamID = teams.first?.id ?? "" }
            await loadProjects()
            connection = .connected("\(who.name) in \(who.organisation)")
        } catch {
            teams = []
            projects = []
            connection = .failed(Self.readable(error))
        }
    }

    private func loadProjects() async {
        guard !teamID.isEmpty, case .connected = connection else { return }
        let credential: LinearCredential =
            key.hasPrefix("lin_api_") ? .apiKey(key) : .accessToken(key)
        projects = (try? await makeDirectory(credential).projects(teamID: teamID)) ?? []
    }

    private func save() {
        if !key.isEmpty {
            settings.save(key.hasPrefix("lin_api_") ? .apiKey(key) : .accessToken(key))
        }
        settings.destination = LinearDestination(
            teamID: teamID,
            projectID: projectID.isEmpty ? nil : projectID)
        onClose()
    }
}
