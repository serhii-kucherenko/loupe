import Foundation
import LoupeCore

/// Keeps the local copy and sends to Linear, in that order.
///
/// The order is the point. Writing the folder first means a Linear outage can never
/// cost somebody their note - the bundle is on disk before anything is attempted
/// over a network. Then, if Linear is configured, the same bundle goes there too,
/// and a failure is thrown so `QueuedTransport` keeps it and tries again.
///
/// Both halves are safe to repeat, which is what makes that retry sound: the file
/// write lands on the same path, and `LinearTransport` searches for the annotation
/// before creating anything.
///
/// **Not configured is not a failure.** Someone who has not set up Linear yet is
/// still annotating perfectly well; refusing their send would be inventing a
/// requirement they never asked for.
public struct LinearDelivery: Transport {

    private let local: Transport
    private let settings: LinearSettings
    private let endpoint: URL

    public init(keeping local: Transport,
                settings: LinearSettings = LinearSettings(),
                endpoint: URL = URL(string: "https://api.linear.app/graphql")!) {
        self.local = local
        self.settings = settings
        self.endpoint = endpoint
    }

    public func send(_ bundle: AnnotationBundle) async throws {
        try await local.send(bundle)

        // Read at send time, not at start: the credential is typed into the panel
        // long after `Loupe.start` has run.
        guard let linear = try? settings.transport(endpoint: endpoint) else { return }
        try await linear.send(bundle)
    }
}
