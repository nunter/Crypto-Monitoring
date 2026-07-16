//
//  BinanceTradingService.swift
//  Crypto Monitoring
//

import Foundation
import CryptoKit

final class BinanceTradingService {
    private let credentialStore: BinanceCredentialStore
    private let session: URLSession
    private let stateLock = NSLock()
    private var timeOffsets: [String: Int64] = [:]
    /// Keeps the trade history for spot pairs that have already been viewed.
    /// This lets their estimated cost and PnL remain visible without polling
    /// every held asset's high-weight `myTrades` endpoint every 10 seconds.
    private var spotTradeHistory: [String: [TradeRecord]] = [:]
    /// Immediate fallback for a freshly filled spot BUY. Spot FULL responses
    /// usually expose cumulative quote quantity/fills instead of `avgPrice`.
    private var spotOrderAverageCosts: [String: Decimal] = [:]
    /// User commission endpoints have a relatively high request weight. Rates
    /// change infrequently, so cache them per credential scope and symbol.
    private var commissionRateCache: [String: CachedCommissionRates] = [:]
    private let commissionRateCacheLifetime: TimeInterval = 15 * 60

    @MainActor
    init(appSettings: AppSettings, credentialStore: BinanceCredentialStore = .shared) {
        self.credentialStore = credentialStore
        self.session = Self.makeSession(
            proxyEnabled: appSettings.proxyEnabled,
            proxyHost: appSettings.proxyHost,
            proxyPort: appSettings.proxyPort,
            proxyUsername: appSettings.proxyUsername,
            proxyPassword: appSettings.proxyPassword
        )
    }

    func hasCredentials(environment: TradingEnvironment, market: MarketType) -> Bool {
        (try? credentialStore.credentials(for: .init(environment: environment, market: market))) != nil
    }

    func credentialPreview(environment: TradingEnvironment, market: MarketType) -> BinanceCredentialPreview? {
        let scope = TradingCredentialScope(environment: environment, market: market)
        guard let credentials = try? credentialStore.credentials(for: scope) else { return nil }
        return BinanceCredentialPreview(
            maskedApiKey: Self.maskedApiKey(credentials.apiKey),
            maskedSecretKey: "••••••••••••••••",
            canDelete: !credentialStore.credentialsAreEnvironmentManaged(for: scope)
        )
    }

    func saveCredentials(apiKey: String, secretKey: String, environment: TradingEnvironment, market: MarketType) throws {
        guard !hasCredentials(environment: environment, market: market) else {
            throw BinanceTradingError.unsupported("当前环境与市场已经配置 API 凭据，请先删除后再添加")
        }
        try credentialStore.save(
            apiKey: apiKey,
            secretKey: secretKey,
            for: .init(environment: environment, market: market)
        )
        withStateLock {
            commissionRateCache.removeAll()
        }
    }

    func deleteCredentials(environment: TradingEnvironment, market: MarketType) throws {
        let scope = TradingCredentialScope(environment: environment, market: market)
        guard !credentialStore.credentialsAreEnvironmentManaged(for: scope) else {
            throw BinanceTradingError.unsupported("当前凭据来自环境变量，请在启动环境中删除对应变量")
        }
        try credentialStore.delete(for: scope)
        withStateLock {
            commissionRateCache.removeAll()
        }
    }

    private static func maskedApiKey(_ apiKey: String) -> String {
        guard apiKey.count > 8 else {
            return String(repeating: "•", count: max(apiKey.count, 8))
        }
        return "\(apiKey.prefix(4))••••••\(apiKey.suffix(4))"
    }

    func testConnection(environment: TradingEnvironment, market: MarketType) async throws -> Bool {
        let account = try await fetchAccount(environment: environment, market: market)
        return account.canTrade
    }

    func fetchDashboard(environment: TradingEnvironment, market: MarketType, symbol: String) async throws -> TradingDashboardData {
        let normalizedSymbol = try normalizeSymbol(symbol)
        let accountData = try await fetchAccountData(environment: environment, market: market)
        let rawAccount = accountData.snapshot
        let trades = try await fetchTrades(environment: environment, market: market, symbol: normalizedSymbol, limit: 1000)
        let filledOrders = FilledOrderRecord.aggregate(trades)
        let pendingOrders = try await fetchPendingOrders(
            environment: environment,
            market: market,
            leverageBySymbol: accountData.leverageBySymbol
        )
        let account: TradingAccountSnapshot
        if market == .spot {
            withStateLock {
                spotTradeHistory[normalizedSymbol] = trades
            }
            account = await enrichingSpotAccount(
                rawAccount,
                environment: environment
            )
        } else {
            account = rawAccount
        }
        return TradingDashboardData(
            account: account,
            pendingOrders: pendingOrders,
            filledOrders: filledOrders,
            analytics: .calculate(from: filledOrders),
            fetchedAt: Date()
        )
    }

    /// 使用当前环境和市场的 exchangeInfo 校验交易对，成功时返回标准化符号。
    func validateTradingSymbol(
        _ symbol: String,
        environment: TradingEnvironment,
        market: MarketType
    ) async throws -> String {
        let normalizedSymbol = try normalizeSymbol(symbol)
        _ = try await fetchSymbolInfo(
            environment: environment,
            market: market,
            symbol: normalizedSymbol
        )
        return normalizedSymbol
    }

    func placeOrder(
        _ request: TradingOrderRequest,
        environment: TradingEnvironment,
        liveTradingEnabled: Bool
    ) async throws -> BinanceOrderResult {
        if environment.isLive && !liveTradingEnabled {
            throw BinanceTradingError.liveTradingDisabled
        }

        let symbol = try normalizeSymbol(request.symbol)
        let symbolInfo = try await fetchSymbolInfo(environment: environment, market: request.market, symbol: symbol)
        switch request.market {
        case .spot:
            return try await placeSpotOrder(
                request,
                symbol: symbol,
                symbolInfo: symbolInfo,
                environment: environment
            )
        case .perpetual:
            return try await placeFuturesOrder(
                request,
                symbol: symbol,
                symbolInfo: symbolInfo,
                environment: environment
            )
        }
    }

    /// Replaces TP/SL protection on an existing USDⓈ-M position. A replacement
    /// is created before the matching old order is cancelled, so a placement
    /// failure leaves the previous protection intact.
    func replaceProtection(
        to position: FuturesPosition,
        replacing existingOrders: [PendingOrder],
        takeProfitPrice: Decimal?,
        stopLossPrice: Decimal?,
        environment: TradingEnvironment,
        market: MarketType,
        liveTradingEnabled: Bool
    ) async throws -> ProtectionOrderResult {
        if environment.isLive && !liveTradingEnabled {
            throw BinanceTradingError.liveTradingDisabled
        }
        guard market == .perpetual, position.amount != 0 else {
            throw BinanceTradingError.unsupported("只有当前有效的永续合约持仓可以设置止盈止损")
        }

        let symbol = try normalizeSymbol(position.symbol)
        let direction: PositionDirection
        if position.positionSide == "LONG" {
            direction = .long
        } else if position.positionSide == "SHORT" {
            direction = .short
        } else {
            direction = position.amount > 0 ? .long : .short
        }
        let symbolInfo = try await fetchSymbolInfo(
            environment: environment,
            market: .perpetual,
            symbol: symbol
        )
        let markPrice = try await fetchMarkPrice(environment: environment, symbol: symbol)
        var references = [markPrice]
        if position.entryPrice > 0 { references.append(position.entryPrice) }
        let protection = try normalizedProtectionPrices(
            takeProfitPrice: takeProfitPrice,
            stopLossPrice: stopLossPrice,
            market: .perpetual,
            direction: direction,
            symbolInfo: symbolInfo,
            referencePrices: references
        )
        guard !protection.isEmpty else {
            throw BinanceTradingError.invalidProtectionPrice("请至少设置一个止盈或止损价格")
        }

        let isHedgeMode = try await fetchHedgeMode(environment: environment)
        let takeProfitUpdate = await replaceFuturesProtectionOrder(
            kind: .takeProfit,
            newPrice: protection.takeProfit,
            oldOrders: existingOrders.filter { protectionKind(for: $0.type) == .takeProfit },
            environment: environment,
            symbol: symbol,
            direction: direction,
            isHedgeMode: isHedgeMode
        )
        let stopLossUpdate = await replaceFuturesProtectionOrder(
            kind: .stopLoss,
            newPrice: protection.stopLoss,
            oldOrders: existingOrders.filter { protectionKind(for: $0.type) == .stopLoss },
            environment: environment,
            symbol: symbol,
            direction: direction,
            isHedgeMode: isHedgeMode
        )
        let createdCount = takeProfitUpdate.createdCount + stopLossUpdate.createdCount
        var failures = takeProfitUpdate.failures + stopLossUpdate.failures
        guard createdCount > 0 else {
            throw BinanceTradingError.unsupported(failures.joined(separator: "；"))
        }
        if createdCount == protection.count {
            let disabledOldOrders = existingOrders.filter { order in
                switch protectionKind(for: order.type) {
                case .takeProfit: return protection.takeProfit == nil
                case .stopLoss: return protection.stopLoss == nil
                case nil: return false
                }
            }
            for oldOrder in disabledOldOrders {
                do {
                    try await cancelPendingOrder(
                        oldOrder,
                        environment: environment,
                        market: .perpetual
                    )
                } catch {
                    failures.append("已关闭的旧保护单 #\(oldOrder.orderId) 撤销失败：\(error.localizedDescription)")
                }
            }
        }
        return ProtectionOrderResult(
            createdCount: createdCount,
            warning: failures.isEmpty ? nil : failures.joined(separator: "；")
        )
    }

