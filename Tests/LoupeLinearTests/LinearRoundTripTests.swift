import XCTest
import Network
import LoupeCore
@testable import LoupeLinear

/// The whole send, over a real socket.
///
/// Every other test here hands `LinearTransport` a `fetch` closure, which proves the
/// mapping and skips `URLSession` entirely - so the headers, the body encoding and
/// the upload PUT have never actually been sent by anything. That is the same gap
/// that made the overlay's controls untappable with a green suite: the parts a test
/// replaces are the parts that break.
///
/// This is as close to the real thing as it can get without a Linear workspace: a
/// local HTTP server that answers `fileUpload` and `issueCreate` the way Linear's API
/// does, and records exactly what arrived. What it cannot prove is that Linear's real
/// API agrees with this stub's idea of itself, which is why one live send by hand is
/// still worth doing once.
final class LinearRoundTripTests: XCTestCase {

    private var linear: FakeLinearServer!

    override func setUp() async throws {
        try await super.setUp()
        linear = try FakeLinearServer()
        try linear.start()
    }

    override func tearDown() async throws {
        linear.stop()
        linear = nil
        try await super.tearDown()
    }

    /// A real `URLSession`, but not `URLSession.shared`.
    ///
    /// The shared session crashes this test process outright - `EXC_BAD_ACCESS` in
    /// `swift_task_dealloc` under `data(for:)`, from inside the concurrency runtime
    /// rather than from anything here. An ephemeral session of our own does the same
    /// job: real sockets, real headers, real body encoding, which is the entire point
    /// of this file. It also keeps these tests off any cache or cookie jar the rest
    /// of the process might be using.
    private static let session = URLSession(configuration: .ephemeral)

    private func transport(_ credential: LinearCredential = .apiKey("lin_api_test"))
        -> LinearTransport {
        LinearTransport(credential: credential,
                        destination: LinearDestination(teamID: "team-1", projectID: "proj-1"),
                        endpoint: linear.graphQL,
                        fetch: { try await Self.session.data(for: $0) })
    }

    private func bundle(_ comments: [String], withImages: Bool = true) -> AnnotationBundle {
        let png = Data("not really a png, but bytes are bytes".utf8)
        return AnnotationBundle(
            sessionID: UUID(),
            app: AppInfo(name: "Demo", version: "1.0", platform: "iOS"),
            annotations: comments.map {
                Annotation(comment: $0,
                           tag: .bug,
                           element: ElementRef(accessibilityID: "row",
                                               bounds: Rect(x: 0, y: 0, width: 10, height: 10)),
                           screenshotPNG: withImages ? png : nil,
                           contextScreenshotPNG: withImages ? png : nil)
            })
    }

    // MARK: - It actually goes over the wire

    func testANoteBecomesAnIssueThroughARealRequest() async throws {
        try await transport().send(bundle(["the stock count is unreadable"]))

        XCTAssertEqual(linear.created.count, 1)
        let issue = try XCTUnwrap(linear.created.first)
        XCTAssertEqual(issue["teamId"] as? String, "team-1")
        XCTAssertEqual(issue["projectId"] as? String, "proj-1")
        XCTAssertEqual(issue["title"] as? String, "the stock count is unreadable")
    }

    /// The tag is the only field the person chose by hand, and `labelIds` is an
    /// array of ids inside the mutation input - the one shape a `fetch` stub cannot
    /// prove arrived intact.
    func testTheTagArrivesAsALabelIdThroughARealRequest() async throws {
        linear.labels = [["id": "label-bug", "name": "Bug"]]

        try await transport().send(bundle(["the stock count is unreadable"]))

        let issue = try XCTUnwrap(linear.created.first)
        XCTAssertEqual(issue["labelIds"] as? [String], ["label-bug"])
    }

