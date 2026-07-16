//
//  TradingDashboardCache.swift
//  Crypto Monitoring
//

import Foundation

/// Disk cache for the trading page. API credentials are intentionally not
/// part of the cached payload and remain in Keychain.
final class TradingDashboardCache {
    static let shared = TradingDashboardCache()

    private struct Envelope: Codable {
        let schemaVersion: Int
        let savedAt: Date
        let dashboard: TradingDashboardData
    }

    private let fileManager: FileManager
    private let directoryURL: URL
    private let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    private let schemaVersion = 3

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let appIdentifier = Bundle.main.bundleIdentifier ?? "com.mark.crypto-monitoring"
        self.directoryURL = applicationSupport
            .appendingPathComponent(appIdentifier, isDirectory: true)
            .appendingPathComponent("TradingDashboardCache", isDirectory: true)
    }

    func load(
        environment: TradingEnvironment,
        market: MarketType,
        symbol: String,
        now: Date = Date()
    ) -> TradingDashboardData? {
        let url = fileURL(environment: environment, market: market, symbol: symbol)
        guard let data = try? Data(contentsOf: url),
              let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.schemaVersion == schemaVersion else {
            return nil
        }

        guard now.timeIntervalSince(envelope.savedAt) <= maximumAge else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return envelope.dashboard
    }

    /// Market switching must never decode a large cached trade history on the
    /// main thread. The caller validates its current scope before applying the
    /// returned snapshot, so a slow read cannot overwrite a newer selection.
    func loadAsync(
        environment: TradingEnvironment,
        market: MarketType,
        symbol: String,
        now: Date = Date()
    ) async -> TradingDashboardData? {
        await Task.detached(priority: .utility) { [self] in
            load(
                environment: environment,
                market: market,
                symbol: symbol,
                now: now
            )
        }.value
    }

    func save(
        _ dashboard: TradingDashboardData,
        environment: TradingEnvironment,
        market: MarketType,
        symbol: String
    ) throws {
        try ensureDirectoryExists()
        let envelope = Envelope(
            schemaVersion: schemaVersion,
            savedAt: Date(),
            dashboard: dashboard
        )
        let data = try encoder.encode(envelope)
        let url = fileURL(environment: environment, market: market, symbol: symbol)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    /// JSON encoding and atomic disk writes can be noticeable for dashboards
    /// containing hundreds of trades. Keep that work off the main actor so a
    /// background refresh never stalls form input or button feedback.
    func saveAsync(
        _ dashboard: TradingDashboardData,
        environment: TradingEnvironment,
        market: MarketType,
        symbol: String
    ) async throws {
        try await Task.detached(priority: .utility) { [self] in
            try save(
                dashboard,
                environment: environment,
                market: market,
                symbol: symbol
            )
        }.value
    }

    func remove(environment: TradingEnvironment, market: MarketType) {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else { return }

        let prefix = "\(environment.rawValue)_\(market.rawValue)_"
        for url in files where url.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func ensureDirectoryExists() throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

    private func fileURL(
        environment: TradingEnvironment,
        market: MarketType,
        symbol: String
    ) -> URL {
        let safeSymbol = symbol.uppercased().filter { $0.isLetter || $0.isNumber }
        let fileName = "\(environment.rawValue)_\(market.rawValue)_\(safeSymbol).json"
        return directoryURL.appendingPathComponent(fileName, isDirectory: false)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
