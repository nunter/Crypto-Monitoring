//
//  TradingModels.swift
//  Crypto Monitoring
//
//  Binance trading and account data models.
//

import Foundation

enum TradingEnvironment: String, CaseIterable, Codable, Identifiable {
    case testnet
    case mainnet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .testnet: return "测试网"
        case .mainnet: return "实盘"
        }
    }

    var isLive: Bool { self == .mainnet }
}

enum TradingAction: String, CaseIterable, Identifiable {
    case open
    case add
    case reduce
    case close

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .open: return "建仓"
        case .add: return "加仓"
        case .reduce: return "减仓"
        case .close: return "平仓"
        }
    }

    var isReducing: Bool { self == .reduce || self == .close }
}

enum PositionDirection: String, CaseIterable, Identifiable {
    case long
    case short

    var id: String { rawValue }
    var displayName: String { self == .long ? "做多" : "做空" }
}

enum TradingOrderType: String, CaseIterable, Identifiable {
    case market
    case limit

    var id: String { rawValue }
    var displayName: String { self == .market ? "市价" : "限价" }
    var apiValue: String { self == .market ? "MARKET" : "LIMIT" }
}

enum TradingSizingMode: String, CaseIterable, Identifiable {
    case amount
    case quantity

    var id: String { rawValue }
    var displayName: String { self == .amount ? "按金额" : "按数量" }
}

struct TradingOrderRequest {
    let symbol: String
    let market: MarketType
    let action: TradingAction
    let direction: PositionDirection
    let orderType: TradingOrderType
    /// Required for limit orders.
    let limitPrice: Decimal?
    let sizingMode: TradingSizingMode
    /// Base-asset quantity for spot orders or quantity-sized futures orders.
    let quantity: Decimal?
    /// USDT amount. Spot open/add uses quote amount; futures open/add uses margin and reduce uses notional amount.
    let amount: Decimal?
    /// Target leverage for futures open/add orders.
    let leverage: Int?
    /// Close the complete position instead of using a partial-close notional amount.
    let closeAll: Bool
    /// Optional take-profit trigger price for open/add orders.
    let takeProfitPrice: Decimal?
    /// Optional stop-loss trigger price for open/add orders.
    let stopLossPrice: Decimal?

    var hasProtection: Bool { takeProfitPrice != nil || stopLossPrice != nil }
}

struct TradingCredentialScope: Hashable {
    let environment: TradingEnvironment
    let market: MarketType

    var keychainSuffix: String { "\(environment.rawValue).\(market.rawValue)" }
}

struct BinanceCredentials {
    let apiKey: String
    let secretKey: String

    var isComplete: Bool { !apiKey.isEmpty && !secretKey.isEmpty }
}

struct BinanceOrderResult: Identifiable {
    let id = UUID()
    let orderId: Int64
    let symbol: String
    let side: String
    let status: String
    let requestedQuantity: Decimal
    let executedQuantity: Decimal
    let averagePrice: Decimal?
    let transactionTime: Date
    /// Number of TP/SL child orders successfully created.
    let protectionOrderCount: Int
    /// The entry order succeeded, but one or more requested protection orders failed.
    let protectionWarning: String?

    func withProtection(count: Int, warning: String? = nil) -> BinanceOrderResult {
        BinanceOrderResult(
            orderId: orderId,
            symbol: symbol,
            side: side,
            status: status,
            requestedQuantity: requestedQuantity,
            executedQuantity: executedQuantity,
            averagePrice: averagePrice,
            transactionTime: transactionTime,
            protectionOrderCount: count,
            protectionWarning: warning
        )
    }
}

struct ProtectionOrderResult {
    let createdCount: Int
    let warning: String?
}

struct BinanceCredentialPreview {
    let maskedApiKey: String
    let maskedSecretKey: String
    let canDelete: Bool
}

struct TradingBalance: Identifiable, Codable {
    var id: String { asset }
    let asset: String
    let free: Decimal
    let locked: Decimal
    var total: Decimal { free + locked }
}

/// A non-quote spot balance presented as a position.
/// Binance Spot does not expose a native position object, so quantity comes
/// from the account balance while price and cost are derived separately.
struct SpotPosition: Identifiable, Codable {
    var id: String { asset }
    let asset: String
    let symbol: String
    let free: Decimal
    let locked: Decimal
    let averageCost: Decimal?
    let currentPrice: Decimal?
    let hasLoadedTradeHistory: Bool

    var quantity: Decimal { free + locked }
    var marketValue: Decimal? { currentPrice.map { $0 * quantity } }
    var unrealizedPnL: Decimal? {
        guard let averageCost, let currentPrice else { return nil }
        return (currentPrice - averageCost) * quantity
    }
    var pnlRate: Decimal? {
        guard let averageCost, averageCost > 0, let currentPrice else { return nil }
        return (currentPrice - averageCost) / averageCost * 100
    }
}

struct FuturesPosition: Identifiable, Codable {
    var id: String { "\(symbol)-\(positionSide)" }
    let symbol: String
    let positionSide: String
    let amount: Decimal
    let entryPrice: Decimal
    let markPrice: Decimal
    let notionalValue: Decimal
    let initialMargin: Decimal
    let unrealizedPnL: Decimal
    let liquidationPrice: Decimal
    let marginAsset: String
    let leverage: Int
    let isolated: Bool

    var absoluteAmount: Decimal { abs(amount) }
    var absoluteNotionalValue: Decimal { abs(notionalValue) }
    var pnlRate: Decimal? {
        guard initialMargin > 0 else { return nil }
        return unrealizedPnL / initialMargin * 100
    }
    var directionText: String {
        if positionSide == "LONG" { return "多" }
        if positionSide == "SHORT" { return "空" }
        return amount < 0 ? "空" : "多"
    }
}

