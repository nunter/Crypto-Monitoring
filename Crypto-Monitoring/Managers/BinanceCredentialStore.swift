//
//  BinanceCredentialStore.swift
//  Crypto Monitoring
//

import Foundation
import Security

/// Stores API secrets in the user's Keychain. Environment variables are supported for development/CI.
final class BinanceCredentialStore {
    static let shared = BinanceCredentialStore()

    private let service = "com.mark.crypto-monitoring.binance"

    private init() {}

    func credentials(for scope: TradingCredentialScope) throws -> BinanceCredentials? {
        if let environmentCredentials = credentialsFromEnvironment(for: scope) {
            return environmentCredentials
        }

        guard let apiKey = try read(account: "apiKey.\(scope.keychainSuffix)"),
              let secretKey = try read(account: "secretKey.\(scope.keychainSuffix)") else {
            return nil
        }
        let credentials = BinanceCredentials(apiKey: apiKey, secretKey: secretKey)
        return credentials.isComplete ? credentials : nil
    }

    func credentialsAreEnvironmentManaged(for scope: TradingCredentialScope) -> Bool {
        credentialsFromEnvironment(for: scope) != nil
    }

    func save(apiKey: String, secretKey: String, for scope: TradingCredentialScope) throws {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSecret = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty, !cleanSecret.isEmpty else { throw BinanceTradingError.missingCredentials }
        try upsert(cleanKey, account: "apiKey.\(scope.keychainSuffix)")
        try upsert(cleanSecret, account: "secretKey.\(scope.keychainSuffix)")
    }

    func delete(for scope: TradingCredentialScope) throws {
        try delete(account: "apiKey.\(scope.keychainSuffix)")
        try delete(account: "secretKey.\(scope.keychainSuffix)")
    }

    private func credentialsFromEnvironment(for scope: TradingCredentialScope) -> BinanceCredentials? {
        let environment = ProcessInfo.processInfo.environment
        let prefix = scope.environment == .testnet ? "BINANCE_TESTNET_" : "BINANCE_"
        let market = scope.market == .spot ? "SPOT_" : "FUTURES_"

        let apiKey = environment["\(prefix)\(market)API_KEY"]
            ?? (scope.environment == .mainnet ? environment["BINANCE_API_KEY"] : nil)
        let secret = environment["\(prefix)\(market)API_SECRET"]
            ?? (scope.environment == .mainnet ? environment["BINANCE_API_SECRET"] : nil)

        guard let apiKey, let secret else { return nil }
        let credentials = BinanceCredentials(apiKey: apiKey, secretKey: secret)
        return credentials.isComplete ? credentials : nil
    }

    private func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw BinanceTradingError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw BinanceTradingError.invalidResponse
        }
        return value
    }

    private func upsert(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let status = SecItemAdd(insert as CFDictionary, nil)
            guard status == errSecSuccess else { throw BinanceTradingError.keychain(status) }
        } else if updateStatus != errSecSuccess {
            throw BinanceTradingError.keychain(updateStatus)
        }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw BinanceTradingError.keychain(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
