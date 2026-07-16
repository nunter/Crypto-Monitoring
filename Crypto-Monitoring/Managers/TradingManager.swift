//
//  TradingManager.swift
//  Crypto Monitoring
//

import Foundation

@MainActor
final class TradingManager: ObservableObject {
    @Published var environment: TradingEnvironment
    @Published var market: MarketType
    @Published var symbol: String
    @Published private(set) var availableTradingSymbols: [String]
    @Published private(set) var credentialsConfigured = false
    @Published private(set) var credentialPreview: BinanceCredentialPreview?
    @Published private(set) var isLoading = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var cancellingOrderIDs: Set<String> = []
    @Published private(set) var addingProtectionOrderIDs: Set<String> = []
    @Published private(set) var dashboard: TradingDashboardData?
    @Published private(set) var lastDashboardUpdate: Date?
    @Published private(set) var isShowingCachedDashboard = false
    @Published private(set) var lastOrder: BinanceOrderResult?
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private let appSettings: AppSettings
    private let service: BinanceTradingService
    private let dashboardCache = TradingDashboardCache.shared
    private var refreshRequestID = 0

    init(appSettings: AppSettings, initialSymbol: String) {
        self.appSettings = appSettings
        self.environment = appSettings.tradingEnvironment
        self.market = appSettings.marketType
        self.symbol = initialSymbol
        self.availableTradingSymbols = Self.makeTradingSymbols(
            customSymbols: appSettings.customCryptoSymbols,
            including: initialSymbol
        )
        self.service = BinanceTradingService(appSettings: appSettings)
        refreshCredentialState()
        scheduleCachedDashboardLoad()
    }

    var liveTradingEnabled: Bool { appSettings.liveTradingEnabled }
    var isCancellingOrder: Bool { !cancellingOrderIDs.isEmpty }
    var isAddingProtection: Bool { !addingProtectionOrderIDs.isEmpty }

    func setEnvironment(_ value: TradingEnvironment) {
        guard environment != value else { return }
        environment = value
        appSettings.saveTradingEnvironment(value)
        resetRemoteData()
        refreshCredentialState()
    }

    func setMarket(_ value: MarketType) {
        guard market != value else { return }
        market = value
        resetRemoteData()
        refreshCredentialState()
    }

    func selectTradingSymbol(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty, normalized != symbol else { return }
        if !availableTradingSymbols.contains(normalized) {
            availableTradingSymbols.append(normalized)
        }
        symbol = normalized
        resetDashboardDataForSymbolChange()
    }

    /// 校验并添加当前市场可交易的 USDT 交易对，成功后立即选中。
    func addTradingSymbol(_ input: String) async throws {
        let compact = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
        guard !compact.isEmpty else { throw BinanceTradingError.invalidSymbol }

        let pair = compact.hasSuffix("USDT") ? compact : "\(compact)USDT"
        guard pair.count > 4 else { throw BinanceTradingError.invalidSymbol }
        let baseSymbol = String(pair.dropLast(4))

        if availableTradingSymbols.contains(pair) {
            selectTradingSymbol(pair)
            statusMessage = "已选择 \(baseSymbol)/USDT"
            return
        }

        let customSymbol = try CustomCryptoSymbol(symbol: baseSymbol)
        let validatedPair = try await service.validateTradingSymbol(
            pair,
            environment: environment,
            market: market
        )

        guard appSettings.addCustomCryptoSymbol(customSymbol) else {
            throw BinanceTradingError.unsupported("无法添加：币种已存在或自定义币种已达到 5 个上限")
        }

        availableTradingSymbols = Self.makeTradingSymbols(
            customSymbols: appSettings.customCryptoSymbols,
            including: validatedPair
        )
        selectTradingSymbol(validatedPair)
        statusMessage = "已添加并选择 \(customSymbol.pairDisplayName)"
    }

    func setLiveTradingEnabled(_ enabled: Bool) {
        appSettings.saveLiveTradingEnabled(enabled)
        objectWillChange.send()
    }

    func clearMessages() {
        errorMessage = nil
        statusMessage = nil
    }

