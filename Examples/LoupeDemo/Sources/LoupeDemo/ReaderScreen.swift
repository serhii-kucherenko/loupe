#if canImport(UIKit)
import SwiftUI
import WebKit
import LoupeCore
import LoupeUI

/// A screen whose content this process cannot draw.
///
/// The demo had nothing like it, and that is why the wrong-screen bug reached
/// somebody's iPad before anything caught it: a `WKWebView` renders in a separate
/// process and hands the result to the compositor, so `drawHierarchy` returns
/// whatever *we* last drew - the screen you came from. Reco's reader is exactly this
/// shape, and so is any host with a web view, a map, or a video layer.
///
/// A flat red page rather than real prose, because what is being checked is which
/// pixels come back, and one colour answers that with no ambiguity.
struct ReaderScreen: View {
    var body: some View {
        VStack(spacing: 0) {
            WebPage()
                .accessibilityIdentifier("reader.page")
            CaptureReadout()
        }
    }
}

private struct WebPage: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.isOpaque = true
        web.loadHTMLString(
            "<html><body style='margin:0;background:#ff0000'></body></html>",
            baseURL: nil)
        CaptureReadout.web = web
        return web
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}

/// What Loupe's capture actually got, in words, so a UI test can read it.
///
/// XCUITest cannot look at a PNG. It can read a label, so the app does the capture
/// for real and says what colour came back. That keeps the assertion on the pixels
/// rather than on something standing in for them.
private struct CaptureReadout: View {
    @MainActor static weak var web: WKWebView?
    @State private var result = "not captured"

    var body: some View {
        Text(result)
            .font(.caption)
            .accessibilityIdentifier("reader.capture")
            .padding(8)
            .task {
                guard CommandLine.arguments.contains("--capture-readout") else { return }
                guard let web = Self.web else { return }

                // Let the red page paint and let the host composite it.
                try? await Task.sleep(nanoseconds: 2_000_000_000)

                // Then change the page and capture straight away. This is meant to be
                // the reported case in miniature: WebKit has repainted in its own
                // process and nothing has composited it into ours yet.
                //
                // **It does not reproduce the bug, and the readout is here to show
                // that rather than to hide it.** On this simulator all three routes
                // return the *old* colour while JavaScript reports the new one - so
                // `takeSnapshot` is no fresher than `drawHierarchy` here, and this
                // screen cannot yet tell a fixed capture from a broken one. Whatever
                // Readium does differently is what SER-718 is actually about.
                var said = "?"
                do {
                    let answer = try await web.evaluateJavaScript("""
                    (function () {
                      document.body.style.background = '#00ff00';
                      return getComputedStyle(document.body).backgroundColor;
                    })()
                    """)
                    said = "\(answer ?? "nil")"
                } catch {
                    // Reported, not swallowed. An assignment evaluates to `undefined`,
                    // which WebKit refuses to bridge, so the call throws even when the
                    // script ran - and a `try?` here hid whether the page had changed
                    // at all, which is the one thing this readout exists to say.
                    said = "threw: \(error.localizedDescription)"
                }
                try? await Task.sleep(nanoseconds: 600_000_000)

                // Both routes side by side, so which one is stale is a reading rather
                // than a guess.
                let hierarchy = UIGraphicsImageRenderer(bounds: web.bounds).image { _ in
                    web.drawHierarchy(in: web.bounds, afterScreenUpdates: true)
                }.pngData()

                let configuration = WKSnapshotConfiguration()
                configuration.rect = web.bounds
                configuration.afterScreenUpdates = true
                let snapshot: Data? = await withCheckedContinuation { continuation in
                    web.takeSnapshot(with: configuration) { image, _ in
                        continuation.resume(returning: image?.pngData())
                    }
                }

                let png = await ElementPicker.screenshotPNG(of: web)
                result = "crop \(Self.middle(of: png))"
                    + " | hierarchy \(Self.middle(of: hierarchy))"
                    + " | snapshot \(Self.middle(of: snapshot))"
                    + " | js \(said)"
            }
    }

    /// The colour in the middle of the picture, as `r,g,b`.
    ///
    /// The buffer is allocated rather than borrowed from an array: a `CGContext` over
    /// `withUnsafeMutableBytes`'s pointer outlives the closure that owns it, and what
    /// comes back is whatever the allocator has done since.
    static func middle(of png: Data?) -> String {
        guard let png, let whole = UIImage(data: png)?.cgImage,
              whole.width > 1, whole.height > 1,
              let middle = whole.cropping(to: CGRect(
                x: whole.width / 2, y: whole.height / 2, width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return "nothing" }

        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        defer { bytes.deallocate() }
        bytes.initialize(repeating: 0, count: 4)
        guard let context = CGContext(
            data: bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return "nothing" }
        context.draw(middle, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return "\(bytes[0]),\(bytes[1]),\(bytes[2])"
    }
}
#endif
