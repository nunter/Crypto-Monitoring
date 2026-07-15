//
//  KlineChartView.swift
//  Crypto Monitoring
//
//  Created by Mark on 2026/07/09.
//

import SwiftUI
import Charts

/// K 线图窗口视图
/// 展示蜡烛图、均线、支撑/阻力位与成交量，支持多周期及现货/永续切换，并自动刷新
struct KlineChartView: View {
    /// API 符号（如 "BTCUSDT"）
    let apiSymbol: String
    /// 展示名称（如 "BTC"）
    let displayName: String
    /// 价格管理器（用于请求 K 线数据，复用其代理配置）
    let priceManager: PriceManager

    @State private var interval: KlineInterval = .fifteenMinutes
    @State private var marketType: MarketType
    @State private var klines: [Kline] = []
    @State private var isLoading: Bool = false
    @State private var loadFailed: Bool = false
    @State private var lastUpdated: Date?

    // 鼠标悬停交互状态（价格图与成交量图共享选中的 K 线，十字光标同步）
    @State private var selectedKline: Kline?
    @State private var priceHoverLocation: CGPoint?
    @State private var volumeHoverLocation: CGPoint?
    @State private var hoverPrice: Double?

    /// 自动刷新定时器（每 15 秒刷新一次最新 K 线）
    private let refreshTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    // 涨/跌配色
    private let bullColor = Color(red: 0.13, green: 0.72, blue: 0.51)
    private let bearColor = Color(red: 0.90, green: 0.29, blue: 0.35)
    private let ma7Color = Color(red: 0.95, green: 0.68, blue: 0.16)
    private let ma25Color = Color(red: 0.64, green: 0.43, blue: 0.91)
    private let ma99Color = Color(red: 0.18, green: 0.68, blue: 0.91)
    private let resistanceColor = Color(red: 0.95, green: 0.38, blue: 0.33)
    private let supportColor = Color(red: 0.20, green: 0.72, blue: 0.48)
    private let visibleKlineCount = 120
    private let longestMovingAveragePeriod = 99
    /// 上下图共用固定宽度的右侧坐标轴，保证绘图区左右边界一致。
    private let yAxisLabelWidth: CGFloat = 54

