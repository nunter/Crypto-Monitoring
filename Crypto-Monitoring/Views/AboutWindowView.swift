//
//  AboutWindowView.swift
//  Crypto Monitoring
//
//  Created by Mark on 2025/10/31.
//

import SwiftUI
import Foundation
import AVFoundation

/**
 * 代理认证URLSessionDelegate
 * 用于处理AboutWindowView中的代理认证
 */
class ProxyAwareURLSessionDelegate: NSObject, URLSessionTaskDelegate {
    private let appSettings: AppSettings

    init(appSettings: AppSettings) {
        self.appSettings = appSettings
        super.init()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {

        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic ||
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest {

            // 获取代理认证信息
            Task { @MainActor in
                let username = appSettings.proxyUsername
                let password = appSettings.proxyPassword

                if !username.isEmpty && !password.isEmpty {
                    let credential = URLCredential(user: username, password: password, persistence: .forSession)
                    completionHandler(.useCredential, credential)
                } else {
                    completionHandler(.performDefaultHandling, nil)
                }
            }
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/**
 * GitHub版本信息模型
 * 用于解析GitHub API返回的版本数据
 */
struct GitHubRelease: Codable {
    let name: String
    let zipball_url: String
    let tarball_url: String
    let commit: GitHubCommit
}

struct GitHubCommit: Codable {
    let sha: String
    let url: String
}

/**
 * 更新错误类型
 */
enum UpdateError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case noReleasesFound
    case decodingError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的API地址"
        case .invalidResponse:
            return "无效的服务器响应"
        case .httpError(let code):
            return "服务器错误 (HTTP \(code))"
        case .noReleasesFound:
            return "未找到发布版本"
        case .decodingError:
            return "版本数据解析失败"
        }
    }
}

/**
 * 关于窗口视图组件
 * 使用 SwiftUI 实现的美观关于界面，替代原有的 NSAlert 对话框
 */
struct AboutWindowView: View {
    // 窗口关闭回调
    let onClose: () -> Void

    // 当前刷新间隔
    let currentRefreshInterval: String

    // 应用版本
    let appVersion: String

    // 应用设置，用于代理配置
    let appSettings: AppSettings

    // 更新检测状态
    @State private var isCheckingForUpdates = false
    @State private var showingUpdateAlert = false
    @State private var updateAlertMessage = ""

    // 音频播放器
    @State private var audioPlayer: AVAudioPlayer?