struct TradingAccountSnapshot: Codable {
    let canTrade: Bool
    let spotBalances: [TradingBalance]
    let spotPositions: [SpotPosition]
    let futuresWalletBalance: Decimal
    let futuresAvailableBalance: Decimal
    let futuresUnrealizedPnL: Decimal
    let futuresPositions: [FuturesPosition]
}

struct TradeRecord: Identifiable, Codable {
    let id: Int64
    let orderId: Int64
    let symbol: String
    let time: Date
    let isBuyer: Bool
    let price: Decimal
    let quantity: Decimal
    let quoteQuantity: Decimal
    let commission: Decimal
    let commissionAsset: String
    let realizedPnL: Decimal?
    let positionSide: String?

    var sideText: String { isBuyer ? "买入" : "卖出" }
}

struct PendingOrder: Identifiable, Codable {
    let id: String
    let orderId: String
    let symbol: String
    let side: String
    let positionSide: String?
    let type: String
    let status: String
    let timeInForce: String?
    let price: Decimal
    let triggerPrice: Decimal
    let originalQuantity: Decimal
    let executedQuantity: Decimal
    let reduceOnly: Bool
    let closePosition: Bool
    let createdAt: Date
    let updatedAt: Date

    var remainingQuantity: Decimal {
        max(originalQuantity - executedQuantity, 0)
    }

    /// Futures conditional orders are returned from the Algo Orders endpoint
    /// and require a different cancellation route.
    var isAlgoOrder: Bool { id.hasPrefix("algo-") }
}

struct TradeAnalytics: Codable {
    let tradeCount: Int
    let buyCount: Int
    let sellCount: Int
    let turnover: Decimal
    let netBaseFlow: Decimal
    let averageBuyPrice: Decimal?
    let averageSellPrice: Decimal?
    let realizedPnL: Decimal
    let profitableCloseRate: Double?
    let commissions: [String: Decimal]

    static let empty = TradeAnalytics(
        tradeCount: 0,
        buyCount: 0,
        sellCount: 0,
        turnover: 0,
        netBaseFlow: 0,
        averageBuyPrice: nil,
        averageSellPrice: nil,
        realizedPnL: 0,
        profitableCloseRate: nil,
        commissions: [:]
    )

    static func calculate(from trades: [TradeRecord]) -> TradeAnalytics {
        guard !trades.isEmpty else { return .empty }

        let buys = trades.filter(\.isBuyer)
        let sells = trades.filter { !$0.isBuyer }
        let buyQuantity = buys.reduce(Decimal.zero) { $0 + $1.quantity }
        let sellQuantity = sells.reduce(Decimal.zero) { $0 + $1.quantity }
        let buyQuote = buys.reduce(Decimal.zero) { $0 + $1.quoteQuantity }
        let sellQuote = sells.reduce(Decimal.zero) { $0 + $1.quoteQuantity }
        let closed = trades.compactMap(\.realizedPnL).filter { $0 != 0 }
        let wins = closed.filter { $0 > 0 }.count
        var commissions: [String: Decimal] = [:]
        for trade in trades {
            commissions[trade.commissionAsset, default: 0] += trade.commission
        }

        return TradeAnalytics(
            tradeCount: trades.count,
            buyCount: buys.count,
            sellCount: sells.count,
            turnover: trades.reduce(Decimal.zero) { $0 + $1.quoteQuantity },
            netBaseFlow: buyQuantity - sellQuantity,
            averageBuyPrice: buyQuantity > 0 ? buyQuote / buyQuantity : nil,
            averageSellPrice: sellQuantity > 0 ? sellQuote / sellQuantity : nil,
            realizedPnL: trades.compactMap(\.realizedPnL).reduce(Decimal.zero, +),
            profitableCloseRate: closed.isEmpty ? nil : Double(wins) / Double(closed.count),
            commissions: commissions
        )
    }
}

struct TradingDashboardData: Codable {
    let account: TradingAccountSnapshot
    let pendingOrders: [PendingOrder]
    let trades: [TradeRecord]
    let analytics: TradeAnalytics
    let fetchedAt: Date
}

enum BinanceTradingError: LocalizedError {
    case missingCredentials
    case liveTradingDisabled
    case invalidSymbol
    case invalidQuantity
    case invalidAmount
    case invalidPrice
    case invalidProtectionPrice(String)
    case noPosition
    case insufficientBalance(String)
    case unsupported(String)
    case invalidResponse
    case api(code: Int, message: String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "尚未配置当前市场的 Binance API Key 与 Secret"
        case .liveTradingDisabled: return "实盘交易开关未开启"
        case .invalidSymbol: return "交易对格式无效"
        case .invalidQuantity: return "数量无效，或低于币安允许的最小下单量"
        case .invalidAmount: return "金额无效，请输入大于 0 的 USDT 金额"
        case .invalidPrice: return "价格无效，或不符合该交易对的价格精度"
        case .invalidProtectionPrice(let message): return message
        case .noPosition: return "当前方向没有可减仓或平仓的持仓"
        case .insufficientBalance(let asset): return "可用 \(asset) 余额不足"
        case .unsupported(let message): return message
        case .invalidResponse: return "币安返回了无法识别的数据"
        case .api(let code, let message): return "币安错误 \(code)：\(message)"
        case .keychain(let status): return "钥匙串操作失败（\(status)）"
        }
    }
}

extension Decimal {
    var plainString: String {
        NSDecimalNumber(decimal: self).stringValue
    }
}
