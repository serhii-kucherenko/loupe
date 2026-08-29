import XCTest
@testable import LoupeLinear

/// Making a project from the panel.
///
/// Its own file and its own fake, rather than extending the one next door: this is
/// the first thing in Loupe that writes something other than an issue, and it fails
/// in ways nothing else does.
@MainActor
final class LinearSettingsFlowProjectTests: XCTestCase {

    private func settings() -> LinearSettings {
        let account = "flow-project-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: account)!
        defaults.removePersistentDomain(forName: account)
        return LinearSettings(account: account, defaults: defaults)
    }

    private final class Fake: @unchecked Sendable {
        var projects: [(String, String)] = []
        var refuseCreateWith: String?
        var created: [String] = []
    }

    private func directory(_ fake: Fake) -> (LinearCredential) -> LinearDirectory {
        { credential in
            LinearDirectory(credential: credential,
                            endpoint: URL(string: "https://example.invalid/graphql")!) { request in
                let raw = request.httpBody ?? Data()
                let body = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
                let text = (body["query"] as? String) ?? ""
                let variables = (body["variables"] as? [String: Any]) ?? [:]

                func json(_ value: [String: Any]) throws -> (Data, URLResponse) {
                    (try JSONSerialization.data(withJSONObject: value),
                     HTTPURLResponse(url: request.url!, statusCode: 200,
                                     httpVersion: nil, headerFields: nil)!)
                }

                if text.contains("projectCreate") {
                    if let why = fake.refuseCreateWith {
                        return try json(["errors": [["message": why]]])
                    }
                    let name = variables["name"] as? String ?? ""
                    fake.created.append(name)
                    let id = "made-\(fake.created.count)"
                    fake.projects.append((id, name))
                    return try json(["data": ["projectCreate": [
                        "success": true, "project": ["id": id, "name": name],
                    ]]])
                }
                if text.contains("viewer") {
                    return try json(["data": [
                        "viewer": ["name": "Serhii"],
                        "organization": ["name": "Skailex"],
                    ]])
                }
                if text.contains("projects") {
                    return try json(["data": ["team": ["projects": [
                        "nodes": fake.projects.map { ["id": $0.0, "name": $0.1] },
                    ]]]])
                }
                return try json(["data": ["teams": ["nodes": [
                    ["id": "t1", "name": "Core Team", "key": "CORE"],
                ]]]])
            }
        }
    }

    private func connected(_ fake: Fake) async -> LinearSettingsFlow {
        let flow = LinearSettingsFlow(settings: settings(),
                                      makeDirectory: directory(fake),
                                      store: { _ in })
        await flow.test(key: "lin_api_abc")
        return flow
    }

    func testANewProjectBecomesTheChosenOne() async {
        let fake = Fake()
        let flow = await connected(fake)

        let made = await flow.createProject(named: "Reco")

        XCTAssertTrue(made)
        XCTAssertEqual(fake.created, ["Reco"])
        XCTAssertTrue(flow.projects.contains { $0.name == "Reco" },
                      "the new project never reached the picker")
        XCTAssertEqual(flow.projects.first { $0.name == "Reco" }?.id, flow.projectID,
                       "it was created and then not selected, so notes still go elsewhere")
    }

    /// Without a team there is nowhere to put it, and Linear would refuse anyway.
    func testItWillNotTryWithoutATeam() async {
        let fake = Fake()
        let flow = await connected(fake)
        flow.teamID = ""

        let made = await flow.createProject(named: "Reco")

        XCTAssertFalse(made)
        XCTAssertTrue(fake.created.isEmpty)
    }

    /// A credential that has not been proved cannot create anything, and trying is
    /// how somebody gets an error that names the wrong problem.
    func testItWillNotTryWithoutAProvedCredential() async {
        let fake = Fake()
        let flow = LinearSettingsFlow(settings: settings(), makeDirectory: directory(fake))
        flow.teamID = "t1"

        let made = await flow.createProject(named: "Reco")

        XCTAssertFalse(made)
        XCTAssertTrue(fake.created.isEmpty)
    }

    /// A refusal has to reach the panel and stay there. Closing on a failure is what
    /// made the refused Keychain write look like a save, and this fails for a reason
    /// nobody would guess: a token that files issues cannot create projects.
    func testARefusalIsReportedAndSaysWhatToDo() async {
        let fake = Fake()
        fake.refuseCreateWith = "Access denied"
        let flow = await connected(fake)

        let made = await flow.createProject(named: "Reco")

        XCTAssertFalse(made)
        guard case .failed(let why) = flow.connection else {
            return XCTFail("a refused create left the panel looking fine: \(flow.connection)")
        }
        XCTAssertTrue(why.contains("Sign in again"), "did not say how to fix it: \(why)")
    }

    /// The same name twice is one project. `projectCreate` is not idempotent, so
    /// without this a retry over a flaky connection leaves two and no way to tell
    /// which one the notes went to.
    func testTheSameNameTwiceDoesNotMakeTwoProjects() async {
        let fake = Fake()
        let flow = await connected(fake)

        await flow.createProject(named: "Reco")
        await flow.createProject(named: "reco")

        XCTAssertEqual(fake.created, ["Reco"], "it made a second project called reco")
        XCTAssertEqual(flow.projects.filter { $0.name.lowercased() == "reco" }.count, 1)
    }
}
