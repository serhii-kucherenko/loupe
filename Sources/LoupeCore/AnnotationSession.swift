import Foundation

/// The tray. You enter annotate mode once, then pick and comment as many times as
/// you like; each annotation lands here. The tray survives navigation on purpose,
/// so one session can span several screens. `send` ships the whole batch at once.
///
/// Give it `persistingTo:` and it also survives the app being killed. Every change
/// is written straight through to that file, because the realistic loss is not a
/// failed send: it is someone annotating on a phone, switching apps, and the system
/// reclaiming the process before they ever pressed Send.
/// Main-actor isolated on purpose. A tray is filled by someone clicking and read by
/// the panel showing it, so main-actor is the truthful model rather than a
/// concession to the compiler - and stating it is what lets `send` await a transport
/// without the session itself crossing an isolation boundary.
@MainActor
public final class AnnotationSession {
    public private(set) var id = UUID()
    public private(set) var annotations: [Annotation] = []

    private let app: AppInfo
    private let transport: Transport
    private let file: URL?

    /// Called after every change so a UI can redraw the tray.
    public var onChange: (() -> Void)?

    public init(app: AppInfo, transport: Transport, persistingTo file: URL? = nil) {
        self.app = app
        self.transport = transport
        self.file = file
        restore()
    }

    public var isEmpty: Bool { annotations.isEmpty }
    public var count: Int { annotations.count }

    public func add(_ annotation: Annotation) {
        annotations.append(annotation)
        changed()
    }

    public func remove(id: UUID) {
        annotations.removeAll { $0.id == id }
        changed()
    }

    /// Edit a comment after the fact, without losing the captured context.
    public func updateComment(id: UUID, comment: String) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[i].comment = comment
        changed()
    }

    /// Change the tag after the fact, same reasoning as `updateComment`.
    public func updateTag(id: UUID, tag: AnnotationTag?) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[i].tag = tag
        changed()
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
        changed()
        return bundle
    }

    // MARK: - Disk

    private func changed() {
        save()
        onChange?()
    }

    /// One file, rewritten whole. A tray is a handful of annotations, so an
    /// append log would be machinery with nothing to buy.
    private func save() {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let saved = SavedTray(sessionID: id, annotations: annotations)
            try encoder.encode(saved).write(to: file)
        } catch {
            // Losing the backup must never take the live tray with it.
            LogRecorder.shared.error("could not save the tray: \(error)", subsystem: "loupe")
        }
    }

    private func restore() {
        // No file at all is the ordinary case: a first run, or a tray already sent.
        guard let file, let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A file that exists and will not decode is a different thing entirely, and
        // it is somebody's unsent notes. Left where it is rather than overwritten, so
        // whatever is in it can still be recovered by hand; the alternative is losing
        // it quietly on the next save.
        guard let saved = try? decoder.decode(SavedTray.self, from: data) else {
            assertionFailure("Loupe could not read the saved tray at \(file.path). "
                             + "It has been left alone; the notes in it are not lost.")
            return
        }
        id = saved.sessionID
        annotations = saved.annotations
    }
}

/// What is written to disk between launches. Deliberately not `AnnotationBundle`:
/// a bundle is a thing that was sent, and this is a thing that has not been.
private struct SavedTray: Codable {
    var sessionID: UUID
    var annotations: [Annotation]
}

public enum LoupeError: Error, Equatable {
    case emptySession
    case transportFailed(String)
}
