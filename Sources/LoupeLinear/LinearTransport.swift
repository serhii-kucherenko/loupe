import Foundation
import LoupeCore

/// Sends each annotation to Linear as its own issue.
///
/// **One issue per note, never one per bundle.** A bundle is a session, and the
/// notes in it are unrelated to each other; an umbrella issue would have to be split
/// by hand, which is the work this is supposed to remove.
///
/// Wrap it in a `QueuedTransport` the way `FileTransport` is wrapped. That is what
/// makes an iPad with no signal safe, and it is also why every write here has to be
/// idempotent: a retry after a half-finished send must not create a second issue.
public final class LinearTransport: Transport, @unchecked Sendable {

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let credential: LinearCredential
    private let destination: LinearDestination
    private let endpoint: URL
    private let fetch: Fetch

    /// - Parameter fetch: injected so the whole path can be tested without a network
    ///   and without `URLProtocol` tricks.
    public init(credential: LinearCredential,
                destination: LinearDestination,
                endpoint: URL = URL(string: "https://api.linear.app/graphql")!,
                fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }) {
        self.credential = credential
        self.destination = destination
        self.endpoint = endpoint
        self.fetch = fetch
    }

    public func send(_ bundle: AnnotationBundle) async throws {
        for annotation in bundle.annotations {
            try await send(annotation, in: bundle)
        }
    }

    private func send(_ annotation: Annotation, in bundle: AnnotationBundle) async throws {
        // Ask first. `QueuedTransport` retries whole bundles, so a send that created
        // three issues and then lost the network would otherwise create the first
        // three again.
        if try await issueExists(for: annotation.id) { return }

        var assets = IssueDraft.Assets()
        assets.crop = try await upload(annotation.screenshotPNG,
                                       named: "\(annotation.id.uuidString).png")
        assets.context = try await upload(annotation.contextScreenshotPNG,
                                          named: "\(annotation.id.uuidString)-context.png")

        let draft = IssueDraft(annotation: annotation, bundle: bundle, assets: assets)
        try await create(draft)
    }

    // MARK: - The three calls

    private func issueExists(for id: UUID) async throws -> Bool {
        let query = """
        query Existing($marker: String!) {
          issues(filter: { description: { contains: $marker } }, first: 1) {
            nodes { id }
          }
        }
        """
        let data = try await graphQL(query, ["marker": IssueDraft.marker(for: id)],
                                     called: "the duplicate check")
        let issues = (data["issues"] as? [String: Any])?["nodes"] as? [[String: Any]]
        return !(issues ?? []).isEmpty
    }

    /// Returns the asset URL, or nil when there was no image to send.
    ///
    /// A missing picture is ordinary rather than exceptional - a region pick on the
    /// web has no crop - so this is not an error path.
    private func upload(_ png: Data?, named filename: String) async throws -> String? {
        guard let png, !png.isEmpty else { return nil }

        let mutation = """
        mutation Upload($contentType: String!, $filename: String!, $size: Int!) {
          fileUpload(contentType: $contentType, filename: $filename, size: $size) {
            success
            uploadFile { uploadUrl assetUrl headers { key value } }
          }
        }
        """
        let data = try await graphQL(mutation, [
            "contentType": "image/png", "filename": filename, "size": png.count,
        ], called: "the image upload")

        guard let payload = (data["fileUpload"] as? [String: Any])?["uploadFile"]
                as? [String: Any],
              let uploadURL = (payload["uploadUrl"] as? String).flatMap(URL.init(string:)),
              let assetURL = payload["assetUrl"] as? String
        else { throw LinearError.api("Linear did not return an upload URL") }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.httpBody = png
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.setValue("public, max-age=31536000", forHTTPHeaderField: "Cache-Control")
        // Every header the mutation handed back has to be echoed or the signed URL
        // rejects the body. This is the step people miss.
        //
        // Checked against Linear's own example on 2026-08-29 (developers/
        // how-to-upload-a-file-to-linear): same two headers set first, by the same
        // names and the same `public, max-age=31536000`, then the returned headers
        // set over the top. Written down so the next person chasing an upload
        // failure does not spend the afternoon re-deriving that this part is right.
        //
        // The one thing that page says which is not obviously true of Loupe: "the
        // PUT request must be executed on the server". That is about a browser,
        // where the request carries an `Origin` and the bucket refuses it. A native
        // app sends no `Origin`, so this is the server case as far as storage is
        // concerned.
        for header in payload["headers"] as? [[String: Any]] ?? [] {
            if let key = header["key"] as? String, let value = header["value"] as? String {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        _ = try await perform(request)
        return assetURL
    }

    private func create(_ draft: IssueDraft) async throws {
        let mutation = """
        mutation Create($input: IssueCreateInput!) {
          issueCreate(input: $input) { success issue { id identifier url } }
        }
        """
        var input: [String: Any] = [
            "title": draft.title,
            "description": draft.description,
            "teamId": destination.teamID,
        ]
        if let project = destination.projectID { input["projectId"] = project }
        if let delegate = destination.delegateID { input["delegateId"] = delegate }

        let data = try await graphQL(mutation, ["input": input], called: "filing the issue")
        let created = (data["issueCreate"] as? [String: Any])?["success"] as? Bool
        guard created == true else {
            throw LinearError.api("Linear declined to create the issue")
        }
    }

    // MARK: - Transport

    /// - Parameter operation: which of the three calls this is, in words, so a
    ///   refusal names it.
    ///
    ///   A send makes three requests - a duplicate check, an upload, and the create -
    ///   and they need different permissions. When Linear refused the first real send
    ///   with `Invalid scope: 'write' required`, nothing said which of the three had
    ///   been refused, so the only way to find out was to change something on the
    ///   account and try again. Every one of those rounds costs somebody a reinstall.
    private func graphQL(_ query: String,
                         _ variables: [String: Any],
                         called operation: String) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credential.headerValue, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["query": query, "variables": variables])

        let data: Data
        do {
            data = try await perform(request)
        } catch {
            throw LinearError.naming(operation, in: error)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LinearError.api("Linear returned something that is not JSON "
                                  + "when asked for \(operation).")
        }
        // A GraphQL error arrives with HTTP 200, so the status code alone proves
        // nothing about whether the thing was done.
        if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
            let first = errors.first?["message"] as? String ?? "unknown error"
            // Read for whether it is about access. "Access denied" is true and
            // useless: it does not say the credential is too narrow, and it does
            // not say that signing in again would fix it.
            throw LinearError.fromGraphQL(first, during: operation)
        }
        return json["data"] as? [String: Any] ?? [:]
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(request)
        } catch {
            throw LinearError.unreachable((error as NSError).localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw LinearError.credentialRejected
        case 403:
            throw LinearError.notPermitted("team \(destination.teamID)")
        case 429:
            let after = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw LinearError.rateLimited(retryAfter: after)
        default:
            throw LinearError.fromHTTP(status: http.statusCode,
                                       body: data,
                                       request: request)
        }
    }
}
