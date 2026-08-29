import SwiftUI
import LoupeCore
import LoupeUI
import LoupeLinear

/// The bits of the demo that differ between a Mac window and an iPad screen.
///
/// Kept deliberately small. The demo's job is to be someone else's product, and a
/// host app that needed a platform abstraction layer to show two columns would be
/// testing the abstraction rather than the overlay.

/// Two columns on a wide screen, stacked on a narrow one.
///
/// `HSplitView` is AppKit-only, and an iPhone has no room for two columns anyway.
struct Columns<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isWide: Bool { sizeClass != .compact }
    #else
    private var isWide: Bool { true }
    #endif

    var body: some View {
        if isWide {
            HStack(alignment: .top, spacing: 0) {
                leading
                Divider()
                trailing
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    leading
                    Divider()
                    trailing
                }
            }
        }
    }
}

/// A width a column would like, which it gives up when there is not room.
///
/// A plain `.frame(minWidth:)` is a promise the layout cannot keep: two columns
/// asking for 460 and 320 want 780 points, and an iPad mini in portrait has 744. The
/// `HStack` honours both minimums, overflows, and gets centred - so *both* edges are
/// clipped. Every iPad screenshot in the README had the left pane's padding sliced
/// off and the pick badge half outside the screen, and it read as a Loupe bug rather
/// than a demo one.
///
/// It was already known on a phone, where "Stock" read "tock", but the guard was hung
/// on the compact size class - and an iPad mini in portrait is regular. The size class
/// was never the question. Whether the columns fit is.
extension View {
    func columnWidth(_ width: CGFloat) -> some View { modifier(ColumnWidth(width: width)) }
}

private struct ColumnWidth: ViewModifier {
    let width: CGFloat

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isWide: Bool { sizeClass != .compact }
    #else
    private var isWide: Bool { true }
    #endif