    /// Protects an already-owned Spot balance with an OCO or a single
    /// conditional SELL order. Only the currently free quantity is reserved.
    func addProtection(
        to position: SpotPosition,
        takeProfitPrice: Decimal?,
        stopLossPrice: Decimal?,
        environment: TradingEnvironment,
        market: MarketType,
        liveTradingEnabled: Bool
    ) async throws -> ProtectionOrderResult {
        if environment.isLive && !liveTradingEnabled {
            throw BinanceTradingError.liveTradingDisabled
        }
        guard market == .spot, position.free > 0 else {
            throw BinanceTradingError.unsupported("当前现货没有可用于止盈止损的可用数量")
        }

        let symbol = try normalizeSymbol(position.symbol)
        let symbolInfo = try await fetchSymbolInfo(
            environment: environment,
            market: .spot,
            symbol: symbol
        )
        let currentPrice = try await fetchSpotPrice(environment: environment, symbol: symbol)
        var references = [currentPrice]
        if let averageCost = position.averageCost, averageCost > 0 {
            references.append(averageCost)
        }
        let protection = try normalizedProtectionPrices(
            takeProfitPrice: takeProfitPrice,
            stopLossPrice: stopLossPrice,
            market: .spot,
            direction: .long,
            symbolInfo: symbolInfo,
            referencePrices: references
        )
        guard !protection.isEmpty else {
            throw BinanceTradingError.invalidProtectionPrice("请至少设置一个止盈或止损价格")
        }

        let createdCount = try await placeSpotProtectionAfterFill(
            environment: environment,
            symbol: symbol,
            symbolInfo: symbolInfo,
            executedQuantity: position.free,
            protection: protection
        )
        guard createdCount > 0 else {
            throw BinanceTradingError.unsupported("止盈止损保护单添加失败")
        }
        return ProtectionOrderResult(createdCount: createdCount, warning: nil)
    }

    /// Cancels one currently open order. Cancellation is allowed even when the
    /// live-order placement switch is off because it only removes market risk.
    func cancelPendingOrder(
        _ order: PendingOrder,
        environment: TradingEnvironment,
        market: MarketType
    ) async throws {
        var parameters: [String: String]
        let path: String

        switch market {
        case .spot:
            guard !order.isAlgoOrder else {
                throw BinanceTradingError.unsupported("现货暂不支持该条件单撤销方式")
            }
            parameters = [
                "symbol": try normalizeSymbol(order.symbol),
                "orderId": order.orderId
            ]
            path = "/api/v3/order"
        case .perpetual:
            if order.isAlgoOrder {
                parameters = ["algoId": order.orderId]
                path = "/fapi/v1/algoOrder"
            } else {
                parameters = [
                    "symbol": try normalizeSymbol(order.symbol),
                    "orderId": order.orderId
                ]
                path = "/fapi/v1/order"
            }
        }

        _ = try await signedRequest(
            environment: environment,
            market: market,
            method: "DELETE",
            path: path,
            parameters: &parameters
        )
    }

    // MARK: - Orders

    private func placeSpotOrder(
        _ request: TradingOrderRequest,
        symbol: String,
        symbolInfo: SymbolInfo,
        environment: TradingEnvironment
    ) async throws -> BinanceOrderResult {
        // 现货方向完全由操作决定：建仓/加仓为买入，减仓/平仓为卖出。
        // 不读取合约表单遗留的多空状态，避免从合约切回现货后误判为做空。
        let isBuy = !request.action.isReducing
        var parameters = [
            "symbol": symbol,
            "side": isBuy ? "BUY" : "SELL",
            "type": request.orderType.apiValue,
            "newOrderRespType": "FULL"
        ]

        var fallbackQuantity: Decimal = 0
        if isBuy && request.sizingMode == .amount {
            guard let quoteAmount = request.amount, quoteAmount > 0 else {
                throw BinanceTradingError.invalidAmount
            }

            let account = try await fetchSpotAccountDTO(environment: environment)
            let availableQuote = account.balances
                .first(where: { $0.asset == symbolInfo.quoteAsset })
                .map { decimal($0.free) } ?? 0
            guard availableQuote >= quoteAmount else {
                throw BinanceTradingError.unsupported(
                    "可用 \(symbolInfo.quoteAsset) 余额不足：需要 \(quoteAmount.plainString)，当前可用 \(availableQuote.plainString)"
                )
            }

            if request.orderType == .market {
                // 市价买入按 quoteOrderQty 直接表达希望花费的 USDT 金额。
                parameters["quoteOrderQty"] = quoteAmount.plainString
            } else {
                guard let requestedPrice = request.limitPrice else { throw BinanceTradingError.invalidPrice }
                let price = try normalizedPrice(requestedPrice, symbolInfo: symbolInfo)
                let quantity = try normalizedQuantity(
                    quoteAmount / price,
                    symbolInfo: symbolInfo,
                    orderType: request.orderType
                )
                fallbackQuantity = quantity
                parameters["quantity"] = quantity.plainString
                parameters["price"] = price.plainString
                parameters["timeInForce"] = "GTC"
            }
        } else {
            let rawQuantity: Decimal
            if request.action == .close && request.closeAll {
                let account = try await fetchSpotAccountDTO(environment: environment)
                guard let balance = account.balances.first(where: { $0.asset == symbolInfo.baseAsset }) else {
                    throw BinanceTradingError.insufficientBalance(symbolInfo.baseAsset)
                }
                rawQuantity = decimal(balance.free)
            } else if let quantity = request.quantity {
                rawQuantity = quantity
            } else {
                throw BinanceTradingError.invalidQuantity
            }

            let quantity = try normalizedQuantity(rawQuantity, symbolInfo: symbolInfo, orderType: request.orderType)
            fallbackQuantity = quantity
            parameters["quantity"] = quantity.plainString
            if request.orderType == .limit {
                guard let requestedPrice = request.limitPrice else { throw BinanceTradingError.invalidPrice }
                parameters["price"] = try normalizedPrice(requestedPrice, symbolInfo: symbolInfo).plainString
                parameters["timeInForce"] = "GTC"
            }
        }

        let data = try await signedRequest(
            environment: environment,
            market: .spot,
            method: "POST",
            path: "/api/v3/order",
            parameters: &parameters
        )
        let response = try decode(OrderResponseDTO.self, from: data)
        let result = response.result(fallbackQuantity: fallbackQuantity)
        if isBuy,
           result.executedQuantity > 0,
           let averagePrice = result.averagePrice,
           averagePrice > 0 {
            withStateLock {
                spotOrderAverageCosts[spotCostKey(environment: environment, symbol: symbol)] = averagePrice
            }
        }
        return result
    }

    private func placeSpotProtectionAfterFill(
        environment: TradingEnvironment,
        symbol: String,
        symbolInfo: SymbolInfo,
        executedQuantity: Decimal,
        protection: ProtectionPrices
    ) async throws -> Int {
        guard executedQuantity > 0 else {
            throw BinanceTradingError.unsupported("主订单尚未成交，无法冻结现货数量")
        }

        // A market BUY can pay commission in the base asset. Use the actual
        // free balance so the protective order never exceeds sellable stock.
        let account = try await fetchSpotAccountDTO(environment: environment)
        let freeBalance = account.balances
            .first(where: { $0.asset == symbolInfo.baseAsset })
            .map { decimal($0.free) } ?? 0
        let quantity = try normalizedQuantity(
            min(executedQuantity, freeBalance),
            symbolInfo: symbolInfo,
            orderType: .limit
        )

        if let takeProfit = protection.takeProfit, let stopLoss = protection.stopLoss {
            var parameters = [
                "symbol": symbol,
                "side": "SELL",
                "quantity": quantity.plainString,
                "aboveType": "TAKE_PROFIT",
                "aboveStopPrice": takeProfit.plainString,
                "belowType": "STOP_LOSS",
                "belowStopPrice": stopLoss.plainString,
                "newOrderRespType": "RESULT"
            ]
            _ = try await signedRequest(
                environment: environment,
                market: .spot,
                method: "POST",
                path: "/api/v3/orderList/oco",
                parameters: &parameters
            )
            return 2
        }

        var parameters = [
            "symbol": symbol,
            "side": "SELL",
            "quantity": quantity.plainString,
            "newOrderRespType": "RESULT"
        ]
        if let takeProfit = protection.takeProfit {
            parameters["type"] = "TAKE_PROFIT"
            parameters["stopPrice"] = takeProfit.plainString
        } else if let stopLoss = protection.stopLoss {
            parameters["type"] = "STOP_LOSS"
            parameters["stopPrice"] = stopLoss.plainString
        } else {
            return 0
        }
        _ = try await signedRequest(
            environment: environment,
            market: .spot,
            method: "POST",
            path: "/api/v3/order",
            parameters: &parameters
        )
        return 1
    }

