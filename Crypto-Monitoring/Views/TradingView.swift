//
//  TradingView.swift
//  Crypto Monitoring
//

import AppKit
import SwiftUI

struct TradingView: View {
    @StateObject private var manager: TradingManager
    @State private var action: TradingAction = .open
    @State private var direction: PositionDirection = .long
    @State private var quantityText = ""
    @State private var amountText = ""
    @State private var leverage = 10
    @State private var closeAll = true
    @State private var orderType: TradingOrderType = .market
    @State private var sizingMode: TradingSizingMode = .amount
    @State private var priceText = ""
    @State private var orderFormFocusToken = 0
    @State private var showingCredentials = false
    @State private var showingSymbolEditor = false
    @State private var protectionEditorPosition: FuturesPosition?
    @State private var protectionEditorSpotPosition: SpotPosition?
    @State private var activeAlert: TradingAlert?
    @State private var appIsActive = true
    @State private var selectedPageSection: TradingPageSection = .overview

    private let dashboardRefreshIntervalNanoseconds: UInt64 = 10_000_000_000
    private static let decimalLocale = Locale(identifier: "en_US_POSIX")
    private static let tradingNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 8
        formatter.minimumFractionDigits = 0
        return formatter
    }()
    private static let tradeDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
    private static let refreshTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(appSettings: AppSettings, initialSymbol: String) {
        _manager = StateObject(wrappedValue: TradingManager(appSettings: appSettings, initialSymbol: initialSymbol))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !manager.credentialsConfigured {
                missingCredentialsView
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 16) {
                            safetyBanner
                            if manager.errorMessage != nil || manager.statusMessage != nil {
                                feedbackBanner
                            }
                            sectionNavigation
                            HStack(alignment: .top, spacing: 16) {
                                orderPanel
                                    .frame(width: 330)
                                    .id("order-form")
                                accountPanel
                                    .frame(maxWidth: .infinity)
                                    .id(TradingPageSection.overview.anchorID)
                            }
                            pendingOrdersPanel
                                .id(TradingPageSection.orders.anchorID)
                            analyticsPanel
                                .id(TradingPageSection.analytics.anchorID)
                            tradeHistoryPanel
                                .id(TradingPageSection.trades.anchorID)
                        }
                        .padding(18)
                    }
                    .onChange(of: orderFormFocusToken) { _ in
                        withAnimation { proxy.scrollTo("order-form", anchor: .top) }
                    }
                    .onChange(of: selectedPageSection) { section in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(section.anchorID, anchor: .top)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .sheet(isPresented: $showingCredentials) {
            CredentialsEditor(manager: manager, isPresented: $showingCredentials)
        }
        .sheet(isPresented: $showingSymbolEditor) {
            TradingSymbolEditor(manager: manager, isPresented: $showingSymbolEditor)
        }
        .sheet(item: $protectionEditorPosition) { position in
            ExistingPositionProtectionEditor(manager: manager, position: position)
        }
        .sheet(item: $protectionEditorSpotPosition) { position in
            ExistingSpotPositionProtectionEditor(manager: manager, position: position)
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .enableLive:
                return Alert(
                    title: Text("启用实盘下单？"),
                    message: Text("启用后订单会发送到真实 Binance 账户。本开关仅在本次应用运行期间有效。"),
                    primaryButton: .destructive(Text("确认启用")) {
                        manager.setLiveTradingEnabled(true)
                    },
                    secondaryButton: .cancel()
                )
            case .submitOrder:
                return Alert(
                    title: Text(manager.environment.isLive ? "确认实盘订单" : "确认测试网订单"),
                    message: Text(orderConfirmationText),
                    primaryButton: .destructive(Text("提交订单")) {
                        Task {
                            await manager.placeOrder(
                                action: action,
                                direction: direction,
                                quantityText: quantityText,
                                amountText: amountText,
                                leverage: leverage,
                                closeAll: closeAll,
                                orderType: orderType,
                                priceText: priceText,
                                sizingMode: sizingMode
                            )
                        }
                    },
                    secondaryButton: .cancel()
                )
            case .cancelOrder(let order):
                return Alert(
                    title: Text(manager.environment.isLive ? "确认取消实盘委托？" : "确认取消测试网委托？"),
                    message: Text(cancelOrderConfirmationText(order)),
                    primaryButton: .destructive(Text("取消委托")) {
                        Task { await manager.cancelPendingOrder(order) }
                    },
                    secondaryButton: .cancel(Text("返回"))
                )
            }
        }
        .onAppear {
            appIsActive = NSApplication.shared.isActive
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appIsActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appIsActive = false
        }
        .task(id: autoRefreshScope) {
            guard manager.credentialsConfigured, appIsActive else { return }

            await manager.refreshDashboard(showsStatusMessage: false)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: dashboardRefreshIntervalNanoseconds)
                } catch {
                    return
                }

                guard !Task.isCancelled,
                      appIsActive,
                      manager.credentialsConfigured,
                      !manager.isLoading,
                      !manager.isSubmitting,
                      !manager.isCancellingOrder,
                      !manager.isAddingProtection else { continue }

                await manager.refreshDashboard(showsStatusMessage: false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Label("Binance 交易与分析", systemImage: "arrow.up.arrow.down.circle.fill")
                .font(.headline)

            Picker("环境", selection: Binding(
                get: { manager.environment },
                set: { manager.setEnvironment($0) }
            )) {
                ForEach(TradingEnvironment.allCases) { environment in
                    Text(environment.displayName).tag(environment)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)

            Picker("市场", selection: Binding(
                get: { manager.market },
                set: { market in
                    manager.setMarket(market)
                    if market == .spot {
                        direction = .long
                        sizingMode = .amount
                    }
                }
            )) {
                ForEach(MarketType.allCases, id: \.self) { market in
                    Text(market.displayName).tag(market)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)

            Label(tradingPairDisplayName(manager.symbol), systemImage: manager.market.systemImageName)
                .font(.callout.weight(.medium))
                .lineLimit(1)

            Spacer()

            if manager.credentialsConfigured {
                Label(autoRefreshText, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .help("账户、持仓、当前委托与历史成交订单每 10 秒自动刷新；应用进入后台时暂停")
            }

            if manager.isLoading {
                ProgressView().controlSize(.small)
            }

            Button {
                Task { await manager.refreshDashboard() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(!manager.credentialsConfigured || manager.isLoading)

            Button("API 凭据") { showingCredentials = true }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(.bar)
    }

    private var missingCredentialsView: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text("尚未配置 \(manager.environment.displayName) · \(manager.market.displayName) 凭据")
                .font(.title3.weight(.semibold))
            Text("API Key 与 Secret 会写入 macOS 钥匙串，不会保存到项目文件或 UserDefaults。")
                .foregroundColor(.secondary)
            Button("配置 API 凭据") { showingCredentials = true }
                .buttonStyle(.borderedProminent)

            if let error = manager.errorMessage {
                Text(error).foregroundColor(.red).font(.callout)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var autoRefreshScope: String {
        [
            manager.environment.rawValue,
            manager.market.rawValue,
            manager.symbol,
            manager.credentialsConfigured ? "configured" : "missing",
            appIsActive ? "active" : "inactive"
        ].joined(separator: "|")
    }

    private var autoRefreshText: String {
        guard appIsActive else { return "自动刷新已暂停" }
        guard let updatedAt = manager.lastDashboardUpdate else { return "每 10 秒自动刷新" }
        if manager.isShowingCachedDashboard {
            return "本地缓存 · \(shortTime(updatedAt)) · 正在更新"
        }
        return "自动刷新 · \(shortTime(updatedAt))"
    }

    private var safetyBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    manager.environment.isLive ? "当前连接实盘" : "当前连接测试网",
                    systemImage: manager.environment.isLive ? "exclamationmark.triangle.fill" : "checkmark.shield.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundColor(manager.environment.isLive ? .red : .green)

                Spacer()

                if manager.environment.isLive {
                    Toggle("允许实盘下单", isOn: Binding(
                        get: { manager.liveTradingEnabled },
                        set: { enabled in
                            if enabled {
                                activeAlert = .enableLive
                            } else {
                                manager.setLiveTradingEnabled(false)
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                }
            }

            Text(manager.environment.isLive
                 ? "账户数据可只读拉取；真实下单还需要开启右侧总开关，并在每笔订单前再次确认。"
                 : "测试网订单不涉及真实资产，建议先在这里验证数量规则、持仓模式和 API 权限。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill((manager.environment.isLive ? Color.red : Color.green).opacity(0.08))
        )
    }

    private var feedbackBanner: some View {
        let isError = manager.errorMessage != nil
        let message = manager.errorMessage ?? manager.statusMessage ?? ""
        return HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundColor(isError ? .red : .green)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button {
                manager.clearMessages()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("关闭提示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill((isError ? Color.red : Color.green).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke((isError ? Color.red : Color.green).opacity(0.18), lineWidth: 1)
        )
    }

    private var sectionNavigation: some View {
        HStack(spacing: 12) {
            Label("页面导航", systemImage: "square.grid.2x2")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Picker("页面导航", selection: $selectedPageSection) {
                ForEach(TradingPageSection.allCases) { section in
                    Label(section.title, systemImage: section.icon).tag(section)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)
            Spacer()
        }
    }

    private var orderPanel: some View {
        TradingCard(title: "下单操作", icon: "paperplane.fill") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("操作", selection: $action) {
                    ForEach(TradingAction.allCases) { action in
                        Text(action.displayName).tag(action)
                    }
                }
                .pickerStyle(.segmented)

                if action == .open {
                    tradingSymbolSelector
                } else {
                    HStack {
                        Text("交易币种")
                        Spacer()
                        Text(tradingPairDisplayName(manager.symbol))
                            .font(.body.monospacedDigit().weight(.semibold))
                    }
                    .font(.callout)
                }

                Picker("订单类型", selection: $orderType) {
                    ForEach(TradingOrderType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                if orderType == .limit {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("委托价格（USDT）").font(.caption).foregroundColor(.secondary)
                        TextField("输入限价", text: $priceText)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospacedDigit())
                    }
                }

                if manager.market == .perpetual {
                    Picker("方向", selection: $direction) {
                        ForEach(PositionDirection.allCases) { direction in
                            Text(direction.displayName).tag(direction)
                        }
                    }
                    .pickerStyle(.segmented)
                } else {
                    HStack {
                        Text("方向")
                        Spacer()
                        Text(action.isReducing ? "卖出现货" : "买入现货")
                            .foregroundColor(action.isReducing ? .red : .green)
                    }
                    .font(.callout)
                }

                orderSizingFields

                Button {
                    activeAlert = .submitOrder
                } label: {
                    if manager.isSubmitting {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    } else {
                        Label(submitButtonTitle, systemImage: "checkmark.shield")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(action.isReducing ? .orange : .blue)
                .disabled(
                    manager.isSubmitting
                    || !isOrderInputValid
                    || (manager.environment.isLive && !manager.liveTradingEnabled)
                )

                if let hint = orderValidationHint {
                    Label(hint, systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let order = manager.lastOrder {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最近订单 #\(order.orderId)").font(.caption.weight(.semibold))
                        Text("\(order.side) · \(order.status) · 已成交 \(format(order.executedQuantity))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var tradingSymbolSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("建仓币种").font(.caption).foregroundColor(.secondary)
            HStack(spacing: 8) {
                Picker("建仓币种", selection: Binding(
                    get: { manager.symbol },
                    set: { manager.selectTradingSymbol($0) }
                )) {
                    ForEach(manager.availableTradingSymbols, id: \.self) { symbol in
                        Text(tradingPairDisplayName(symbol)).tag(symbol)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    showingSymbolEditor = true
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .help("添加当前环境与市场支持的 USDT 交易对")
            }
            Text("选择已有币种，或添加新的 USDT 交易对")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var accountPanel: some View {
        TradingCard(title: "账户与持仓", icon: "wallet.pass.fill") {
            if let account = manager.dashboard?.account {
                if manager.market == .spot {
                    VStack(alignment: .leading, spacing: 10) {
                        let quoteBalance = account.spotBalances.first { $0.asset == "USDT" }
                        LazyVGrid(columns: metricColumns, spacing: 8) {
                            metricTile("USDT 总余额", quoteBalance?.total ?? 0, suffix: " USDT", icon: "wallet.pass")
                            metricTile("USDT 可用", quoteBalance?.free ?? 0, suffix: " USDT", icon: "checkmark.circle")
                            metricTile("USDT 冻结", quoteBalance?.locked ?? 0, suffix: " USDT", icon: "lock")
                        }
                        Divider()
                        positionSectionHeader(
                            title: "现货持仓",
                            count: account.spotPositions.count,
                            icon: "bitcoinsign.circle.fill"
                        )
                        if account.spotPositions.isEmpty {
                            Text("暂无现货持仓（USDT 余额不计为持仓）")
                                .foregroundColor(.secondary)
                        } else {
                            ViewThatFits(in: .horizontal) {
                                VStack(spacing: 0) {
                                    spotPositionHeader
                                    Divider()
                                    ForEach(account.spotPositions) { position in
                                        spotPositionRow(position)
                                        Divider()
                                    }
                                }
                                .frame(minWidth: 1000)
                                VStack(spacing: 8) {
                                    ForEach(account.spotPositions) { position in
                                        compactSpotPositionRow(position)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        LazyVGrid(columns: metricColumns, spacing: 8) {
                            metricTile("钱包余额", account.futuresWalletBalance, suffix: " USDT", icon: "wallet.pass")
                            metricTile("可用余额", account.futuresAvailableBalance, suffix: " USDT", icon: "checkmark.circle")
                            metricTile("未实现盈亏", account.futuresUnrealizedPnL, suffix: " USDT", colored: true, icon: "chart.line.uptrend.xyaxis")
                        }
                        Divider()
                        positionSectionHeader(
                            title: "合约持仓",
                            count: account.futuresPositions.count,
                            icon: "chart.line.uptrend.xyaxis.circle.fill"
                        )
                        if account.futuresPositions.isEmpty {
                            Text("暂无合约持仓").foregroundColor(.secondary)
                        } else {
                            ViewThatFits(in: .horizontal) {
                                VStack(spacing: 0) {
                                    positionHeader
                                    Divider()
                                    ForEach(account.futuresPositions) { position in
                                        positionRow(position)
                                        Divider()
                                    }
                                }
                                .frame(minWidth: 1260)
                                VStack(spacing: 8) {
                                    ForEach(account.futuresPositions) { position in
                                        compactFuturesPositionRow(position)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                emptyLoadingView("尚未加载账户数据")
            }
        }
    }

    private var analyticsPanel: some View {
        TradingCard(title: "历史成交订单分析（由最近 1000 条成交汇总）", icon: "chart.bar.xaxis") {
            let analytics = manager.dashboard?.analytics ?? .empty
            LazyVGrid(columns: metricColumns, spacing: 8) {
                metricTile("成交订单数", Decimal(analytics.orderCount), icon: "number")
                metricTile("成交额", analytics.turnover, suffix: " USDT", icon: "banknote")
                metricTile("净基础币流入", analytics.netBaseFlow, colored: true, icon: "arrow.left.arrow.right")
                metricTile("已实现盈亏", analytics.realizedPnL, suffix: manager.market == .perpetual ? " USDT" : "", colored: true, icon: "chart.line.uptrend.xyaxis")
                metricTextTile(
                    "盈利平仓率",
                    analytics.profitableCloseRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—",
                    icon: "percent"
                )
                metricTextTile("手续费", commissionText(analytics.commissions), icon: "receipt")
            }
        }
    }

    private var pendingOrdersPanel: some View {
        let orders = (manager.dashboard?.pendingOrders ?? []).filter { order in
            !order.isAlgoOrder || (!order.closePosition && !order.reduceOnly)
        }
        return TradingCard(title: "当前委托（\(orders.count)）", icon: "list.bullet.rectangle.portrait") {
            if manager.dashboard == nil {
                emptyLoadingView("尚未加载当前委托")
            } else if orders.isEmpty {
                emptyLoadingView("当前没有待成交或待触发订单")
            } else {
                ViewThatFits(in: .horizontal) {
                    VStack(spacing: 0) {
                        pendingOrderHeader
                        Divider()
                        ForEach(orders) { order in
                            pendingOrderRow(order)
                            Divider()
                        }
                    }
                    .frame(minWidth: 1575)

                    VStack(spacing: 8) {
                        ForEach(orders) { order in
                            compactPendingOrderRow(order)
                        }
                    }
                }
            }
        }
    }

    private var pendingOrderHeader: some View {
        HStack(spacing: 10) {
            Text("委托时间").frame(width: 125, alignment: .leading)
            Text("币种/单号").frame(width: 105, alignment: .leading)
            Text("方向").frame(width: 90, alignment: .leading)
            Text("订单类型").frame(width: 130, alignment: .leading)
            Text("委托价").frame(width: 100, alignment: .trailing)
            Text("触发价").frame(width: 100, alignment: .trailing)
            Text("委托数量").frame(width: 100, alignment: .trailing)
            Text("已成交").frame(width: 100, alignment: .trailing)
            Text("剩余数量").frame(width: 100, alignment: .trailing)
            Text("预计保证金").frame(width: 110, alignment: .trailing)
            Text("杠杆倍数").frame(width: 60, alignment: .trailing)
            Text("预计手续费").frame(width: 120, alignment: .trailing)
            Text("状态").frame(width: 90, alignment: .trailing)
            Text("操作").frame(width: 90, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(.secondary)
        .padding(.vertical, 5)
    }

    private func pendingOrderRow(_ order: PendingOrder) -> some View {
        HStack(spacing: 10) {
            Text(shortDate(order.createdAt)).frame(width: 125, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(tradingPairDisplayName(order.symbol)).fontWeight(.semibold)
                Text("#\(order.orderId)").font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            .frame(width: 105, alignment: .leading)
            Text(pendingOrderSideText(order))
                .foregroundColor(order.side == "BUY" ? .green : .red)
                .frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(pendingOrderTypeText(order.type))
                if let timeInForce = order.timeInForce, !timeInForce.isEmpty {
                    Text(timeInForce).font(.caption2).foregroundColor(.secondary)
                }
            }
            .frame(width: 130, alignment: .leading)
            Text(order.price > 0 ? format(order.price) : "—").frame(width: 100, alignment: .trailing)
            Text(order.triggerPrice > 0 ? format(order.triggerPrice) : "—").frame(width: 100, alignment: .trailing)
            Text(order.closePosition && order.originalQuantity == 0 ? "全部" : format(order.originalQuantity))
                .frame(width: 100, alignment: .trailing)
            Text(format(order.executedQuantity)).frame(width: 100, alignment: .trailing)
            Text(order.closePosition && order.originalQuantity == 0 ? "全部" : format(order.remainingQuantity))
                .frame(width: 100, alignment: .trailing)
            Text(pendingOrderMarginText(order))
                .frame(width: 110, alignment: .trailing)
                .help("按剩余委托数量、委托/触发价和当前交易对杠杆估算")
            Text(pendingOrderLeverageText(order)).frame(width: 60, alignment: .trailing)
            Text(pendingOrderCommissionText(order))
                .frame(width: 120, alignment: .trailing)
                .help("按剩余委托成交额与当前账户 maker/taker 费率估算，未计 BNB 抵扣，实际以成交回报为准")
            Text(pendingOrderStatusText(order.status))
                .foregroundColor(pendingOrderStatusColor(order.status))
                .frame(width: 90, alignment: .trailing)
            HStack(spacing: 6) {
                if manager.cancellingOrderIDs.contains(order.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("取消") { activeAlert = .cancelOrder(order) }
                        .foregroundColor(.red)
                        .buttonStyle(.borderless)
                }
            }
            .frame(width: 90, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .padding(.vertical, 7)
    }

    private func compactPendingOrderRow(_ order: PendingOrder) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(minimum: 110), spacing: 12, alignment: .leading),
            count: 4
        )
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: order.isAlgoOrder ? "shield.lefthalf.filled" : "doc.text.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(order.isAlgoOrder ? .purple : .blue)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill((order.isAlgoOrder ? Color.purple : Color.blue).opacity(0.1))
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(tradingPairDisplayName(order.symbol))
                        .font(.callout.weight(.bold))
                    Text("#\(order.orderId) · \(shortDate(order.createdAt))")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(pendingOrderSideText(order))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(order.side == "BUY" ? .green : .red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill((order.side == "BUY" ? Color.green : Color.red).opacity(0.1))
                    )
                statusBadge(
                    pendingOrderStatusText(order.status),
                    color: pendingOrderStatusColor(order.status)
                )
            }

            Divider()

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                pendingOrderMetric(
                    "订单类型",
                    pendingOrderTypeText(order.type),
                    icon: "slider.horizontal.3"
                )
                pendingOrderMetric(
                    order.price > 0 ? "委托价" : "触发价",
                    format(order.price > 0 ? order.price : order.triggerPrice),
                    icon: "tag"
                )
                pendingOrderMetric(
                    "剩余数量",
                    order.closePosition && order.originalQuantity == 0 ? "全部" : format(order.remainingQuantity),
                    icon: "cube"
                )
                pendingOrderMetric(
                    "已成交",
                    format(order.executedQuantity),
                    icon: "chart.bar.fill"
                )
            }

            HStack(spacing: 10) {
                pendingOrderSummaryTile(
                    "预计保证金",
                    pendingOrderMarginText(order),
                    icon: "banknote",
                    color: .blue
                )
                pendingOrderSummaryTile(
                    "杠杆倍数",
                    pendingOrderLeverageText(order),
                    icon: "gauge.with.dots.needle.50percent",
                    color: .orange
                )
                pendingOrderSummaryTile(
                    "预计手续费",
                    pendingOrderCommissionText(order),
                    icon: "receipt",
                    color: .purple
                )
            }
            .help("保证金按剩余委托名义价值÷当前杠杆估算；手续费按剩余成交额与账户当前 maker/taker 费率估算，未计 BNB 抵扣")

            HStack(spacing: 10) {
                if order.executedQuantity > 0 {
                    Label("已成交 \(format(order.executedQuantity))", systemImage: "chart.bar.fill")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                } else {
                    Label("等待成交", systemImage: "clock")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if manager.cancellingOrderIDs.contains(order.id) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在取消").font(.caption)
                    }
                } else {
                    Button(role: .destructive) {
                        activeAlert = .cancelOrder(order)
                    } label: {
                        Label("取消委托", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.72))
                .shadow(color: .black.opacity(0.035), radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(NSColor.separatorColor).opacity(0.45), lineWidth: 1)
        )
    }

    private var tradeHistoryPanel: some View {
        let orders = manager.dashboard?.filledOrders ?? []
        return TradingCard(title: "历史成交订单（\(orders.count)）", icon: "clock.arrow.circlepath") {
            if !orders.isEmpty {
                LazyVStack(spacing: 0) {
                    tradeRowHeader
                    Divider()
                    ForEach(orders) { order in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("#\(order.orderId)")
                                Text(shortDate(order.time)).foregroundColor(.secondary)
                            }
                            .frame(width: 140, alignment: .leading)
                            Text(order.sideText)
                                .foregroundColor(order.isBuyer ? .green : .red)
                                .frame(width: 55, alignment: .leading)
                            Text(format(order.price)).frame(maxWidth: .infinity, alignment: .trailing)
                            Text(format(order.quantity)).frame(maxWidth: .infinity, alignment: .trailing)
                            Text(format(order.quoteQuantity)).frame(maxWidth: .infinity, alignment: .trailing)
                            Text(order.realizedPnL.map(signed) ?? "—")
                                .foregroundColor((order.realizedPnL ?? 0) >= 0 ? .green : .red)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            Text(commissionText(order.commissions))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            HStack(spacing: 5) {
                                Button("再开") { prepareTradeAction(order, action: .open) }
                                Button("平仓") { prepareTradeAction(order, action: .close) }
                            }
                            .buttonStyle(.borderless)
                            .frame(width: 90, alignment: .trailing)
                        }
                        .font(.caption.monospacedDigit())
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            } else {
                emptyLoadingView("当前交易对暂无历史成交订单")
            }
        }
    }

    private var tradeRowHeader: some View {
        HStack {
            Text("订单号 / 成交时间").frame(width: 140, alignment: .leading)
            Text("方向").frame(width: 55, alignment: .leading)
            Text("价格").frame(maxWidth: .infinity, alignment: .trailing)
            Text("数量").frame(maxWidth: .infinity, alignment: .trailing)
            Text("成交额").frame(maxWidth: .infinity, alignment: .trailing)
            Text("已实现盈亏").frame(maxWidth: .infinity, alignment: .trailing)
            Text("手续费").frame(maxWidth: .infinity, alignment: .trailing)
            Text("快捷操作").frame(width: 90, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(.secondary)
        .padding(.vertical, 5)
    }

    private var orderConfirmationText: String {
        let sizing: String
        if manager.market == .spot {
            if action == .close && closeAll {
                sizing = "数量：全部可用数量"
            } else if !action.isReducing && sizingMode == .amount {
                sizing = "买入金额：\(amountText) USDT"
            } else {
                sizing = "数量：\(quantityText)"
            }
        } else if action == .close && closeAll {
            sizing = "金额：全部持仓\n持仓杠杆：\(selectedPosition?.leverage ?? leverage)x（不修改）"
        } else if action.isReducing {
            let value = sizingMode == .quantity ? "减少数量：\(quantityText)" : "减少名义金额：\(amountText) USDT"
            sizing = "\(value)\n持仓杠杆：\(selectedPosition?.leverage ?? leverage)x（不修改）"
        } else {
            let value = sizingMode == .quantity
                ? "数量：\(quantityText)"
                : "保证金金额：\(amountText) USDT\n预计名义金额：\(estimatedNotionalText) USDT"
            sizing = "\(value)\n杠杆：\(leverage)x"
        }
        let side = manager.market == .spot
            ? (action.isReducing ? "卖出" : "买入")
            : direction.displayName
        let priceLine = orderType == .limit ? "\n委托价格：\(priceText) USDT" : ""
        return "环境：\(manager.environment.displayName)\n市场：\(manager.market.displayName)\n交易对：\(manager.symbol.uppercased())\n操作：\(action.displayName) / \(side)\n\(sizing)\n\n订单类型：\(orderType.displayName)单\(priceLine)"
    }

    @ViewBuilder
    private var orderSizingFields: some View {
        if manager.market == .spot {
            VStack(alignment: .leading, spacing: 8) {
                if action == .close {
                    Toggle("全部卖出", isOn: $closeAll).toggleStyle(.switch)
                }

                if !action.isReducing {
                    Picker("下单单位", selection: $sizingMode) {
                        ForEach(TradingSizingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if !action.isReducing && sizingMode == .amount {
                    Text("买入金额（USDT）").font(.caption).foregroundColor(.secondary)
                    TextField("例如 100", text: $amountText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                    Text("市价单按实际花费金额买入；限价单会按金额与委托价换算数量")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("数量（基础币）").font(.caption).foregroundColor(.secondary)
                    TextField(action == .close && closeAll ? "平仓将自动使用全部可用数量" : "例如 0.001", text: $quantityText)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                        .disabled(action == .close && closeAll)
                    if action.isReducing,
                       !(action == .close && closeAll),
                       let available = availableReduceQuantity {
                        quickQuantityButtons(available: available)
                    }
                }
                if action == .close && closeAll {
                    Text("将卖出当前交易对的全部可用现货余额")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if action == .close {
                    Toggle("全部平仓", isOn: $closeAll)
                        .toggleStyle(.switch)
                }

                if !(action == .close && closeAll) {
                    Picker("下单单位", selection: $sizingMode) {
                        ForEach(TradingSizingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if sizingMode == .quantity {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("合约数量（基础币）")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("例如 0.001", text: $quantityText)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospacedDigit())
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(action.isReducing ? "减少名义金额（USDT）" : "保证金金额（USDT）")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField(action.isReducing ? "例如 100（按名义价值）" : "例如 100（保证金）", text: $amountText)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospacedDigit())
                        }
                    }

                    if action.isReducing, let available = availableReduceQuantity {
                        quickQuantityButtons(available: available)
                    }
                }

                if action.isReducing {
                    HStack {
                        Text("持仓杠杆")
                        Spacer()
                        Text("\(selectedPosition?.leverage ?? 0)x")
                            .font(.body.monospacedDigit().weight(.semibold))
                    }
                    .font(.callout)
                    Text("减仓和平仓不会修改现有持仓杠杆")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Stepper(value: $leverage, in: 1...125) {
                        HStack {
                            Text("杠杆倍数")
                            Spacer()
                            Text("\(leverage)x")
                                .font(.body.monospacedDigit().weight(.semibold))
                        }
                    }
                    Text(sizingMode == .amount
                         ? "预计名义金额：\(estimatedNotionalText) USDT"
                         : "按输入数量下单，最终占用保证金以 Binance 返回为准")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var selectedPosition: FuturesPosition? {
        manager.dashboard?.account.futuresPositions.first {
            guard $0.symbol == manager.symbol.uppercased() else { return false }
            return direction == .long ? $0.directionText == "多" : $0.directionText == "空"
        }
    }

    private var estimatedNotionalText: String {
        guard let amount = parsedDecimal(amountText), amount > 0 else {
            return "—"
        }
        return format(amount * Decimal(leverage))
    }

    private var submitButtonTitle: String {
        let side = manager.market == .spot
            ? (action.isReducing ? "卖出" : "买入")
            : direction.displayName
        return "预览\(action.displayName) · \(side)"
    }

    private var orderValidationHint: String? {
        if manager.environment.isLive && !manager.liveTradingEnabled {
            return "开启“允许实盘下单”后才可预览实盘订单"
        }
        if orderType == .limit && (parsedDecimal(priceText) ?? 0) <= 0 {
            return "请输入有效的限价价格"
        }
        if manager.market == .spot {
            if action == .close && closeAll { return nil }
            if !action.isReducing && sizingMode == .amount {
                return (parsedDecimal(amountText) ?? 0) > 0 ? nil : "请输入买入金额"
            }
            return (parsedDecimal(quantityText) ?? 0) > 0 ? nil : "请输入基础币数量"
        }
        if action.isReducing && selectedPosition == nil {
            return "当前币种与方向没有可操作的合约持仓"
        }
        if action == .close && closeAll { return nil }
        if sizingMode == .quantity {
            return (parsedDecimal(quantityText) ?? 0) > 0 ? nil : "请输入合约数量"
        }
        return (parsedDecimal(amountText) ?? 0) > 0
            ? nil
            : (action.isReducing ? "请输入减少的名义金额" : "请输入保证金金额")
    }

    private var availableReduceQuantity: Decimal? {
        if manager.market == .perpetual {
            return selectedPosition?.absoluteAmount
        }
        return manager.dashboard?.account.spotPositions.first {
            $0.symbol == manager.symbol.uppercased()
        }?.free
    }

    private func quickQuantityButtons(available: Decimal) -> some View {
        HStack(spacing: 6) {
            Text("快捷数量")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer(minLength: 2)
            ForEach([25, 50, 75, 100], id: \.self) { percent in
                Button("\(percent)%") {
                    sizingMode = .quantity
                    quantityText = (available * Decimal(percent) / 100).plainString
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("使用可用持仓的 \(percent)%")
            }
        }
    }

    private var isOrderInputValid: Bool {
        if orderType == .limit && (parsedDecimal(priceText) ?? 0) <= 0 { return false }
        if manager.market == .spot {
            if action == .close && closeAll { return true }
            if !action.isReducing && sizingMode == .amount {
                return (parsedDecimal(amountText) ?? 0) > 0
            }
            return (parsedDecimal(quantityText) ?? 0) > 0
        }
        if action == .close && closeAll { return selectedPosition != nil }
        let hasSize = sizingMode == .quantity
            ? (parsedDecimal(quantityText) ?? 0) > 0
            : (parsedDecimal(amountText) ?? 0) > 0
        guard hasSize else { return false }
        return action.isReducing ? selectedPosition != nil : (1...125).contains(leverage)
    }

    private func parsedDecimal(_ text: String) -> Decimal? {
        Decimal(
            string: text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines),
            locale: Self.decimalLocale
        )
    }

    private var spotPositionHeader: some View {
        HStack(spacing: 10) {
            Text("币种").frame(width: 90, alignment: .leading)
            Text("持仓金额").frame(width: 110, alignment: .trailing)
            Text("成本单价").frame(width: 100, alignment: .trailing)
            Text("当前单价").frame(width: 100, alignment: .trailing)
            Text("倍数").frame(width: 45, alignment: .trailing)
            Text("数量").frame(width: 105, alignment: .trailing)
            Text("盈亏/收益率").frame(width: 120, alignment: .trailing)
            Text("快捷操作").frame(width: 210, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(.secondary)
        .padding(.vertical, 5)
    }

    private func spotPositionRow(_ position: SpotPosition) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(position.asset).fontWeight(.semibold)
                if position.locked > 0 {
                    Text("冻结 \(format(position.locked))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 90, alignment: .leading)
            Text(position.marketValue.map { "\(format($0)) USDT" } ?? "—")
                .frame(width: 110, alignment: .trailing)
            Text(position.averageCost.map(format) ?? "—")
                .frame(width: 100, alignment: .trailing)
            Text(position.currentPrice.map(format) ?? "—")
                .frame(width: 100, alignment: .trailing)
            Text("1x").frame(width: 45, alignment: .trailing)
            Text(format(position.quantity)).frame(width: 105, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 2) {
                Text(position.unrealizedPnL.map(signed) ?? "—")
                Text(position.pnlRate.map { "\(signed($0))%" }
                     ?? (position.hasLoadedTradeHistory ? "无买入记录" : "待加载成本"))
                    .font(.caption2)
            }
            .foregroundColor(spotPnLColor(position.unrealizedPnL))
            .frame(width: 120, alignment: .trailing)
            HStack(spacing: 6) {
                Button("止盈止损") { protectionEditorSpotPosition = position }
                    .disabled(position.free <= 0 || manager.addingProtectionOrderIDs.contains(position.id))
                Button("加仓") { prepareSpotPositionAction(position, action: .add) }
                Button("减仓") { prepareSpotPositionAction(position, action: .reduce) }
                    .disabled(position.free <= 0)
                Button("平仓") { prepareSpotPositionAction(position, action: .close) }
                    .disabled(position.free <= 0)
            }
            .buttonStyle(.borderless)
            .frame(width: 210, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .padding(.vertical, 7)
        .help(position.averageCost == nil ? "系统会分批拉取最近成交流水；充值或测试网赠送资产没有买入成交，因此无法计算成本" : "盈亏按最多 1000 笔最近成交流水推算的持仓成本计算")
    }

    private func compactSpotPositionRow(_ position: SpotPosition) -> some View {
        let pnlColor = spotPnLColor(position.unrealizedPnL)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 11) {
                Image(systemName: "bitcoinsign")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.blue)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.blue.opacity(0.11)))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(position.asset)
                            .font(.headline.weight(.bold))
                        statusBadge("现货", color: .blue)
                        statusBadge("1x", color: .secondary)
                    }
                    Text("持仓价值  \(position.marketValue.map { "\(format($0)) USDT" } ?? "—")")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("未实现盈亏")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(position.unrealizedPnL.map(signed) ?? "—")
                        .font(.title3.monospacedDigit().weight(.bold))
                        .foregroundColor(pnlColor)
                    Text(position.pnlRate.map { "\(signed($0))%" }
                         ?? (position.hasLoadedTradeHistory ? "无买入记录" : "成本待加载"))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundColor(pnlColor)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                spacing: 8
            ) {
                positionDataTile("持仓数量", format(position.quantity), icon: "cube.fill", color: .blue)
                positionDataTile("可用数量", format(position.free), icon: "checkmark.circle.fill", color: .green)
                positionDataTile("成本单价", position.averageCost.map(format) ?? "—", icon: "building.columns.fill", color: .orange)
                positionDataTile("当前单价", position.currentPrice.map(format) ?? "—", icon: "waveform.path.ecg", color: .purple)
            }

            HStack(spacing: 8) {
                if position.locked > 0 {
                    Label("冻结 \(format(position.locked))", systemImage: "lock.fill")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.orange.opacity(0.1)))
                } else {
                    Label("全部可用", systemImage: "checkmark.shield.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.green)
                }
                Spacer()
            }

            Divider().opacity(0.7)

            HStack(spacing: 7) {
                Button {
                    protectionEditorSpotPosition = position
                } label: {
                    Label("止盈止损", systemImage: "shield.lefthalf.filled")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(position.free <= 0 || manager.addingProtectionOrderIDs.contains(position.id))

                Spacer(minLength: 4)

                Button {
                    prepareSpotPositionAction(position, action: .add)
                } label: {
                    Label("加仓", systemImage: "plus")
                }
                Button {
                    prepareSpotPositionAction(position, action: .reduce)
                } label: {
                    Label("减仓", systemImage: "minus")
                }
                .disabled(position.free <= 0)
                Button {
                    prepareSpotPositionAction(position, action: .close)
                } label: {
                    Label("平仓", systemImage: "xmark")
                }
                .tint(.orange)
                .disabled(position.free <= 0)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(15)
        .background(positionCardBackground(accent: .blue))
        .shadow(color: .black.opacity(0.04), radius: 7, y: 3)
        .help(position.averageCost == nil ? "系统会分批拉取最近成交流水；充值或测试网赠送资产没有买入成交，因此无法计算成本" : "盈亏按最多 1000 笔最近成交流水推算的持仓成本计算")
    }

    private func spotPnLColor(_ pnl: Decimal?) -> Color {
        guard let pnl else { return .secondary }
        return pnl >= 0 ? .green : .red
    }

    private func prepareSpotPositionAction(_ position: SpotPosition, action: TradingAction) {
        manager.selectTradingSymbol(position.symbol)
        direction = .long
        self.action = action
        orderType = position.currentPrice == nil ? .market : .limit
        priceText = position.currentPrice?.plainString ?? ""
        closeAll = false
        if action.isReducing {
            sizingMode = .quantity
            quantityText = position.free.plainString
            amountText = ""
        } else {
            sizingMode = .amount
            quantityText = ""
            amountText = ""
        }
        orderFormFocusToken += 1
    }

    private var positionHeader: some View {
        HStack(spacing: 10) {
            Text("币种/方向").frame(width: 100, alignment: .leading)
            Text("名义金额").frame(width: 100, alignment: .trailing)
            Text("保证金").frame(width: 90, alignment: .trailing)
            Text("开仓单价").frame(width: 100, alignment: .trailing)
            Text("标记单价").frame(width: 100, alignment: .trailing)
            Text("倍数").frame(width: 55, alignment: .trailing)
            Text("数量").frame(width: 90, alignment: .trailing)
            Text("盈亏/收益率").frame(width: 115, alignment: .trailing)
            Text("止盈 / 止损").frame(width: 180, alignment: .trailing)
            Text("快捷操作").frame(width: 210, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(.secondary)
        .padding(.vertical, 5)
    }

    private func positionRow(_ position: FuturesPosition) -> some View {
        let protectionOrders = futuresProtectionOrders(for: position)
        let takeProfitPrices = protectionOrders
            .filter { $0.type.contains("TAKE_PROFIT") }
            .map { $0.triggerPrice > 0 ? $0.triggerPrice : $0.price }
        let stopLossPrices = protectionOrders
            .filter { $0.type.contains("STOP") && !$0.type.contains("TAKE_PROFIT") }
            .map { $0.triggerPrice > 0 ? $0.triggerPrice : $0.price }
        return HStack(spacing: 10) {
            HStack(spacing: 5) {
                Text(position.symbol).fontWeight(.semibold)
                Text(position.directionText)
                    .foregroundColor(position.directionText == "多" ? .green : .red)
            }
            .frame(width: 100, alignment: .leading)
            Text("\(format(position.absoluteNotionalValue)) \(position.marginAsset)")
                .frame(width: 100, alignment: .trailing)
            Text(format(position.initialMargin)).frame(width: 90, alignment: .trailing)
            Text(format(position.entryPrice)).frame(width: 100, alignment: .trailing)
            Text(format(position.markPrice)).frame(width: 100, alignment: .trailing)
            Text("\(position.leverage)x").frame(width: 55, alignment: .trailing)
            Text(format(position.absoluteAmount)).frame(width: 90, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 2) {
                Text(signed(position.unrealizedPnL))
                Text(position.pnlRate.map { "\(signed($0))%" } ?? "—")
                    .font(.caption2)
            }
            .foregroundColor(position.unrealizedPnL >= 0 ? .green : .red)
            .frame(width: 115, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 2) {
                Text("止盈 \(pendingOrderProtectionText(takeProfitPrices))")
                    .foregroundColor(takeProfitPrices.isEmpty ? .secondary : .green)
                Text("止损 \(pendingOrderProtectionText(stopLossPrices))")
                    .foregroundColor(stopLossPrices.isEmpty ? .secondary : .red)
            }
            .frame(width: 180, alignment: .trailing)
            HStack(spacing: 6) {
                Button(protectionOrders.isEmpty ? "设置止盈止损" : "修改止盈止损") {
                    protectionEditorPosition = position
                }
                    .disabled(manager.addingProtectionOrderIDs.contains(position.id))
                Button("加仓") { preparePositionAction(position, action: .add) }
                Button("减仓") { preparePositionAction(position, action: .reduce) }
                Button("平仓") { preparePositionAction(position, action: .close) }
            }
            .buttonStyle(.borderless)
            .frame(width: 210, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .padding(.vertical, 7)
    }

    private func compactFuturesPositionRow(_ position: FuturesPosition) -> some View {
        let directionColor: Color = position.directionText == "多" ? .green : .red
        let pnlColor: Color = position.unrealizedPnL >= 0 ? .green : .red
        let protectionOrders = futuresProtectionOrders(for: position)
        let takeProfitPrices = protectionOrders
            .filter { $0.type.contains("TAKE_PROFIT") }
            .map { $0.triggerPrice > 0 ? $0.triggerPrice : $0.price }
        let stopLossPrices = protectionOrders
            .filter { $0.type.contains("STOP") && !$0.type.contains("TAKE_PROFIT") }
            .map { $0.triggerPrice > 0 ? $0.triggerPrice : $0.price }

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 11) {
                Image(systemName: position.directionText == "多" ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(directionColor)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(directionColor.opacity(0.11)))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(tradingPairDisplayName(position.symbol))
                            .font(.headline.weight(.bold))
                        statusBadge("\(position.directionText)仓", color: directionColor)
                        statusBadge("\(position.leverage)x", color: .orange)
                    }
                    Text("名义价值  \(format(position.absoluteNotionalValue)) \(position.marginAsset)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 3) {
                    Text("未实现盈亏")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(signed(position.unrealizedPnL))
                        .font(.title3.monospacedDigit().weight(.bold))
                        .foregroundColor(pnlColor)
                    Text(position.pnlRate.map { "\(signed($0))%" } ?? "—")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundColor(pnlColor)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                spacing: 8
            ) {
                positionDataTile("开仓单价", format(position.entryPrice), icon: "flag.checkered", color: directionColor)
                positionDataTile("标记单价", format(position.markPrice), icon: "waveform.path.ecg", color: .purple)
                positionDataTile("持仓数量", format(position.absoluteAmount), icon: "cube.fill", color: .blue)
                positionDataTile("占用保证金", "\(format(position.initialMargin)) \(position.marginAsset)", icon: "shield.fill", color: .orange)
            }

            HStack(spacing: 10) {
                pendingOrderProtectionTile(
                    "止盈",
                    prices: takeProfitPrices,
                    icon: "arrow.up.right",
                    color: .green
                )
                pendingOrderProtectionTile(
                    "止损",
                    prices: stopLossPrices,
                    icon: "arrow.down.right",
                    color: .red
                )
            }

            Divider().opacity(0.7)

            HStack(spacing: 7) {
                Button {
                    protectionEditorPosition = position
                } label: {
                    Label(
                        protectionOrders.isEmpty ? "设置保护" : "修改保护",
                        systemImage: "shield.lefthalf.filled"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(manager.addingProtectionOrderIDs.contains(position.id))

                Spacer(minLength: 4)

                Button {
                    preparePositionAction(position, action: .add)
                } label: {
                    Label("加仓", systemImage: "plus")
                }
                Button {
                    preparePositionAction(position, action: .reduce)
                } label: {
                    Label("减仓", systemImage: "minus")
                }
                Button {
                    preparePositionAction(position, action: .close)
                } label: {
                    Label("平仓", systemImage: "xmark")
                }
                .tint(.orange)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(15)
        .background(positionCardBackground(accent: directionColor))
        .shadow(color: .black.opacity(0.04), radius: 7, y: 3)
    }

    private func preparePositionAction(_ position: FuturesPosition, action: TradingAction) {
        manager.selectTradingSymbol(position.symbol)
        direction = position.directionText == "多" ? .long : .short
        self.action = action
        leverage = max(1, min(125, position.leverage))
        orderType = .limit
        priceText = position.markPrice.plainString
        sizingMode = .quantity
        quantityText = position.absoluteAmount.plainString
        amountText = ""
        closeAll = false
        orderFormFocusToken += 1
    }

    private func prepareTradeAction(_ order: FilledOrderRecord, action: TradingAction) {
        manager.selectTradingSymbol(order.symbol)
        if order.positionSide == "LONG" {
            direction = .long
        } else if order.positionSide == "SHORT" {
            direction = .short
        } else {
            direction = order.isBuyer ? .long : .short
        }
        self.action = action
        orderType = .limit
        priceText = order.price.plainString
        sizingMode = .quantity
        quantityText = order.quantity.plainString
        amountText = ""
        closeAll = false
        orderFormFocusToken += 1
    }

    private var metricColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 140), spacing: 8)]
    }

    private func metricTile(
        _ title: String,
        _ value: Decimal,
        suffix: String = "",
        colored: Bool = false,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            Text("\(format(value))\(suffix)")
                .font(.headline.monospacedDigit())
                .foregroundColor(colored ? (value >= 0 ? .green : .red) : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(10)
        .background(compactRowBackground)
    }

    private func metricTextTile(_ title: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(10)
        .background(compactRowBackground)
    }

    private func positionSectionHeader(title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.blue)
            Text(title)
                .font(.callout.weight(.semibold))
            Text("\(count) 个持仓")
                .font(.caption2.weight(.semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.09)))
            Spacer()
            Text("价格与盈亏实时更新")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func positionDataTile(
        _ title: String,
        _ value: String,
        icon: String,
        color: Color
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 25, height: 25)
                .background(Circle().fill(color.opacity(0.1)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(color.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(color.opacity(0.11), lineWidth: 1)
        )
    }

    private func positionCardBackground(accent: Color) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.76))
            RoundedRectangle(cornerRadius: 14)
                .stroke(accent.opacity(0.2), lineWidth: 1)
            Capsule()
                .fill(accent.opacity(0.75))
                .frame(width: 3)
                .padding(.vertical, 12)
                .padding(.leading, 1)
        }
    }

    private func pendingOrderMetric(
        _ title: String,
        _ value: String,
        icon: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pendingOrderSummaryTile(
        _ title: String,
        _ value: String,
        icon: String,
        color: Color
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 26, height: 26)
                .background(Circle().fill(color.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(color.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(color.opacity(0.14), lineWidth: 1)
        )
    }

    private func pendingOrderProtectionTile(
        _ title: String,
        prices: [Decimal],
        icon: String,
        color: Color
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(color)
                .frame(width: 24, height: 24)
                .background(Circle().fill(color.opacity(0.12)))
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(color)
            Spacer(minLength: 8)
            Text(prices.isEmpty ? "未设置" : pendingOrderProtectionText(prices))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundColor(prices.isEmpty ? .secondary : color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(color.opacity(prices.isEmpty ? 0.025 : 0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(color.opacity(prices.isEmpty ? 0.08 : 0.16), lineWidth: 1)
        )
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.11)))
    }

    private var compactRowBackground: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(Color(NSColor.windowBackgroundColor).opacity(0.56))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
            )
    }

    private func emptyLoadingView(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, minHeight: 70)
    }

    private func format(_ value: Decimal) -> String {
        Self.tradingNumberFormatter.string(from: value as NSDecimalNumber) ?? value.plainString
    }

    private func signed(_ value: Decimal) -> String {
        "\(value >= 0 ? "+" : "")\(format(value))"
    }

    private func shortDate(_ date: Date) -> String {
        Self.tradeDateFormatter.string(from: date)
    }

    private func tradingPairDisplayName(_ symbol: String) -> String {
        let normalized = symbol.uppercased()
        guard normalized.hasSuffix("USDT"), normalized.count > 4 else { return normalized }
        return "\(normalized.dropLast(4))/USDT"
    }

    private func pendingOrderSideText(_ order: PendingOrder) -> String {
        var parts = [order.side == "BUY" ? "买入" : "卖出"]
        if order.positionSide == "LONG" {
            parts.append("多")
        } else if order.positionSide == "SHORT" {
            parts.append("空")
        }
        if order.closePosition {
            parts.append("全平")
        } else if order.reduceOnly {
            parts.append("减仓")
        }
        return parts.joined(separator: "·")
    }

    private func pendingOrderMarginText(_ order: PendingOrder) -> String {
        guard let margin = order.estimatedMargin else { return "—" }
        return "≈\(format(margin)) USDT"
    }

    private func pendingOrderLeverageText(_ order: PendingOrder) -> String {
        order.leverage.map { "\($0)x" } ?? "—"
    }

    private func pendingOrderCommissionText(_ order: PendingOrder) -> String {
        guard let commission = order.estimatedCommission else { return "—" }
        let asset = order.estimatedCommissionAsset.map { " \($0)" } ?? ""
        return "≈\(format(commission))\(asset)"
    }

    private func pendingOrderProtectionText(_ prices: [Decimal]) -> String {
        guard !prices.isEmpty else { return "—" }
        return prices.map(format).joined(separator: " / ")
    }

    private func futuresProtectionOrders(for position: FuturesPosition) -> [PendingOrder] {
        let isLong = position.positionSide == "LONG"
            || (position.positionSide == "BOTH" && position.amount > 0)
        return (manager.dashboard?.pendingOrders ?? []).filter { order in
            guard order.isAlgoOrder,
                  order.symbol == position.symbol,
                  order.closePosition || order.reduceOnly,
                  order.type.contains("TAKE_PROFIT") || order.type.contains("STOP") else {
                return false
            }
            let sideMatches = isLong ? order.side == "SELL" : order.side == "BUY"
            let positionSideMatches = order.positionSide == position.positionSide
                || order.positionSide == "BOTH"
                || position.positionSide == "BOTH"
            return sideMatches && positionSideMatches
        }
    }

    private func pendingOrderTypeText(_ type: String) -> String {
        switch type {
        case "LIMIT": return "限价"
        case "MARKET": return "市价"
        case "LIMIT_MAKER": return "只挂单限价"
        case "STOP", "STOP_MARKET", "STOP_LOSS": return "止损"
        case "STOP_LOSS_LIMIT": return "止损限价"
        case "TAKE_PROFIT", "TAKE_PROFIT_MARKET": return "止盈"
        case "TAKE_PROFIT_LIMIT": return "止盈限价"
        case "TRAILING_STOP_MARKET": return "追踪止损"
        default: return type.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func pendingOrderStatusText(_ status: String) -> String {
        switch status {
        case "NEW": return "待成交"
        case "PARTIALLY_FILLED": return "部分成交"
        case "PENDING_NEW": return "提交中"
        case "PENDING_CANCEL": return "撤销中"
        case "TRIGGERED": return "已触发"
        default: return status
        }
    }

    private func pendingOrderStatusColor(_ status: String) -> Color {
        switch status {
        case "PARTIALLY_FILLED": return .orange
        case "PENDING_CANCEL": return .red
        case "TRIGGERED": return .purple
        default: return .blue
        }
    }

    private func cancelOrderConfirmationText(_ order: PendingOrder) -> String {
        let priceText: String
        if order.price > 0 {
            priceText = "委托价：\(format(order.price)) USDT"
        } else if order.triggerPrice > 0 {
            priceText = "触发价：\(format(order.triggerPrice)) USDT"
        } else {
            priceText = "委托价：市价"
        }
        let remaining = order.closePosition && order.originalQuantity == 0
            ? "全部"
            : format(order.remainingQuantity)
        return "环境：\(manager.environment.displayName)\n市场：\(manager.market.displayName)\n交易对：\(tradingPairDisplayName(order.symbol))\n方向：\(pendingOrderSideText(order))\n类型：\(pendingOrderTypeText(order.type))\n\(priceText)\n剩余数量：\(remaining)\n订单号：#\(order.orderId)\n\n取消后无法恢复。"
    }

    private func shortTime(_ date: Date) -> String {
        Self.refreshTimeFormatter.string(from: date)
    }

    private func commissionText(_ commissions: [String: Decimal]) -> String {
        if commissions.isEmpty { return "—" }
        return commissions.keys.sorted().map { "\(format(commissions[$0] ?? 0)) \($0)" }.joined(separator: " / ")
    }
}

private enum TradingPageSection: String, CaseIterable, Identifiable {
    case overview
    case orders
    case analytics
    case trades

    var id: String { rawValue }
    var anchorID: String { "trading-section-\(rawValue)" }

    var title: String {
        switch self {
        case .overview: return "持仓总览"
        case .orders: return "当前委托"
        case .analytics: return "交易分析"
        case .trades: return "历史成交订单"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "wallet.pass"
        case .orders: return "list.bullet.rectangle"
        case .analytics: return "chart.bar"
        case .trades: return "clock"
        }
    }
}

private enum TradingAlert: Identifiable {
    case enableLive
    case submitOrder
    case cancelOrder(PendingOrder)

    var id: String {
        switch self {
        case .enableLive: return "enable-live"
        case .submitOrder: return "submit-order"
        case .cancelOrder(let order): return "cancel-order-\(order.id)"
        }
    }
}

private struct TradingCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
            content
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(NSColor.separatorColor).opacity(0.7), lineWidth: 1)
        )
    }
}

private struct CredentialsEditor: View {
    @ObservedObject var manager: TradingManager
    @Binding var isPresented: Bool
    @State private var apiKey = ""
    @State private var secretKey = ""
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Binance API 凭据").font(.title2.weight(.semibold))
            Text("作用域：\(manager.environment.displayName) · \(manager.market.displayName)")
                .foregroundColor(.secondary)

            Label("Secret 仅写入 macOS 钥匙串。建议在 Binance 创建启用 IP 白名单、关闭提现权限的专用 API Key。", systemImage: "lock.shield")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if manager.credentialsConfigured, let preview = manager.credentialPreview {
                VStack(alignment: .leading, spacing: 12) {
                    Label("已配置", systemImage: "checkmark.shield.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.green)

                    HStack {
                        Text("API Key")
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Text(preview.maskedApiKey)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    HStack {
                        Text("Secret")
                            .foregroundColor(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Text(preview.maskedSecretKey)
                            .font(.body.monospaced())
                    }

                    if !preview.canDelete {
                        Label("该凭据由启动环境变量提供，需从启动环境中删除。", systemImage: "terminal")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(NSColor.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                )
            } else {
                TextField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                SecureField("Secret Key", text: $secretKey)
                    .textFieldStyle(.roundedBorder)
            }

            if let error = manager.errorMessage {
                Text(error).font(.caption).foregroundColor(.red)
            } else if let status = manager.statusMessage {
                Text(status).font(.caption).foregroundColor(.green)
            }

            HStack {
                if manager.credentialsConfigured, manager.credentialPreview?.canDelete == true {
                    Button("删除当前凭据", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                }
                Spacer()
                Button(manager.credentialsConfigured ? "关闭" : "取消") { isPresented = false }
                if manager.credentialsConfigured {
                    Button("测试连接") {
                        Task { await manager.testConnection() }
                    }
                    .disabled(manager.isLoading)
                } else {
                    Button("添加") {
                        manager.saveCredentials(apiKey: apiKey, secretKey: secretKey)
                        if manager.credentialsConfigured {
                            apiKey = ""
                            secretKey = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || secretKey.isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
        .alert("删除当前 API 凭据？", isPresented: $showingDeleteConfirmation) {
            Button("删除", role: .destructive) {
                manager.deleteCredentials()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从 macOS 钥匙串删除 \(manager.environment.displayName) · \(manager.market.displayName) 的 API Key 与 Secret。")
        }
    }
}

private struct TradingSymbolEditor: View {
    @ObservedObject var manager: TradingManager
    @Binding var isPresented: Bool
    @State private var symbolInput = ""
    @State private var isValidating = false
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加建仓币种").font(.title2.weight(.semibold))
            Text("作用域：\(manager.environment.displayName) · \(manager.market.displayName)")
                .foregroundColor(.secondary)

            Text("输入币种简称或 USDT 交易对。添加前会向当前币安环境校验是否可交易。")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("例如 OP、XRP、1000PEPE 或 OPUSDT", text: Binding(
                get: { symbolInput },
                set: { value in
                    symbolInput = String(
                        value
                            .filter { $0.isLetter || $0.isNumber }
                            .uppercased()
                            .prefix(16)
                    )
                    validationError = nil
                }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit { addSymbol() }

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                Button {
                    addSymbol()
                } label: {
                    if isValidating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("验证并添加")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(symbolInput.count < 2 || isValidating)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func addSymbol() {
        guard !isValidating, symbolInput.count >= 2 else { return }
        isValidating = true
        validationError = nil
        Task {
            do {
                try await manager.addTradingSymbol(symbolInput)
                isPresented = false
            } catch {
                validationError = error.localizedDescription
            }
            isValidating = false
        }
    }
}

private struct ExistingPositionProtectionEditor: View {
    @ObservedObject var manager: TradingManager
    let position: FuturesPosition

    @Environment(\.dismiss) private var dismiss
    @State private var takeProfitEnabled = true
    @State private var takeProfitText = ""
    @State private var stopLossEnabled = true
    @State private var stopLossText = ""
    @State private var showingConfirmation = false

    private static let decimalLocale = Locale(identifier: "en_US_POSIX")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(hasExistingProtection ? "修改持仓止盈止损" : "设置持仓止盈止损")
                .font(.title2.weight(.semibold))
            Text("\(position.symbol) · \(directionText) · \(position.leverage)x")
                .font(.callout.monospacedDigit())
                .foregroundColor(.secondary)

            Label(
                "保护单使用标记价格触发，并按市价平掉该方向全部持仓。保存时会替换该方向现有的止盈止损。",
                systemImage: "info.circle"
            )
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 20) {
                Text("开仓价 \(position.entryPrice.plainString)")
                Text("标记价 \(position.markPrice.plainString)")
            }
            .font(.caption.monospacedDigit())
            .foregroundColor(.secondary)

            if hasExistingProtection {
                Label("已自动带入当前数值。新保护单创建成功后才会撤销对应旧单。", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundColor(.blue)
            }

            Toggle("启用止盈", isOn: $takeProfitEnabled)
            if takeProfitEnabled {
                TextField("止盈触发价（USDT）", text: $takeProfitText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospacedDigit())
            }

            Toggle("启用止损", isOn: $stopLossEnabled)
            if stopLossEnabled {
                TextField("止损触发价（USDT）", text: $stopLossText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospacedDigit())
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if manager.environment.isLive && !manager.liveTradingEnabled {
                Label("请先在交易页开启“允许实盘下单”", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button {
                    showingConfirmation = true
                } label: {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(hasExistingProtection ? "预览修改" : "预览设置")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    validationMessage != nil
                        || isSubmitting
                        || (manager.environment.isLive && !manager.liveTradingEnabled)
                )
            }
        }
        .padding(22)
        .frame(width: 500)
        .onAppear(perform: loadExistingValues)
        .alert(hasExistingProtection ? "确认修改持仓保护？" : "确认设置持仓保护？", isPresented: $showingConfirmation) {
            Button(hasExistingProtection ? "确认修改" : "确认设置", role: .destructive) {
                Task {
                    let succeeded = await manager.updateProtection(
                        to: position,
                        replacing: existingProtectionOrders,
                        takeProfitText: takeProfitEnabled ? takeProfitText : "",
                        stopLossText: stopLossEnabled ? stopLossText : ""
                    )
                    if succeeded { dismiss() }
                }
            }
            Button("返回", role: .cancel) {}
        } message: {
            Text(confirmationText)
        }
    }

    private var isSubmitting: Bool {
        manager.addingProtectionOrderIDs.contains(position.id)
    }

    private var isLong: Bool {
        if position.positionSide == "LONG" { return true }
        if position.positionSide == "SHORT" { return false }
        return position.amount > 0
    }

    private var directionText: String {
        isLong ? "多仓" : "空仓"
    }

    private var hasExistingProtection: Bool {
        !existingProtectionOrders.isEmpty
    }

    private var existingProtectionOrders: [PendingOrder] {
        (manager.dashboard?.pendingOrders ?? []).filter { order in
            guard order.isAlgoOrder,
                  order.symbol == position.symbol,
                  order.closePosition || order.reduceOnly,
                  order.type.contains("TAKE_PROFIT") || order.type.contains("STOP") else {
                return false
            }
            let sideMatches = isLong ? order.side == "SELL" : order.side == "BUY"
            let positionSideMatches = order.positionSide == position.positionSide
                || order.positionSide == "BOTH"
                || position.positionSide == "BOTH"
            return sideMatches && positionSideMatches
        }
    }

    private var validationMessage: String? {
        guard takeProfitEnabled || stopLossEnabled else {
            return "请至少启用止盈或止损"
        }

        let takeProfit = decimal(takeProfitText)
        let stopLoss = decimal(stopLossText)
        if takeProfitEnabled && (takeProfit ?? 0) <= 0 {
            return "请输入有效的止盈触发价"
        }
        if stopLossEnabled && (stopLoss ?? 0) <= 0 {
            return "请输入有效的止损触发价"
        }

        let references = [position.entryPrice, position.markPrice].filter { $0 > 0 }
        guard let minimumReference = references.min(),
              let maximumReference = references.max() else { return nil }
        if let takeProfit, takeProfitEnabled {
            if isLong && takeProfit <= maximumReference { return "多仓止盈价必须高于开仓价及标记价" }
            if !isLong && takeProfit >= minimumReference { return "空仓止盈价必须低于开仓价及标记价" }
        }
        if let stopLoss, stopLossEnabled {
            if isLong && stopLoss >= minimumReference { return "多仓止损价必须低于开仓价及标记价" }
            if !isLong && stopLoss <= maximumReference { return "空仓止损价必须高于开仓价及标记价" }
        }
        return nil
    }

    private var confirmationText: String {
        var lines = [
            "环境：\(manager.environment.displayName)",
            "持仓：\(position.symbol) \(directionText)",
            "数量：\(position.absoluteAmount.plainString)",
            hasExistingProtection ? "将替换当前方向已有保护单" : "当前仓位不会被立即修改"
        ]
        if takeProfitEnabled { lines.append("止盈：\(takeProfitText) USDT") }
        if stopLossEnabled { lines.append("止损：\(stopLossText) USDT") }
        lines.append("触发后将市价平掉该方向全部持仓。")
        return lines.joined(separator: "\n")
    }

    private func loadExistingValues() {
        guard hasExistingProtection else { return }
        let takeProfit = existingProtectionOrders.first { $0.type.contains("TAKE_PROFIT") }
        let stopLoss = existingProtectionOrders.first {
            $0.type.contains("STOP") && !$0.type.contains("TAKE_PROFIT")
        }
        takeProfitEnabled = takeProfit != nil
        takeProfitText = takeProfit.map {
            ($0.triggerPrice > 0 ? $0.triggerPrice : $0.price).plainString
        } ?? ""
        stopLossEnabled = stopLoss != nil
        stopLossText = stopLoss.map {
            ($0.triggerPrice > 0 ? $0.triggerPrice : $0.price).plainString
        } ?? ""
    }

    private func decimal(_ text: String) -> Decimal? {
        Decimal(
            string: text
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            locale: Self.decimalLocale
        )
    }
}

private struct ExistingSpotPositionProtectionEditor: View {
    @ObservedObject var manager: TradingManager
    let position: SpotPosition

    @Environment(\.dismiss) private var dismiss
    @State private var takeProfitEnabled = true
    @State private var takeProfitText = ""
    @State private var stopLossEnabled = true
    @State private var stopLossText = ""
    @State private var showingConfirmation = false

    private static let decimalLocale = Locale(identifier: "en_US_POSIX")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("为现货持仓添加止盈止损")
                .font(.title2.weight(.semibold))
            Text("\(position.symbol) · 可用 \(position.free.plainString) \(position.asset)")
                .font(.callout.monospacedDigit())
                .foregroundColor(.secondary)

            Label(
                "将使用当前可用数量创建 OCO 或单个条件卖单。已被其他挂单冻结的数量不会重复使用。",
                systemImage: "info.circle"
            )
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if hasExistingProtection {
                Label("当前交易对已经存在卖出条件单；继续添加前请确认可用数量和触发价格。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Toggle("添加止盈", isOn: $takeProfitEnabled)
            if takeProfitEnabled {
                TextField("止盈触发价（USDT）", text: $takeProfitText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospacedDigit())
            }

            Toggle("添加止损", isOn: $stopLossEnabled)
            if stopLossEnabled {
                TextField("止损触发价（USDT）", text: $stopLossText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospacedDigit())
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if manager.environment.isLive && !manager.liveTradingEnabled {
                Label("请先在交易页开启“允许实盘下单”", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("预览并添加") { showingConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        validationMessage != nil
                            || isSubmitting
                            || (manager.environment.isLive && !manager.liveTradingEnabled)
                    )
            }
        }
        .padding(22)
        .frame(width: 500)
        .alert("确认添加现货保护？", isPresented: $showingConfirmation) {
            Button("确认添加", role: .destructive) {
                Task {
                    let succeeded = await manager.addProtection(
                        to: position,
                        takeProfitText: takeProfitEnabled ? takeProfitText : "",
                        stopLossText: stopLossEnabled ? stopLossText : ""
                    )
                    if succeeded { dismiss() }
                }
            }
            Button("返回", role: .cancel) {}
        } message: {
            Text(confirmationText)
        }
    }

    private var isSubmitting: Bool {
        manager.addingProtectionOrderIDs.contains(position.id)
    }

    private var hasExistingProtection: Bool {
        manager.dashboard?.pendingOrders.contains { order in
            order.symbol == position.symbol
                && order.side == "SELL"
                && (order.type.contains("STOP") || order.type.contains("TAKE_PROFIT"))
        } ?? false
    }

    private var validationMessage: String? {
        guard position.free > 0 else { return "当前没有可用于保护单的可用数量" }
        guard takeProfitEnabled || stopLossEnabled else { return "请至少启用止盈或止损" }

        let takeProfit = decimal(takeProfitText)
        let stopLoss = decimal(stopLossText)
        if takeProfitEnabled && (takeProfit ?? 0) <= 0 { return "请输入有效的止盈触发价" }
        if stopLossEnabled && (stopLoss ?? 0) <= 0 { return "请输入有效的止损触发价" }

        let references = [position.currentPrice, position.averageCost].compactMap { $0 }.filter { $0 > 0 }
        guard let minimumReference = references.min(),
              let maximumReference = references.max() else { return nil }
        if let takeProfit, takeProfitEnabled, takeProfit <= maximumReference {
            return "现货止盈价必须高于当前价及成本价"
        }
        if let stopLoss, stopLossEnabled, stopLoss >= minimumReference {
            return "现货止损价必须低于当前价及成本价"
        }
        return nil
    }

    private var confirmationText: String {
        var lines = [
            "环境：\(manager.environment.displayName)",
            "现货：\(position.symbol)",
            "使用当前可用数量：\(position.free.plainString) \(position.asset)"
        ]
        if takeProfitEnabled { lines.append("止盈：\(takeProfitText) USDT") }
        if stopLossEnabled { lines.append("止损：\(stopLossText) USDT") }
        lines.append("提交后对应现货数量将被保护单冻结。")
        return lines.joined(separator: "\n")
    }

    private func decimal(_ text: String) -> Decimal? {
        Decimal(
            string: text
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            locale: Self.decimalLocale
        )
    }
}
