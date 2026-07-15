//
//  TradingWindowManager.swift
//  Crypto Monitoring
//

import SwiftUI

@MainActor
final class TradingWindowManager: ObservableObject {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private let appSettings: AppSettings

    init(appSettings: AppSettings) {
        self.appSettings = appSettings
    }

    func showTradingWindow(initialSymbol: String) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            return
        }

        let view = TradingView(appSettings: appSettings, initialSymbol: initialSymbol)
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Binance 交易与数据分析"
        window.contentViewController = NSViewController()
        window.contentViewController?.view = hostingView
        window.minSize = NSSize(width: 980, height: 680)
        window.isReleasedWhenClosed = false
        window.center()

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.window = nil
                if let observer = self?.closeObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self?.closeObserver = nil
                }
            }
        }

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
    }
}
