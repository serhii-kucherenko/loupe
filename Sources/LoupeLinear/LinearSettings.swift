import Foundation
import Security
import LoupeCore

/// Where the Linear credential lives, and the only place it lives.
///
/// The Keychain, never `UserDefaults`, never a plist, never the repo, never a log
/// line. The SDK is meant to be compiled into dev and staging builds only, which
/// lowers the stakes but does not remove them: a token in a sandbox backup is still
/// a token.
///
/// Destination ids are not secret and sit in `UserDefaults` beside it, so that
/// clearing a credential does not lose which team someone picked.
/// `@unchecked` because it holds a `UserDefaults`, which Swift has not marked
/// `Sendable` but which Apple documents as thread-safe. The Keychain calls are
/// thread-safe too. This has to cross an isolation boundary for real: a transport
/// reads it at send time, off the main actor.
public struct LinearSettings: @unchecked Sendable {

    public static let service = "dev.loupe.linear"

    private let account: String
    private let defaults: UserDefaults

    public init(account: String = "default", defaults: UserDefaults = .standard) {
        self.account = account
        self.defaults = defaults
    }

    // MARK: - The credential

    public func credential() -> LinearCredential? {
        guard let stored = read() else { return nil }
        // The prefix is Linear's own, and it is the difference between a header that
        // works and one that does not.
        return stored.hasPrefix("lin_api_") ? .apiKey(stored) : .accessToken(stored)
    }

    @discardableResult
    public func save(_ credential: LinearCredential) -> Bool {
        switch credential {
        case .apiKey(let value), .accessToken(let value): return write(value)
        }
    }

    @discardableResult
    public func clearCredential() -> Bool {
        SecItemDelete(baseQuery() as CFDictionary) == errSecSuccess
    }

    // MARK: - Where notes go

    public var destination: LinearDestination? {
        get {
            guard let team = defaults.string(forKey: key("team")) else { return nil }
            return LinearDestination(teamID: team,
                                     projectID: defaults.string(forKey: key("project")),
                                     delegateID: defaults.string(forKey: key("delegate")))
        }
        nonmutating set {
            defaults.set(newValue?.teamID, forKey: key("team"))
            defaults.set(newValue?.projectID, forKey: key("project"))
            defaults.set(newValue?.delegateID, forKey: key("delegate"))
        }
    }

    /// Ready to send, or the reason it is not.
    public func transport(endpoint: URL = URL(string: "https://api.linear.app/graphql")!)
        throws -> LinearTransport {
        guard let credential = credential() else { throw LinearError.notConfigured }
        guard let destination else {
            throw LinearError.notPermitted("no team chosen yet")
        }
        return LinearTransport(credential: credential,
                               destination: destination,
                               endpoint: endpoint)
    }

    // MARK: - Keychain

    private func key(_ name: String) -> String { "\(Self.service).\(account).\(name)" }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    private func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    private func write(_ value: String) -> Bool {
        let data = Data(value.utf8)
        // Delete first rather than branching on update-or-add: two paths that must
        // agree is one more place to be subtly wrong about an empty Keychain.
        SecItemDelete(baseQuery() as CFDictionary)

        var query = baseQuery()
        query[kSecValueData as String] = data
        // Never leaves the device, and is not needed before first unlock.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}
