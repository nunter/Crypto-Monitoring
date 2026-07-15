//
//  PriceManager.swift
//  Crypto Monitoring
//
//  Created by Mark on 2025/10/28.
//

import Foundation
import Combine

// 价格管理器，负责定时刷新币种价格
@MainActor
class PriceManager: ObservableObject {
    @Published var currentPrice: Double = 0.0
    // 当前活跃币种的现货价与永续价（用于状态栏同时展示，0.0 表示暂无数据）
    @Published var currentSpotPrice: Double = 0.0
    @Published var currentPerpetualPrice: Double = 0.0
    @Published var isFetching: Bool = false
    @Published var lastError: PriceError?
    @Published var selectedSymbol: CryptoSymbol

    // 自定义币种相关属性
    @Published var customCryptoSymbols: [CustomCryptoSymbol] = []
    @Published var selectedCustomSymbolIndex: Int?
    @Published var useCustomSymbol: Bool = false

    private let priceService: PriceService
    private var timer: Timer?
    private var currentRefreshInterval: TimeInterval = RefreshInterval.fiveSeconds.rawValue // 当前刷新间隔
    private let appSettings: AppSettings

    // 自定义币种价格缓存
    private var customSymbolPriceCache: [String: (price: Double, timestamp: Date)] = [:]
    private let cacheExpirationTime: TimeInterval = 30.0 // 缓存30秒

    init(initialSymbol: CryptoSymbol = .btc, appSettings: AppSettings) {
        selectedSymbol = initialSymbol
        self.appSettings = appSettings
        self.priceService = PriceService(appSettings: appSettings)

        // 初始化自定义币种状态
        self.customCryptoSymbols = appSettings.customCryptoSymbols
        self.selectedCustomSymbolIndex = appSettings.selectedCustomSymbolIndex
        self.useCustomSymbol = appSettings.useCustomSymbol

        startPriceUpdates()
    }

    deinit {
        // 在deinit中不能直接调用@MainActor方法
        timer?.invalidate()
        timer = nil
    }

    // 开始定时更新价格
    func startPriceUpdates() {
        #if DEBUG
    print("⏰ [Price Manager] 启动定时器，刷新间隔: \(Int(currentRefreshInterval))秒 | 币种: \(selectedSymbol.displayName)")
        #endif

        // 立即获取一次价格
        Task {
            await fetchPrice()
        }

        // 设置定时器，使用weak self避免循环引用
        timer = Timer.scheduledTimer(withTimeInterval: currentRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.fetchPrice()
            }
        }

