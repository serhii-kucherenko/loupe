import SwiftUI
import LoupeCore
import LoupeUI

/// Turning capture into delivery, in one call.
///
/// ```swift
/// Loupe.start(app: app)
/// Loupe.attach(to: window)
/// LoupeLinear.enable()          // adds the settings panel and the transport
/// ```
///
/// Everything here is opt-in by construction: a host that never imports this module
/// never compiles a line of it, and `LoupeCore` still has no idea what an issue
/// tracker is.
@MainActor
public enum LoupeLinear {

    /// Where the panel should appear from, since the SDK does not own a view
    /// hierarchy it can present into.
    public static private(set) var settingsSheet: (() -> AnyView)?

    /// Whether a note would reach Linear right now, which is worth being able to ask
    /// before annotating rather than after pressing Send.
    public static func isConfigured(_ settings: LinearSettings = LinearSettings()) -> Bool {
        (try? settings.transport()) != nil
    }

    /// Wires the settings panel into the tray and, once configured, the transport
    /// into the session.
    ///
    /// - Parameter present: how to show the panel. A host with its own navigation
    ///   passes its own; the default asks the overlay to show it, which is what an
    ///   iPad with no settings screen needs.
    public static func enable(settings: LinearSettings = LinearSettings(),
                              oauth: LinearOAuth? = nil,
                              present: ((AnyView) -> Void)? = nil) {
        guard let model = Loupe.model else { return }
        presenter = present

        settingsSheet = {
            AnyView(LinearSettingsSheet(settings: settings, oauth: oauth, onClose: {
                Loupe.model?.dismissPanel()
            }))
        }

        model.onSettings = { presentSettings() }
    }

    /// Opens the settings panel from wherever the host wants.
    ///
    /// A host with its own settings screen can put a "Linear settings" item in its own
    /// menu and call this, rather than relying on the overlay's gear. Named, because
    /// the only way to do it before was to read `settingsSheet` out of this type and
    /// present it yourself, which one adopter did - after reading the source.
    public static func presentSettings() {
        guard let sheet = settingsSheet?() else { return }
        if let present = presenter {
            present(sheet)
        } else {
            Loupe.model?.present(sheet)
        }
    }

    private static var presenter: ((AnyView) -> Void)?
}