    private func placeFuturesOrder(
        _ request: TradingOrderRequest,
        symbol: String,
        symbolInfo: SymbolInfo,
        environment: TradingEnvironment
    ) async throws -> BinanceOrderResult {
        let isHedgeMode = try await fetchHedgeMode(environment: environment)
        var rawQuantity: Decimal
        var leverageToSet: Int?
        var parameters: [String: String] = [
            "symbol": symbol,
            "type": request.orderType.apiValue,
            "newOrderRespType": "RESULT"
        ]

        let currentMarkPrice: Decimal?
        if request.orderType == .market && request.sizingMode == .amount && !(request.action == .close && request.closeAll) {
            currentMarkPrice = try await fetchMarkPrice(environment: environment, symbol: symbol)
        } else {
            currentMarkPrice = nil
        }

        let referencePrice: Decimal
        if request.orderType == .limit {
            guard let price = request.limitPrice else { throw BinanceTradingError.invalidPrice }
            let finalPrice = try normalizedPrice(price, symbolInfo: symbolInfo)
            parameters["price"] = finalPrice.plainString
            parameters["timeInForce"] = "GTC"
            referencePrice = finalPrice
        } else if request.sizingMode == .amount && !(request.action == .close && request.closeAll) {
            referencePrice = currentMarkPrice ?? 0
        } else {
            // Direct-quantity market orders and full closes do not need a price conversion.
            referencePrice = 1
        }
        guard referencePrice > 0 else { throw BinanceTradingError.invalidResponse }

        if request.action.isReducing {
            let account = try await fetchFuturesAccountDTO(environment: environment)
            guard let position = matchingPosition(
                in: account.positions,
                symbol: symbol,
                direction: request.direction,
                hedgeMode: isHedgeMode
            ) else {
                throw BinanceTradingError.noPosition
            }

            let available = abs(decimal(position.positionAmt))
            guard available > 0 else { throw BinanceTradingError.noPosition }
            if request.action == .close && request.closeAll {
                rawQuantity = available
            } else if request.sizingMode == .quantity, let quantity = request.quantity, quantity > 0 {
                rawQuantity = min(quantity, available)
            } else {
                guard let amount = request.amount, amount > 0 else {
                    throw BinanceTradingError.invalidQuantity
                }
                // Reducing amounts are entered as position notional in USDT; leverage is not changed while closing.
                rawQuantity = min(amount / referencePrice, available)
            }
            parameters["side"] = request.direction == .long ? "SELL" : "BUY"
            if isHedgeMode {
                parameters["positionSide"] = request.direction == .long ? "LONG" : "SHORT"
            } else {
                parameters["reduceOnly"] = "true"
            }
        } else {
            guard let leverage = request.leverage, (1...125).contains(leverage) else {
                throw BinanceTradingError.invalidQuantity
            }
            if request.sizingMode == .quantity {
                guard let quantity = request.quantity, quantity > 0 else {
                    throw BinanceTradingError.invalidQuantity
                }
                rawQuantity = quantity
            } else {
                guard let amount = request.amount, amount > 0 else {
                    throw BinanceTradingError.invalidQuantity
                }
                // Open/add amount is margin in USDT. Convert margin × leverage into base-asset quantity.
                rawQuantity = amount * Decimal(leverage) / referencePrice
            }
            leverageToSet = leverage
            parameters["side"] = request.direction == .long ? "BUY" : "SELL"
            if isHedgeMode {
                parameters["positionSide"] = request.direction == .long ? "LONG" : "SHORT"
            }
        }

        let finalQuantity = try normalizedQuantity(rawQuantity, symbolInfo: symbolInfo, orderType: request.orderType)
        parameters["quantity"] = finalQuantity.plainString

        // Validate quantity before changing the symbol-level leverage.
        if let leverageToSet {
            try await changeLeverage(environment: environment, symbol: symbol, leverage: leverageToSet)
        }

        let data = try await signedRequest(
            environment: environment,
            market: .perpetual,
            method: "POST",
            path: "/fapi/v1/order",
            parameters: &parameters
        )
        let response = try decode(OrderResponseDTO.self, from: data)
        return response.result(fallbackQuantity: finalQuantity)
    }

    private func replaceFuturesProtectionOrder(
        kind: ProtectionKind,
        newPrice: Decimal?,
        oldOrders: [PendingOrder],
        environment: TradingEnvironment,
        symbol: String,
        direction: PositionDirection,
        isHedgeMode: Bool
    ) async -> (createdCount: Int, failures: [String]) {
        let label = kind == .takeProfit ? "止盈" : "止损"
        var createdCount = 0
        var failures: [String] = []

        guard let newPrice else { return (0, []) }
        do {
            try await placeFuturesProtectionOrder(
                environment: environment,
                symbol: symbol,
                direction: direction,
                isHedgeMode: isHedgeMode,
                type: kind == .takeProfit ? "TAKE_PROFIT_MARKET" : "STOP_MARKET",
                triggerPrice: newPrice
            )
            createdCount = 1
        } catch {
            return (0, ["\(label)更新失败：\(error.localizedDescription)"])
        }

        for oldOrder in oldOrders {
            do {
                try await cancelPendingOrder(
                    oldOrder,
                    environment: environment,
                    market: .perpetual
                )
            } catch {
                failures.append("旧\(label)单 #\(oldOrder.orderId) 撤销失败：\(error.localizedDescription)")
            }
        }
        return (createdCount, failures)
    }

    private func placeFuturesProtectionOrder(
        environment: TradingEnvironment,
        symbol: String,
        direction: PositionDirection,
        isHedgeMode: Bool,
        type: String,
        triggerPrice: Decimal
    ) async throws {
        var parameters = [
            "algoType": "CONDITIONAL",
            "symbol": symbol,
            "side": direction == .long ? "SELL" : "BUY",
            "type": type,
            "triggerPrice": triggerPrice.plainString,
            "workingType": "MARK_PRICE",
            "priceProtect": "true",
            "closePosition": "true",
            "newOrderRespType": "RESULT"
        ]
        if isHedgeMode {
            parameters["positionSide"] = direction == .long ? "LONG" : "SHORT"
        } else {
            parameters["positionSide"] = "BOTH"
        }
        _ = try await signedRequest(
            environment: environment,
            market: .perpetual,
            method: "POST",
            path: "/fapi/v1/algoOrder",
            parameters: &parameters
        )
    }

    private func normalizedProtectionPrices(
        takeProfitPrice: Decimal?,
        stopLossPrice: Decimal?,
        market: MarketType,
        direction: PositionDirection,
        symbolInfo: SymbolInfo,
        referencePrices: [Decimal]
    ) throws -> ProtectionPrices {
        let validReferences = referencePrices.filter { $0 > 0 }
        guard let minimumReference = validReferences.min(),
              let maximumReference = validReferences.max() else {
            throw BinanceTradingError.invalidResponse
        }
        let isLong = market == .spot || direction == .long
        let takeProfit = try takeProfitPrice.map {
            try normalizedPrice($0, symbolInfo: symbolInfo)
        }
        let stopLoss = try stopLossPrice.map {
            try normalizedPrice($0, symbolInfo: symbolInfo)
        }

        if let takeProfit {
            if isLong && takeProfit <= maximumReference {
                throw BinanceTradingError.invalidProtectionPrice("做多/现货的止盈价必须高于入场价及当前价")
            }
            if !isLong && takeProfit >= minimumReference {
                throw BinanceTradingError.invalidProtectionPrice("做空的止盈价必须低于入场价及当前价")
            }
        }
        if let stopLoss {
            if isLong && stopLoss >= minimumReference {
                throw BinanceTradingError.invalidProtectionPrice("做多/现货的止损价必须低于入场价及当前价")
            }
            if !isLong && stopLoss <= maximumReference {
                throw BinanceTradingError.invalidProtectionPrice("做空的止损价必须高于入场价及当前价")
            }
        }
        return ProtectionPrices(takeProfit: takeProfit, stopLoss: stopLoss)
    }

