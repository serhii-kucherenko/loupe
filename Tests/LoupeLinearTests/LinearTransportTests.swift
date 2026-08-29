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
    /// The workspace's labels, as `issueLabels` nodes.
    var labels: [[String: Any]] = []
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
        } else if query.contains("issueLabels") {
            json = ["data": ["issueLabels": ["nodes": labels]]]
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
            // Named. A send is three calls with three different permission needs,
            // and "Team not found" alone cannot be narrowed without another attempt.
            XCTAssertEqual(error as? LinearError,
                           .api("the duplicate check: Team not found"))
        }
    }

    // MARK: - The body is the answer

    /// "Linear returned 400" is true and useless. Linear says which field or which
    /// argument it did not like, and that sentence was being thrown away - so the
    /// only information about a real failure never left the transport.
    func testARejectedRequestCarriesWhatTheServerActuallySaid() async {
        let said = """
        {"errors":[{"message":"Argument Validation Error","extensions":{"field":"size"}}]}
        """
        let transport = LinearTransport(
            credential: .apiKey("k"),
            destination: LinearDestination(teamID: "TEAM"),
            fetch: { request in
                (Data(said.utf8),
                 HTTPURLResponse(url: request.url!, statusCode: 400,
                                 httpVersion: nil, headerFields: nil)!)
            })

        do {
            try await transport.send(bundle(["a note"]))
            XCTFail("expected the send to throw")
        } catch {
            let message = (error as? LinearError)?.localizedDescription ?? "\(error)"
            XCTAssertTrue(message.contains("Argument Validation Error"),
                          "the server's own words are the whole point: \(message)")
            XCTAssertTrue(message.contains("400"), message)
            XCTAssertTrue(message.contains("the duplicate check"),
                          "and which of the three calls it was: \(message)")
        }
    }

    /// `perform` is shared with the image PUT, which goes to a signed storage URL and
    /// not to Linear at all. Blaming Linear for it sends somebody to check the wrong
    /// thing - a broken signature and a bad mutation have nothing in common.
    func testAFailureFromTheUploadHostIsNotBlamedOnLinear() {
        let request = URLRequest(url: URL(string: "https://uploads.example.com/signed")!)
        let message = LinearError.fromHTTP(
            status: 403,
            body: Data("<Error><Code>SignatureDoesNotMatch</Code></Error>".utf8),
            request: request).description

        XCTAssertTrue(message.contains("uploads.example.com"), message)
        XCTAssertFalse(message.contains("Linear"), message)
        XCTAssertTrue(message.contains("SignatureDoesNotMatch"), message)
    }

    func testAFailureFromLinearIsNamedAsLinear() {
        let request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        let message = LinearError.fromHTTP(status: 400,
                                              body: Data("no such team".utf8),
                                              request: request).description
        XCTAssertEqual(message, "Linear returned 400: no such team")
    }

    /// Some servers answer an error with a whole HTML page. The message is read on a
    /// phone, inside a row in the tray.
    func testAVeryLongAnswerIsCutRatherThanDumped() {
        let request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        let message = LinearError.fromHTTP(status: 500,
                                              body: Data(String(repeating: "x", count: 5000).utf8),
                                              request: request).description
        XCTAssertLessThan(message.count, 500)
        XCTAssertTrue(message.hasSuffix("\u{2026}"), "and it must say it was cut")
    }

    /// An empty body is a real answer too, and it has to read as a sentence rather
    /// than trail off after a colon.
    func testAnEmptyAnswerStillReadsLikeASentence() {
        let request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        let message = LinearError.fromHTTP(status: 502, body: Data(), request: request).description
        XCTAssertEqual(message, "Linear returned 502 and said nothing.")
    }

    /// The failure that actually happened, on Serhii's iPad, on the first real send:
    /// HTTP 400 carrying `Invalid scope: 'write' required` and an inner
    /// `"statusCode": 403`. The refusal was in plain English in the body and the
    /// status code disagreed with it, so reading only the status printed a scope
    /// problem as an unexplained 400 and cost a whole round trip.
    func testAScopeRefusalIsRecognisedEvenWhenTheStatusSaysOtherwise() async {
        let said = """
        {"errors":[{"message":"Invalid scope: 'write' required","extensions":        {"type":"forbidden","code":"FORBIDDEN","statusCode":403,"userError":true}}]}
        """
        let transport = LinearTransport(
            credential: .accessToken("oauth-token"),
            destination: LinearDestination(teamID: "TEAM"),
            fetch: { request in
                (Data(said.utf8),
                 HTTPURLResponse(url: request.url!, statusCode: 400,
                                 httpVersion: nil, headerFields: nil)!)
            })

        do {
            try await transport.send(bundle(["never landed"]))
            XCTFail("expected the send to throw")
        } catch let error as LinearError {
            guard case .credentialTooNarrow = error else {
                return XCTFail("a scope refusal must read as one, not as a bare 400: \(error)")
            }
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("sign in again"),
                          "and it must say what would fix it: \(message)")
            XCTAssertTrue(message.contains("Invalid scope"), message)
            XCTAssertTrue(message.contains("the duplicate check"),
                          "which call was refused is the next question: \(message)")
            XCTAssertFalse(error.isWorthRetrying, "the same scope will be just as narrow")
        } catch {
            XCTFail("expected a LinearError, got \(error)")
        }
    }
}

