import SwiftUI
import LoupeCore
import LoupeUI

/// Where someone puts their Linear credential in, on the device they are holding.
///
/// It lives here rather than in `LoupeUI` on purpose: a host that wants capture only
/// takes `LoupeUI` and never compiles a line of Linear. The dependency that matters
/// is the one that does not exist.
///
/// The behaviour is all in `LinearSettingsFlow`, which is a plain object with no view
/// in it. It used to be in here, where nothing could reach it.
@MainActor
public struct LinearSettingsSheet: View {

    @StateObject private var flow: LinearSettingsFlow
    private let onClose: () -> Void
    /// Present when the host has registered an OAuth application. Absent is normal:
    /// the API key path needs no setup at all, and asking someone to register an app
    /// before they can try the tool is a worse first five minutes.
    private let oauth: LinearOAuth?
    private let settings: LinearSettings

    @State private var key = ""

    public init(settings: LinearSettings = LinearSettings(),
                oauth: LinearOAuth? = nil,
                makeDirectory: @escaping (LinearCredential) -> LinearDirectory = {
                    LinearDirectory(credential: $0)
                },
                onClose: @escaping () -> Void) {
        self.settings = settings
        self.oauth = oauth
        self.onClose = onClose
        _flow = StateObject(wrappedValue: LinearSettingsFlow(settings: settings,
                                                             makeDirectory: makeDirectory))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LoupeTheme.Space.md) {
            header
            Divider().overlay(LoupeTheme.Colors.line.color)

            // Signed in, or the two ways to sign in. Never both, and never a
            // primary button saying "Sign in with Linear" to somebody who already
            // has. That branch used to render whenever an OAuth application was
            // configured and never looked at the connection at all, so the loudest
            // thing on the panel contradicted the status line underneath it.
            if isSignedIn {
                signedIn
            } else {
                if let oauth {
                    // Full width, because it is the recommended path and a button
                    // that hugs its label reads as one option among several rather
                    // than as the one to take.
                    signIn(with: oauth)
                        .frame(maxWidth: .infinity)
                    Text("or paste a key")
                        .font(LoupeTheme.Typography.note)
                        .foregroundStyle(LoupeTheme.Colors.inkSoft.color)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                credentialField
            }

            status

            if !flow.teams.isEmpty {
                // Where a note actually lands, in the order it narrows: workspace,
                // then team, then project.
                if let workspace = flow.workspace {
                    field("Workspace") {
                        Text(workspace)
                            .font(LoupeTheme.Typography.label)
                            .foregroundStyle(LoupeTheme.Colors.ink.color)
                    }
                }

                picker("Team", selection: $flow.teamID,
                       options: flow.teams.map { ($0.id, "\($0.name) · \($0.key)") })
                    .onChange(of: flow.teamID) { _ in Task { await flow.loadProjects() } }

                picker("Project", selection: $flow.projectID,
                       options: [("", "None")] + flow.projects.map { ($0.id, $0.name) })

                // Loupe does not create projects. Linear has no scope that allows it
                // short of `write`, which is write access to a whole account, and an
                // annotation tool has no business asking for that. So this says where
                // to go and the button below brings the new one back.
                Text("Need another project? Make it in Linear, then Refresh.")
                    .font(LoupeTheme.Typography.note)
                    .foregroundStyle(LoupeTheme.Colors.inkSoft.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(LoupeTheme.Space.md)
        .frame(width: 360)
        .loupePanel()
        .task { await flow.load() }
    }

    private var isSignedIn: Bool {
        if case .connected = flow.connection { return true }
        return false
    }

    /// Who is connected, and the way back out.
    ///
    /// Sign out rather than nothing: a key for the wrong workspace is the common
    /// mistake, and somebody who can see they are signed in as the wrong person needs
    /// a way to stop being.
    private var signedIn: some View {
        HStack {
            VStack(alignment: .leading, spacing: LoupeTheme.Space.xs) {
                Text("Signed in")
                    .font(LoupeTheme.Typography.note)
                    .foregroundStyle(LoupeTheme.Colors.inkSoft.color)
                Text(flow.person ?? "this workspace")
                    .font(LoupeTheme.Typography.label)
                    .foregroundStyle(LoupeTheme.Colors.ink.color)
            }
            Spacer()
            Button("Sign out") {
                key = ""
                flow.signOut()
            }
            .buttonStyle(LoupeButtonStyle(kind: .secondary))
            .accessibilityLabel("Sign out of Linear")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                do {
                    let signedIn = try await LinearSignIn(oauth: oauth).run()
                    try settings.save(signedIn)
                    key = ""
                    await flow.connect(signedIn)
                } catch {
                    await flow.connect(.accessToken(""))
                }
            }
        }
        .buttonStyle(LoupeButtonStyle(kind: .primary))
        .accessibilityLabel("Sign in with Linear")
    }
    #else
    private func signIn(with oauth: LinearOAuth) -> some View { EmptyView() }
    #endif

    @ViewBuilder
    private var status: some View {
        switch flow.connection {
        case .idle:
            // Save needs a team, and a team needs a credential. Without this the
            // panel showed a disabled Save and nothing at all saying why.
            Text("Sign in or paste a key to choose where notes go.")
                .font(LoupeTheme.Typography.note)
                .foregroundStyle(LoupeTheme.Colors.inkSoft.color)
                .fixedSize(horizontal: false, vertical: true)
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
            // One button, two jobs, because they are the same request. Before there
            // is a credential it proves the one being typed; afterwards it asks
            // Linear again, which is how a project made in the browser a moment ago
            // turns up in the picker.
            //
            // It used to be disabled whenever the key field was empty - which, after
            // signing in, it always is. So somebody who signed in had no way to
            // refresh anything at all.
            //
            // Bordered, not quiet: a quiet button has no outline until it is hovered,
            // and there is no hover on a touch screen - so on the device this read as
            // a label rather than something to press.
            Button(isSignedIn ? "Refresh" : "Test connection") {
                Task {
                    if isSignedIn {
                        await flow.refresh()
                    } else {
                        await flow.test(key: key)
                    }
                }
            }
            .buttonStyle(LoupeButtonStyle(kind: .secondary))
            .disabled(flow.connection == .testing || (!isSignedIn && key.isEmpty))
            .accessibilityLabel(isSignedIn
                                ? "Refresh teams and projects from Linear"
                                : "Test the connection to Linear")
            Spacer()
            Button("Save") {
                // Only on a write that actually took. A panel that closes on a refused
                // Keychain write is the whole of the bug this replaced: it looked
                // exactly like success, and the key was gone on the next launch.
                if flow.save(key: key) { onClose() }
            }
            .buttonStyle(LoupeButtonStyle(kind: .primary))
            .disabled(!flow.canSave)
        }
    }

    /// A labelled row. The workspace uses one without a control, because it is not a
    /// choice - it is what the credential is.
    private func field<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: LoupeTheme.Space.xs) {
            Text(title)
                .font(LoupeTheme.Typography.note)
                .foregroundStyle(LoupeTheme.Colors.inkSoft.color)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
}