    /// The header form is the difference between a request that works and a 401, and
    /// until now nothing had ever put it on an actual socket.
    func testAPersonalKeyArrivesBareAndATokenArrivesAsABearer() async throws {
        try await transport(.apiKey("lin_api_test")).send(bundle(["a"], withImages: false))
        XCTAssertEqual(linear.authorizations.first, "lin_api_test")

        linear.reset()
        try await transport(.accessToken("oauth-abc")).send(bundle(["b"], withImages: false))
        XCTAssertEqual(linear.authorizations.first, "Bearer oauth-abc")
    }

    /// Both pictures, uploaded by PUT to the URL the mutation handed back, carrying
    /// every header it handed back with it. Linear rejects the upload otherwise, and
    /// an injected `fetch` could never have checked it.
    func testBothImagesArePutWithTheHeadersLinearAskedFor() async throws {
        try await transport().send(bundle(["look at this"]))

        XCTAssertEqual(linear.uploads.count, 2, "the crop and the context shot")
        for upload in linear.uploads {
            XCTAssertEqual(upload.method, "PUT")
            XCTAssertEqual(upload.headers["x-linear-test"], "echoed",
                           "the headers from fileUpload must be sent back")
            XCTAssertEqual(upload.headers["Content-Type"], "image/png")
            XCTAssertFalse(upload.body.isEmpty, "the bytes have to arrive")
        }

        let description = try XCTUnwrap(linear.created.first?["description"] as? String)
        for asset in linear.assetURLs {
            XCTAssertTrue(description.contains(asset),
                          "every uploaded image should be referenced in the body")
        }
    }

    /// `QueuedTransport` retries whole bundles, so a send that half-succeeded must not
    /// file everything twice. The marker search is what prevents it, and this is the
    /// first test to make that round trip for real.
    func testSendingTheSameBundleTwiceFilesOneIssue() async throws {
        let once = bundle(["said only once"])
        try await transport().send(once)
        try await transport().send(once)

        XCTAssertEqual(linear.created.count, 1, "a repeat send must be a no-op")
        XCTAssertGreaterThanOrEqual(linear.searches, 2, "and it must ask before creating")
    }

    func testTwoNotesInOneBundleBecomeTwoIssues() async throws {
        try await transport().send(bundle(["first thing", "second thing"], withImages: false))

        XCTAssertEqual(linear.created.count, 2)
        XCTAssertEqual(Set(linear.created.compactMap { $0["title"] as? String }),
                       ["first thing", "second thing"])
    }

    /// A real 401 from a real socket, rather than a stubbed one.
    func testARejectedKeyComesBackAsSomethingReadable() async {
        linear.rejectEverything = true
        do {
            try await transport().send(bundle(["never lands"], withImages: false))
            XCTFail("a 401 must not look like success")
        } catch let error as LinearError {
            XCTAssertEqual(error, .credentialRejected)
            XCTAssertFalse(error.isWorthRetrying)
        } catch {
            XCTFail("expected a LinearError, got \(error)")
        }
    }

    /// The local copy is kept whatever Linear does, which is the promise
    /// `LinearDelivery` makes: a failed send must never lose the note.
    func testTheLocalCopySurvivesALinearFailure() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("loupe-roundtrip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        linear.rejectEverything = true

        // A configured store, so delivery genuinely tries Linear rather than skipping
        // it as unconfigured - which would prove nothing.
        let account = "roundtrip-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: account)!
        defer { defaults.removePersistentDomain(forName: account) }
        let store = LinearSettings(account: account, defaults: defaults)
        do {
            try store.save(.apiKey("lin_api_test"))
        } catch LinearError.couldNotStore(let status) {
            throw XCTSkip("the Keychain refused the write (OSStatus \(status))")
        }
        store.destination = LinearDestination(teamID: "team-1", projectID: nil)

        let delivery = LinearDelivery(keeping: FileTransport(directory: directory),
                                      settings: store,
                                      endpoint: linear.graphQL)

        do {
            try await delivery.send(bundle(["kept anyway"], withImages: false))
            XCTFail("Linear rejected everything, so this should have thrown")
        } catch {
            // Expected. The point is what is on disk afterwards.
        }

        let written = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(written.isEmpty, "the note must survive a failed send")
    }
}
