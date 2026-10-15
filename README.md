# TAS for Mac

用 **Swift + SwiftUI** 构建的原生 macOS 客户端与命令行工具（Telegram as Storage）。原生 macOS 界面、Swift 核心和 `tas` 命令行共用同一套底层架构；运行与构建完全基于原生平台，不依赖 Node.js、Electron、WebView 或任何非原生运行时。

系统要求：**macOS 26+**，**Apple Silicon（arm64）**。

---

## 核心特性

- **macOS 原生设置体系（Settings · ⌘,）**：偏好设置采用标准 macOS 设置窗口设计，集成常规、文件库、机器人、更新、维护 5 个独立分栏。
- **全局菜单栏与常驻状态图标**：
  - 屏幕顶部系统菜单栏提供完整工作区快捷切换（`⌘1`~`⌘5`）、文件上传（`⌘U`）、目录同步（`⌘⇧O`）、立即同步（`⌘R`）、备份索引（`⌘⇧B`）与锁定（`⌘⇧L`）。
  - 右上角常驻状态栏图标（MenuBarExtra）实时反映文件库解锁/锁定状态、同步中动态图标与统计信息。
- **全自动与即时版本更新**：
  - 支持应用启动时自动检查更新（默认关闭，可在原生设置中启用），发现新版弹窗一键升级并自动重启。
  - 侧边栏左下角提供即时检查更新按钮；原生设置中同步显示桌面客户端（GUI）与内置命令行工具（CLI）的版本状态。
- **安全端到端加密**：
  - 基于 AES-256-GCM 与 PBKDF2-SHA512（600,000 次迭代）的本地流式加密。
  - 密码更改采用代际密钥机制：**新上传使用新一代密钥**，**已有内容仍使用过去代密钥**；旧密码仍可解密**旧版密文**，不能撤销。
  - 可选将登录密码安全保存在本机 Apple 钥匙串中以实现开机与启动自动解锁。
- **完整的文件版本管理**：
  - 支持文件历史版本查看、指定版本下载与按需回滚恢复；恢复版本自动作为新版本追加，不破坏历史完整性。
  - 支持软删除与彻底清除机制，软删除文件保留完整历史并支持随时恢复。
- **高效文件传输与同步**：
  - 统一的拖拽上传中心：支持文件与完整文件夹层级拖拽，19 MiB 自动分块，断点续传。
  - 本地文件夹持续同步：支持后台每 30 秒自动检测本地变更并增量推送。
  - Telegram 多机器人负载均衡与分块多路上传。
  - 加密远端索引备份与一键灾难恢复。
- **系统级集成体验**：
  - 支持登录后开机自启（经由系统 `SMAppService` 安全托管的独立登录助手）、静默自启、关闭窗口保留在后台菜单栏。
  - 主界面左下角提供即时外观切换（浅色/深色/跟随系统）与语言切换（简体中文/English）。

---

## 获取与安装

### 预编译安装包

从 [GitHub Releases](https://github.com/liuchzzyy/tas-macos/releases/tag/v1.4.6) 下载：
- **[TAS-1.4.6-arm64.dmg](https://github.com/liuchzzyy/tas-macos/releases/download/v1.4.6/TAS-1.4.6-arm64.dmg)**
- **[SHA-256 校验文件](https://github.com/liuchzzyy/tas-macos/releases/download/v1.4.6/TAS-1.4.6-arm64.dmg.sha256)**

校验并安装：
```sh
shasum -a 256 -c TAS-1.4.6-arm64.dmg.sha256
```
打开 DMG 并将 `TAS.app` 拖入“应用程序”（`/Applications`）目录。

> **提示**：当前构建使用 ad-hoc 签名。首次打开时若提示未受信任，请在 macOS「系统设置 ▸ 隐私与安全性」中允许打开。

### 首次配置

1. 打开应用，输入 **Bot Token**、**Chat ID** 并设定加密密码（至少 12 位，包含大小写字母、数字及符号）。
2. 在 Telegram 中向机器人发送 `/start`。若在群组中使用，请确保机器人已入群并具有发送媒体文件的权限。
3. 进入应用后，所有凭据加密存储于本地配置文件 `~/.tas/config.json`，密码仅在解锁会话期间驻留内存。

---

## 命令行工具（tas CLI）

应用包内自带独立的 `tas` 命令行工具，位于：
```sh
/Applications/TAS.app/Contents/Helpers/tas
```

建议在 shell 配置文件中添加别名：
```sh
alias tas="/Applications/TAS.app/Contents/Helpers/tas"
```

### 常用命令示例

```sh
# 初始配置
tas init

# 上传文件（支持备注与追加新版本）
tas push report.pdf --name documents/report.pdf --message "初稿"
tas push report.pdf --name documents/report.pdf --new-version --message "修订稿"

# 查看版本历史与详情
tas history documents/report.pdf --json

# 取回历史版本（不改变当前最新版本）
tas pull documents/report.pdf --version 1 --output ~/Downloads/report-v1.pdf

# 将指定历史版本恢复为最新版本（会暂停该路径的自动同步）
tas restore documents/report.pdf --version 1 --message "恢复初稿"
tas sync resume documents/report.pdf

# 软删除与彻底清除
tas delete documents/report.pdf              # 软删除（仍保留历史，可恢复）
tas list --deleted                           # 查看已删除项
tas delete documents/report.pdf --hard --yes # 永久清除（不可撤销）

# 状态统计与完整性校验
tas status --json
tas verify --deep --all-versions

# 目录同步
tas sync add ~/Documents/Notes
tas sync start --watch

# 加密索引备份与恢复
tas index backup
tas index rebuild
```

---

## 从源码构建与测试

环境要求：macOS 26+，Apple Silicon Mac，Xcode Command Line Tools / Swift 6.2+。

```sh
# 克隆仓库
git clone https://github.com/liuchzzyy/tas-macos.git
cd tas-macos

# 运行自动化测试套件
swift test -c release

# 运行 UI 契约与版本验证
python3 scripts/test-workspace-ui.py
python3 scripts/test-version-contract.py

# 编译并打包 Release DMG
./scripts/build-macos.sh

# 打开打包后的应用
open dist/TAS.app
```

### 清理缓存与临时文件

```sh
./scripts/cleanup.sh                  # 预览待清理项目
./scripts/cleanup.sh --apply           # 执行清理（移入废纸篓）
./scripts/cleanup.sh --apply --build   # 同时清理 SwiftPM 构建缓存
./scripts/cleanup.sh --apply --dist    # 同时清理旧版本 DMG 产物
```

---

## 开源协议

本项目采用 MIT 许可协议。原项目：[ixchio/tas](https://github.com/ixchio/tas)。