    // MARK: - Account and trade data

    private func fetchAccount(environment: TradingEnvironment, market: MarketType) async throws -> TradingAccountSnapshot {
        try await fetchAccountData(environment: environment, market: market).snapshot
    }

    private func fetchAccountData(
        environment: TradingEnvironment,
        market: MarketType
    ) async throws -> AccountData {
        switch market {
        case .spot:
            let dto = try await fetchSpotAccountDTO(environment: environment)
            return AccountData(
                snapshot: TradingAccountSnapshot(
                    canTrade: dto.canTrade,
                    spotBalances: dto.balances.map {
                        TradingBalance(asset: $0.asset, free: decimal($0.free), locked: decimal($0.locked))
                    }.filter { $0.total != 0 }.sorted { $0.asset < $1.asset },
                    spotPositions: [],
                    futuresWalletBalance: 0,
                    futuresAvailableBalance: 0,
                    futuresUnrealizedPnL: 0,
                    futuresPositions: []
                ),
                leverageBySymbol: [:]
            )
        case .perpetual:
            let dto = try await fetchFuturesAccountDTO(environment: environment)
            let positionRisks = try await fetchFuturesPositionRisks(environment: environment)
            let leverageBySymbol = dto.positions.reduce(into: [String: Int]()) { result, position in
                if let leverage = Int(position.leverage), leverage > 0 {
                    result[position.symbol] = leverage
                }
            }
            return AccountData(
                snapshot: TradingAccountSnapshot(
                    canTrade: dto.canTrade,
                    spotBalances: [],
                    spotPositions: [],
                    futuresWalletBalance: decimal(dto.totalWalletBalance),
                    futuresAvailableBalance: decimal(dto.availableBalance),
                    futuresUnrealizedPnL: decimal(dto.totalUnrealizedProfit),
                    futuresPositions: positionRisks.map { risk in
                        let accountPosition = dto.positions.first {
                            $0.symbol == risk.symbol && $0.positionSide == risk.positionSide
                        }
                        return FuturesPosition(
                            symbol: risk.symbol,
                            positionSide: risk.positionSide,
                            amount: decimal(risk.positionAmt),
                            entryPrice: decimal(risk.entryPrice),
                            markPrice: decimal(risk.markPrice),
                            notionalValue: decimal(risk.notional),
                            initialMargin: decimal(risk.initialMargin),
                            unrealizedPnL: decimal(risk.unRealizedProfit),
                            liquidationPrice: decimal(risk.liquidationPrice),
                            marginAsset: risk.marginAsset,
                            leverage: Int(accountPosition?.leverage ?? "0") ?? 0,
                            isolated: accountPosition?.isolated ?? false
                        )
                    }.filter { $0.amount != 0 }
                ),
                leverageBySymbol: leverageBySymbol
            )
        }
    }

    /// Spot has balances rather than a futures-style position endpoint. Build
    /// position rows from every non-USDT balance and enrich them with the
    /// latest USDT ticker. Cost/PnL becomes available once that pair's trade
    /// history has been loaded (the selected pair is always loaded).
    private func enrichingSpotAccount(
        _ account: TradingAccountSnapshot,
        environment: TradingEnvironment
    ) async -> TradingAccountSnapshot {
        let prices = (try? await fetchAllSpotPrices(environment: environment)) ?? [:]
        let positionBalances = account.spotBalances
            .filter { $0.asset != "USDT" && $0.total > 0 }
            .sorted { lhs, rhs in
                let lhsValue = (prices["\(lhs.asset)USDT"] ?? 0) * lhs.total
                let rhsValue = (prices["\(rhs.asset)USDT"] ?? 0) * rhs.total
                return lhsValue == rhsValue ? lhs.asset < rhs.asset : lhsValue > rhsValue
            }

        // Populate several missing cost histories per refresh. The selected
        // pair was already loaded above, and caching prevents repeated calls.
        // Limiting each batch avoids a burst when an account contains dust in
        // many assets; subsequent 10-second refreshes continue the queue.
        var remainingCostLoads = 6
        for balance in positionBalances where remainingCostLoads > 0 {
            let symbol = "\(balance.asset)USDT"
            let historyIsMissing = withStateLock { spotTradeHistory[symbol] == nil }
            guard prices[symbol] != nil, historyIsMissing else { continue }
            if let trades = try? await fetchTrades(
                environment: environment,
                market: .spot,
                symbol: symbol,
                limit: 1000
            ) {
                withStateLock {
                    spotTradeHistory[symbol] = trades
                }
            }
            remainingCostLoads -= 1
        }

        let positions = positionBalances
            .map { balance -> SpotPosition in
                let symbol = "\(balance.asset)USDT"
                let cachedState = withStateLock {
                    (
                        spotTradeHistory[symbol],
                        spotOrderAverageCosts[spotCostKey(environment: environment, symbol: symbol)]
                    )
                }
                let averageCost = cachedState.0.flatMap {
                    spotAverageCost(from: $0, baseAsset: balance.asset)
                } ?? cachedState.1
                return SpotPosition(
                    asset: balance.asset,
                    symbol: symbol,
                    free: balance.free,
                    locked: balance.locked,
                    averageCost: averageCost,
                    currentPrice: prices[symbol],
                    hasLoadedTradeHistory: cachedState.0 != nil
                )
            }
            .sorted { lhs, rhs in
                let lhsValue = lhs.marketValue ?? 0
                let rhsValue = rhs.marketValue ?? 0
                return lhsValue == rhsValue ? lhs.asset < rhs.asset : lhsValue > rhsValue
            }

        return TradingAccountSnapshot(
            canTrade: account.canTrade,
            spotBalances: account.spotBalances,
            spotPositions: positions,
            futuresWalletBalance: account.futuresWalletBalance,
            futuresAvailableBalance: account.futuresAvailableBalance,
            futuresUnrealizedPnL: account.futuresUnrealizedPnL,
            futuresPositions: account.futuresPositions
        )
    }

    private func fetchAllSpotPrices(environment: TradingEnvironment) async throws -> [String: Decimal] {
        let data = try await publicRequest(
            environment: environment,
            market: .spot,
            path: "/api/v3/ticker/price",
            parameters: [:]
        )
        return try decode([SpotTickerPriceDTO].self, from: data).reduce(into: [:]) { result, ticker in
            result[ticker.symbol] = decimal(ticker.price)
        }
    }

    /// Weighted-average inventory cost. Sells remove the proportional cost of
    /// the sold quantity. Deposited or test-granted assets legitimately have no
    /// trade-derived cost, so the UI shows their PnL as unavailable.
    private func spotAverageCost(from trades: [TradeRecord], baseAsset: String) -> Decimal? {
        var inventory: Decimal = 0
        var inventoryCost: Decimal = 0
        var totalBoughtQuantity: Decimal = 0
        var totalBoughtCost: Decimal = 0

        for trade in trades.sorted(by: { $0.time < $1.time }) {
            if trade.isBuyer {
                let baseCommission = trade.commissionAsset == baseAsset ? trade.commission : 0
                let received = max(trade.quantity - baseCommission, 0)
                let quoteCommission = trade.commissionAsset == "USDT" ? trade.commission : 0
                inventory += received
                inventoryCost += trade.quoteQuantity + quoteCommission
                totalBoughtQuantity += received
                totalBoughtCost += trade.quoteQuantity + quoteCommission
            } else if inventory > 0 {
                let baseCommission = trade.commissionAsset == baseAsset ? trade.commission : 0
                let removed = min(trade.quantity + baseCommission, inventory)
                inventoryCost -= inventoryCost / inventory * removed
                inventory -= removed
                if inventory <= 0 {
                    inventory = 0
                    inventoryCost = 0
                }
            }
        }

        if inventory > 0, inventoryCost > 0 {
            return inventoryCost / inventory
        }
        // The API returns only the most recent trades. If that window starts
        // after an older acquisition, proportional inventory reconstruction
        // can reach zero even though the account still holds the asset. A
        // weighted average of the available BUY executions is the safest
        // transparent fallback and avoids leaving the cost column blank.
        guard totalBoughtQuantity > 0, totalBoughtCost > 0 else { return nil }
        return totalBoughtCost / totalBoughtQuantity
    }

    private func spotCostKey(environment: TradingEnvironment, symbol: String) -> String {
        "\(environment.rawValue):\(symbol)"
    }