    func body(content: Content) -> some View {
        if isWide {
            // Ideal, not minimum. SwiftUI shares the space in proportion to the
            // ideals when there is enough and shrinks both when there is not, which
            // is what a column should do. A minimum cannot be negotiated, and an
            // unnegotiable minimum on a screen too small for it is an overflow.
            content.frame(idealWidth: width, maxWidth: .infinity, alignment: .leading)
        } else {
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A PNG from disk, as a SwiftUI image, on either platform.
func demoImage(contentsOf url: URL) -> Image? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    #if canImport(UIKit)
    guard let image = UIImage(data: data) else { return nil }
    return Image(uiImage: image)
    #elseif canImport(AppKit)
    guard let image = NSImage(data: data) else { return nil }
    return Image(nsImage: image)
    #else
    return nil
    #endif
}

/// The two roles, side by side, because the point of the demo is the seam between
/// them: one person leaves notes, and the other thing reads what came out.
struct RootView: View {
    let server: StubServer
    @State private var role: Role = .annotator
    @State private var loupeIsInstalled = true

    /// Only under `--offer-teardown`, so it is never in a screenshot.
    ///
    /// A host that turns Loupe off from its own menu is the real case - and
    /// `Loupe.stop()` used to leave the pill on screen with nothing behind it,
    /// because a `UIWindow` shown in a scene is retained by the scene rather than by
    /// whoever made it. That is not a thing a unit test can ask.
    /// Deliberately not a `scene=`: every scene begins annotating, and this needs the
    /// app exactly as it launches - pill and all - because the pill going away is the
    /// thing being asserted.
    private var offersTeardown: Bool {
        CommandLine.arguments.contains("--offer-teardown")
    }


    enum Role: String, CaseIterable, Identifiable {
        case annotator = "Annotator"
        case agent = "Agent inbox"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Role", selection: $role) {
                ForEach(Role.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            if offersTeardown, loupeIsInstalled {
                Button("Turn Loupe off") {
                    Loupe.stop()
                    loupeIsInstalled = false
                }
                .padding(.bottom, 12)
            }

            Divider()

            switch role {
            case .annotator: AnnotatorScreen(server: server)
            case .agent: AgentInbox()
            }
        }
    }
}

/// Everything the demo needs to say at launch, in one place, so both app entry
/// points stay to the few lines that are genuinely per-platform.
@MainActor
enum DemoLaunch {

    /// Throws away any tray left on disk, before Loupe gets a chance to read it.
    ///
    /// The tray surviving the app being killed is a feature - it is the whole of the
    /// offline queue - and it also makes UI tests order-dependent: one test that
    /// saves a note leaves every later test looking at "1 note" where it expected
    /// none. Five tests failed that way in one run and every one of them read as a
    /// missing pull, which is a long way from the cause.
    ///
    /// Asked for by the same function Loupe uses rather than rebuilt here. The path
    /// differs on Catalyst and inside a sandbox, and a second copy of that rule would
    /// go stale silently - the demo would look clean and would not be.
    static func clearSavedTrayIfAsked(appName: String) {
        guard CommandLine.arguments.contains("--fresh-session") else { return }
        try? FileManager.default.removeItem(
            at: FileTransport.defaultDirectory(appName: appName)
                .appendingPathComponent("tray.json"))
    }

    static func start(server: StubServer, platform: String) {
        Self.server = server
        do {
            try server.start()
            print("LOUPE-DEMO stub server on port \(server.port)")
        } catch {
            // Never swallowed. A demo whose server did not start looks exactly like
            // a demo whose network capture is broken, and that is the one claim the
            // whole thing exists to show.
            print("LOUPE-DEMO stub server failed: \(error)")
        }

        let app = AppInfo(name: "LoupeDemo",
                          version: "0.1.0",
                          commitSHA: gitSHA(),
                          platform: platform,
                          environment: "staging")
        clearSavedTrayIfAsked(appName: app.name)

        // Keep the folder, and deliver to Linear once somebody has configured it.
        // Not configured is not a failure: annotating works from the first launch,
        // and delivery switches itself on when the credential exists.
        let local = queuedTransport(server: server, appName: app.name)
            ?? FileTransport(directory: FileTransport.defaultDirectory(appName: app.name))
        Loupe.start(app: app, transport: LinearDelivery(keeping: local))

        // Puts the settings panel behind the tray's gear. Everything Linear in this
        // demo is these two lines.
        LoupeLinear.enable(oauth: demoOAuth)
        Seed.installIfNeeded(app: app, into: FileTransport.defaultDirectory(appName: app.name))
        LogRecorder.shared.info("stub server on \(server.port)", subsystem: "demo")
    }

    /// The OAuth application this demo signs in against.
    ///
    /// A client id is a public identifier rather than a credential. It ships in the
    /// binary of every OAuth mobile app there is, and PKCE is precisely what removes
    /// the need for a secret alongside it - so there is nothing here to leak. It is
    /// checked in so the settings panel's "Sign in with Linear" button does something
    /// when you tap it, instead of being a control that only works on one machine.
    ///
    /// The application is not public, so it installs into one workspace only. Your own
    /// host registers its own at `https://linear.app/settings/api/applications/new`
    /// and passes its own id here; the redirect is a parameter for that reason.
    private static let demoOAuth = LinearOAuth(clientID: "6b85019f81641e2fe253c67f42760bfa",
                                               redirectURI: "loupe://linear")

    /// The transport for a run that is testing the offline queue.
    ///
    /// `endpoint=dead` points at a port nothing listens on, so every send fails and
    /// the bundle stays on disk. `endpoint=stub` points at the demo's own intake
    /// route. Run one, kill the app, run the other: that is the whole offline story,
    /// and it is the half that cannot be checked without a real process boundary.
    /// Absent the argument, the demo writes files like it always has.
    private(set) static var queue: QueuedTransport?
    /// So a scene can read what the stub actually received.
    private(set) static var server: StubServer?

    private static func queuedTransport(server: StubServer, appName: String) -> Transport? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let raw = arguments.first(where: { $0.hasPrefix("endpoint=") }) else { return nil }

        let endpoint = String(raw.dropFirst("endpoint=".count)) == "stub"
            ? server.baseURL.appendingPathComponent("loupe/intake")
            : URL(string: "http://127.0.0.1:1/nothing-is-listening")!

        let directory = FileTransport.defaultDirectory(appName: appName)
            .appendingPathComponent("queue")
        let queue = QueuedTransport(wrapping: HTTPTransport(endpoint: endpoint),
                                    directory: directory)
        Self.queue = queue
        print("LOUPE-DEMO queue at \(directory.path), endpoint \(endpoint)")
        return queue
    }

    /// The single most useful field in a bundle: it is how an agent checks out the
    /// code that produced the screenshot. Only reachable on a Mac, where the demo
    /// runs from its own checkout; on a device it is baked in at build time or absent.
    private static func gitSHA() -> String? {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "--short", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let sha = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (sha?.isEmpty ?? true) ? nil : sha
        #else
        return Bundle.main.infoDictionary?["GitSHA"] as? String
        #endif
    }
}
