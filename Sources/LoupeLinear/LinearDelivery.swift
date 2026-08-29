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
/// **A send that did not reach Linear never reports success.** It used to. The whole
/// thing hung on one `try?`:
///
/// ```swift
/// guard let linear = try? settings.transport(endpoint: endpoint) else { return }
/// ```
///
/// `transport()` throws more than one thing, and that could not tell them apart - so
/// a missing team, a broken destination, anything at all became `return`. And
/// `return` is *success*: the local write had already happened, so nothing threw, the
/// queue dropped the bundle and the tray said "Sent 2". Two notes were reported as
/// delivered on a real iPad and neither existed in Linear.
///
/// Taking the product means meaning to deliver. `LoupeLinear` is opt-in - a host that
/// only wants capture never compiles a line of it - so a host that *did* take it and
/// has not finished setting it up is misconfigured, not exempt. The note is safe on
/// disk either way, the message says what to do, and `.notConfigured` is not worth
/// retrying so the tray does not offer a button that cannot work.
///
/// Annotating still works from the first launch. Only Send says so.
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
        // long after `Loupe.start` has run. Anything it throws is thrown on - a
        // credential that is missing, a team that was never chosen, all of it. The
        // local copy is already down, so nothing is lost by saying so.
        let linear = try settings.transport(endpoint: endpoint)
        try await linear.send(bundle)
    }
}
