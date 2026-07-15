//
//  MarketType.swift
//  Crypto Monitoring
//
//  Created by Mark on 2026/07/06.
//

import Foundation

/// 市场类型枚举
/// 用于区分币安现货行情与 USDT 本位永续合约行情
enum MarketType: String, CaseIterable, Codable, Hashable {
    /// 现货
    case spot = "spot"
    /// USDT 本位永续合约
    case perpetual = "perpetual"

    /// 对应行情接口的基础 URL
    /// - 现货：https://api.binance.com/api/v3/ticker/price
    /// - 永续：https://fapi.binance.com/fapi/v1/ticker/price
    var tickerBaseURL: String {
        switch self {
        case .spot:
            return "https://api.binance.com/api/v3/ticker/price"
        case .perpetual:
            return "https://fapi.binance.com/fapi/v1/ticker/price"
        }
    }

    /// 对应 K 线（klines）接口的基础 URL
    /// - 现货：https://api.binance.com/api/v3/klines
    /// - 永续：https://fapi.binance.com/fapi/v1/klines
    var klinesBaseURL: String {
        switch self {
        case .spot:
            return "https://api.binance.com/api/v3/klines"
        case .perpetual:
            return "https://fapi.binance.com/fapi/v1/klines"
        }
    }

    /// 完整显示名称
    var displayName: String {
        switch self {
        case .spot:
            return "现货"
        case .perpetual:
            return "永续合约"
        }
    }

    /// 简短显示名称（用于菜单栏等空间受限处）
    var shortName: String {
        switch self {
        case .spot:
            return "现货"
        case .perpetual:
            return "永续"
        }
    }

    /// 单字符标识（用于菜单栏标题紧凑展示）
    var badge: String {
        switch self {
        case .spot:
            return "现"
        case .perpetual:
            return "永"
        }
    }

    /// 对应的 SF Symbols 图标名称
    var systemImageName: String {
        switch self {
        case .spot:
            return "dollarsign.circle"
        case .perpetual:
            return "arrow.triangle.2.circlepath.circle"
        }
    }

    /// 切换到另一种市场类型
    var toggled: MarketType {
        switch self {
        case .spot:
            return .perpetual
        case .perpetual:
            return .spot
        }
    }

    /// 菜单标题（带勾选标记）
    /// - Parameter isCurrent: 是否为当前选中的市场类型
    /// - Returns: 菜单展示文本
    func menuTitle(isCurrent: Bool) -> String {
        return isCurrent ? "✓ \(displayName)" : "  \(displayName)"
    }
}

/// 菜单栏标题中展示的行情来源。它只影响标题文本，不改变复制价格、K 线和交易页使用的默认市场。
enum MenuBarPriceDisplayMode: String, CaseIterable, Codable, Hashable {
    case spot = "spot"
    case perpetual = "perpetual"
    case both = "both"

    var displayName: String {
        switch self {
        case .spot:
            return "仅现货"
        case .perpetual:
            return "仅永续"
        case .both:
            return "同时显示"
        }
    }
}
