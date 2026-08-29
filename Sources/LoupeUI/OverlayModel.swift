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

    /// Frames of the overlay's own controls, in window coordinates, reported by the
    /// views themselves. Deliberately not `@Published`: the window reads it during
    /// hit-testing, and republishing it would loop with the layout that produces it.
    /// See `InteractiveRegions.swift`.
    public var interactiveRegions: [CGRect] = []
    /// The rectangle being dragged out right now, in window points.
    ///
    /// Published, unlike `interactiveRegions`, because the whole value of the
    /// gesture is watching the rectangle follow your finger. Nothing is captured
    /// until the drag ends.
    @Published public private(set) var dragRegion: Rect?

    /// What is typed into the open comment popover.
    ///
    /// On the model rather than in the popover's own `@State`, because an outside
    /// tap has to be able to decide what to do with it, and a view cannot be asked.
    @Published public var draftComment = ""
    @Published public var draftTag: AnnotationTag?

    /// Whether the full tray is open.
    ///
    /// Collapsed by default and stays collapsed until somebody asks for it - in
    /// `.browsing` too, which is the part that matters. Saving a note used to pop the
    /// whole panel open, and "the sidebar appears only when I add an annotation" was
    /// reported four times. Presence never changes for the whole session now; only
    /// the count on the tab moves.
    @Published public private(set) var trayExpanded = false

    /// Where the drawer's pull sits on the trailing edge, for the rest of the process.
    ///
    /// Someone who moved it off the thing they were trying to annotate should not
    /// have to move it again on the next pick.
    @Published public private(set) var handle = DrawerHandle()

    @Published public private(set) var annotations: [Annotation] = []
    @Published public private(set) var sendState: SendState = .idle

    /// Bundles that failed to send and are waiting on disk, if the transport keeps
    /// a queue. The tray shows this so "3 waiting to send" is never a surprise.
    @Published public private(set) var pendingCount: Int = 0

    private let session: AnnotationSession
    private let queue: QueuedTransport?

    /// A panel the tray can open, supplied by whoever knows what settings mean.
    ///
    /// A closure rather than a type, because `LoupeUI` must not learn what Linear is
    /// - that is the whole point of `LoupeLinear` being a separate product. The tray
    /// shows a settings control only when something has set this.
    @Published public var onSettings: (() -> Void)?

    /// A panel the overlay is currently showing on top of everything else.
    ///
    /// `AnyView` because the overlay deliberately does not know what is in it. The
    /// settings sheet is the only user today, and it comes from a product `LoupeUI`
    /// cannot see.
    @Published public var panel: AnyView?

    public func present(_ view: AnyView) { panel = view }
    public func dismissPanel() { panel = nil }

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
        trayExpanded = false
        set(.picking(hover: nil))
    }

    public func endAnnotating() {
        trayExpanded = false
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

    /// Pointing somewhere else while a comment is open.
    ///
    /// Reported as friction: "when I point at smth I can't then simply point at
    /// another place, I need to manually close the previously clicked unsaved one".
    ///
    /// An empty draft is thrown away, because nothing was said. A draft with words
    /// in it becomes a note first: silently discarding what somebody typed is the
    /// one unacceptable option here, and the tray already has per-note delete for
    /// anyone who did not mean it.
    @discardableResult
    public func resolveDraftAndResumePicking() -> Annotation? {
        guard case .commenting = mode else { return nil }

        guard !draftComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancelComment()
            return nil
        }

        let saved = saveComment(draftComment, tag: draftTag)
        resumePicking()
        return saved
    }

    /// The person is dragging a rectangle out. Feedback only.
    ///
    /// Any mode that takes input, not just `.picking`. A drag begun while a comment
    /// is open re-picks - and it used to draw nothing at all until the finger came
    /// up, so someone was sizing a rectangle blind, on a touch screen, with a hand
    /// over the thing being sized.
    public func drag(to rect: Rect?) {
        guard mode.swallowsInput else { return }
        dragRegion = rect
    }

    /// The person clicked an element. Pins it and opens the popover.
    public func pick(_ ref: ElementRef, screenshotPNG: Data? = nil,
                     contextScreenshotPNG: Data? = nil,
                     screen: String? = nil, viewport: Rect? = nil) {
        guard case .picking = mode else { return }
        draftComment = ""
        draftTag = nil
        set(.commenting(PendingPick(ref: ref, screenshotPNG: screenshotPNG,
                                    contextScreenshotPNG: contextScreenshotPNG,
                                    index: annotations.count + 1,
                                    screen: screen, viewport: viewport)))
    }

    /// Backing out of a comment returns you to picking, not out of annotate mode.
    /// Cancelling one pick is not the same as being finished.
    public func cancelComment() {
        guard case .commenting = mode else { return }
        draftComment = ""
        draftTag = nil
        set(.picking(hover: nil))
    }

    /// Commits the comment and goes straight back to picking.
    ///
    /// **Saving a note is not finishing.** It used to drop to `.browsing`, which is a
    /// state with nothing on screen to say you are in it: the app stopped responding
    /// to picks and the only way to carry on was "Pick another", inside a drawer that
    /// starts shut. So "make annotations" - plural, which is the ordinary case -
    /// meant finding a hidden button between every one of them. That is most of what
    /// "you are a bit confusing in terms of the flow" was about.
    ///
    /// The cost is that the app underneath stays frozen after a save. That is the
    /// honest reading of being in annotate mode, and the way out is now a cross on
    /// the pull that is always on screen - which the old browsing state never had.
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
        draftComment = ""
        draftTag = nil
        set(.picking(hover: nil))
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

    public func toggleTray() { trayExpanded.toggle() }

    public func setTrayExpanded(_ expanded: Bool) { trayExpanded = expanded }

    /// Slides the pull along the edge, out of the way of whatever is under it.
    public func moveHandle(toFraction fraction: Double) { handle.move(to: fraction) }

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
            sendState = .failed(message(for: error), canRetry: canRetry(error))
            // The tray is where the failure is readable and where Try again lives,
            // so a failed send always ends up there, wherever it started from - and
            // *open*, which it was not. `.browsing` behind a shut drawer put the
            // reason somewhere nobody could see, which is the whole failure this
            // project keeps finding in other clothes.
            trayExpanded = true
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
            sendState = .failed(message(for: error), canRetry: canRetry(error))
        }
    }

    public func dismissSendError() {
        if case .failed = sendState { sendState = .idle }
    }

    // MARK: - Private

    private func set(_ new: OverlayMode) {
        guard new != mode else { return }
        // Any change of mode ends a drag. `drag(to:)` never comes through here, so
        // this cannot wipe the rectangle out from under the gesture that owns it.
        dragRegion = nil
        mode = new
        onModeChange?(new)
    }

    /// The person seeing this is a developer looking at their own staging build, so
    /// the real reason is more use to them than a reassuring sentence.
    private func message(for error: Error) -> String {
        if case LoupeError.transportFailed(let why) = error { return why }
        // `localizedDescription` directly, not through an `NSError` bridge. Both work
        // now that `LinearError` conforms to `LocalizedError`, but the bridge is what
        // produced "LinearError error 3" on the first real send, and there is no
        // reason to keep depending on it.
        return error.localizedDescription
    }

    /// Whether "Try again" is honest advice for this failure.
    ///
    /// Anything that does not say is assumed retryable: "send it again" is the right
    /// default for a transport whose errors say nothing about themselves.
    private func canRetry(_ error: Error) -> Bool {
        (error as? RetryableError)?.isWorthRetrying ?? true
    }
}
