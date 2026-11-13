# MiscKit

[![Latest Release](https://img.shields.io/github/v/release/gexiaosen/MiscKit?label=Download)](https://github.com/gexiaosen/MiscKit/releases/latest)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue)](LICENSE)
[![macOS 26+](https://img.shields.io/badge/platform-macOS%2026%2B-black)](#compatibility)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138)](https://swift.org)
[![Apple Silicon](https://img.shields.io/badge/arch-Apple%20Silicon-silver)](#compatibility)

[English](#english) · [简体中文](#简体中文)

---

## English

A native macOS launcher and all-in-one glass-panel utility suite built with Swift 6.2 and SwiftUI — zero external code dependencies, with the single exception of [Sparkle 2](https://github.com/sparkle-project/Sparkle) for auto-updates.

### Compatibility

- **Architecture**: **Apple Silicon (`arm64`) only** (Intel `x86_64` Macs are not supported).
- **macOS Version**: Compatible with **macOS 26.0+**, developed and verified on **macOS 27.2+**.
- **Unsupported Versions**: **macOS 15 and earlier are not supported.**

### Download, First Launch & Auto-Update

**[Download the latest release](https://github.com/gexiaosen/MiscKit/releases/latest)** — grab `MiscKit-vX.Y.Z-arm64.dmg`, then drag the app to `Applications`.

Releases are distributed outside the App Store without Apple notarization, so the **first launch** requires a one-time Gatekeeper override:

```bash
xattr -cr /Applications/MiscKit.app
```

…or open **System Settings → Privacy & Security** and click **Open Anyway**.

**Auto-updates** are built in via Sparkle 2: the app silently checks the release feed once a day; when a newer version is found, a red badge appears on **Settings → About** (no popup, no interruption). Use **Check for Updates…** in the menu bar to review and install with release notes. Update archives are EdDSA-signed, so the entire update chain works without an Apple Developer Program membership.

### Built-in Tools

All tools live inside a single translucent launcher panel (`⌥Space` / `⌥Z` or double-tap modifier, configurable in Settings):

- **App Launcher**: Search and launch installed apps (English, Chinese, Pinyin, and custom aliases) + quick actions (Quit, Force Quit, Relaunch, Reveal in Finder, Terminal).
- **File Search**: Spotlight & filesystem search with quick scopes (`file`), previews, Finder/Terminal actions, and trash support.
- **Meeting Codes**: Recognizes meeting codes and invite links from typed text or recent clipboard.
- **OTP Authenticator**: TOTP/HOTP 2FA codes with Keychain-backed secret storage, QR/screenshot/migration import, time-drift calibration, and 60-second clipboard auto-clear.
- **Scratchpad Calculator (`Calc`)**: Multi-sheet live math, variables, constants, units, and percentage expressions (`calc` / `=`).
- **Health Reminders**: Configurable water & stand intervals, active hours, weekday/weekend rules, full-screen / gentle overlays, and menu bar countdowns.
- **Hosts Manager**: Multi-section Base + Overlay `/etc/hosts` editing, drag-and-drop overlay ordering, line-level toggles, validation, diff preview, automatic backups, and atomic privileged apply.
- **System Actions & Settings Panes**: Lock screen, sleep, display sleep, volume presets, media playback, trash, and deep-links into macOS System Settings panes.
- **Quicklinks & Dictionary**: Custom URL templates (`%s` / `{query}`) and built-in macOS Dictionary lookup (`dict`).

### Language Switching

- Supports **Follow System**, **English**, and **简体中文**.
- Switch live without restarting in **Settings → General → Language** (`Cmd+,`).
- Search keywords always accept English, Chinese, and Pinyin simultaneously regardless of the active UI language.

### Build, Test & Install

Build artifacts must reside outside iCloud-synced `~/Documents` directories (file-provider xattrs break `codesign`). The `Makefile` defaults `SCRATCH` to `~/.cache/misckit-build`:

```bash
make build                      # Debug build (arm64)
make test                       # Run unit tests (swift test --arch arm64)
make scan                       # Run secret scan self-test + repo scan
make app CONFIG=debug           # Build Debug bundle (app.misckit.MiscKit.dev)
make app CONFIG=release         # Build Release bundle (app.misckit.MiscKit)
make install                    # Build Release, quit old instance, install to /Applications
```

You can also invoke `swift` directly:

```bash
swift build --arch arm64 --scratch-path "$HOME/.cache/misckit-build"
swift test  --arch arm64 --scratch-path "$HOME/.cache/misckit-build"
```

### Data Storage

- **Preferences, Scratchpad Sheets, Aliases, File Scopes & Recents**: `UserDefaults`.
- **File Index, App Snapshot, Settings Pane Cache, Quicklinks, Hosts State & Backups**: `~/Library/Application Support/MiscKit/` (hosts backups roll the latest 10 snapshots).
- **OTP Secrets**: Stored strictly in the macOS Keychain; JSON metadata stores only account identifiers and display labels.

### Security Model & Privacy

- **OTP Secrets**: Stored strictly in the macOS Keychain via `SecItem*` APIs; account metadata JSON stores only non-secret identifiers and labels. Copied OTP codes are automatically cleared from `NSPasteboard` after 60 seconds (`ClipboardGuard`).
- **Privileged Writes (`Hosts`)**: Writing `/etc/hosts` always creates a timestamped local backup first and performs atomic writes via system administrator authorization (`osascript`), never storing or caching credentials.
- **Minimal Network**: The only background request is the Sparkle update check — once a day against the GitHub Releases feed, EdDSA-verified. No analytics, no telemetry, no other network activity.
- **Release Verification**: Automated secret scan (`Scripts/scan-secrets.sh`) is enforced in CI and build packaging.
- **Vulnerability Disclosure**: Please report security vulnerabilities privately via GitHub Security Advisories or maintainer contact rather than public issues.

### Development Guidelines

1. **Localization (`L10n`)**:
   - User-visible strings are defined in `Sources/MiscKitCore/Resources/Localizable.xcstrings` (both `en` and `zh-Hans`) with typed accessors in `Sources/MiscKitCore/Localization/L10n.swift`.
   - Preserve trilingual search keywords (`zh` + `en` + `pinyin`) across launcher tools and actions regardless of active UI language.
   - Use `@Environment(\.appLanguage)` in SwiftUI views for dynamic zero-restart language updates.
2. **Design System & Accessibility Audits**:
   - Use semantic `Theme.*` colors (never raw `.red` / `.orange`, `Color.red` / `Color.orange`, or `Theme.tertiaryText`).
   - Use `Type.*` font tokens; keep `ContrastAuditTests` and `TypeGateTests` passing.
3. **Security & Privacy Hygiene**:
   - Never commit real paths, emails, domains, internal IPs, keys, or personal data. Use RFC 2606 domains (`example.test`, `example.com`) in tests.
   - Run `make scan` before every commit.

### Releasing (maintainers)

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` (numeric, strictly increasing) in `Resources/Info.plist`.
2. Add a `## [X.Y.Z]` section at the top of `CHANGELOG.md` describing what changed since the previous release. This section becomes the GitHub Release notes verbatim — the first release documents every feature, later ones only the delta.
3. Commit, then `git tag vX.Y.Z && git push --tags`.

CI then runs the secret scan, tests, packages the `.dmg` (ad-hoc signed), signs it with the EdDSA key stored in repo secrets, creates the GitHub Release and uploads `appcast.xml` — existing installs pick it up on their next daily check.

### License

Licensed under the **GNU General Public License v3.0 (GPL-3.0)**. See [LICENSE](LICENSE) for details.

---

## 简体中文

原生 macOS 玻璃面板启动器与效率工具套件，基于 Swift 6.2 与 SwiftUI 构建——零第三方代码依赖（自动更新框架 [Sparkle 2](https://github.com/sparkle-project/Sparkle) 是唯一例外）。

### 系统与硬件兼容性

- **芯片架构**：**仅支持 Apple Silicon（`arm64`）Mac**，不支持 Intel（`x86_64`）机型。
- **系统版本**：**兼容 macOS 26.0+**，在 **macOS 27.2+ 环境下开发并完整验证**。
- **不兼容说明**：**不支持 macOS 15 及更早系统版本**。

### 下载、首次打开与自动更新

**[下载最新版本](https://github.com/gexiaosen/MiscKit/releases/latest)**：获取 `MiscKit-vX.Y.Z-arm64.dmg`，将 app 拖入「应用程序」。

由于不经 App Store 分发、未做苹果公证，**首次打开**需要一次性绕过 Gatekeeper：

```bash
xattr -cr /Applications/MiscKit.app
```

或在 **系统设置 → 隐私与安全性** 中点击「仍要打开」。

内置 **Sparkle 2 自动更新**：每日静默检查一次 Release feed，发现新版本仅在 **设置 → 关于** 行点亮小红点，不弹窗不打扰；通过菜单栏「检查更新…」或「关于」页按钮查看更新说明并安装。更新包经 EdDSA 签名验证，无需苹果开发者账号即可实现完整更新闭环。

### 内置工具

所有功能集成在同一个玻璃面板中（默认快捷键可在 **设置 → 快捷键** 自定义，支持组合键与双击修饰键唤起）：

- **应用直达**：支持英文、中文、拼音与自定义别名搜索，支持退出、强制退出、重启、在访达显示、终端打开等行内动作。
- **文件搜索**：结合 Spotlight 与本地索引快速检索文件与目录，支持范围过滤、预览与移至废纸篓。
- **会议号识别**：自动识别文本或剪贴板中的会议号与入会链接。
- **OTP 验证码**：基于系统钥匙串安全保存 TOTP/HOTP 密钥，支持二维码截图/迁移包导入、时间校准及复制后 60 秒自动清理剪贴板。
- **稿纸计算（Calc）**：多页实时表达式、变量、常量与单位换算。
- **健康提醒**：喝水与站立定时提醒、时段窗口与周末跳过、免打扰黑名单、全屏覆盖提醒与菜单栏倒计时。
- **Hosts 分段管理**：基座 + 多叠加段启用与拖拽排序、逐行临时禁用、语法与跨段冲突校验、生效预览、Diff 对比、自动备份与原子化管理员写入。
- **系统动作与系统设置面板直达**：锁屏、睡眠、关闭显示器、音量控制、媒体播放及 System Settings 子面板直达。
- **网址别名与词典**：自定义 URL 模板与系统词典查词。

### 中英文切换

- 内置 **跟随系统（Follow System）**、**简体中文**、**English** 三种界面语言选项。
- 在 **设置 → 通用 → 语言**（`Cmd+,`）中切换后立即生效，无需重启应用。
- 无论当前界面处于中文还是英文，搜索关键词始终同时兼容 **英文 + 中文 + 拼音**。

### 构建、测试与安装

由于 `~/Documents` 等 iCloud 同步目录会为构建产物附加 file-provider 扩展属性并导致 `codesign` 校验失败，请始终通过 `Makefile` 或显式指定 `--scratch-path "$HOME/.cache/misckit-build"` 构建：

```bash
make build                      # 编译 Debug 版本（arm64）
make test                       # 运行单元测试（swift test --arch arm64）
make scan                       # 运行敏感信息扫描自检与全仓扫描
make app CONFIG=debug           # 打包 Debug 版（app.misckit.MiscKit.dev，与正式版数据/钥匙串隔离）
make app CONFIG=release         # 打包 Release 版（~/.cache/misckit-build/product/MiscKit.app）
make install                    # 打包 Release → 干净退出旧实例 → 安装到 /Applications → 重新拉起
```

`make install` 会先验证签名与资源包、读取已安装版本号与进程 PID，门禁扫描未通过时拒绝出包。

### 数据存储

- **偏好设置、稿纸内容、应用别名、文件范围与最近打开**：`UserDefaults`。
- **文件索引、应用快照、设置面板缓存、网址别名与 Hosts 备份**：`~/Library/Application Support/MiscKit/`（Hosts 备份滚动保留最近 10 份）。
- **OTP 密钥**：仅存于 macOS 系统钥匙串，本地 JSON 元数据仅保存条目名与顺序。

### 安全机制与隐私

- **OTP 密钥**：通过 `SecItem*` API 严格保存在系统钥匙串中；本地 JSON 仅保存非敏感标识符与展示标签。复制的 OTP 验证码会在 60 秒后自动从剪贴板清除（`ClipboardGuard`）。
- **Hosts 写入**：写入 `/etc/hosts` 前强制生成带时间戳的本地备份，通过系统管理员授权（`osascript`）原子写入，绝不缓存管理员凭据。
- **最小网络面**：后台仅有 Sparkle 每日一次的更新检查（访问 GitHub Releases feed，EdDSA 签名校验），不含任何分析、遥测或其他网络行为。
- **发布审计门禁**：打包脚本强制运行敏感信息扫描（`Scripts/scan-secrets.sh`），CI 同样覆盖。
- **漏洞披露**：如发现安全漏洞，请通过 GitHub 私密漏洞汇报通道或私下联系维护者，请勿公开发布 exploit 详情。

### 开发与贡献规范

1. **本地化（`L10n`）**：
   - 界面可见字符串统一维护于 `Sources/MiscKitCore/Resources/Localizable.xcstrings`（包含 `en` 与 `zh-Hans`），通过 `Sources/MiscKitCore/Localization/L10n.swift` 类型安全读取。
   - 启动器各工具的搜索关键词始终保持三语（中/英/拼音）兼容。
   - 视图中通过 `@Environment(\.appLanguage)` 感知语言变更，实现即时切换无需重启。
2. **设计系统与门禁测试**：
   - 统一采用 `Theme.*` 语义颜色（禁止裸用 `.red` / `.orange`、`Color.red` / `Color.orange` 或 `Theme.tertiaryText`）。
   - 字号统一走 `Type.*` 令牌；保持 `ContrastAuditTests` 与 `TypeGateTests` 测试全部通过。
3. **安全规范**：
   - 禁止提交任何真实个人路径、邮箱、域名、内部 IP 或私钥；测试用例统一使用 RFC 2606 虚拟域名（`example.test`, `example.com`）。
   - 每次提交前运行 `make scan`。

### 发布流程（维护者）

1. 同步递增 `Resources/Info.plist` 中的 `CFBundleShortVersionString` 与 `CFBundleVersion`（纯数字，严格递增）。
2. 在 `CHANGELOG.md` 顶部追加 `## [X.Y.Z]` 段落，写本次相对上一版的变化；该段落会原样成为 GitHub Release 的更新说明。首个版本写全功能，后续版本只写增量。
3. 提交后 `git tag vX.Y.Z && git push --tags`。

CI 会依次执行密钥扫描、测试、打 dmg（ad-hoc 签名）、用仓库 Secrets 里的 EdDSA 私钥签名、创建 GitHub Release 并上传 `appcast.xml`；存量用户在下一轮每日检查时自动发现新版本。

### 开源许可

本项目采用 **GNU General Public License v3.0（GPL-3.0）** 开源协议，完整文本见 [LICENSE](LICENSE)。
