import Foundation
import Security
import LocalAuthentication

/// Storage for random history keys. Tests inject a memory implementation; keys never enter defaults or the history tree.
protocol HistoryKeyProvider: Sendable {
    func loadKey(id: String) throws -> Data?
    func storeKey(_ data: Data, id: String) throws
}

struct HistoryKeychain: HistoryKeyProvider {
    let service: String
    init(bundleID: String = Bundle.main.bundleIdentifier ?? "com.tavodev.agentsconfig.debug") {
        service = bundleID + ".history.encryption"
    }
    private func query(_ id: String) throws -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        guard AppPaths.overrideHome == nil, AppPaths.environmentHome == nil,
              environment["AGENTSCONFIG_DEFAULTS_SUITE"] == nil,
              !environment.keys.contains(where: { $0.hasPrefix("XCTest") || $0.hasPrefix("XCInject") }),
              NSClassFromString("XCTestCase") == nil else { throw HistoryEncryption.Failure.keychainUnavailable }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: id]
    }
    func loadKey(id: String) throws -> Data? {
        var request = try query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw HistoryEncryption.Failure.keychainUnavailable }
        return data
    }
    func storeKey(_ data: Data, id: String) throws {
        var request = try query(id)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        // Add only: an existing key is never overwritten, even if another process created it.
        guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw HistoryEncryption.Failure.keychainUnavailable }
    }
}