    var body: some View {
        VStack(spacing: 20) {
            // 应用图标和标题区域
            VStack(spacing: 16) {
                // 应用图标
                Image(systemName: "bitcoinsign.circle.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.orange)

                // 应用标题和版本
                VStack(spacing: 4) {
                    Text("Crypto Monitoring")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("版本 \(appVersion)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // v2.0.0 功能概览
            VStack(alignment: .leading, spacing: 12) {
                Text("Crypto Monitoring v2.0")
                    .font(.headline)
                    .fontWeight(.semibold)

                VStack(alignment: .leading, spacing: 8) {
                    FeatureRow(icon: "chart.line.uptrend.xyaxis", title: "实时行情与 K 线", description: "价格、涨跌和走势一目了然")

                    FeatureRow(icon: "bitcoinsign.circle", title: "多币种与自定义交易对", description: "支持主流币种，也可添加自定义币种")

                    FeatureRow(icon: "arrow.left.arrow.right.circle", title: "Binance 交易工作台", description: "现货与 USDT 永续合约操作")

                    FeatureRow(icon: "chart.bar.xaxis", title: "账户与交易分析", description: "余额、持仓、成交、盈亏与手续费")

                    FeatureRow(icon: "lock.shield", title: "安全优先", description: "测试网默认开启，凭据保存于钥匙串")

                }
            }

            Divider()

            // 使用提示
            VStack(alignment: .leading, spacing: 8) {
                Text("快速开始")
                    .font(.headline)
                    .fontWeight(.semibold)

                VStack(alignment: .leading, spacing: 6) {
                    TipRow(text: "• 点击菜单栏币种名称切换监控对象")
                    TipRow(text: "• Option + 点击可复制价格或打开交易窗口")
                    TipRow(text: "• 当前刷新间隔：\(currentRefreshInterval)")
                }
            }

//            Spacer()
//                .frame(height: 10) // 减少间距，让按钮上移

            // 按钮区域
            HStack(spacing: 12) {
                // 检测更新按钮
                Button(action: checkForUpdates) {
                    HStack {
                        if isCheckingForUpdates {
                            ProgressView()
                                .scaleEffect(0.4)
                                .frame(width: 8, height: 8)
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                        Text(isCheckingForUpdates ? "检测中..." : "检测更新")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isCheckingForUpdates)

                Spacer()

                // 关闭按钮
                Button(action: onClose) {
                    Text("确定")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440, height: 620) // 设置固定高度以适应内容
        .alert("检测更新", isPresented: $showingUpdateAlert) {
            Button("确定", role: .cancel) {
                // 如果消息中包含"发现新版本"，则打开发布页面并关闭窗口
                if updateAlertMessage.contains("发现新版本") {
                    openReleasePage()
                    onClose()
                }
            }
        } message: {
            Text(updateAlertMessage)
        }
    }

    /**
     * 检测更新
     */
    private func checkForUpdates() {
        isCheckingForUpdates = true

        // 在后台线程执行网络请求
        DispatchQueue.global(qos: .userInitiated).async {
            self.performUpdateCheck()
        }
    }

    /**
     * 执行更新检测
     */
    private func performUpdateCheck() {
        do {
            // 获取最新版本信息
            let latestVersion = try fetchLatestVersion()

            // 比较版本号
            let comparisonResult = compareVersions(appVersion, latestVersion)

            // 回到主线程更新UI状态
            DispatchQueue.main.async {
                self.isCheckingForUpdates = false

                switch comparisonResult {
                case .orderedSame:
                    self.updateAlertMessage = "🎉 您已使用最新版本！"
                    self.showingUpdateAlert = true
                case .orderedAscending:
                    self.updateAlertMessage = "🆕 发现新版本！\n当前版本：\(self.appVersion)\n最新版本：\(latestVersion)\n\n点击确定后将打开GitHub发布页面。"
                    self.playAlarmSound() // 播放提示音
                    self.showingUpdateAlert = true
                case .orderedDescending:
                    self.updateAlertMessage = "🎉 您已使用最新版本！\n当前版本：\(self.appVersion)"
                    self.showingUpdateAlert = true
                }
            }

        } catch {
            let errorMessage = error.localizedDescription

            DispatchQueue.main.async {
                self.isCheckingForUpdates = false
                self.updateAlertMessage = "❌ 检测更新失败\n\n错误信息：\(errorMessage)\n\n请检查网络连接后重试。"
                self.showingUpdateAlert = true
            }
        }
    }

    /**
     * 从GitHub API获取最新版本
     * - Returns: 最新版本号字符串
     * - Throws: 网络错误或解析错误
     */
    private func fetchLatestVersion() throws -> String {
        // GitHub API配置
        let gitHubAPIURL = "https://api.github.com/repos/nunter/Crypto-Monitoring/tags"

        // 构建请求URL
        guard let url = URL(string: gitHubAPIURL) else {
            throw UpdateError.invalidURL
        }

        // 创建支持代理的URLSession
        let session = createProxyAwareURLSession()

        // 使用信号量实现同步网络请求
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String, Error>?

        // 配置请求
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("Crypto-Monitoring", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15.0

        // 发送网络请求
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                result = .failure(error)
                semaphore.signal()
                return
            }

            // 检查HTTP响应状态
            guard let httpResponse = response as? HTTPURLResponse else {
                result = .failure(UpdateError.invalidResponse)
                semaphore.signal()
                return
            }

            guard httpResponse.statusCode == 200 else {
                result = .failure(UpdateError.httpError(httpResponse.statusCode))
                semaphore.signal()
                return
            }

            guard let data = data else {
                result = .failure(UpdateError.noReleasesFound)
                semaphore.signal()
                return
            }

            do {
                // 解析JSON数据
                let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)

                guard let latestRelease = releases.first else {
                    result = .failure(UpdateError.noReleasesFound)
                    semaphore.signal()
                    return
                }

                // 提取版本号（去掉v前缀）
                let versionString = latestRelease.name
                let cleanVersion = versionString.hasPrefix("v") ?
                    String(versionString.dropFirst()) : versionString

                result = .success(cleanVersion)
            } catch {
                result = .failure(UpdateError.decodingError)
            }

            semaphore.signal()
        }

        task.resume()
        semaphore.wait()

        // 处理结果
        guard let result = result else {
            throw UpdateError.noReleasesFound
        }

        switch result {
        case .success(let version):
            return version
        case .failure(let error):
            throw error
        }
    }

    /**
     * 创建支持代理的URLSession
     * - Returns: 配置好的URLSession
     */
    private func createProxyAwareURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15.0
        configuration.timeoutIntervalForResource = 30.0

        // 如果启用了代理，配置代理设置
        if appSettings.proxyEnabled {
            let proxyDict: [AnyHashable: Any] = [
                kCFNetworkProxiesHTTPEnable: 1,
                kCFNetworkProxiesHTTPProxy: appSettings.proxyHost,
                kCFNetworkProxiesHTTPPort: appSettings.proxyPort,
                kCFNetworkProxiesHTTPSEnable: 1,
                kCFNetworkProxiesHTTPSProxy: appSettings.proxyHost,
                kCFNetworkProxiesHTTPSPort: appSettings.proxyPort
            ]
            configuration.connectionProxyDictionary = proxyDict
        }

        // 创建代理认证凭证存储
        if appSettings.proxyEnabled && !appSettings.proxyUsername.isEmpty && !appSettings.proxyPassword.isEmpty {
            let credential = URLCredential(user: appSettings.proxyUsername, password: appSettings.proxyPassword, persistence: .forSession)

            // 为HTTP设置认证
            let httpProtectionSpace = URLProtectionSpace(
                host: appSettings.proxyHost,
                port: appSettings.proxyPort,
                protocol: "http",
                realm: nil,
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic
            )
            URLCredentialStorage.shared.setDefaultCredential(credential, for: httpProtectionSpace)

            // 为HTTPS设置认证
            let httpsProtectionSpace = URLProtectionSpace(
                host: appSettings.proxyHost,
                port: appSettings.proxyPort,
                protocol: "https",
                realm: nil,
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic
            )
            URLCredentialStorage.shared.setDefaultCredential(credential, for: httpsProtectionSpace)
        }

        // 创建delegate并设置URLSession
        let delegate = ProxyAwareURLSessionDelegate(appSettings: appSettings)
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /**
     * 比较版本号
     * - Parameters:
     *   - version1: 版本号1
     *   - version2: 版本号2
     * - Returns: 比较结果
     */
    private func compareVersions(_ version1: String, _ version2: String) -> ComparisonResult {
        // 处理版本号格式，移除非数字字符（除点外）
        let cleanV1 = version1.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)
        let cleanV2 = version2.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)

        let v1Components = cleanV1.split(separator: ".").compactMap { Int($0) }
        let v2Components = cleanV2.split(separator: ".").compactMap { Int($0) }

        let maxCount = max(v1Components.count, v2Components.count)

        for i in 0..<maxCount {
            let v1Value = i < v1Components.count ? v1Components[i] : 0
            let v2Value = i < v2Components.count ? v2Components[i] : 0

            if v1Value < v2Value {
                return .orderedAscending
            } else if v1Value > v2Value {
                return .orderedDescending
            }
        }

        return .orderedSame
    }

    /**
     * 打开发布页面
     */
    private func openReleasePage() {
        let releasePageURL = "https://github.com/nunter/Crypto-Monitoring/releases/latest"
        guard let url = URL(string: releasePageURL) else {
            print("❌ 无效的发布页面URL: \(releasePageURL)")
            return
        }

        NSWorkspace.shared.open(url)
        print("✅ 已在浏览器中打开发布页面: \(releasePageURL)")
    }

    /**
     * 播放提示音
     * 播放Resources目录中的alarm.mp3文件
     */
    private func playAlarmSound() {
        guard let audioPath = Bundle.main.path(forResource: "alarm", ofType: "mp3") else {
            print("❌ 无法找到alarm.mp3文件")
            return
        }

        let audioURL = URL(fileURLWithPath: audioPath)

        do {
            // 创建音频播放器 - 这个方法可能抛出错误
            let player = try AVAudioPlayer(contentsOf: audioURL)
            self.audioPlayer = player
            player.prepareToPlay()

            // 播放音频
            player.play()
            print("✅ 已播放更新提示音")
        } catch {
            print("❌ 播放提示音失败: \(error.localizedDescription)")
        }
    }
}

/**
 * 功能特性行组件
 */
struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

/**
 * 使用技巧行组件
 */
struct TipRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.body)
                .foregroundColor(.primary)
            Spacer()
        }
    }
}

/**
 * 关于窗口管理器
 * 负责创建和管理关于窗口的显示
 */
class AboutWindowManager: ObservableObject {
    private var aboutWindow: NSWindow?

