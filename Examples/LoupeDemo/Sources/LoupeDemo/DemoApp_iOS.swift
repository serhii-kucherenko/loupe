#if os(iOS)
import SwiftUI
import UIKit
import LoupeCore
import LoupeUI

/// The same demo, on iPad and iPhone.
///
/// The screens are shared with the Mac build; only the launch and the reach for a
/// window differ, which is the point - a host app should not have to know much
/// about Loupe.
@main
struct LoupeDemoiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView(server: delegate.server)
                .background(WindowAccessor { window in
                    Loupe.attach(to: window)
                    DemoScene.run(in: window)
                })
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    let server = StubServer()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated {
            DemoLaunch.start(server: server, platform: UIDevice.current.userInterfaceIdiom == .pad
                             ? "iPadOS" : "iOS")
        }
        return true
    }
}

/// Drives the overlay into one state and stops, so a simulator run can take the
/// same pictures a person would. Nothing here runs unless the launch arguments ask
/// for it: `xcrun simctl launch <device> dev.loupe.demo scene=tray`.
///
/// It also prints what the picker resolved to, which is the thing actually worth
/// knowing on iOS - SwiftUI renders into very few UIViews, so what the
/// meaningful-ancestor walk lands on is a real question rather than an assumption.
@MainActor
enum DemoScene {
    static func run(in window: UIWindow) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let raw = arguments.first(where: { $0.hasPrefix("scene=") }) else { return }
        let scene = String(raw.dropFirst("scene=".count))
        guard let model = Loupe.model else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                model.beginAnnotating()

                // Proportional, not fixed. Points tuned on one iPad land off the
                // screen on an iPhone, and the scene is the only way these states
                // are ever seen on a device.
                let size = window.bounds.size
                let row = CGPoint(x: size.width * 0.26, y: size.height * 0.27)
                let basket = CGPoint(x: size.width * 0.77, y: size.height * 0.165)

                if scene == "hover" || scene == "pick" || scene == "tray" {
                    report(at: row, in: window, label: "row")
                    pick(at: row, in: window, model: model)
                }
                if scene == "tray" {
                    model.saveComment("stock count is unreadable at that size", tag: .polish)
                    model.resumePicking()
                    report(at: basket, in: window, label: "basket")
                    pick(at: basket, in: window, model: model)
                    model.saveComment("the empty basket gives you nowhere to go", tag: .bug)
                }
            }
        }
    }

    private static func report(at point: CGPoint, in window: UIWindow, label: String) {
        guard let shot = ElementPicker.capture(at: point, in: window) else {
            print("LOUPE-SCENE \(label): nothing at \(point)")
            return
        }
        print("LOUPE-SCENE \(label): class=\(shot.ref.className ?? "region") "
              + "id=\(shot.ref.accessibilityID ?? "-") "
              + "label=\(shot.ref.label ?? "-") bounds=\(shot.ref.bounds) "
              + "crop=\(shot.screenshotPNG?.count ?? 0)B")
    }

    private static func pick(at point: CGPoint, in window: UIWindow, model: OverlayModel) {
        guard let shot = ElementPicker.capture(at: point, in: window) else { return }
        model.pick(shot.ref,
                   screenshotPNG: shot.screenshotPNG,
                   contextScreenshotPNG: shot.contextScreenshotPNG,
                   viewport: Rect(x: 0, y: 0, width: window.bounds.width,
                                  height: window.bounds.height))
    }
}

/// Reaches the `UIWindow` behind a SwiftUI scene, once there is one.
///
/// A shake is not wired up here on purpose: the pill is the discoverable way in.
/// A host that wants the gesture calls `Loupe.handleShake()` from its own
/// `motionEnded`, which is the one place it is reliable.
struct WindowAccessor: UIViewRepresentable {
    let onWindow: (UIWindow) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}
#endif
