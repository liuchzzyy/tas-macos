# TAS for Mac

用 **Swift + SwiftUI** 重写的 TAS（Telegram as Storage）。原生 macOS 界面、Swift 核心和 `tas` 命令行共用同一套文件处理代码；运行和构建均不需要 npm、Node.js、Electron、WebView 或 Rust。

支持 macOS 13 及以上，仅构建 Apple Silicon (arm64) 的 DMG 安装包。

## 获取与运行

从 [GitHub Releases](https://github.com/liuchzzyy/tas-macos/releases/latest) 下载最新版 Apple Silicon (arm64) DMG；当前版本是 [v1.0.1](https://github.com/liuchzzyy/tas-macos/releases/tag/v1.0.1)，可直接下载 [TAS-1.0.1-arm64.dmg](https://github.com/liuchzzyy/tas-macos/releases/download/v1.0.1/TAS-1.0.1-arm64.dmg)（[SHA-256 校验文件](https://github.com/liuchzzyy/tas-macos/releases/download/v1.0.1/TAS-1.0.1-arm64.dmg.sha256)）。仓库目前为私有仓库，下载需有访问权限。

打开 DMG，将 `TAS.app` 拖入“应用程序”。当前构建使用临时签名，**尚未使用 Apple Developer ID 签名或公证**。如果 macOS 阻止打开，在“系统设置 → 隐私与安全性”中允许这次打开。

需要尚未发布的最新构建时，也可在 [Actions](https://github.com/liuchzzyy/tas-macos/actions/workflows/macos.yml) 下载 `TAS-macOS-arm64` artifact；GitHub 会先将 artifact 打包为 ZIP，解压后才是 DMG。

首次使用填写 Bot Token、Chat ID 和加密密码。新文件库密码至少 12 位，并包含大小写字母、数字和符号；创建界面逐项提示，已有文件库仍可用原密码解锁。请先在 Telegram 中向机器人发送 `/start`；群组需将机器人加入群组并授予发送文件权限。Token 加密保存在本地，密码只保留在解锁会话中。设置中的“检查更新”读取 GitHub 最新 Release；私有仓库需在本机安装 GitHub CLI 并完成 `gh auth login`，或使用浏览器打开 Releases。

已有 TAS 用户可以直接选择原来的 `~/.tas` 目录并输入原密码。请先退出旧客户端，并备份整个数据目录；原生版使用进程锁防止同时写入，但旧版部分命令不遵守此锁。

## 功能

- 中文 SwiftUI 文件库：搜索、标签、拖放上传、下载、删除、原生文件选择器。
- AES-256-GCM 加密、gzip 压缩、19 MiB 分块和流式文件处理。
- 持久化上传队列，网络中断或退出后可继续上传，不依赖原文件仍然存在。
- 下载完成后校验认证标签、原始大小和 SHA-256，再原子替换目标文件。
- 多机器人分配；按分块记录机器人归属，停用机器人仍可读取已有文件。
- 加密远端索引备份／恢复。恢复前备份本地 SQLite；删除时远端索引更新失败会回滚本地记录。
- 文件夹手动同步和应用运行期间每 30 秒自动检查；可按逻辑路径恢复全部文件。
- 原生 Swift 命令行：上传、下载、搜索、标签、续传、机器人管理、同步、校验和诊断。

这是原生版本的首个实现。**旧 Node 版的 HTTP 临时分享服务和 macFUSE 挂载尚未移植**；本版本不注册 Finder 虚拟磁盘。同步仅上传新增／修改，不镜像删除；多个同步目录的同名相对路径会更新同一份文件，兼容原版行为。

## 从源码构建

需要 Apple Silicon Mac、Xcode 或 Command Line Tools、Swift 6.0+：

```sh
git clone https://github.com/liuchzzyy/tas-macos.git
cd tas-macos
swift test -c release
./scripts/build-macos.sh
open dist/TAS.app
```

`Package.resolved` 固定依赖版本。系统库使用 SQLite、zlib、CommonCrypto、CryptoKit；[CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift) 1.10.0 提供兼容旧文件格式的流式 AES-GCM。没有 Node 原生模块或浏览器运行时。CryptoSwift 保留其原始许可，构建脚本会将许可放入应用包。

`swift test -c release` 也可在装有 SQLite/zlib 开发库的 Linux + Swift 6 上运行核心测试；SwiftUI 应用必须在 macOS 构建。正式签名可设置 `TAS_SIGN_IDENTITY`；公证凭据不包含在仓库中。

## 命令行

安装后的命令行位于：

```sh
/Applications/TAS.app/Contents/Helpers/tas --help
```

开发时可用 `swift run -c release tas --help`。示例：

```sh
tas init
tas push ~/Documents/report.pdf --name documents/report.pdf
tas list
tas pull documents/report.pdf --output ~/Downloads/report.pdf
tas resume
tas index backup
tas verify --deep
tas sync add ~/Documents/Notes
tas sync start --watch
```

`tas` 需加入 PATH 或使用完整路径。支持 `TAS_DATA_DIR`、`TAS_PASSWORD`、`TAS_BOT_TOKEN`、`TAS_CHAT_ID`，也可用 `--data-dir` 和 `--password-file`。交互密码／Token 不回显。自动化优先使用权限 600 的单行密码文件。CLI 和图形界面不能同时解锁同一文件库。

## 兼容性与数据保护

读取 v1 明文 Token、v2 加密 Token 和 v3 机器人池配置，写入机器人设置时升级为 v3 加密配置并保留未知字段。兼容 600,000 次 PBKDF2-SHA512、旧密码校验值、WAS1 头、既有 SQLite 表、待续传记录和远端 manifest。旧索引的唯一 hash 约束迁移前会自动备份。

配置和索引默认位于 `~/.tas`。`config.json`、加密密码与远端索引指针共同用于恢复；丢失这些信息时，单靠 Telegram 消息无法可靠重建整个文件库。请始终保留独立备份。Telegram Bot API 不是持久性存储服务；旧版超过托管 API 下载上限的分块需配置本地 Bot API。

测试使用旧 Node `Encryptor` 实际生成的公开样本，覆盖密码派生、空文件、中文、流式加解密、损坏拒绝、权限、符号链接路径拒绝、索引迁移、续传、机器人归属、删除回滚和恢复。网络测试使用本地 fake，不上传真实文件或使用真实 Token。

## 大小与性能

每次 macOS CI 构建输出应用目录与 DMG 大小、架构和 CLI 启动测量，随 artifact 提供 `build-report-*.txt`。移除 Electron 的浏览器运行时能减少分发内容；具体体积以构建产物为准。

Swift 原生界面有利于降低界面运行时开销，但不代表所有处理都会更快：网络速度仍受 Telegram 和网络限制；为了兼容旧格式，8 MiB 以内的文件使用 Apple CryptoKit 加速，大文件 AES-GCM 使用 CryptoSwift 流式处理，吞吐量需要单独实测，不能直接假定高于 Node/OpenSSL。

源项目：[ixchio/tas](https://github.com/ixchio/tas)。MIT 许可与上游署名保留在 `LICENSE` 中。
