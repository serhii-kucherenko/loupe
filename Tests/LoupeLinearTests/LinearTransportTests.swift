import XCTest
import LoupeCore
@testable import LoupeLinear

/// A Linear that answers from a script, so the whole path can be exercised without a
/// network and without anyone's real workspace.
private final class FakeLinear: @unchecked Sendable {
    /// Every request that was made, in order. The assertions that matter are about
    /// what was *not* sent as much as what was.
    var requests: [(url: URL, body: [String: Any])] = []
    var existingIssueIDs: [String] = []
    var status = 200
    var responseHeaders: [String: String] = [:]

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let body: [String: Any] = request.httpBody
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            .flatMap { $0 as? [String: Any] } ?? [:]
        requests.append((request.url!, body))

        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: responseHeaders)!
        guard status == 200 else { return (Data(), response) }

        // The PUT of the image itself carries no JSON.
        guard request.url?.host == "api.linear.app" else { return (Data(), response) }

        let query = (body["query"] as? String) ?? ""
        let json: [String: Any]
        if query.contains("issues(filter") {
            json = ["data": ["issues": ["nodes": existingIssueIDs.map { ["id": $0] }]]]
        } else if query.contains("fileUpload") {
            json = ["data": ["fileUpload": ["success": true, "uploadFile": [
                "uploadUrl": "https://uploads.example.com/signed",
                "assetUrl": "https://uploads.linear.app/asset.png",
                "headers": [["key": "x-amz-acl", "value": "private"]],
            ]]]]
        } else {
            json = ["data": ["issueCreate": ["success": true,
                                             "issue": ["id": "1", "identifier": "SER-1",
                                                       "url": "https://linear.app/i/SER-1"]]]]
        }
        return (try JSONSerialization.data(withJSONObject: json), response)
    }
}

private func bundle(_ comments: [String], id: UUID = UUID()) -> AnnotationBundle {
    AnnotationBundle(
        sessionID: id,
        app: AppInfo(name: "Demo", version: "1.2.0", commitSHA: "abc1234",
                     platform: "iOS", environment: "staging"),
        annotations: comments.map {
            var annotation = Annotation(
                comment: $0, tag: .bug,
                element: ElementRef(accessibilityID: "search.results",
                                    bounds: Rect(x: 1, y: 2, width: 3, height: 4)))
            annotation.screenshotPNG = Data([0x89, 0x50])
            annotation.contextScreenshotPNG = Data([0x89, 0x50, 0x4E])
            return annotation
        },
        sentAt: Date())
}

/// A captured `var` cannot cross into a `@Sendable` closure in Swift 6 mode, and the
/// Swift 6 CI job compiles these tests.
private final class Box: @unchecked Sendable {
    private(set) var value: String?
    func first(_ candidate: String?) { if value == nil { value = candidate } }
}

final class LinearTransportTests: XCTestCase {

    private func transport(_ linear: FakeLinear) -> LinearTransport {
        LinearTransport(credential: .apiKey("lin_api_test"),
                        destination: LinearDestination(teamID: "TEAM"),
                        fetch: { try await linear.fetch($0) })
    }

    func testEachNoteBecomesItsOwnIssue() async throws {
        let linear = FakeLinear()

        try await transport(linear).send(bundle(["first thing", "second thing"]))

        let created = linear.requests.filter {
            ($0.body["query"] as? String)?.contains("issueCreate") == true
        }
        XCTAssertEqual(created.count, 2, "a bundle is a session of unrelated notes")
    }

    // QueuedTransport retries whole bundles, so this is what stands between a lost
    // network and a workspace full of duplicates.
    func testANoteThatAlreadyHasAnIssueIsNotCreatedAgain() async throws {
        let linear = FakeLinear()
        linear.existingIssueIDs = ["already-there"]

        try await transport(linear).send(bundle(["first thing"]))

        let created = linear.requests.filter {
            ($0.body["query"] as? String)?.contains("issueCreate") == true
        }
        XCTAssertTrue(created.isEmpty, "a retry must be a no-op, not a second issue")
    }

    func testTheImagesGoUpAndTheirURLsLandInTheBody() async throws {
        let linear = FakeLinear()

        try await transport(linear).send(bundle(["a note"]))

        let puts = linear.requests.filter { $0.url.host == "uploads.example.com" }
        XCTAssertEqual(puts.count, 2, "the crop and the context shot")

        let create = linear.requests.first {
            ($0.body["query"] as? String)?.contains("issueCreate") == true
        }
        let input = (create?.body["variables"] as? [String: Any])?["input"] as? [String: Any]
        let description = input?["description"] as? String ?? ""
        XCTAssertTrue(description.contains("https://uploads.linear.app/asset.png"))
    }

    func testTheKeyIsSentTheWayLinearWantsItRatherThanAsBearer() async throws {
        let seen = Box()
        let linear = FakeLinear()
        let transport = LinearTransport(
            credential: .apiKey("lin_api_test"),
            destination: LinearDestination(teamID: "TEAM"),
            fetch: { request in
                seen.first(request.value(forHTTPHeaderField: "Authorization"))
                return try await linear.fetch(request)
            })

        try await transport.send(bundle(["a note"]))

        XCTAssertEqual(seen.value, "lin_api_test", "a personal key is not a Bearer token")
    }

    func testAnOAuthTokenIsSentAsBearer() {
        XCTAssertEqual(LinearCredential.accessToken("abc").headerValue, "Bearer abc")
    }

    // MARK: - Failures, which have to be told apart

    private func failure(status: Int, headers: [String: String] = [:]) async -> Error? {
        let linear = FakeLinear()
        linear.status = status
        linear.responseHeaders = headers
        do {
            try await transport(linear).send(bundle(["a note"]))
            return nil
        } catch {
            return error
        }
    }

    func testARejectedCredentialSaysSo() async {
        let error = await failure(status: 401)
        XCTAssertEqual(error as? LinearError, .credentialRejected)
        XCTAssertFalse((error as? LinearError)?.isWorthRetrying ?? true,
                       "a rejected key will be rejected again")
    }

    func testNoPermissionNamesTheTeam() async {
        let error = await failure(status: 403)
        XCTAssertEqual(error as? LinearError, .notPermitted("team TEAM"))
    }

    func testRateLimitingIsWorthRetryingAndCarriesTheDelay() async {
        let error = await failure(status: 429, headers: ["Retry-After": "30"])
        XCTAssertEqual(error as? LinearError, .rateLimited(retryAfter: 30))
        XCTAssertTrue((error as? LinearError)?.isWorthRetrying ?? false)
    }

    // A GraphQL error arrives with HTTP 200, so the status code proves nothing.
    func testAGraphQLErrorIsNotMistakenForSuccess() async {
        let transport = LinearTransport(
            credential: .apiKey("k"),
            destination: LinearDestination(teamID: "TEAM"),
            fetch: { request in
                let body = ["errors": [["message": "Team not found"]]]
                return (try JSONSerialization.data(withJSONObject: body),
                        HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!)
            })

        do {
            try await transport.send(bundle(["a note"]))
            XCTFail("expected the send to throw")
        } catch {
            XCTAssertEqual(error as? LinearError, .api("Team not found"))
        }
    }
}
