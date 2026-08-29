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

        if scene == "queue" || scene == "drain" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                Task { await runQueue(scene, in: window, model: model) }
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                if scene == "key" {
                    func report(_ label: String) {
                        let key = window.windowScene?.windows.first { $0.isKeyWindow }
                        let name = key.map { $0 === window ? "APP" : "\(type(of: $0))" }
                        print("LOUPE-KEY \(label): key=\(name ?? "none")")
                    }
                    report("off")
                    model.beginAnnotating()
                    report("picking")

                    // The half that matters: the comment field must still be able
                    // to take the keyboard, or refusing key status has traded one
                    // bug for a worse one.
                    let point = CGPoint(x: window.bounds.width * 0.26,
                                        y: window.bounds.height * 0.27)
                    pick(at: point, in: window, model: model)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        MainActor.assumeIsolated {
                            report("commenting")
                            model.cancelComment()
                            model.endAnnotating()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                MainActor.assumeIsolated { report("back to off") }
                            }
                        }
                    }
                    return
                }

                model.beginAnnotating()

                // Proportional, not fixed. Points tuned on one iPad land off the
                // screen on an iPhone, and the scene is the only way these states
                // are ever seen on a device.
                let size = window.bounds.size
                let row = CGPoint(x: size.width * 0.26, y: size.height * 0.27)
                let basket = CGPoint(x: size.width * 0.77, y: size.height * 0.165)

                // Drag-select, mid-gesture and then committed. The mid-gesture
                // frame is the one worth looking at: if the dashed rectangle does
                // not track the finger, the gesture is unusable however correct the
                // captured bounds turn out to be.
                if scene == "drag" || scene == "dragging" {
                    let from = CGPoint(x: size.width * 0.10, y: size.height * 0.22)
                    let to = CGPoint(x: size.width * 0.46, y: size.height * 0.34)
                    model.drag(to: Rect(x: from.x, y: from.y,
                                        width: to.x - from.x, height: to.y - from.y))
                    if scene == "drag" {
                        let rect = CGRect(x: from.x, y: from.y,
                                          width: to.x - from.x, height: to.y - from.y)
                        if let shot = ElementPicker.capture(rect: rect, in: window) {
                            print("LOUPE-SCENE drag: kind=\(shot.ref.kind.rawValue) "
                                  + "bounds=\(shot.ref.bounds) crop=\(shot.screenshotPNG?.count ?? 0)B")
                            model.pick(shot.ref,
                                       screenshotPNG: shot.screenshotPNG,
                                       contextScreenshotPNG: shot.contextScreenshotPNG,
                                       viewport: Rect(x: 0, y: 0, width: size.width,
                                                      height: size.height))
                        }
                    }
                }

                // Which window holds the keyboard, in each mode. The host's own key
                // commands go to the key window's responder chain, so an overlay
                // that keeps key status silently breaks them.
                // SER-695: point somewhere, type nothing, point somewhere else.
                // The second pick must land rather than hit a dead overlay.
                if scene == "repick" {
                    let first = CGPoint(x: size.width * 0.26, y: size.height * 0.27)
                    let second = CGPoint(x: size.width * 0.26, y: size.height * 0.40)
                    pick(at: first, in: window, model: model)
                    print("LOUPE-REPICK after first: \(model.mode)")
                    model.resolveDraftAndResumePicking()
                    pick(at: second, in: window, model: model)
                    if case .commenting(let p) = model.mode {
                        print("LOUPE-REPICK second landed: bounds=\(p.ref.bounds)")
                    } else {
                        print("LOUPE-REPICK second did not land: \(model.mode)")
                    }
                }

                // The bar used to sit top-trailing and swallow every touch on it.
                // Anything under it was unpickable, which is what got reported.
                if scene == "occlusion" {
                    let underTheOldBar = CGPoint(x: size.width * 0.77,
                                                 y: size.height * 0.06)
                    let regions = model.interactiveRegions
                    print("LOUPE-OCCLUSION regions=\(regions)")
                    let blocked = regions.contains { $0.contains(underTheOldBar) }
                    print("LOUPE-OCCLUSION point \(underTheOldBar) blocked=\(blocked)")
                    report(at: underTheOldBar, in: window, label: "under the old bar")
                }

                // SER-697: pick low on the screen, where the keyboard lands on top
                // of Save unless the popover knows the keyboard is there.
                if scene == "lowpick" {
                    let low = CGPoint(x: size.width * 0.26, y: size.height * 0.66)
                    pick(at: low, in: window, model: model)
                    print("LOUPE-LOW picked at \(low) of \(size)")
                }

                // The settings panel, which is how a credential gets in on a device.
                //
                // Deliberately with no notes saved first. It used to save one, which
                // quietly made it the only scene that could reach the panel at all:
                // the gear lived in the tray, the tray only exists once a note has
                // been saved, and so the state a person actually meets on a fresh
                // install was the one state never being tested. See SER-700.
                if scene == "settings" {
                    model.beginAnnotating()
                    model.onSettings?()
                }

                // Annotate mode, nothing picked. What somebody sees a second after
                // installing, and the state the corner controls have to work in.
                if scene == "zero" {
                    model.beginAnnotating()
                }

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
                    // Asked for, because the tray no longer opens itself. That is
                    // the whole of SER-693: saving a note used to change the layout
                    // underneath somebody at the moment they were least expecting it.
                    model.setTrayExpanded(true)
                }

                // The tray opened with nothing in it, which is how somebody reaches
                // Send and the note list on a first run.
                if scene == "emptytray" {
                    model.beginAnnotating()
                    model.setTrayExpanded(true)
                }
            }
        }
    }

    /// The offline queue across a real process boundary, which is the only place it
    /// can honestly be checked. `scene=queue endpoint=dead` leaves three annotations
    /// on disk; kill the app; `scene=drain endpoint=stub` proves they survived and
    /// arrive exactly once.
    private static func runQueue(_ scene: String, in window: UIWindow,
                                 model: OverlayModel) async {
        guard let queue = DemoLaunch.queue else {
            print("LOUPE-QUEUE no queued transport: pass endpoint=dead or endpoint=stub")
            return
        }

        if scene == "queue" {
            model.beginAnnotating()
            let size = window.bounds.size
            for (index, fraction) in [0.27, 0.35, 0.43].enumerated() {
                pick(at: CGPoint(x: size.width * 0.26, y: size.height * fraction),
                     in: window, model: model)
                model.saveComment("offline note \(index + 1)", tag: .bug)
                model.resumePicking()
            }

            // One send is one bundle, whatever it holds, so three notes queue as a
            // single pending file rather than three.
            let notes = model.annotations.count
            do {
                _ = try await Loupe.send()
                print("LOUPE-QUEUE unexpected: the send succeeded against a dead endpoint")
            } catch {
                print("LOUPE-QUEUE queued \(notes) notes while offline, "
                      + "pending=\(queue.pendingCount) bundle(s)")
            }
            return
        }

        print("LOUPE-QUEUE survived the restart, pending=\(queue.pendingCount)")
        do {
            try await queue.drain()
            print("LOUPE-QUEUE drained, pending=\(queue.pendingCount) "
                  + "received=\(DemoLaunch.server?.intakeCount ?? -1)")
        } catch {
            print("LOUPE-QUEUE drain failed: \(error)")
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
