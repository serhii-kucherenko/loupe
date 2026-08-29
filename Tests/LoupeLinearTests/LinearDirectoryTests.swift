import XCTest
@testable import LoupeLinear

/// A Linear that answers project queries from a script, and remembers exactly what
/// was asked of it.
///
/// It reads the *encoded body*, not an intercepted call. Every other transport test
/// injects `fetch` above the encoding, so a mutation could be malformed and still
/// pass - the same shape of gap that let an untappable pill through a green suite.
private final class FakeProjects: @unchecked Sendable {
    var existing: [(id: String, name: String)] = []
    var queries: [(text: String, variables: [String: Any])] = []
    /// A GraphQL error to answer the mutation with, in Linear's own shape: a 200
    /// with the failure in `errors`.
    var refuseCreateWith: String?
    var createdID = "new-project"

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let body = (request.httpBody
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }
            as? [String: Any]) ?? [:]
        let text = (body["query"] as? String) ?? ""
        queries.append((text, (body["variables"] as? [String: Any]) ?? [:]))

        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        var json: [String: Any]
        if text.contains("projectCreate") {
            if let why = refuseCreateWith {
                json = ["errors": [["message": why]]]
            } else {
                let name = (body["variables"] as? [String: Any])?["name"] as? String ?? ""
                json = ["data": ["projectCreate": [
                    "success": true,
                    "project": ["id": createdID, "name": name],
                ]]]
            }
        } else {
            json = ["data": ["team": ["projects": [
                "nodes": existing.map { ["id": $0.id, "name": $0.name] },
            ]]]]
        }
        return (try JSONSerialization.data(withJSONObject: json), response)
    }
}

final class LinearDirectoryTests: XCTestCase {

    private func directory(_ fake: FakeProjects) -> LinearDirectory {
        LinearDirectory(credential: .apiKey("lin_api_x"), fetch: fake.fetch)
    }

    func testCreatingAProjectSendsTheMutationLinearExpects() async throws {
        let fake = FakeProjects()
        let project = try await directory(fake).createProject(named: "Reco", teamID: "team-1")

        XCTAssertEqual(project.id, "new-project")
        XCTAssertEqual(project.name, "Reco")

        let mutation = try XCTUnwrap(fake.queries.last)
        XCTAssertTrue(mutation.text.contains("projectCreate"), "no projectCreate mutation")
        XCTAssertTrue(mutation.text.contains("teamIds"),
                      "a project without a team belongs nowhere")
        XCTAssertEqual(mutation.variables["name"] as? String, "Reco")
        XCTAssertEqual(mutation.variables["teams"] as? [String], ["team-1"],
                       "the team has to travel as a variable, not be baked into the text")
    }

    /// `projectCreate` is not idempotent the way `issueCreate` is, so a retry after a
    /// dropped connection would otherwise leave two projects with one name and no way
    /// to tell which one the notes went to.
    func testAProjectThatAlreadyExistsIsReusedRatherThanDuplicated() async throws {
        let fake = FakeProjects()
        fake.existing = [(id: "already-there", name: "Reco")]

        let project = try await directory(fake).createProject(named: "Reco", teamID: "team-1")

        XCTAssertEqual(project.id, "already-there")
        XCTAssertFalse(fake.queries.contains { $0.text.contains("projectCreate") },
                       "it created a second project called Reco")
    }

    /// "Reco" and "  reco " are the same project to the person typing them.
    func testMatchingIgnoresCaseAndSurroundingSpace() async throws {
        let fake = FakeProjects()
        fake.existing = [(id: "already-there", name: "Reco")]

        let project = try await directory(fake).createProject(named: "  reco ", teamID: "team-1")

        XCTAssertEqual(project.id, "already-there")
        XCTAssertFalse(fake.queries.contains { $0.text.contains("projectCreate") })
    }

    func testAnEmptyNameNeverReachesLinear() async {
        let fake = FakeProjects()
        do {
            _ = try await directory(fake).createProject(named: "   ", teamID: "team-1")
            XCTFail("an empty name was accepted")
        } catch {
            XCTAssertTrue(fake.queries.isEmpty, "it asked Linear about a nameless project")
        }
    }

    /// A token scoped `issues:create` files issues perfectly well and is refused
    /// here. Meeting that without being told why is how somebody concludes the
    /// feature is broken rather than that their sign-in was narrower than they need.
    func testATooNarrowTokenSaysWhatToDoAboutIt() async {
        let fake = FakeProjects()
        fake.refuseCreateWith = "Access denied"

        do {
            _ = try await directory(fake).createProject(named: "Reco", teamID: "team-1")
            XCTFail("a refused create returned a project")
        } catch let error as LinearError {
            let said = error.description
            XCTAssertTrue(said.contains("Sign in again"), "did not say how to fix it: \(said)")
            XCTAssertTrue(said.contains("API key"), "did not offer the other way in: \(said)")
        } catch {
            XCTFail("threw something that is not a LinearError: \(error)")
        }
    }

    /// A failure that is not about scope must not be relabelled as one - being sent
    /// to re-authorise over a dropped connection is a wild goose chase.
    func testAnUnrelatedFailureIsReportedAsItself() async {
        let fake = FakeProjects()
        fake.refuseCreateWith = "Something else went wrong"

        do {
            _ = try await directory(fake).createProject(named: "Reco", teamID: "team-1")
            XCTFail("a refused create returned a project")
        } catch let error as LinearError {
            XCTAssertFalse(error.description.contains("Sign in again"),
                           "an unrelated failure was reported as a scope problem")
        } catch {
            XCTFail("threw something that is not a LinearError: \(error)")
        }
    }
}
