# Crypto Monitoring

<div align="center">

![Crypto Monitoring](./assets/iShot_2025-11-04_00.30.31.png)

**面向 macOS 的轻量级加密货币行情与交易监控工具**

[![Version](https://img.shields.io/badge/version-v2.0.0-2ea44f)](https://github.com/nunter/Crypto-Monitoring/releases)
[![Platform](https://img.shields.io/badge/platform-macOS-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.0%2B-F05138?logo=swift&logoColor=white)](https://swift.org/)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-007AFF)](https://developer.apple.com/xcode/swiftui/)
[![License](https://img.shields.io/badge/license-GPL--3.0-green)](./LICENSE)

[项目主页](https://github.com/nunter/Crypto-Monitoring) · [提交 Issue](https://github.com/nunter/Crypto-Monitoring/issues) · [查看 Releases](https://github.com/nunter/Crypto-Monitoring/releases)

</div>

## 项目简介

Crypto Monitoring 是一款原生 macOS 菜单栏应用，用于快速查看加密货币行情，并在需要时进行 Binance 账户与交易管理。应用常驻菜单栏，不占用 Dock 空间，支持实时价格、K 线、代理网络、自定义币种以及现货和 USDT 本位永续合约操作。

v2.0.0 在行情监控的基础上加入了 Binance 交易工作台和账户分析能力，同时强化了测试网优先、钥匙串凭据存储和实盘二次授权等安全措施。

## 功能特性

### 行情监控

- 支持 BTC、ETH、BNB、SOL、DOGE 等常用币种的 USDT 行情
- 支持添加 3–5 个字符的自定义币种，并自动生成图标
- 可选择 5、10、30、60 秒刷新间隔，也支持手动刷新
- 菜单栏显示当前价格、涨跌信息和连接状态
- 提供 K 线图窗口，帮助快速了解价格走势
- 网络异常时自动重试，并支持 HTTP/HTTPS 代理及代理认证

### Binance 交易与分析

- 支持现货和 USDT 本位永续合约
- 支持市价单与 GTC 限价单，以及建仓、加仓、减仓和全平
- 合约交易支持方向、杠杆、保证金和数量配置
- 查看资产余额、合约持仓、最近成交、手续费和已实现盈亏
- 支持单向持仓与双向持仓模式，并限制减仓数量不超过现有持仓
- 交易界面可从持仓和最近成交快速回填操作参数

### 安全与体验

- API Secret 仅保存于 macOS 钥匙串，不写入 UserDefaults 或项目文件
- 默认使用 Binance 测试网；实盘下单需要每次启动后重新授权
- 支持开机自启动
- 基于 SwiftUI + AppKit 构建，原生适配 macOS
- 支持Apple Silicon 通用架构

## 系统要求

- macOS 13.5 或更高版本
- Xcode 16.2 或更高版本（从源码构建）
- 可访问 Binance API 的网络环境；受限网络可配置代理

## 安装与运行

### 使用已发布版本

从 [Releases](https://github.com/nunter/Crypto-Monitoring/releases) 下载最新的 `Crypto Monitoring.app`，将应用拖入“应用程序”目录后启动。

如果 macOS 阻止首次启动，请前往“系统设置 → 隐私与安全性”，在安全提示中选择“仍要打开”。

### 从源码运行

```bash
git clone https://github.com/nunter/Crypto-Monitoring.git
cd Crypto-Monitoring
open "Crypto Monitoring.xcodeproj"
```

在 Xcode 中选择 `Crypto Monitoring` scheme，选择本机作为运行目标，然后按 `⌘R` 启动。

常用构建命令：

```bash
xcodebuild -project "Crypto Monitoring.xcodeproj" -scheme "Crypto Monitoring" -configuration Debug build
xcodebuild -project "Crypto Monitoring.xcodeproj" -scheme "Crypto Monitoring" -configuration Release build
```

## 使用 Binance 交易功能

1. 右键点击菜单栏图标，打开“Binance 交易与分析”。
2. 选择测试网或实盘，再选择现货或永续合约。
3. 在“API 凭据”中填写对应作用域的 API Key 和 Secret，并先测试连接。
4. 建议先使用 Spot Testnet / USDⓈ-M Futures Testnet 验证权限、精度和持仓模式。
5. 确认交易参数后提交订单；实盘下单前必须重新开启“允许实盘下单”，且每笔订单都会要求二次确认。

安全建议：请使用专用 API Key，仅开启读取及必要的交易权限，关闭提现权限，并在 Binance 后台设置 IP 白名单。

## API 与数据来源

价格与交易数据来自 Binance API。公开行情接口示例：

```text
GET https://api.binance.com/api/v3/ticker/price?symbol=BTCUSDT
```

应用不会在仓库中保存 API 凭据。开发调试时也可以通过环境变量注入凭据，具体变量名请参考应用中的 Binance 凭据配置。

## 项目结构

```text
Crypto-Monitoring/
├── Core/         菜单栏应用入口与菜单管理
├── Managers/     行情、交易、缓存和凭据管理
├── Models/       行情、K 线、交易和币种模型
├── Utils/        API 地址与图标等工具
├── Views/        SwiftUI 界面
└── Windows/      交易、K 线和偏好设置窗口
```

## 贡献

欢迎通过 [Issue](https://github.com/nunter/Crypto-Monitoring/issues) 报告问题或提出建议，也欢迎提交 Pull Request。提交代码前请确认项目能够在 Xcode 中正常编译，并避免提交任何 API Key、Secret 或本地构建产物。

## 许可证

本项目采用 [GNU General Public License v3.0](./LICENSE) 发布。

## 关于项目

Crypto Monitoring 由开发者社区维护，目标是提供一个清晰、快速且安全边界明确的 macOS 加密货币监控入口。项目主页：[nunter/Crypto-Monitoring](https://github.com/nunter/Crypto-Monitoring)。

特别感谢原作者 [jiayouzl](https://github.com/jiayouzl) 及其原始项目 [jiayouzl/Crypto-Monitoring](https://github.com/jiayouzl/Crypto-Monitoring) 的开源贡献与基础工作。
