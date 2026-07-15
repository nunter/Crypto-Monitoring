//
//  Kline.swift
//  Crypto Monitoring
//
//  Created by Mark on 2026/07/09.
//

import Foundation

/// 单根 K 线（蜡烛）数据模型
/// 对应币安 klines 接口返回的一条记录
struct Kline: Identifiable {
    let id = UUID()
    /// 开盘时间
    let openTime: Date
    /// 开盘价
    let open: Double
    /// 最高价
    let high: Double
    /// 最低价
    let low: Double
    /// 收盘价
    let close: Double
    /// 成交量（以基础币计）
    let volume: Double
    /// 收盘时间
    let closeTime: Date

    /// 是否为阳线（收盘价 >= 开盘价）
    var isBullish: Bool { close >= open }
}

/// K 线周期枚举
enum KlineInterval: String, CaseIterable, Identifiable {
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case oneHour = "1h"
    case fourHours = "4h"
    case oneDay = "1d"

    var id: String { rawValue }

    /// 完整显示名称
    var displayName: String {
        switch self {
        case .fiveMinutes: return "5分钟"
        case .fifteenMinutes: return "15分钟"
        case .oneHour: return "1小时"
        case .fourHours: return "4小时"
        case .oneDay: return "1天"
        }
    }

    /// 简短显示名称（用于分段控件）
    var shortName: String {
        switch self {
        case .fiveMinutes: return "5m"
        case .fifteenMinutes: return "15m"
        case .oneHour: return "1H"
        case .fourHours: return "4H"
        case .oneDay: return "1D"
        }
    }
}