    private func fetchSpotAccountDTO(environment: TradingEnvironment) async throws -> SpotAccountDTO {
        var parameters = ["omitZeroBalances": "true"]
        let data = try await signedRequest(
            environment: environment,
            market: .spot,
            method: "GET",
            path: "/api/v3/account",
            parameters: &parameters
        )
        return try decode(SpotAccountDTO.self, from: data)
    }

    private func fetchFuturesAccountDTO(environment: TradingEnvironment) async throws -> FuturesAccountDTO {
        var parameters: [String: String] = [:]
        let data = try await signedRequest(
            environment: environment,
            market: .perpetual,
            method: "GET",
            path: "/fapi/v2/account",
            parameters: &parameters
        )
        return try decode(FuturesAccountDTO.self, from: data)
    }

    private func fetchFuturesPositionRisks(environment: TradingEnvironment) async throws -> [FuturesPositionRiskDTO] {
        var parameters: [String: String] = [:]
        let data = try await signedRequest(
            environment: environment,
            market: .perpetual,
            method: "GET",
            path: "/fapi/v3/positionRisk",
            parameters: &parameters
        )
        return try decode([FuturesPositionRiskDTO].self, from: data)
    }

    private func fetchMarkPrice(environment: TradingEnvironment, symbol: String) async throws -> Decimal {
        let data = try await publicRequest(
            environment: environment,
            market: .perpetual,
            path: "/fapi/v1/premiumIndex",
            parameters: ["symbol": symbol]
        )
        return decimal(try decode(MarkPriceDTO.self, from: data).markPrice)
    }

    private func fetchSpotPrice(environment: TradingEnvironment, symbol: String) async throws -> Decimal {
        let data = try await publicRequest(
            environment: environment,
            market: .spot,
            path: "/api/v3/ticker/price",
            parameters: ["symbol": symbol]
        )
        let price = decimal(try decode(SpotTickerPriceDTO.self, from: data).price)
        guard price > 0 else { throw BinanceTradingError.invalidResponse }
        return price
    }

    private func changeLeverage(environment: TradingEnvironment, symbol: String, leverage: Int) async throws {
        var parameters = ["symbol": symbol, "leverage": String(leverage)]
        _ = try await signedRequest(
            environment: environment,
            market: .perpetual,
            method: "POST",
            path: "/fapi/v1/leverage",
            parameters: &parameters
        )
    }

    private func fetchTrades(
        environment: TradingEnvironment,
        market: MarketType,
        symbol: String,
        limit: Int
    ) async throws -> [TradeRecord] {
        var parameters = ["symbol": symbol, "limit": String(min(max(limit, 1), 1000))]
        let path = market == .spot ? "/api/v3/myTrades" : "/fapi/v1/userTrades"
        let data = try await signedRequest(
            environment: environment,
            market: market,
            method: "GET",
            path: path,
            parameters: &parameters
        )
        let records = try decode([TradeDTO].self, from: data)
        return records.map {
            let quantity = decimal($0.qty)
            let price = decimal($0.price)
            return TradeRecord(
                id: $0.id,
                orderId: $0.orderId,
                symbol: $0.symbol ?? symbol,
                time: Date(timeIntervalSince1970: TimeInterval($0.time) / 1000),
                isBuyer: $0.isBuyer ?? $0.buyer ?? false,
                price: price,
                quantity: quantity,
                quoteQuantity: decimal($0.quoteQty) == 0 ? price * quantity : decimal($0.quoteQty),
                commission: decimal($0.commission),
                commissionAsset: $0.commissionAsset,
                realizedPnL: $0.realizedPnl.map(decimal),
                positionSide: $0.positionSide
            )
        }
    }

    private func fetchPendingOrders(
        environment: TradingEnvironment,
        market: MarketType,
        leverageBySymbol: [String: Int]
    ) async throws -> [PendingOrder] {
        var parameters: [String: String] = [:]
        let path = market == .spot ? "/api/v3/openOrders" : "/fapi/v1/openOrders"
        let data = try await signedRequest(
            environment: environment,
            market: market,
            method: "GET",
            path: path,
            parameters: &parameters
        )
        let regularOrders = try decode([OpenOrderDTO].self, from: data).map { order in
            let createdMilliseconds = order.time ?? order.updateTime ?? 0
            let updatedMilliseconds = order.updateTime ?? order.time ?? 0
            var pendingOrder = PendingOrder(
                id: "regular-\(order.symbol)-\(order.orderId)",
                orderId: String(order.orderId),
                symbol: order.symbol,
                side: order.side,
                positionSide: order.positionSide,
                type: order.origType ?? order.type,
                status: order.status,
                timeInForce: order.timeInForce,
                price: decimal(order.price),
                triggerPrice: decimal(order.stopPrice),
                originalQuantity: decimal(order.origQty),
                executedQuantity: decimal(order.executedQty),
                reduceOnly: order.reduceOnly ?? false,
                closePosition: order.closePosition ?? false,
                createdAt: date(milliseconds: createdMilliseconds),
                updatedAt: date(milliseconds: updatedMilliseconds)
            )
            pendingOrder.orderListId = order.orderListId
            return pendingOrder
        }

        guard market == .perpetual else {
            return await enrichPendingOrders(
                regularOrders,
                environment: environment,
                market: market,
                leverageBySymbol: leverageBySymbol
            )
        }

        // USDⓈ-M 新版接口将止盈止损、条件单和追踪委托单独归入 Algo Orders。
        // 测试网可能暂未开放该接口，因此失败时仍保留普通待成交订单。
        var algoParameters: [String: String] = [:]
        do {
            let algoData = try await signedRequest(
                environment: environment,
                market: market,
                method: "GET",
                path: "/fapi/v1/openAlgoOrders",
                parameters: &algoParameters
            )
            let algoOrders = try decodeFuturesAlgoPendingOrders(from: algoData)
            return await enrichPendingOrders(
                regularOrders + algoOrders,
                environment: environment,
                market: market,
                leverageBySymbol: leverageBySymbol
            )
        } catch {
            #if DEBUG
            print("⚠️ [BinanceTradingService] 开放 Algo 委托拉取失败，尝试历史接口回填: \(error.localizedDescription)")
            #endif
            let fallbackAlgoOrders = await fetchActiveAlgoOrderFallback(
                environment: environment,
                market: market,
                symbols: Set(regularOrders.map(\.symbol))
            )
            return await enrichPendingOrders(
                regularOrders + fallbackAlgoOrders,
                environment: environment,
                market: market,
                leverageBySymbol: leverageBySymbol
            )
        }
    }

    private func fetchActiveAlgoOrderFallback(
        environment: TradingEnvironment,
        market: MarketType,
        symbols: Set<String>
    ) async -> [PendingOrder] {
        var result: [PendingOrder] = []
        for symbol in symbols {
            var parameters = ["symbol": symbol, "limit": "100"]
            guard let data = try? await signedRequest(
                environment: environment,
                market: market,
                method: "GET",
                path: "/fapi/v1/allAlgoOrders",
                parameters: &parameters
            ), let orders = try? decodeFuturesAlgoPendingOrders(from: data) else {
                continue
            }
            result.append(contentsOf: orders.filter { isActiveAlgoStatus($0.status) })
        }
        return result.reduce(into: [PendingOrder]()) { unique, order in
            if !unique.contains(where: { $0.id == order.id }) { unique.append(order) }
        }
    }

    private func decodeFuturesAlgoPendingOrders(from data: Data) throws -> [PendingOrder] {
        try decode([FuturesAlgoOpenOrderDTO].self, from: data).compactMap { order in
            guard let algoId = order.algoId,
                  algoId > 0,
                  let orderType = order.orderType,
                  let symbol = order.symbol,
                  !symbol.isEmpty,
                  let side = order.side,
                  !side.isEmpty else {
                #if DEBUG
                print("⚠️ [BinanceTradingService] 忽略字段不完整的合约 Algo 委托")
                #endif
                return nil
            }
            return PendingOrder(
                id: "algo-\(symbol)-\(algoId)",
                orderId: String(algoId),
                symbol: symbol,
                side: side,
                positionSide: order.positionSide,
                type: orderType,
                status: order.algoStatus ?? "NEW",
                timeInForce: order.timeInForce,
                price: decimal(order.price),
                triggerPrice: decimal(order.triggerPrice),
                originalQuantity: decimal(order.quantity),
                executedQuantity: 0,
                reduceOnly: order.reduceOnly ?? false,
                closePosition: order.closePosition ?? false,
                createdAt: date(milliseconds: order.createTime ?? order.updateTime ?? 0),
                updatedAt: date(milliseconds: order.updateTime ?? order.createTime ?? 0)
            )
        }
    }

    private func isActiveAlgoStatus(_ status: String) -> Bool {
        ["NEW", "PENDING_NEW", "PARTIALLY_FILLED"].contains(status.uppercased())
    }