    /**
     * 显示关于窗口
     * - Parameters:
     *   - currentRefreshInterval: 当前刷新间隔显示文本
     *   - appVersion: 应用版本号
     *   - appSettings: 应用设置，用于代理配置
     */
    func showAboutWindow(currentRefreshInterval: String, appVersion: String, appSettings: AppSettings) {
        // 如果窗口已存在，则将其带到前台
        if let existingWindow = aboutWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }

        // 创建新的关于窗口
        let aboutView = AboutWindowView(
            onClose: { [weak self] in
                self?.closeAboutWindow()
            },
            currentRefreshInterval: currentRefreshInterval,
            appVersion: appVersion,
            appSettings: appSettings
        )

        let hostingView = NSHostingView(rootView: aboutView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 620), // 与视图尺寸保持一致
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        window.title = "关于"
        window.contentViewController = NSViewController()
        window.contentViewController?.view = hostingView

        // 强制窗口布局完成后再设置居中位置
        window.layoutIfNeeded()

        // 设置窗口在屏幕垂直居中显示
        centerWindowInScreen(window)

        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible

        // 设置窗口级别，确保显示在最前面
        window.level = .floating

        // 保存窗口引用
        self.aboutWindow = window

        // 显示窗口
        window.makeKeyAndOrderFront(nil)

