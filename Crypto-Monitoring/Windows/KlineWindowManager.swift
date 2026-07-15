//
//  KlineWindowManager.swift
//  Crypto Monitoring
//
//  Created by Mark on 2026/07/09.
//

import SwiftUI

/// K 线图窗口管理器
/// 负责创建/复用每个币种对应的 K 线图窗口
@MainActor
class KlineWindowManager: ObservableObject {
    /// 按 API 符号缓存已打开的窗口（每个币种一个窗口）
    private var windows: [String: NSWindow] = [:]
    /// 窗口关闭通知的观察者，用于在窗口关闭后从缓存中移除
    private var closeObservers: [String: NSObjectProtocol] = [:]

    private let appSettings: AppSettings
    private let priceManager: PriceManager

    init(appSettings: AppSettings, priceManager: PriceManager) {
        self.appSettings = appSettings
        self.priceManager = priceManager
    }

    /// 切换指定币种的 K 线图窗口显示状态
    /// - Parameters:
    ///   - apiSymbol: API 符号（如 "BTCUSDT"）
    ///   - displayName: 展示名称（如 "BTC"）
    func toggleKlineWindow(apiSymbol: String, displayName: String) {
        if let existing = windows[apiSymbol] {
            removeWindow(for: apiSymbol)
            existing.close()
            return
        }

        showKlineWindow(apiSymbol: apiSymbol, displayName: displayName)
    }

    /// 显示指定币种的 K 线图窗口
    /// - Parameters:
    ///   - apiSymbol: API 符号（如 "BTCUSDT"）
    ///   - displayName: 展示名称（如 "BTC"）
    func showKlineWindow(apiSymbol: String, displayName: String) {
        // 若窗口已存在，直接前置
        if let existing = windows[apiSymbol] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            existing.orderFrontRegardless()
            return
        }

        let chartView = KlineChartView(
            apiSymbol: apiSymbol,
            displayName: displayName,
            priceManager: priceManager,
            initialMarketType: appSettings.marketType
        )

        let hostingView = NSHostingView(rootView: chartView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "\(displayName) K线图"
        window.contentViewController = NSViewController()
        window.contentViewController?.view = hostingView
        window.isReleasedWhenClosed = false
        window.titleVisibility = .visible
        window.minSize = NSSize(width: 640, height: 560)
        window.center()

        windows[apiSymbol] = window

        // 监听窗口关闭以清理缓存
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.removeWindow(for: apiSymbol)
            }
        }
        closeObservers[apiSymbol] = observer

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()

        print("✅ 已显示 \(displayName) K线图窗口")
    }

    /// 从缓存中移除已关闭的窗口并注销观察者
    private func removeWindow(for apiSymbol: String) {
        if let observer = closeObservers[apiSymbol] {
            NotificationCenter.default.removeObserver(observer)
            closeObservers.removeValue(forKey: apiSymbol)
        }
        windows.removeValue(forKey: apiSymbol)
    }
}