        #if DEBUG
    print("✅ [Price Manager] 定时器启动成功")
        #endif
    }

    // 停止价格更新
    @MainActor
    func stopPriceUpdates() {
        #if DEBUG
    print("⏹️ [Price Manager] 停止定时器")
        #endif

        timer?.invalidate()
        timer = nil

        #if DEBUG
    print("✅ [Price Manager] 定时器已停止")
        #endif
    }

    // 手动刷新价格
    func refreshPrice() async {
        #if DEBUG
    print("🔄 [Price Manager] 用户手动刷新价格 | 币种: \(selectedSymbol.displayName)")
        #endif

        await fetchPrice()
    }

    // 获取价格的核心方法（带重试机制）
    private func fetchPrice() async {
        isFetching = true
        lastError = nil

        // 获取当前活跃的币种信息
        let activeApiSymbol = getCurrentActiveApiSymbol()
        let activeDisplayName = getCurrentDisplayName()
        let activeMarketType = appSettings.marketType
        var didUpdatePrice = false

        #if DEBUG
        print("🔄 [Price Manager] 开始获取价格 | 币种: \(activeDisplayName)")
        #endif

        defer {
            isFetching = false

            #if DEBUG
            if let error = lastError {
                print("⚠️ [Price Manager] 价格获取流程结束，最终失败: \(error.localizedDescription) | 币种: \(activeDisplayName)")
            } else if didUpdatePrice {
                print("✅ [Price Manager] 价格获取流程结束，成功")
            } else {
                print("ℹ️ [Price Manager] 价格获取流程结束，结果已丢弃 | 币种已更新")
            }
            #endif
        }

        // 重试最多3次，每次同时获取现货与永续价格
        let maxRetries = 3

        for attempt in 1...maxRetries {
            #if DEBUG
            print("📡 [Price Manager] 尝试获取价格 (第\(attempt)次) | 币种: \(activeDisplayName)")
            #endif

            let (spotOpt, perpOpt) = await fetchBothMarketPrices(forApiSymbol: activeApiSymbol)

            // 检查币种或市场类型是否已更改
            guard activeApiSymbol == getCurrentActiveApiSymbol(),
                  activeMarketType == appSettings.marketType else {
                #if DEBUG
                print("ℹ️ [Price Manager] 币种已切换至 \(getCurrentDisplayName())，丢弃旧结果")
                #endif
                return
            }

            // 当前市场类型对应的价格（用于状态栏主价与复制）
            let activePrice = activeMarketType == .spot ? spotOpt : perpOpt

            if spotOpt != nil || perpOpt != nil {
                // 至少一个市场有价格，更新展示
                currentSpotPrice = spotOpt ?? 0.0
                currentPerpetualPrice = perpOpt ?? 0.0
                currentPrice = activePrice ?? currentPrice
                didUpdatePrice = true
                lastError = nil

                #if DEBUG
                let formatter = DateFormatter()
                formatter.timeStyle = .medium
                let currentTime = formatter.string(from: Date())
                let spotStr = spotOpt.map { String(format: "%.4f", $0) } ?? "—"
                let perpStr = perpOpt.map { String(format: "%.4f", $0) } ?? "—"
                print("✅ [Price Manager] 价格更新成功: \(activeDisplayName) 现货 $\(spotStr) | 永续 $\(perpStr) | 时间: \(currentTime)")
                #endif

                break // 成功获取价格，退出重试循环
            } else {
                // 两个市场都失败
                #if DEBUG
                print("❌ [Price Manager] 价格获取失败 (第\(attempt)次) | 币种: \(activeDisplayName)")
                #endif

                if attempt == maxRetries {
                    lastError = .serverError(0)
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(attempt * 1_000_000_000)) // 递增延迟
                }
            }
        }
    }

    // 格式化价格显示
    var formattedPrice: String {
        let displayName = getCurrentDisplayName()

        if isFetching {
            return "\(displayName): 更新中..."
        }

        if lastError != nil {
            return "\(displayName): 错误"
        }

        if currentPrice == 0.0 {
            return "\(displayName): 加载中..."
        }

        return "\(displayName): $\(formatPriceWithCommas(currentPrice))"
    }

    // 获取详细错误信息
    var errorMessage: String? {
        return lastError?.localizedDescription
    }

    // 格式化价格为千分位分隔形式
    private func formatPriceWithCommas(_ price: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        
        return formatter.string(from: NSNumber(value: price)) ?? String(format: "%.4f", price)
    }

    /// 更新当前币种
    /// - Parameter symbol: 用户选中的新币种
    func updateSymbol(_ symbol: CryptoSymbol) {
        guard symbol != selectedSymbol else { return }

        #if DEBUG
        print("🔁 [Price Manager] 更新币种: \(selectedSymbol.displayName) → \(symbol.displayName)")
        #endif

        selectedSymbol = symbol
        currentPrice = 0.0
        currentSpotPrice = 0.0
        currentPerpetualPrice = 0.0
        lastError = nil

        Task { [weak self] in
            await self?.fetchPrice()
        }
    }

    /// 市场类型发生变化时调用（现货 ⇄ 永续合约）
    /// 重置当前价格并立即按新市场类型重新获取
    func updateMarketType() {
        #if DEBUG
        print("🔁 [Price Manager] 市场类型变更为: \(appSettings.marketType.displayName)")
        #endif

        currentPrice = 0.0
        currentSpotPrice = 0.0
        currentPerpetualPrice = 0.0
        lastError = nil

        Task { [weak self] in
            await self?.fetchPrice()
        }
    }

    // MARK: - Refresh Interval Configuration

    /// 更新刷新间隔
    /// - Parameter interval: 新的刷新间隔
    func updateRefreshInterval(_ interval: RefreshInterval) {
        let oldInterval = RefreshInterval.allCases.first { $0.rawValue == currentRefreshInterval }?.displayText ?? "未知"

        #if DEBUG
        print("⏱️ [Price Manager] 刷新间隔变更: \(oldInterval) → \(interval.displayText)")
        #endif

        currentRefreshInterval = interval.rawValue

        // 如果定时器正在运行，重启它以应用新的间隔
        if timer != nil {
            #if DEBUG
            print("🔄 [Price Manager] 重启定时器以应用新的刷新间隔")
            #endif

            stopPriceUpdates()
            startPriceUpdates()
        }
    }

    /// 获取当前刷新间隔
    /// - Returns: 当前的RefreshInterval枚举值
    func getCurrentRefreshInterval() -> RefreshInterval {
        return RefreshInterval.allCases.first { $0.rawValue == currentRefreshInterval } ?? .fiveSeconds
    }
    
    /// 并发获取所有支持币种的价格（用于菜单一次性显示全部币种）
    nonisolated func fetchAllPrices() async -> [CryptoSymbol: (price: Double?, errorMessage: String?)] {
        var results = [CryptoSymbol: (Double?, String?)]()

        await withTaskGroup(of: (CryptoSymbol, Double?, String?).self) { group in
            for symbol in CryptoSymbol.allCases {
                group.addTask { [weak self] in
                    guard let self = self else { return (symbol, nil, "PriceManager已释放") }
                    do {
                        let price = try await self.priceService.fetchPrice(for: symbol)
                        return (symbol, price, nil)
                    } catch let error as PriceError {
                        return (symbol, nil, error.localizedDescription)
                    } catch {
                        return (symbol, nil, "网络错误：\(error.localizedDescription)")
                    }
                }
            }

            for await (symbol, price, errorMsg) in group {
                results[symbol] = (price, errorMsg)
            }
        }

        return results
    }

    /// 并发获取所有默认币种的现货与永续价格（用于菜单同时展示两个市场）
    /// - Returns: 每个币种对应的现货价与永续价（获取失败为 nil）
    nonisolated func fetchAllPricesBothMarkets() async -> [CryptoSymbol: (spot: Double?, perpetual: Double?)] {
        var results = [CryptoSymbol: (Double?, Double?)]()

        await withTaskGroup(of: (CryptoSymbol, Double?, Double?).self) { group in
            for symbol in CryptoSymbol.allCases {
                group.addTask { [weak self] in
                    guard let self = self else { return (symbol, nil, nil) }
                    async let spot = try? self.priceService.fetchPrice(for: symbol, marketType: .spot)
                    async let perp = try? self.priceService.fetchPrice(for: symbol, marketType: .perpetual)
                    return (symbol, await spot, await perp)
                }
            }

            for await (symbol, spot, perp) in group {
                results[symbol] = (spot, perp)
            }
        }

        return results
    }

    /// 获取指定 API 符号的现货与永续价格（用于菜单中自定义币种同时展示）
    /// - Parameter apiSymbol: API 符号（如 "ADAUSDT"）
    /// - Returns: 现货价与永续价（获取失败为 nil）
    func fetchBothMarketPrices(forApiSymbol apiSymbol: String) async -> (spot: Double?, perpetual: Double?) {
        async let spot = try? priceService.fetchPrice(forApiSymbol: apiSymbol, marketType: .spot)
        async let perp = try? priceService.fetchPrice(forApiSymbol: apiSymbol, marketType: .perpetual)
        return (await spot, await perp)
    }

    /// 获取单个币种的价格（用于Option+点击复制功能）
    /// - Parameter symbol: 要获取价格的币种
    /// - Returns: 价格值，如果获取失败返回nil
    func fetchSinglePrice(for symbol: CryptoSymbol, marketType: MarketType? = nil) async -> Double? {
        let market = marketType ?? appSettings.marketType
        do {
            return try await priceService.fetchPrice(for: symbol, marketType: market)
        } catch {
            print("❌ 获取 \(symbol.displayName)(\(market.shortName)) 价格失败: \(error.localizedDescription)")
            return nil
        }
    }

    /// 更新网络配置（当代理设置发生变化时调用）
    @MainActor
    func updateNetworkConfiguration() {
        priceService.updateNetworkConfiguration()
    }

    /// 获取指定币种的 K 线数据（供 K 线图窗口使用）
    /// - Parameters:
    ///   - apiSymbol: API 符号（如 "BTCUSDT"）
    ///   - interval: K 线周期
    ///   - marketType: 市场类型（现货 / 永续合约）
    ///   - limit: K 线根数
    /// - Returns: K 线数组；获取失败返回 nil
    func fetchKlines(forApiSymbol apiSymbol: String,
                     interval: KlineInterval,
                     marketType: MarketType,
                     limit: Int = 120) async -> [Kline]? {
        do {
            return try await priceService.fetchKlines(
                forApiSymbol: apiSymbol,
                interval: interval,
                marketType: marketType,
                limit: limit
            )
        } catch {
            #if DEBUG
            print("❌ [Price Manager] 获取K线失败: \(apiSymbol)(\(marketType.shortName)/\(interval.rawValue)) - \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    // MARK: - 自定义币种支持方法

    /// 获取当前活跃的币种API符号
    /// - Returns: 当前活跃币种的API符号
    private func getCurrentActiveApiSymbol() -> String {
        return appSettings.getCurrentActiveApiSymbol()
    }

    /// 获取当前活跃的币种显示名称
    /// - Returns: 当前活跃币种的显示名称
    private func getCurrentDisplayName() -> String {
        return appSettings.getCurrentActiveDisplayName()
    }

    /// 更新币种设置（当AppSettings中的自定义币种发生变化时调用）
    func updateCryptoSymbolSettings() {
        customCryptoSymbols = appSettings.customCryptoSymbols
        selectedCustomSymbolIndex = appSettings.selectedCustomSymbolIndex
        useCustomSymbol = appSettings.useCustomSymbol

        // 重置价格状态，强制重新获取
        currentPrice = 0.0
        currentSpotPrice = 0.0
        currentPerpetualPrice = 0.0
        lastError = nil

        #if DEBUG
        print("🔁 [Price Manager] 已更新币种设置，当前币种: \(getCurrentDisplayName())")
        #endif

        // 立即获取新币种的价格
        Task {
            await fetchPrice()
        }
    }

    /// 获取所有支持的币种（包括默认币种和自定义币种）
    /// - Returns: 所有可用币种的API符号列表
    func getAllAvailableSymbols() -> [String] {
        var symbols = CryptoSymbol.allApiSymbols

        // 添加所有自定义币种
        for customSymbol in appSettings.customCryptoSymbols {
            symbols.append(customSymbol.apiSymbol)
        }

        return symbols
    }

    /// 根据API符号获取对应的显示名称
    /// - Parameter apiSymbol: API符号
    /// - Returns: 显示名称，如果找不到则返回API符号本身
    func getDisplayName(forApiSymbol apiSymbol: String) -> String {
        // 首先检查是否是默认币种
        if let defaultSymbol = CryptoSymbol.fromApiSymbol(apiSymbol) {
            return defaultSymbol.displayName
        }

        // 检查是否是自定义币种
        for customSymbol in appSettings.customCryptoSymbols {
            if customSymbol.apiSymbol == apiSymbol {
                return customSymbol.displayName
            }
        }

        // 如果都找不到，返回API符号的基础部分（去掉USDT）
        if apiSymbol.hasSuffix("USDT") {
            let baseSymbol = String(apiSymbol.dropLast(4))
            return baseSymbol
        }

        return apiSymbol
    }

    // MARK: - 价格缓存机制

    /// 从缓存获取自定义币种价格
    /// - Parameter apiSymbol: API符号
    /// - Returns: 缓存的价格，如果已过期或不存在则返回nil
    private func getCachedPrice(forApiSymbol apiSymbol: String) -> Double? {
        guard let cachedData = customSymbolPriceCache[apiSymbol] else {
            return nil
        }

        // 检查缓存是否过期
        let timeSinceCache = Date().timeIntervalSince(cachedData.timestamp)
        if timeSinceCache > cacheExpirationTime {
            // 缓存已过期，移除
            customSymbolPriceCache.removeValue(forKey: apiSymbol)
            #if DEBUG
            print("🗑️ [Price Manager] 缓存已过期，移除: \(apiSymbol)")
            #endif
            return nil
        }

        #if DEBUG
        print("💾 [Price Manager] 使用缓存价格: \(apiSymbol) = $\(String(format: "%.4f", cachedData.price))")
        #endif
        return cachedData.price
    }

    /// 缓存自定义币种价格
    /// - Parameters:
    ///   - price: 价格值
    ///   - apiSymbol: API符号
    private func cachePrice(_ price: Double, forApiSymbol apiSymbol: String) {
        customSymbolPriceCache[apiSymbol] = (price: price, timestamp: Date())
        #if DEBUG
        print("💾 [Price Manager] 已缓存价格: \(apiSymbol) = $\(String(format: "%.4f", price))")
        #endif

        // 清理过期缓存
        cleanExpiredCache()
    }

    /// 清理过期的缓存条目
    private func cleanExpiredCache() {
        let currentTime = Date()
        let expiredKeys = customSymbolPriceCache.compactMap { key, value in
            currentTime.timeIntervalSince(value.timestamp) > cacheExpirationTime ? key : nil
        }

        for key in expiredKeys {
            customSymbolPriceCache.removeValue(forKey: key)
        }

        if !expiredKeys.isEmpty {
            #if DEBUG
            print("🗑️ [Price Manager] 已清理 \(expiredKeys.count) 个过期缓存条目")
            #endif
        }
    }

    /// 清空所有缓存
    private func clearAllCache() {
        customSymbolPriceCache.removeAll()
        #if DEBUG
        print("🗑️ [Price Manager] 已清空所有价格缓存")
        #endif
    }

    /// 获取自定义币种价格（带缓存）
    /// - Parameter apiSymbol: API符号
    /// - Returns: 价格值
    func fetchCustomSymbolPrice(forApiSymbol apiSymbol: String, marketType: MarketType? = nil) async -> Double? {
        let market = marketType ?? appSettings.marketType
        // 缓存键包含市场类型，避免现货/永续价格互相覆盖
        let cacheKey = "\(apiSymbol)_\(market.rawValue)"

        // 首先尝试从缓存获取
        if let cachedPrice = getCachedPrice(forApiSymbol: cacheKey) {
            return cachedPrice
        }

        // 缓存未命中，从网络获取
        do {
            let price = try await priceService.fetchPrice(forApiSymbol: apiSymbol, marketType: market)
            cachePrice(price, forApiSymbol: cacheKey)
            return price
        } catch {
            #if DEBUG
            print("❌ [Price Manager] 获取自定义币种价格失败: \(apiSymbol)(\(market.shortName)) - \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    /// 批量获取多个币种的价格（带缓存优化）
    /// - Parameter apiSymbols: API符号数组
    /// - Returns: 价格字典
    func fetchMultiplePrices(forApiSymbols apiSymbols: [String]) async -> [String: Double] {
        var results = [String: Double]()
        var symbolsToFetch = [String]()

        // 首先检查缓存
        for symbol in apiSymbols {
            if let cachedPrice = getCachedPrice(forApiSymbol: symbol) {
                results[symbol] = cachedPrice
            } else {
                symbolsToFetch.append(symbol)
            }
        }

        // 批量获取未缓存的币种价格
        if !symbolsToFetch.isEmpty {
            await withTaskGroup(of: (String, Double?).self) { group in
                for symbol in symbolsToFetch {
                    group.addTask { [weak self] in
                        do {
                            let price = try await self?.priceService.fetchPrice(forApiSymbol: symbol)
                            if let price = price {
                                return (symbol, price)
                            } else {
                                return (symbol, nil)
                            }
                        } catch {
                            #if DEBUG
                            print("❌ [Price Manager] 批量获取价格失败: \(symbol) - \(error.localizedDescription)")
                            #endif
                            return (symbol, nil)
                        }
                    }
                }

                for await (symbol, price) in group {
                    if let price = price {
                        results[symbol] = price
                        // 缓存获取到的价格
                        cachePrice(price, forApiSymbol: symbol)
                    }
                }
            }
        }

        return results
    }
}
