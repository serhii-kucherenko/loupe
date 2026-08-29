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
    @State private var isOpen = false

    var body: some View {
        VStack(spacing: 0) {
            Button("Open the book") { isOpen = true }
                .padding(24)
            WebPage()
                .accessibilityIdentifier("reader.page")
            CaptureReadout()
        }
        // **Presented, not pushed.** This is the shape that broke: a view controller
        // presented over the root is not inside the root's view, so a capture that
        // drew `rootViewController.view` drew the screen underneath. Somebody
        // annotated a page in a book and got a picture of their library.
        .fullScreenCover(isPresented: $isOpen) {
            OpenBook(close: { isOpen = false })
        }
    }
}

/// The page somebody is actually looking at when they annotate.
private struct OpenBook: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Close the book", action: close)
                Spacer()
                Text("Chapter one").accessibilityIdentifier("book.chapter")
            }
            .padding(16)

            // Flat and unmistakable: if the capture shows anything else, it is not
            // this screen.
            Color(red: 0, green: 0, blue: 1)
                .accessibilityIdentifier("book.page")

            WindowFinderProbe()
                .frame(width: 0, height: 0)
            CaptureReadout(label: "book")
        }
    }
}

/// Hands the readout the window it is actually inside.
private struct WindowFinderProbe: UIViewRepresentable {
    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            CaptureReadout.hostWindow = window
        }
    }

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {}
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
    var label = "reader"
    @MainActor static weak var web: WKWebView?
    @MainActor static weak var hostWindow: UIWindow?
    @State private var result = "not captured"

    var body: some View {
        Text(result)
            .font(.caption)
            .accessibilityIdentifier("\(label).capture")
            .padding(8)
            .task {
                guard CommandLine.arguments.contains("--capture-readout") else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                result = label == "book" ? await Self.fromTheWindow() : await Self.fromTheWeb()
            }
    }

    /// The context shot, which is meant to be the whole window - and used to be the
    /// root view controller's view, which does not contain anything presented over
    /// it. This is the reported bug: capture inside a presented screen and get the
    /// screen underneath.
    @MainActor
    static func fromTheWindow() async -> String {
        guard let window = hostWindow else { return "no window" }
        let box = CGRect(x: window.bounds.midX - 40, y: window.bounds.midY - 40,
                         width: 80, height: 80)
        let png = await ElementPicker.contextPNG(ofRegion: box, in: window)
        return "context \(middle(of: png))"
    }

    @MainActor
    static func fromTheWeb() async -> String {
        guard let web = web else { return "no web view" }
        let png = await ElementPicker.screenshotPNG(of: web)
        return "crop \(middle(of: png))"
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