    func refreshCredentialState() {
        credentialPreview = service.credentialPreview(environment: environment, market: market)
        credentialsConfigured = credentialPreview != nil
    }

    func saveCredentials(apiKey: String, secretKey: String) {
        guard !credentialsConfigured else {
            errorMessage = "当前环境与市场已经配置 API 凭据，请先删除后再添加"
            return
        }
        do {
            try service.saveCredentials(
                apiKey: apiKey,
                secretKey: secretKey,
                environment: environment,
                market: market
            )
            refreshCredentialState()
            errorMessage = nil
            statusMessage = "凭据已安全保存到 macOS 钥匙串"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteCredentials() {
        do {
            try service.deleteCredentials(environment: environment, market: market)
            dashboardCache.remove(environment: environment, market: market)
            refreshCredentialState()
            dashboard = nil
            lastDashboardUpdate = nil
            isShowingCachedDashboard = false
            invalidateRefreshRequests()
            statusMessage = "当前环境与市场的凭据已删除"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func testConnection() async {
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        defer { isLoading = false }
        do {
            let canTrade = try await service.testConnection(environment: environment, market: market)
            statusMessage = canTrade
                ? "账户接口连接成功；API 下单权限将在提交订单时由 Binance 校验"
                : "账户接口连接成功，但 Binance 返回账户当前不可交易"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshDashboard(showsStatusMessage: Bool = true) async {
        guard credentialsConfigured else {
            if showsStatusMessage {
                errorMessage = BinanceTradingError.missingCredentials.localizedDescription
            }
            return
        }

        refreshRequestID &+= 1
        let requestID = refreshRequestID
        let requestedEnvironment = environment
        let requestedMarket = market
        let requestedSymbol = symbol

        isLoading = true
        if showsStatusMessage {
            errorMessage = nil
        }
        defer {
            if requestID == refreshRequestID {
                isLoading = false
            }
        }

        do {
            let refreshedDashboard = try await service.fetchDashboard(
                environment: requestedEnvironment,
                market: requestedMarket,
                symbol: requestedSymbol
            )

            guard requestID == refreshRequestID,
                  requestedEnvironment == environment,
                  requestedMarket == market,
                  requestedSymbol == symbol else { return }

            let wasWaitingForInitialDashboard = dashboard == nil
            dashboard = refreshedDashboard
            lastDashboardUpdate = refreshedDashboard.fetchedAt
            isShowingCachedDashboard = false
            do {
                try await dashboardCache.saveAsync(
                    refreshedDashboard,
                    environment: requestedEnvironment,
                    market: requestedMarket,
                    symbol: requestedSymbol
                )
            } catch {
                #if DEBUG
                print("⚠️ [TradingManager] 交易页缓存写入失败: \(error.localizedDescription)")
                #endif
            }
            if showsStatusMessage {
                statusMessage = "账户、当前委托与历史成交订单已更新"
            } else if wasWaitingForInitialDashboard {
                // 自动刷新从暂时性连接失败中恢复后，移除首次加载错误。
                errorMessage = nil
            }
        } catch {
            guard requestID == refreshRequestID,
                  !Task.isCancelled,
                  (error as? URLError)?.code != .cancelled else { return }

            // 后台轮询不覆盖下单结果；首次加载失败时仍显示连接问题。
            if showsStatusMessage || dashboard == nil {
                errorMessage = error.localizedDescription
            }
        }
    }

    func placeOrder(
        action: TradingAction,
        direction: PositionDirection,
        quantityText: String,
        amountText: String,
        leverage: Int,
        closeAll: Bool,
        orderType: TradingOrderType,
        priceText: String,
        sizingMode: TradingSizingMode
    ) async {
        let closesCompletePosition = action == .close && closeAll
        let quantity: Decimal?
        let spotNeedsQuantity = market == .spot
            && !closesCompletePosition
            && (action.isReducing || sizingMode == .quantity)
        let futuresNeedsQuantity = market == .perpetual
            && sizingMode == .quantity
            && !closesCompletePosition
        let needsQuantity = spotNeedsQuantity || futuresNeedsQuantity
        if needsQuantity {
            let normalized = quantityText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            quantity = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
            guard let quantity, quantity > 0 else {
                errorMessage = BinanceTradingError.invalidQuantity.localizedDescription
                return
            }
        } else {
            quantity = nil
        }

        let amount: Decimal?
        let spotNeedsAmount = market == .spot
            && !action.isReducing
            && sizingMode == .amount
        let futuresNeedsAmount = market == .perpetual
            && sizingMode == .amount
            && !closesCompletePosition
        if spotNeedsAmount || futuresNeedsAmount {
            let normalized = amountText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            amount = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
            guard let amount, amount > 0 else {
                errorMessage = BinanceTradingError.invalidAmount.localizedDescription
                return
            }
        } else {
            amount = nil
        }

        let limitPrice: Decimal?
        if orderType == .limit {
            let normalized = priceText.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            limitPrice = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
            guard let limitPrice, limitPrice > 0 else {
                errorMessage = BinanceTradingError.invalidPrice.localizedDescription
                return
            }
        } else {
            limitPrice = nil
        }

        isSubmitting = true
        errorMessage = nil
        statusMessage = nil
        defer { isSubmitting = false }
        do {
            lastOrder = try await service.placeOrder(
                TradingOrderRequest(
                    symbol: symbol,
                    market: market,
                    action: action,
                    direction: market == .spot ? .long : direction,
                    orderType: orderType,
                    limitPrice: limitPrice,
                    sizingMode: sizingMode,
                    quantity: quantity,
                    amount: amount,
                    leverage: market == .perpetual ? leverage : nil,
                    closeAll: closeAll
                ),
                environment: environment,
                liveTradingEnabled: appSettings.liveTradingEnabled
            )
            statusMessage = "\(action.displayName)指令已提交"
            await refreshDashboard(showsStatusMessage: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func parsePositiveDecimal(_ text: String) -> Decimal? {
        let normalized = text
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), value > 0 else {
            return nil
        }
        return value
    }

    func cancelPendingOrder(_ order: PendingOrder) async {
        guard !cancellingOrderIDs.contains(order.id) else { return }
        let requestedEnvironment = environment
        let requestedMarket = market
        invalidateRefreshRequests()
        cancellingOrderIDs.insert(order.id)
        errorMessage = nil
        statusMessage = nil
        defer { cancellingOrderIDs.remove(order.id) }

        do {
            try await service.cancelPendingOrder(
                order,
                environment: requestedEnvironment,
                market: requestedMarket
            )
            guard requestedEnvironment == environment,
                  requestedMarket == market else { return }
            removePendingOrderFromDashboard(order)
            await refreshDashboard(showsStatusMessage: false)
            statusMessage = "已取消 \(order.symbol) 委托 #\(order.orderId)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateProtection(
        to position: FuturesPosition,
        replacing existingOrders: [PendingOrder],
        takeProfitText: String,
        stopLossText: String
    ) async -> Bool {
        guard !addingProtectionOrderIDs.contains(position.id) else { return false }
        let takeProfit = Self.parsePositiveDecimal(takeProfitText)
        let stopLoss = Self.parsePositiveDecimal(stopLossText)
        guard takeProfit != nil || stopLoss != nil else {
            errorMessage = "请至少输入一个有效的止盈或止损触发价"
            return false
        }

        let requestedEnvironment = environment
        let requestedMarket = market
        addingProtectionOrderIDs.insert(position.id)
        errorMessage = nil
        statusMessage = nil
        defer { addingProtectionOrderIDs.remove(position.id) }

        do {
            let result = try await service.replaceProtection(
                to: position,
                replacing: existingOrders,
                takeProfitPrice: takeProfit,
                stopLossPrice: stopLoss,
                environment: requestedEnvironment,
                market: requestedMarket,
                liveTradingEnabled: appSettings.liveTradingEnabled
            )
            guard requestedEnvironment == environment, requestedMarket == market else { return true }
            if let warning = result.warning {
                errorMessage = "持仓保护已部分更新，但\(warning)"
            } else {
                statusMessage = "已更新 \(position.symbol) \(position.directionText)仓止盈止损"
            }
            await refreshDashboard(showsStatusMessage: false)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func addProtection(
        to position: SpotPosition,
        takeProfitText: String,
        stopLossText: String
    ) async -> Bool {
        guard !addingProtectionOrderIDs.contains(position.id) else { return false }
        let takeProfit = Self.parsePositiveDecimal(takeProfitText)
        let stopLoss = Self.parsePositiveDecimal(stopLossText)
        guard takeProfit != nil || stopLoss != nil else {
            errorMessage = "请至少输入一个有效的止盈或止损触发价"
            return false
        }

        let requestedEnvironment = environment
        let requestedMarket = market
        addingProtectionOrderIDs.insert(position.id)
        errorMessage = nil
        statusMessage = nil
        defer { addingProtectionOrderIDs.remove(position.id) }

        do {
            let result = try await service.addProtection(
                to: position,
                takeProfitPrice: takeProfit,
                stopLossPrice: stopLoss,
                environment: requestedEnvironment,
                market: requestedMarket,
                liveTradingEnabled: appSettings.liveTradingEnabled
            )
            guard requestedEnvironment == environment, requestedMarket == market else { return true }
            statusMessage = "已为 \(position.asset) 现货持仓添加 \(result.createdCount) 个止盈/止损保护单"
            await refreshDashboard(showsStatusMessage: false)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func resetRemoteData() {
        invalidateRefreshRequests()
        dashboard = nil
        lastDashboardUpdate = nil
        isShowingCachedDashboard = false
        lastOrder = nil
        errorMessage = nil
        statusMessage = nil
        scheduleCachedDashboardLoad()
    }

    private func resetDashboardDataForSymbolChange() {
        invalidateRefreshRequests()
        dashboard = nil
        lastDashboardUpdate = nil
        isShowingCachedDashboard = false
        errorMessage = nil
        scheduleCachedDashboardLoad()
    }

    private func invalidateRefreshRequests() {
        refreshRequestID &+= 1
        isLoading = false
    }

    private func scheduleCachedDashboardLoad() {
        let requestedEnvironment = environment
        let requestedMarket = market
        let requestedSymbol = symbol

        Task { [weak self] in
            guard let self else { return }
            let cached = await dashboardCache.loadAsync(
                environment: requestedEnvironment,
                market: requestedMarket,
                symbol: requestedSymbol
            )
            guard let cached,
                  requestedEnvironment == environment,
                  requestedMarket == market,
                  requestedSymbol == symbol,
                  dashboard == nil else { return }

            dashboard = cached
            lastDashboardUpdate = cached.fetchedAt
            isShowingCachedDashboard = true
        }
    }

    private func removePendingOrderFromDashboard(_ order: PendingOrder) {
        guard let current = dashboard else { return }
        let updated = TradingDashboardData(
            account: current.account,
            pendingOrders: current.pendingOrders.filter { $0.id != order.id },
            filledOrders: current.filledOrders,
            analytics: current.analytics,
            fetchedAt: Date()
        )
        dashboard = updated
        lastDashboardUpdate = updated.fetchedAt
        isShowingCachedDashboard = false
        let requestedEnvironment = environment
        let requestedMarket = market
        let requestedSymbol = symbol
        Task {
            try? await dashboardCache.saveAsync(
                updated,
                environment: requestedEnvironment,
                market: requestedMarket,
                symbol: requestedSymbol
            )
        }
    }

    private static func makeTradingSymbols(
        customSymbols: [CustomCryptoSymbol],
        including symbol: String
    ) -> [String] {
        let candidates = CryptoSymbol.allCases.map(\.apiSymbol)
            + customSymbols.map(\.apiSymbol)
            + [symbol.uppercased()]
        return candidates.reduce(into: [String]()) { result, candidate in
            if !result.contains(candidate) {
                result.append(candidate)
            }
        }
    }
}
