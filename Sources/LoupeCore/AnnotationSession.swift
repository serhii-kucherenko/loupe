import Foundation

/// The tray. You enter annotate mode once, then pick and comment as many times as
/// you like; each annotation lands here. The tray survives navigation on purpose,
/// so one session can span several screens. `send` ships the whole batch at once.
public final class AnnotationSession {
    public private(set) var id = UUID()
    public private(set) var annotations: [Annotation] = []

    private let app: AppInfo
    private let transport: Transport

    /// Called after every change so a UI can redraw the tray.
    public var onChange: (() -> Void)?

    public init(app: AppInfo, transport: Transport) {
        self.app = app
        self.transport = transport
    }

    public var isEmpty: Bool { annotations.isEmpty }
    public var count: Int { annotations.count }

    public func add(_ annotation: Annotation) {
        annotations.append(annotation)
        onChange?()
    }

    public func remove(id: UUID) {
        annotations.removeAll { $0.id == id }
        onChange?()
    }

    /// Edit a comment after the fact, without losing the captured context.
    public func updateComment(id: UUID, comment: String) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[i].comment = comment
        onChange?()
    }

    public func makeBundle() -> AnnotationBundle {
        AnnotationBundle(sessionID: id, app: app, annotations: annotations)
    }

    /// Ship the tray to triage, then start a fresh session.
    /// The tray is only cleared once the transport confirms.
    @discardableResult
    public func send() async throws -> AnnotationBundle {
        guard !annotations.isEmpty else { throw LoupeError.emptySession }
        let bundle = makeBundle()
        try await transport.send(bundle)
        annotations.removeAll()
        id = UUID()
        onChange?()
        return bundle
    }
}

public enum LoupeError: Error, Equatable {
    case emptySession
    case transportFailed(String)
}