        print("✅ 已显示关于窗口")
    }

    /**
     * 将窗口在屏幕中垂直居中显示
     * - Parameter window: 要居中的窗口
     */
    private func centerWindowInScreen(_ window: NSWindow) {
        guard let screen = NSScreen.main else {
            // 如果无法获取主屏幕信息，使用默认的 center() 方法
            window.center()
            return
        }

        // 先使用系统的 center() 方法进行基础居中
        window.center()

        // 获取居中后的窗口位置
        let currentFrame = window.frame
        let screenFrame = screen.visibleFrame

        // 计算理想的垂直居中位置
        let idealCenterY = screenFrame.origin.y + (screenFrame.height - currentFrame.height) / 2

        // 如果当前Y位置不等于理想的Y位置，进行调整
        if abs(currentFrame.origin.y - idealCenterY) > 1 {
            var adjustedFrame = currentFrame
            adjustedFrame.origin.y = idealCenterY
            window.setFrame(adjustedFrame, display: false)

            print("✅ 窗口位置已调整到垂直居中")
            print("📐 原始Y位置: \(currentFrame.origin.y)")
            print("📐 调整后Y位置: \(idealCenterY)")
        } else {
            print("✅ 窗口已经在垂直居中位置")
        }

        print("📐 屏幕可见区域: \(screenFrame)")
        print("📐 最终窗口位置: \(window.frame)")
    }

    /**
     * 关闭关于窗口
     */
    private func closeAboutWindow() {
        aboutWindow?.close()
        aboutWindow = nil
        print("✅ 已关闭关于窗口")
    }
}

#Preview {
    AboutWindowView(
        onClose: {},
        currentRefreshInterval: "30秒",
        appVersion: "2.0.0",
        appSettings: AppSettings()
    )
}