    private func enrichPendingOrders(
        _ pendingOrders: [PendingOrder],
        environment: TradingEnvironment,
        market: MarketType,
        leverageBySymbol: [String: Int]
    ) async -> [PendingOrder] {
        let symbols = Set(pendingOrders.map(\.symbol))
        var ratesBySymbol: [String: OrderCommissionRates] = [:]
        for symbol in symbols {
            if let rates = try? await commissionRates(
                environment: environment,
                market: market,
                symbol: symbol
            ) {
                ratesBySymbol[symbol] = rates
            }
        }

        var enriched = pendingOrders.map { order -> PendingOrder in
            var order = order
            let protectionPrice = order.triggerPrice > 0 ? order.triggerPrice : order.price
            if protectionPrice > 0 {
                switch protectionKind(for: order.type) {
                case .takeProfit:
                    order.takeProfitPrices = [protectionPrice]
                case .stopLoss:
                    order.stopLossPrices = [protectionPrice]
                case nil:
                    break
                }
            }

            if market == .perpetual {
                order.leverage = leverageBySymbol[order.symbol]
            }

            let valuationPrice = order.price > 0 ? order.price : order.triggerPrice
            let remainingNotional = valuationPrice > 0 && order.remainingQuantity > 0
                ? valuationPrice * order.remainingQuantity
                : 0
            if remainingNotional > 0,
               let rates = ratesBySymbol[order.symbol] {
                let isMakerEstimate = (order.type == "LIMIT" || order.type == "LIMIT_MAKER")
                    && order.triggerPrice == 0
                let rate = rates.rate(isMaker: isMakerEstimate, isBuyer: order.side == "BUY")
                if rate > 0 {
                    order.estimatedCommission = remainingNotional * rate
                    order.estimatedCommissionAsset = order.symbol.hasSuffix("USDT") ? "USDT" : nil
                }
            }

            if market == .perpetual,
               !isProtectionCandidate(order, market: market),
               !order.reduceOnly,
               !order.closePosition,
               let leverage = order.leverage,
               leverage > 0,
               remainingNotional > 0 {
                order.estimatedMargin = remainingNotional / Decimal(leverage)
            }
            return order
        }

        let protections = enriched.filter { isProtectionCandidate($0, market: market) }
        enriched = enriched.map { order -> PendingOrder in
            guard !isProtectionCandidate(order, market: market) else { return order }

            let matches: [PendingOrder]
            switch market {
            case .spot:
                guard let orderListId = order.orderListId, orderListId >= 0 else { return order }
                matches = protections.filter { $0.orderListId == orderListId }
            case .perpetual:
                let direction = pendingOrderDirection(order, isProtection: false)
                matches = protections.filter {
                    $0.symbol == order.symbol
                        && pendingOrderDirection($0, isProtection: true) == direction
                }
            }

            var order = order
            order.takeProfitPrices = uniqueSortedPrices(
                order.takeProfitPrices
                    + matches.flatMap(\.takeProfitPrices)
            )
            order.stopLossPrices = uniqueSortedPrices(
                order.stopLossPrices
                    + matches.flatMap(\.stopLossPrices)
            )
            return order
        }

        return enriched.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func commissionRates(
        environment: TradingEnvironment,
        market: MarketType,
        symbol: String
    ) async throws -> OrderCommissionRates {
        let cacheKey = "\(environment.rawValue):\(market.rawValue):\(symbol)"
        let now = Date()
        if let cached = withStateLock({ commissionRateCache[cacheKey] }),
           now.timeIntervalSince(cached.fetchedAt) < commissionRateCacheLifetime {
            guard let rates = cached.rates else { throw BinanceTradingError.invalidResponse }
            return rates
        }

        do {
            var parameters = ["symbol": symbol]
            let path = market == .spot ? "/api/v3/account/commission" : "/fapi/v1/commissionRate"
            let data = try await signedRequest(
                environment: environment,
                market: market,
                method: "GET",
                path: path,
                parameters: &parameters
            )
            let rates: OrderCommissionRates
            switch market {
            case .spot:
                let dto = try decode(SpotCommissionRateDTO.self, from: data)
                rates = OrderCommissionRates(
                    makerBuyer: dto.totalRate(isMaker: true, isBuyer: true, decimal: decimal),
                    makerSeller: dto.totalRate(isMaker: true, isBuyer: false, decimal: decimal),
                    takerBuyer: dto.totalRate(isMaker: false, isBuyer: true, decimal: decimal),
                    takerSeller: dto.totalRate(isMaker: false, isBuyer: false, decimal: decimal)
                )
            case .perpetual:
                let dto = try decode(FuturesCommissionRateDTO.self, from: data)
                let maker = decimal(dto.makerCommissionRate)
                let taker = decimal(dto.takerCommissionRate)
                rates = OrderCommissionRates(
                    makerBuyer: maker,
                    makerSeller: maker,
                    takerBuyer: taker,
                    takerSeller: taker
                )
            }
            withStateLock {
                commissionRateCache[cacheKey] = CachedCommissionRates(rates: rates, fetchedAt: now)
            }
            return rates
        } catch {
            // Cache unsupported/testnet failures too; otherwise the 10-second
            // dashboard refresh would repeatedly hit this weight-20 endpoint.
            withStateLock {
                commissionRateCache[cacheKey] = CachedCommissionRates(rates: nil, fetchedAt: now)
            }
            throw error
        }
    }

    private func isProtectionCandidate(_ order: PendingOrder, market: MarketType) -> Bool {
        guard protectionKind(for: order.type) != nil else { return false }
        switch market {
        case .spot:
            return order.side == "SELL"
        case .perpetual:
            return order.reduceOnly || order.closePosition
        }
    }

    private func protectionKind(for type: String) -> ProtectionKind? {
        if type.contains("TAKE_PROFIT") { return .takeProfit }
        if type.contains("STOP") { return .stopLoss }
        return nil
    }

    private func pendingOrderDirection(_ order: PendingOrder, isProtection: Bool) -> String {
        if order.positionSide == "LONG" || order.positionSide == "SHORT" {
            return order.positionSide ?? ""
        }
        if isProtection {
            return order.side == "SELL" ? "LONG" : "SHORT"
        }
        return order.side == "BUY" ? "LONG" : "SHORT"
    }

    private func uniqueSortedPrices(_ prices: [Decimal]) -> [Decimal] {
        prices.reduce(into: [Decimal]()) { result, price in
            if price > 0, !result.contains(price) { result.append(price) }
        }
        .sorted()
    }

    private func fetchHedgeMode(environment: TradingEnvironment) async throws -> Bool {
        var parameters: [String: String] = [:]
        let data = try await signedRequest(
            environment: environment,
            market: .perpetual,
            method: "GET",
            path: "/fapi/v1/positionSide/dual",
            parameters: &parameters
        )
        return try decode(PositionModeDTO.self, from: data).dualSidePosition
    }

    // MARK: - Symbol rules

    private func fetchSymbolInfo(environment: TradingEnvironment, market: MarketType, symbol: String) async throws -> SymbolInfo {
        let path = market == .spot ? "/api/v3/exchangeInfo" : "/fapi/v1/exchangeInfo"
        let data = try await publicRequest(
            environment: environment,
            market: market,
            path: path,
            parameters: ["symbol": symbol]
        )
        let exchangeInfo = try decode(ExchangeInfoDTO.self, from: data)
        guard let item = exchangeInfo.symbols.first(where: { $0.symbol == symbol }) else {
            throw BinanceTradingError.invalidSymbol
        }
        let lot = item.filters.first(where: { $0.filterType == "LOT_SIZE" })
        let marketLot = item.filters.first(where: { $0.filterType == "MARKET_LOT_SIZE" && decimal($0.stepSize) > 0 })
        let priceFilter = item.filters.first(where: { $0.filterType == "PRICE_FILTER" })
        guard let lot, let priceFilter else { throw BinanceTradingError.invalidResponse }
        return SymbolInfo(
            baseAsset: item.baseAsset,
            quoteAsset: item.quoteAsset,
            minimumQuantity: decimal(lot.minQty),
            maximumQuantity: decimal(lot.maxQty),
            stepSize: decimal(lot.stepSize),
            marketMinimumQuantity: decimal(marketLot?.minQty),
            marketMaximumQuantity: decimal(marketLot?.maxQty),
            marketStepSize: decimal(marketLot?.stepSize),
            minimumPrice: decimal(priceFilter.minPrice),
            maximumPrice: decimal(priceFilter.maxPrice),
            tickSize: decimal(priceFilter.tickSize)
        )
    }

    private func normalizedQuantity(
        _ quantity: Decimal,
        symbolInfo: SymbolInfo,
        orderType: TradingOrderType
    ) throws -> Decimal {
        let useMarketRules = orderType == .market && symbolInfo.marketStepSize > 0
        let stepSize = useMarketRules ? symbolInfo.marketStepSize : symbolInfo.stepSize
        let minimum = useMarketRules ? symbolInfo.marketMinimumQuantity : symbolInfo.minimumQuantity
        let maximum = useMarketRules ? symbolInfo.marketMaximumQuantity : symbolInfo.maximumQuantity
        guard quantity > 0, stepSize > 0 else { throw BinanceTradingError.invalidQuantity }
        let units = quantity / stepSize
        var roundedUnits = Decimal()
        var value = units
        NSDecimalRound(&roundedUnits, &value, 0, .down)
        let result = roundedUnits * stepSize
        guard result >= minimum,
              maximum == 0 || result <= maximum else {
            throw BinanceTradingError.invalidQuantity
        }
        return result
    }

    private func normalizedPrice(_ price: Decimal, symbolInfo: SymbolInfo) throws -> Decimal {
        guard price > 0, symbolInfo.tickSize > 0 else { throw BinanceTradingError.invalidPrice }
        let units = price / symbolInfo.tickSize
        var roundedUnits = Decimal()
        var value = units
        NSDecimalRound(&roundedUnits, &value, 0, .down)
        let result = roundedUnits * symbolInfo.tickSize
        guard result >= symbolInfo.minimumPrice,
              symbolInfo.maximumPrice == 0 || result <= symbolInfo.maximumPrice else {
            throw BinanceTradingError.invalidPrice
        }
        return result
    }

    private func matchingPosition(
        in positions: [FuturesPositionDTO],
        symbol: String,
        direction: PositionDirection,
        hedgeMode: Bool
    ) -> FuturesPositionDTO? {
        if hedgeMode {
            let side = direction == .long ? "LONG" : "SHORT"
            return positions.first { $0.symbol == symbol && $0.positionSide == side && decimal($0.positionAmt) != 0 }
        }
        return positions.first {
            guard $0.symbol == symbol && $0.positionSide == "BOTH" else { return false }
            let amount = decimal($0.positionAmt)
            return direction == .long ? amount > 0 : amount < 0
        }
    }

    // MARK: - HTTP and signing

    private func signedRequest(
        environment: TradingEnvironment,
        market: MarketType,
        method: String,
        path: String,
        parameters: inout [String: String]
    ) async throws -> Data {
        let scope = TradingCredentialScope(environment: environment, market: market)
        guard let credentials = try credentialStore.credentials(for: scope), credentials.isComplete else {
            throw BinanceTradingError.missingCredentials
        }

        let offset = try await serverTimeOffset(environment: environment, market: market)
        parameters["timestamp"] = String(Int64(Date().timeIntervalSince1970 * 1000) + offset)
        parameters["recvWindow"] = "5000"
        let payload = encodedQuery(parameters)
        let signature = hmacSHA256(payload, secret: credentials.secretKey)
        let signedPayload = "\(payload)&signature=\(signature)"
        let baseURL = baseURL(environment: environment, market: market)

        guard var components = URLComponents(string: baseURL + path) else {
            throw BinanceTradingError.invalidResponse
        }
        var request: URLRequest
        if method == "GET" || method == "DELETE" {
            components.percentEncodedQuery = signedPayload
            guard let url = components.url else { throw BinanceTradingError.invalidResponse }
            request = URLRequest(url: url)
        } else {
            guard let url = components.url else { throw BinanceTradingError.invalidResponse }
            request = URLRequest(url: url)
            request.httpBody = Data(signedPayload.utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(credentials.apiKey, forHTTPHeaderField: "X-MBX-APIKEY")
        return try await execute(request)
    }

    private func publicRequest(
        environment: TradingEnvironment,
        market: MarketType,
        path: String,
        parameters: [String: String]
    ) async throws -> Data {
        guard var components = URLComponents(string: baseURL(environment: environment, market: market) + path) else {
            throw BinanceTradingError.invalidResponse
        }
        components.percentEncodedQuery = encodedQuery(parameters)
        guard let url = components.url else { throw BinanceTradingError.invalidResponse }
        return try await execute(URLRequest(url: url))
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BinanceTradingError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder().decode(APIErrorDTO.self, from: data) {
                throw BinanceTradingError.api(code: apiError.code, message: apiError.msg)
            }
            throw BinanceTradingError.api(code: http.statusCode, message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return data
    }

    private func serverTimeOffset(environment: TradingEnvironment, market: MarketType) async throws -> Int64 {
        let cacheKey = "\(environment.rawValue).\(market.rawValue)"
        if let offset = withStateLock({ timeOffsets[cacheKey] }) { return offset }
        let path = market == .spot ? "/api/v3/time" : "/fapi/v1/time"
        let started = Int64(Date().timeIntervalSince1970 * 1000)
        let data = try await publicRequest(environment: environment, market: market, path: path, parameters: [:])
        let finished = Int64(Date().timeIntervalSince1970 * 1000)
        let serverTime = try decode(ServerTimeDTO.self, from: data).serverTime
        let offset = serverTime - ((started + finished) / 2)
        withStateLock {
            timeOffsets[cacheKey] = offset
        }
        return offset
    }

    private func withStateLock<T>(_ operation: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operation()
    }

    private func baseURL(environment: TradingEnvironment, market: MarketType) -> String {
        switch (environment, market) {
        case (.mainnet, .spot): return "https://api.binance.com"
        case (.testnet, .spot): return "https://testnet.binance.vision"
        case (.mainnet, .perpetual): return "https://fapi.binance.com"
        case (.testnet, .perpetual): return "https://testnet.binancefuture.com"
        }
    }

    private static func makeSession(
        proxyEnabled: Bool,
        proxyHost: String,
        proxyPort: Int,
        proxyUsername: String,
        proxyPassword: String
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        if proxyEnabled {
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": proxyHost,
                "HTTPPort": proxyPort,
                "HTTPSEnable": 1,
                "HTTPSProxy": proxyHost,
                "HTTPSPort": proxyPort
            ]
            if !proxyUsername.isEmpty && !proxyPassword.isEmpty {
                let credential = URLCredential(
                    user: proxyUsername,
                    password: proxyPassword,
                    persistence: .forSession
                )
                URLCredentialStorage.shared.setDefaultCredential(
                    credential,
                    for: URLProtectionSpace(
                        host: proxyHost,
                        port: proxyPort,
                        protocol: "https",
                        realm: nil,
                        authenticationMethod: NSURLAuthenticationMethodHTTPBasic
                    )
                )
            }
        }
        return URLSession(configuration: configuration)
    }

    private func encodedQuery(_ parameters: [String: String]) -> String {
        parameters.keys.sorted().map { key in
            "\(percentEncode(key))=\(percentEncode(parameters[key] ?? ""))"
        }.joined(separator: "&")
    }

    private func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func hmacSHA256(_ payload: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        return authenticationCode.map { String(format: "%02x", $0) }.joined()
    }

    private func normalizeSymbol(_ symbol: String) throws -> String {
        let normalized = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let valid = normalized.range(of: "^[A-Z0-9]{5,20}$", options: .regularExpression) != nil
        guard valid else { throw BinanceTradingError.invalidSymbol }
        return normalized
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            #if DEBUG
            print("❌ [BinanceTradingService] 解码失败: \(error)")
            #endif
            throw BinanceTradingError.invalidResponse
        }
    }

    private func decimal(_ value: String?) -> Decimal {
        guard let value else { return 0 }
        return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    private func date(milliseconds: Int64) -> Date {
        guard milliseconds > 0 else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}

private struct AccountData {
    let snapshot: TradingAccountSnapshot
    let leverageBySymbol: [String: Int]
}

private struct OrderCommissionRates {
    let makerBuyer: Decimal
    let makerSeller: Decimal
    let takerBuyer: Decimal
    let takerSeller: Decimal

    func rate(isMaker: Bool, isBuyer: Bool) -> Decimal {
        switch (isMaker, isBuyer) {
        case (true, true): return makerBuyer
        case (true, false): return makerSeller
        case (false, true): return takerBuyer
        case (false, false): return takerSeller
        }
    }
}

private struct CachedCommissionRates {
    let rates: OrderCommissionRates?
    let fetchedAt: Date
}

private enum ProtectionKind {
    case takeProfit
    case stopLoss
}

// MARK: - Binance REST DTOs

private struct APIErrorDTO: Decodable { let code: Int; let msg: String }
private struct ServerTimeDTO: Decodable { let serverTime: Int64 }
private struct PositionModeDTO: Decodable { let dualSidePosition: Bool }
private struct MarkPriceDTO: Decodable { let markPrice: String }
private struct SpotTickerPriceDTO: Decodable {
    let symbol: String
    let price: String
}

private struct SpotAccountDTO: Decodable {
    let canTrade: Bool
    let balances: [SpotBalanceDTO]
}

private struct SpotCommissionComponentDTO: Decodable {
    let maker: String
    let taker: String
    let buyer: String
    let seller: String

    func rate(
        isMaker: Bool,
        isBuyer: Bool,
        decimal: (String?) -> Decimal
    ) -> Decimal {
        decimal(isMaker ? maker : taker) + decimal(isBuyer ? buyer : seller)
    }
}

private struct SpotCommissionRateDTO: Decodable {
    let standardCommission: SpotCommissionComponentDTO
    let specialCommission: SpotCommissionComponentDTO
    let taxCommission: SpotCommissionComponentDTO

    func totalRate(
        isMaker: Bool,
        isBuyer: Bool,
        decimal: (String?) -> Decimal
    ) -> Decimal {
        standardCommission.rate(isMaker: isMaker, isBuyer: isBuyer, decimal: decimal)
            + specialCommission.rate(isMaker: isMaker, isBuyer: isBuyer, decimal: decimal)
            + taxCommission.rate(isMaker: isMaker, isBuyer: isBuyer, decimal: decimal)
    }
}

private struct FuturesCommissionRateDTO: Decodable {
    let makerCommissionRate: String
    let takerCommissionRate: String
}

private struct SpotBalanceDTO: Decodable {
    let asset: String
    let free: String
    let locked: String
}

private struct FuturesAccountDTO: Decodable {
    let canTrade: Bool
    let totalWalletBalance: String
    let totalUnrealizedProfit: String
    let availableBalance: String
    let positions: [FuturesPositionDTO]
}

private struct FuturesPositionDTO: Decodable {
    let symbol: String
    let positionAmt: String
    let entryPrice: String
    let unrealizedProfit: String
    let leverage: String
    let isolated: Bool
    let positionSide: String
}

private struct FuturesPositionRiskDTO: Decodable {
    let symbol: String
    let positionSide: String
    let positionAmt: String
    let entryPrice: String
    let markPrice: String
    let unRealizedProfit: String
    let liquidationPrice: String
    let notional: String
    let marginAsset: String
    let initialMargin: String
}

private struct TradeDTO: Decodable {
    let id: Int64
    let orderId: Int64
    let symbol: String?
    let price: String
    let qty: String
    let quoteQty: String?
    let commission: String
    let commissionAsset: String
    let time: Int64
    let isBuyer: Bool?
    let buyer: Bool?
    let realizedPnl: String?
    let positionSide: String?
}

private struct OpenOrderDTO: Decodable {
    let symbol: String
    let orderId: Int64
    let price: String
    let origQty: String
    let executedQty: String
    let status: String
    let timeInForce: String?
    let type: String
    let origType: String?
    let side: String
    let stopPrice: String?
    let time: Int64?
    let updateTime: Int64?
    let positionSide: String?
    let reduceOnly: Bool?
    let closePosition: Bool?
    let orderListId: Int64?
}

private struct FuturesAlgoOpenOrderDTO: Decodable {
    let algoId: Int64?
    let orderType: String?
    let symbol: String?
    let side: String?
    let positionSide: String?
    let timeInForce: String?
    let quantity: String?
    let algoStatus: String?
    let triggerPrice: String?
    let price: String?
    let reduceOnly: Bool?
    let closePosition: Bool?
    let createTime: Int64?
    let updateTime: Int64?

    private enum CodingKeys: String, CodingKey {
        case algoId
        case orderType
        case symbol
        case side
        case positionSide
        case timeInForce
        case quantity
        case algoStatus
        case triggerPrice
        case price
        case reduceOnly
        case closePosition
        case createTime
        case updateTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        algoId = container.flexibleInt64(forKey: .algoId)
        orderType = container.flexibleString(forKey: .orderType)
        symbol = container.flexibleString(forKey: .symbol)
        side = container.flexibleString(forKey: .side)
        positionSide = container.flexibleString(forKey: .positionSide)
        timeInForce = container.flexibleString(forKey: .timeInForce)
        // Close-all TP/SL orders cannot carry quantity. Different Binance
        // environments have returned this as an omitted value, a string, or
        // a numeric zero, so decode it losslessly instead of failing the array.
        quantity = container.flexibleString(forKey: .quantity)
        algoStatus = container.flexibleString(forKey: .algoStatus)
        triggerPrice = container.flexibleString(forKey: .triggerPrice)
        price = container.flexibleString(forKey: .price)
        reduceOnly = container.flexibleBool(forKey: .reduceOnly)
        closePosition = container.flexibleBool(forKey: .closePosition)
        createTime = container.flexibleInt64(forKey: .createTime)
        updateTime = container.flexibleInt64(forKey: .updateTime)
    }
}

private extension KeyedDecodingContainer {
    func flexibleString(forKey key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Decimal.self, forKey: key) {
            return NSDecimalNumber(decimal: value).stringValue
        }
        if let value = try? decode(Bool.self, forKey: key) {
            return value ? "true" : "false"
        }
        return nil
    }

    func flexibleInt64(forKey key: Key) -> Int64? {
        if let value = try? decode(Int64.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return Int64(value) }
        return nil
    }

    func flexibleBool(forKey key: Key) -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) {
            switch value.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        if let value = try? decode(Int.self, forKey: key) { return value != 0 }
        return nil
    }
}

private struct ExchangeInfoDTO: Decodable { let symbols: [ExchangeSymbolDTO] }
private struct ExchangeSymbolDTO: Decodable {
    let symbol: String
    let baseAsset: String
    let quoteAsset: String
    let filters: [ExchangeFilterDTO]
}
private struct ExchangeFilterDTO: Decodable {
    let filterType: String
    let minQty: String?
    let maxQty: String?
    let stepSize: String?
    let minPrice: String?
    let maxPrice: String?
    let tickSize: String?
}

private struct SymbolInfo {
    let baseAsset: String
    let quoteAsset: String
    let minimumQuantity: Decimal
    let maximumQuantity: Decimal
    let stepSize: Decimal
    let marketMinimumQuantity: Decimal
    let marketMaximumQuantity: Decimal
    let marketStepSize: Decimal
    let minimumPrice: Decimal
    let maximumPrice: Decimal
    let tickSize: Decimal
}

private struct OrderResponseDTO: Decodable {
    let orderId: Int64
    let symbol: String
    let side: String
    let status: String
    let origQty: String?
    let executedQty: String?
    let avgPrice: String?
    let cummulativeQuoteQty: String?
    let cumQuote: String?
    let fills: [OrderFillDTO]?
    let transactTime: Int64?
    let updateTime: Int64?

    func result(fallbackQuantity: Decimal) -> BinanceOrderResult {
        let original = Decimal(string: origQty ?? "") ?? fallbackQuantity
        let executed = Decimal(string: executedQty ?? "") ?? 0
        let explicitAverage = Decimal(string: avgPrice ?? "").flatMap { $0 > 0 ? $0 : nil }
        let cumulativeQuote = Decimal(string: cummulativeQuoteQty ?? cumQuote ?? "") ?? 0
        let cumulativeAverage = executed > 0 && cumulativeQuote > 0 ? cumulativeQuote / executed : nil
        let fillQuantity = fills?.reduce(Decimal.zero) {
            $0 + (Decimal(string: $1.qty) ?? 0)
        } ?? 0
        let fillQuote = fills?.reduce(Decimal.zero) {
            let price = Decimal(string: $1.price) ?? 0
            let quantity = Decimal(string: $1.qty) ?? 0
            return $0 + price * quantity
        } ?? 0
        let fillAverage = fillQuantity > 0 && fillQuote > 0 ? fillQuote / fillQuantity : nil
        let price = explicitAverage ?? cumulativeAverage ?? fillAverage
        let milliseconds = transactTime ?? updateTime ?? Int64(Date().timeIntervalSince1970 * 1000)
        return BinanceOrderResult(
            orderId: orderId,
            symbol: symbol,
            side: side,
            status: status,
            requestedQuantity: original,
            executedQuantity: executed,
            averagePrice: price,
            transactionTime: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        )
    }
}

private struct SpotOrderListResponseDTO: Decodable {
    let orderReports: [OrderResponseDTO]
}

private struct ProtectionPrices {
    let takeProfit: Decimal?
    let stopLoss: Decimal?

    static let empty = ProtectionPrices(takeProfit: nil, stopLoss: nil)
    var isEmpty: Bool { takeProfit == nil && stopLoss == nil }
    var count: Int { (takeProfit == nil ? 0 : 1) + (stopLoss == nil ? 0 : 1) }
}

private struct OrderFillDTO: Decodable {
    let price: String
    let qty: String
}
