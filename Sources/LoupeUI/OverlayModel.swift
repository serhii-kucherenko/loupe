import Foundation
import LoupeCore

#if canImport(SwiftUI)
import SwiftUI
#endif

/// The overlay's whole brain, with no window in it.
///
/// The platform layer feeds it points that have already been resolved to elements,
/// and it decides what mode to be in and what the tray holds. Keeping the window out
/// is what lets the mode machine be tested at all.
@MainActor
public final class OverlayModel: ObservableObject {

    @Published public private(set) var mode: OverlayMode = .off
    @Published public private(set) var annotations: [Annotation] = []
    @Published public private(set) var sendState: SendState = .idle

    /// Bundles that failed to send and are waiting on disk, if the transport keeps
    /// a queue. The tray shows this so "3 waiting to send" is never a surprise.
    @Published public private(set) var pendingCount: Int = 0

    private let session: AnnotationSession
    private let queue: QueuedTransport?

    /// Called when the overlay wants the host to stop or start swallowing input.
    public var onModeChange: ((OverlayMode) -> Void)?

    public init(session: AnnotationSession, queue: QueuedTransport? = nil) {
        self.session = session
        self.queue = queue
        self.annotations = session.annotations
        self.pendingCount = queue?.pendingCount ?? 0
        session.onChange = { [weak self] in
            Task { @MainActor in self?.annotations = self?.session.annotations ?? [] }
        }
    }

    // MARK: - Mode

    public func beginAnnotating() {
        guard mode == .off else { return }
        set(.picking(hover: nil))
    }

    public func endAnnotating() {
        set(.off)
    }

    /// The hotkey. Off starts a session; anything else ends it. One key, one meaning:
    /// "am I annotating right now".
    public func toggleAnnotating() {
        mode == .off ? beginAnnotating() : endAnnotating()
    }

    /// The pointer moved. Only meaningful while picking.
    public func hover(_ ref: ElementRef?) {
        guard case .picking = mode else { return }
        set(.picking(hover: ref))
    }

    /// The person clicked an element. Pins it and opens the popover.
    public func pick(_ ref: ElementRef, screenshotPNG: Data? = nil,
                     contextScreenshotPNG: Data? = nil,
                     screen: String? = nil, viewport: Rect? = nil) {
        guard case .picking = mode else { return }
        set(.commenting(PendingPick(ref: ref, screenshotPNG: screenshotPNG,
                                    contextScreenshotPNG: contextScreenshotPNG,
                                    index: annotations.count + 1,
                                    screen: screen, viewport: viewport)))
    }

    /// Backing out of a comment returns you to picking, not out of annotate mode.
    /// Cancelling one pick is not the same as being finished.
    public func cancelComment() {
        guard case .commenting = mode else { return }
        set(.picking(hover: nil))
    }

    /// Commits the comment and drops to browsing, so the app underneath is usable
    /// again and you can walk to the next screen.
    @discardableResult
    public func saveComment(_ comment: String, tag: AnnotationTag?) -> Annotation? {
        guard case .commenting(let pick) = mode else { return nil }
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let annotation = Annotation(
            comment: trimmed,
            tag: tag,
            element: pick.ref,
            screenshotPNG: pick.screenshotPNG,
            contextScreenshotPNG: pick.contextScreenshotPNG,
            trace: NetworkRecorder.shared.recent(),
            logs: LogRecorder.shared.recent(),
            screen: pick.screen,
            viewport: pick.viewport)

        session.add(annotation)
        annotations = session.annotations
        set(.browsing)
        return annotation
    }

    /// From the compact bar: open the full tray to read or send what is there.
    public func review() {
        guard case .picking = mode else { return }
        set(.browsing)
    }

    /// From the tray: go pick another element.
    public func resumePicking() {
        guard mode == .browsing else { return }
        set(.picking(hover: nil))
    }

    // MARK: - Tray

    public func remove(id: UUID) {
        session.remove(id: id)
        annotations = session.annotations
    }

    public func updateComment(id: UUID, comment: String) {
        session.updateComment(id: id, comment: comment)
        annotations = session.annotations
    }

    public func updateTag(id: UUID, tag: AnnotationTag?) {
        session.updateTag(id: id, tag: tag)
        annotations = session.annotations
    }

    /// Ships the tray.
    ///
    /// A successful send closes the overlay. Send is the end of the job, and an empty
    /// overlay left floating over someone's app is clutter they now have to dismiss.
    public func send() async {
        guard !annotations.isEmpty, sendState != .sending else { return }
        let count = annotations.count
        sendState = .sending
        do {
            try await session.send()
            annotations = session.annotations
            pendingCount = queue?.pendingCount ?? 0
            sendState = .sent(count)
            set(.off)
        } catch {
            pendingCount = queue?.pendingCount ?? 0
            sendState = .failed(message(for: error))
            // The tray is where the failure is readable and where Try again lives,
            // so a failed send always ends up there, wherever it started from.
            set(.browsing)
        }
    }

    /// Retry whatever is stuck on disk.
    public func drainPending() async {
        guard let queue, queue.pendingCount > 0 else { return }
        sendState = .sending
        do {
            try await queue.drain(attempts: 3, initialDelay: 1)
            pendingCount = queue.pendingCount
            sendState = .idle
        } catch {
            pendingCount = queue.pendingCount
            sendState = .failed(message(for: error))
        }
    }

    public func dismissSendError() {
        if case .failed = sendState { sendState = .idle }
    }

    // MARK: - Private

    private func set(_ new: OverlayMode) {
        guard new != mode else { return }
        mode = new
        onModeChange?(new)
    }

    /// The person seeing this is a developer looking at their own staging build, so
    /// the real reason is more use to them than a reassuring sentence.
    private func message(for error: Error) -> String {
        if case LoupeError.transportFailed(let why) = error { return why }
        return (error as NSError).localizedDescription
    }
}