    init(apiSymbol: String, displayName: String, priceManager: PriceManager, initialMarketType: MarketType) {
        self.apiSymbol = apiSymbol
        self.displayName = displayName
        self.priceManager = priceManager
        _marketType = State(initialValue: initialMarketType)
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            controls
            indicatorLegend

            if klines.isEmpty && isLoading {
                loadingPlaceholder
            } else if klines.isEmpty && loadFailed {
                errorPlaceholder
            } else {
                priceChart
                    .frame(minHeight: 260)
                volumeChart
                    .frame(height: 100)
            }

            footer
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 560)
        .task(id: reloadKey) {
            await loadKlines()
        }
        .onReceive(refreshTimer) { _ in
            Task { await loadKlines(silently: true) }
        }
    }

    /// 触发重新加载的键（周期或市场类型变化时刷新）
    private var reloadKey: String { "\(interval.rawValue)_\(marketType.rawValue)" }

    // MARK: - 顶部信息

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(displayName)/USDT")
                .font(.system(size: 20, weight: .bold))

            if let latest = klines.last {
                Text(formatPrice(latest.close))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundColor(changeColor)

                Text(changeText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(changeColor)
            }

            Spacer()

            if isLoading {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - 控制区（周期 + 市场类型）

    private var controls: some View {
        HStack(spacing: 16) {
            Picker("周期", selection: $interval) {
                ForEach(KlineInterval.allCases) { item in
                    Text(item.shortName).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)

            Picker("市场", selection: $marketType) {
                ForEach(MarketType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 180)

            Spacer()
        }
    }

    // MARK: - 蜡烛图

    private var priceChart: some View {
        Chart {
            ForEach(visibleKlines) { k in
                // 上下影线（最高价 - 最低价）
                RuleMark(
                    x: .value("时间", k.openTime),
                    yStart: .value("最低", k.low),
                    yEnd: .value("最高", k.high)
                )
                .foregroundStyle(k.isBullish ? bullColor : bearColor)
                .lineStyle(StrokeStyle(lineWidth: 1))

                // 实体（开盘价 - 收盘价）
                RectangleMark(
                    x: .value("时间", k.openTime),
                    yStart: .value("开盘", k.open),
                    yEnd: .value("收盘", k.close),
                    width: .fixed(bodyWidth)
                )
                .foregroundStyle(k.isBullish ? bullColor : bearColor)
            }

            ForEach(movingAverage(period: 7)) { point in
                LineMark(
                    x: .value("时间", point.date),
                    y: .value("均线", point.value),
                    series: .value("周期", "MA7")
                )
                .foregroundStyle(ma7Color)
                .lineStyle(StrokeStyle(lineWidth: 1.4))
                .interpolationMethod(.linear)
            }

            ForEach(movingAverage(period: 25)) { point in
                LineMark(
                    x: .value("时间", point.date),
                    y: .value("均线", point.value),
                    series: .value("周期", "MA25")
                )
                .foregroundStyle(ma25Color)
                .lineStyle(StrokeStyle(lineWidth: 1.4))
                .interpolationMethod(.linear)
            }

            ForEach(movingAverage(period: 99)) { point in
                LineMark(
                    x: .value("时间", point.date),
                    y: .value("均线", point.value),
                    series: .value("周期", "MA99")
                )
                .foregroundStyle(ma99Color)
                .lineStyle(StrokeStyle(lineWidth: 1.4))
                .interpolationMethod(.linear)
            }

            if let resistanceLevel {
                RuleMark(y: .value("阻力位", resistanceLevel))
                    .foregroundStyle(resistanceColor.opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [7, 4]))
            }

            if let supportLevel {
                RuleMark(y: .value("支撑位", supportLevel))
                    .foregroundStyle(supportColor.opacity(0.9))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [7, 4]))
            }

            // 垂直十字光标（选中的 K 线）
            if let sel = selectedKline {
                RuleMark(x: .value("时间", sel.openTime))
                    .foregroundStyle(Color.gray.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }

            // 水平十字光标（鼠标所在价格）
            if let hoverPrice, priceHoverLocation != nil {
                RuleMark(y: .value("价格", hoverPrice))
                    .foregroundStyle(Color.gray.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .trailing, alignment: .center) {
                        Text(formatAxisPrice(hoverPrice))
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.85)))
                            .foregroundColor(.white)
                    }
            }
        }
        .chartXScale(domain: timeDomain)
        .chartYScale(domain: priceDomain)
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let price = value.as(Double.self) {
                        Text(formatAxisPrice(price))
                            .monospacedDigit()
                            .frame(width: yAxisLabelWidth, alignment: .leading)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisTimeString(date))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let plot = geo[proxy.plotAreaFrame]
                            priceHoverLocation = location
                            selectedKline = nearestKline(atX: location.x, plotOriginX: plot.origin.x, proxy: proxy)
                            hoverPrice = proxy.value(atY: location.y - plot.origin.y, as: Double.self)
                        case .ended:
                            priceHoverLocation = nil
                            hoverPrice = nil
                            selectedKline = nil
                        }
                    }

                if let sel = selectedKline, let loc = priceHoverLocation {
                    tooltipView(for: sel)
                        .position(
                            x: tooltipCenterX(loc.x, containerWidth: geo.size.width),
                            y: tooltipCenterY(loc.y, containerHeight: geo.size.height)
                        )
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - 指标图例

    private var indicatorLegend: some View {
        HStack(spacing: 14) {
            indicatorItem("MA7", value: movingAverage(period: 7).last?.value, color: ma7Color)
            indicatorItem("MA25", value: movingAverage(period: 25).last?.value, color: ma25Color)
            indicatorItem("MA99", value: movingAverage(period: 99).last?.value, color: ma99Color)

            Spacer(minLength: 6)

            indicatorItem("阻力", value: resistanceLevel, color: resistanceColor, dashed: true)
            indicatorItem("支撑", value: supportLevel, color: supportColor, dashed: true)
        }
        .font(.caption2)
        .foregroundColor(.secondary)
    }

    private func indicatorItem(_ title: String, value: Double?, color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(color)
                .frame(width: 16, height: dashed ? 1 : 2)
            Text(title)
            Text(value.map(formatAxisPrice) ?? "—")
                .monospacedDigit()
                .foregroundColor(color)
        }
    }

    // MARK: - 成交量图

    private var volumeChart: some View {
        Chart {
            ForEach(visibleKlines) { k in
                BarMark(
                    x: .value("时间", k.openTime),
                    y: .value("成交量", k.volume),
                    width: .fixed(bodyWidth)
                )
                .foregroundStyle((k.isBullish ? bullColor : bearColor).opacity(0.55))
            }

            // 垂直十字光标（与价格图同步）
            if let sel = selectedKline {
                RuleMark(x: .value("时间", sel.openTime))
                    .foregroundStyle(Color.gray.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartXScale(domain: timeDomain)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let vol = value.as(Double.self) {
                        Text(formatVolume(vol))
                            .monospacedDigit()
                            .frame(width: yAxisLabelWidth, alignment: .leading)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisTimeString(date))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let plot = geo[proxy.plotAreaFrame]
                            volumeHoverLocation = location
                            selectedKline = nearestKline(atX: location.x, plotOriginX: plot.origin.x, proxy: proxy)
                        case .ended:
                            volumeHoverLocation = nil
                            selectedKline = nil
                        }
                    }

                if let sel = selectedKline, let loc = volumeHoverLocation {
                    volumeTooltipView(for: sel)
                        .position(
                            x: tooltipCenterX(loc.x, containerWidth: geo.size.width),
                            y: min(max(loc.y, 24), max(24, geo.size.height - 24))
                        )
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - 底部信息

    private var footer: some View {
        HStack {
            Text("成交量（\(displayName)）")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            if let lastUpdated {
                Text("更新于 \(timeString(lastUpdated))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在加载 K 线数据…")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private var errorPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            Text("加载失败，请检查网络或代理设置")
                .font(.callout)
                .foregroundColor(.secondary)
            Button("重试") {
                Task { await loadKlines() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    // MARK: - 数据加载

    @MainActor
    private func loadKlines(silently: Bool = false) async {
        let requestedInterval = interval
        let requestedMarketType = marketType

        if !silently {
            isLoading = true
            klines = []
            selectedKline = nil
        }
        let result = await priceManager.fetchKlines(
            forApiSymbol: apiSymbol,
            interval: requestedInterval,
            marketType: requestedMarketType,
            limit: visibleKlineCount + longestMovingAveragePeriod - 1
        )

        // 周期/市场已切换时，丢弃旧请求的迟到结果。
        guard interval == requestedInterval, marketType == requestedMarketType else { return }
        isLoading = false

        if let result, !result.isEmpty {
            klines = result
            loadFailed = false
            lastUpdated = Date()
        } else if !silently {
            loadFailed = true
        }
    }

    // MARK: - 计算属性 / 格式化

    /// 图表只显示最新 120 根；更早的数据仅用于预热长周期均线。
    private var visibleKlines: [Kline] {
        Array(klines.suffix(visibleKlineCount))
    }

    /// 均线使用完整请求数据计算，再裁切到可见区，避免 MA99 只显示末尾一小段。
    private func movingAverage(period: Int) -> [MovingAveragePoint] {
        guard period > 0, klines.count >= period else { return [] }

        var result: [MovingAveragePoint] = []
        var sum = klines.prefix(period).reduce(0) { $0 + $1.close }
        result.append(MovingAveragePoint(date: klines[period - 1].openTime, value: sum / Double(period)))

        if klines.count > period {
            for index in period..<klines.count {
                sum += klines[index].close - klines[index - period].close
                result.append(MovingAveragePoint(date: klines[index].openTime, value: sum / Double(period)))
            }
        }
        guard let firstVisibleDate = visibleKlines.first?.openTime else { return [] }
        return result.filter { $0.date >= firstVisibleDate }
    }

    /// 使用最近 50 根已收盘 K 线的最高点作为近期阻力位。
    private var resistanceLevel: Double? {
        completedKlinesForLevels.map(\.high).max()
    }

    /// 使用最近 50 根已收盘 K 线的最低点作为近期支撑位。
    private var supportLevel: Double? {
        completedKlinesForLevels.map(\.low).min()
    }

    private var completedKlinesForLevels: ArraySlice<Kline> {
        let completed = klines.filter { $0.closeTime <= Date() }
        return completed.suffix(50)
    }

    /// 蜡烛实体宽度（根据数据量自适应）
    private var bodyWidth: CGFloat {
        let count = max(visibleKlines.count, 1)
        // 大致在 2~6 点之间自适应
        return max(2, min(6, 600.0 / CGFloat(count)))
    }

    /// 价格图和成交量图共用同一横轴范围，并在首尾各保留半根 K 线的空间。
    private var timeDomain: ClosedRange<Date> {
        guard let first = visibleKlines.first, let last = visibleKlines.last else {
            let now = Date()
            return now.addingTimeInterval(-1)...now.addingTimeInterval(1)
        }

        let candleDuration: TimeInterval
        if visibleKlines.count > 1 {
            candleDuration = visibleKlines[1].openTime.timeIntervalSince(first.openTime)
        } else {
            candleDuration = max(last.closeTime.timeIntervalSince(last.openTime), 1)
        }
        let padding = max(candleDuration / 2, 0.5)
        return first.openTime.addingTimeInterval(-padding)...last.openTime.addingTimeInterval(padding)
    }

    /// 价格坐标轴范围（留 3% 余量，避免贴边）
    private var priceDomain: ClosedRange<Double> {
        let indicatorValues = [7, 25, 99].flatMap { movingAverage(period: $0).map(\.value) }
        let lows = visibleKlines.map(\.low) + indicatorValues
        let highs = visibleKlines.map(\.high) + indicatorValues
        guard let minLow = lows.min(), let maxHigh = highs.max(), maxHigh > minLow else {
            return 0...1
        }
        let padding = (maxHigh - minLow) * 0.03
        return (minLow - padding)...(maxHigh + padding)
    }

    /// 涨跌幅颜色（相对于窗口内首根开盘价）
    private var changeColor: Color {
        guard let first = visibleKlines.first, let last = visibleKlines.last else { return .primary }
        return last.close >= first.open ? bullColor : bearColor
    }

    /// 涨跌幅文本
    private var changeText: String {
        guard let first = visibleKlines.first, let last = visibleKlines.last, first.open != 0 else { return "" }
        let change = (last.close - first.open) / first.open * 100
        let sign = change >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", change))%"
    }

    private func formatPrice(_ price: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = price < 1 ? 6 : 2
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return "$" + (formatter.string(from: NSNumber(value: price)) ?? String(format: "%.2f", price))
    }

    private func formatAxisPrice(_ price: Double) -> String {
        if price >= 1000 {
            return String(format: "%.0f", price)
        } else if price >= 1 {
            return String(format: "%.2f", price)
        } else {
            return String(format: "%.4f", price)
        }
    }

    private func formatVolume(_ volume: Double) -> String {
        if volume >= 1_000_000 {
            return String(format: "%.1fM", volume / 1_000_000)
        } else if volume >= 1_000 {
            return String(format: "%.1fK", volume / 1_000)
        } else {
            return String(format: "%.0f", volume)
        }
    }

    /// 坐标轴时间标签（根据周期决定粒度）
    private func axisTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        switch interval {
        case .fiveMinutes, .fifteenMinutes, .oneHour:
            formatter.dateFormat = "HH:mm"
        case .fourHours:
            formatter.dateFormat = "MM-dd HH:mm"
        case .oneDay:
            formatter.dateFormat = "MM-dd"
        }
        return formatter.string(from: date)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: - 悬停交互辅助

    /// 根据鼠标横坐标找到最接近的 K 线
    private func nearestKline(atX x: CGFloat, plotOriginX: CGFloat, proxy: ChartProxy) -> Kline? {
        guard let date = proxy.value(atX: x - plotOriginX, as: Date.self) else { return nil }
        return visibleKlines.min(by: {
            abs($0.openTime.timeIntervalSince(date)) < abs($1.openTime.timeIntervalSince(date))
        })
    }

    /// 价格图详情浮层（跟随鼠标显示 OHLC / 涨跌 / 成交量 / 时间）
    private func tooltipView(for k: Kline) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tooltipTimeString(k.openTime))
                .font(.caption2)
                .foregroundColor(.secondary)
            tooltipRow("开", formatPrice(k.open))
            tooltipRow("高", formatPrice(k.high))
            tooltipRow("低", formatPrice(k.low))
            tooltipRow("收", formatPrice(k.close))
            tooltipRow("涨跌", candleChangeText(k), color: k.isBullish ? bullColor : bearColor)
            tooltipRow("量", formatVolume(k.volume))
        }
        .padding(8)
        .frame(width: tooltipWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
        .shadow(radius: 4)
    }

    /// 成交量图详情浮层（跟随鼠标显示成交量 / 时间）
    private func volumeTooltipView(for k: Kline) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tooltipTimeString(k.openTime))
                .font(.caption2)
                .foregroundColor(.secondary)
            tooltipRow("量", formatVolume(k.volume))
        }
        .padding(8)
        .frame(width: tooltipWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.3)))
        .shadow(radius: 4)
    }

    private func tooltipRow(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundColor(color)
        }
    }

    /// 单根 K 线的涨跌幅文本（收盘相对开盘）
    private func candleChangeText(_ k: Kline) -> String {
        guard k.open != 0 else { return "—" }
        let change = (k.close - k.open) / k.open * 100
        let sign = change >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", change))%"
    }

    /// 浮层宽度
    private var tooltipWidth: CGFloat { 148 }

    /// 计算浮层水平中心位置（避免超出边界，鼠标右侧优先）
    private func tooltipCenterX(_ x: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let half = tooltipWidth / 2
        let gap: CGFloat = 16
        var center = x + gap + half
        if center + half > containerWidth {
            center = x - gap - half
        }
        return min(max(center, half), max(half, containerWidth - half))
    }

    /// 计算浮层垂直中心位置（估算高度约 150，避免超出上下边界）
    private func tooltipCenterY(_ y: CGFloat, containerHeight: CGFloat) -> CGFloat {
        let half: CGFloat = 75
        return min(max(y, half), max(half, containerHeight - half))
    }

    /// 浮层内时间文本（含日期）
    private func tooltipTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

/// 图表中的单个均线数据点。
private struct MovingAveragePoint: Identifiable {
    var id: Date { date }
    let date: Date
    let value: Double
}