// MARK: - The tag somebody picked has to reach the issue

extension LinearTransportTests {

    private func label(_ name: String, id: String, team: String? = nil) -> [String: Any] {
        var node: [String: Any] = ["id": id, "name": name]
        if let team { node["team"] = ["id": team] }
        return node
    }

    private func created(_ linear: FakeLinear) -> [String: Any]? {
        let create = linear.requests.first {
            ($0.body["query"] as? String)?.contains("issueCreate") == true
        }
        return (create?.body["variables"] as? [String: Any])?["input"] as? [String: Any]
    }

    /// `bundle` tags everything `.bug`, and the workspace's own label is `Bug`.
    /// That capital B is the whole reason this test exists: it is what a real
    /// workspace looks like, and an exact-match lookup drops the tag against it.
    func testATaggedNoteArrivesWithTheMatchingLabel() async throws {
        let linear = FakeLinear()
        linear.labels = [label("Bug", id: "label-bug")]

        try await transport(linear).send(bundle(["the row is cut off"]))

        XCTAssertEqual(created(linear)?["labelIds"] as? [String], ["label-bug"],
                       "the tag is the one thing the person actually chose")
    }

    func testATagWithNoMatchingLabelIsSaidOnTheIssueRatherThanDropped() async throws {
        let linear = FakeLinear()
        linear.labels = [label("Improvement", id: "label-improvement")]

        try await transport(linear).send(bundle(["the row is cut off"]))

        let input = created(linear)
        XCTAssertNil(input?["labelIds"], "never invent a label in somebody's workspace")
        let description = input?["description"] as? String ?? ""
        XCTAssertTrue(description.contains("Tagged **bug**"),
                      "the choice still has to arrive: \(description)")
    }

    /// A round trip nobody needs is a round trip that can fail.
    func testAnUntaggedBundleNeverAsksForLabels() async throws {
        let linear = FakeLinear()
        var untagged = bundle(["no tag on this one"])
        untagged.annotations[0].tag = nil

        try await transport(linear).send(untagged)

        let lookups = linear.requests.filter {
            ($0.body["query"] as? String)?.contains("issueLabels") == true
        }
        XCTAssertTrue(lookups.isEmpty)
    }

    func testTheLabelsAreReadOnceForTheWholeBundle() async throws {
        let linear = FakeLinear()
        linear.labels = [label("Bug", id: "label-bug")]

        try await transport(linear).send(bundle(["first", "second", "third"]))

        let lookups = linear.requests.filter {
            ($0.body["query"] as? String)?.contains("issueLabels") == true
        }
        XCTAssertEqual(lookups.count, 1)
    }

    // MARK: - The matching rule itself, which is pure

    func testATeamsOwnLabelBeatsAWorkspaceOneOfTheSameName() {
        let labels = [
            LinearLabel(id: "workspace", name: "bug", teamID: nil),
            LinearLabel(id: "ours", name: "bug", teamID: "TEAM"),
        ]
        XCTAssertEqual(LinearLabel.id(for: .bug, in: labels, teamID: "TEAM"), "ours")
    }

    func testAWorkspaceLabelIsUsedWhenTheTeamHasNoneOfItsOwn() {
        let labels = [LinearLabel(id: "workspace", name: "Bug", teamID: nil)]
        XCTAssertEqual(LinearLabel.id(for: .bug, in: labels, teamID: "TEAM"), "workspace")
    }

    /// Another team's label is not Loupe's to use, and Linear refuses it anyway.
    func testAnotherTeamsLabelIsNeverUsed() {
        let labels = [LinearLabel(id: "theirs", name: "bug", teamID: "OTHER")]
        XCTAssertNil(LinearLabel.id(for: .bug, in: labels, teamID: "TEAM"))
    }
}
