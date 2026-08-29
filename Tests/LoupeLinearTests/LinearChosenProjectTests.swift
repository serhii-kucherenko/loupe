import XCTest
@testable import LoupeLinear

/// Keeping the project somebody chose.
///
/// "the project that I picked wasn't stored" - and the store turned out to be
/// innocent, so these pin the two places it can be dropped instead of written.
@MainActor
final class LinearChosenProjectTests: XCTestCase {

    private func settings() -> LinearSettings {
        let account = "chosen-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: account)!
        defaults.removePersistentDomain(forName: account)
        return LinearSettings(account: account, defaults: defaults)
    }

    private final class Fake: @unchecked Sendable {
        var projects: [(String, String)] = [("p9", "Reco")]
        var failProjects = false
        var projectCalls = 0
    }

    private func directory(_ fake: Fake) -> (LinearCredential) -> LinearDirectory {
        { credential in
            LinearDirectory(credential: credential,
                            endpoint: URL(string: "https://example.invalid/graphql")!) { request in
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                func ok(_ payload: String) -> (Data, URLResponse) {
                    (Data(payload.utf8),
                     HTTPURLResponse(url: request.url!, statusCode: 200,
                                     httpVersion: nil, headerFields: nil)!)
                }
                if body.contains("viewer") {
                    return ok(#"{"data":{"viewer":{"name":"S"},"organization":{"name":"O"}}}"#)
                }
                if body.contains("projects") {
                    fake.projectCalls += 1
                    if fake.failProjects { throw URLError(.notConnectedToInternet) }
                    let nodes = fake.projects
                        .map { #"{"id":"\#($0.0)","name":"\#($0.1)"}"# }
                        .joined(separator: ",")
                    return ok(#"{"data":{"team":{"projects":{"nodes":[\#(nodes)]}}}}"#)
                }
                return ok(#"{"data":{"teams":{"nodes":[{"id":"t1","name":"Core","key":"C"}]}}}"#)
            }
        }
    }

    private func connected(_ fake: Fake, on store: LinearSettings) async -> LinearSettingsFlow {
        let flow = LinearSettingsFlow(settings: store,
                                      makeDirectory: directory(fake),
                                      store: { _ in })
        await flow.test(key: "lin_api_abc")
        return flow
    }

    /// The whole round trip: choose it, save it, come back to it.
    func testAChosenProjectComesBack() async {
        let store = settings()
        let fake = Fake()

        let first = await connected(fake, on: store)
        first.projectID = "p9"
        XCTAssertTrue(first.save(key: ""))

        let second = LinearSettingsFlow(settings: store,
                                        makeDirectory: directory(fake),
                                        store: { _ in })
        await second.load()

        XCTAssertEqual(second.projectID, "p9", "the chosen project did not come back")
    }

    /// A failed request is not evidence that a project is gone.
    ///
    /// `try?` used to turn a dropped call into an empty list, which is indistinguishable
    /// from "this team has no projects" - and would quietly move where notes go.
    func testADroppedRequestDoesNotThrowAwayTheChosenProject() async {
        let store = settings()
        let fake = Fake()
        store.destination = LinearDestination(teamID: "t1", projectID: "p9")

        let flow = await connected(fake, on: store)
        flow.projectID = "p9"
        fake.failProjects = true

        await flow.loadProjects()

        XCTAssertEqual(flow.projectID, "p9",
                       "a dropped request was read as 'your project no longer exists'")
    }

    /// A project that really is gone must not stay chosen, which is the rule teams
    /// already follow. Leaving it means Save writes a destination Linear will refuse.
    func testAProjectThatNoLongerExistsIsDropped() async {
        let store = settings()
        let fake = Fake()

        let flow = await connected(fake, on: store)
        flow.projectID = "p9"

        fake.projects = [("p10", "Something else")]
        await flow.loadProjects()

        XCTAssertEqual(flow.projectID, "", "a deleted project stayed chosen")
    }
}
