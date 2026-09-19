# Pi Web Desktop

> Unofficial native macOS companion for [`agegr/pi-web`](https://github.com/agegr/pi-web).

Pi Web Desktop is a macOS AppKit/WebKit shell that starts, monitors, and displays a local Pi Web service. It does not modify the upstream Pi Web web application.

## 上游归属与非官方声明

- 本仓库是社区维护的**非官方**项目，与上游 Pi Web 维护者没有隶属、赞助或背书关系，也不是上游的官方发行版。
- 应用不 fork、不打包、不修改上游 Web 服务代码；上游 Pi Web、Pi CLI、`@earendil-works/pi-coding-agent` 或 Pi packages 的问题请先到对应上游仓库确认。
- 上游项目：[`agegr/pi-web`](https://github.com/agegr/pi-web)。应用自身的问题请在本仓库提 Issue。
- 本仓库以 MIT License 发布，见 [LICENSE](LICENSE)。

## 支持矩阵

以 `Configuration/AppIdentity.xcconfig`、`Scripts/build.sh` 和最近一次本地验证为准；下表中的“未承诺”表示项目不做出该保证，也不在自动验证范围内。

| 维度 | 当前状态 |
| --- | --- |
| CPU | Apple Silicon（arm64）。Xcode 工程的 6 个 build configuration 与 `Scripts/build.sh` 都只构建 arm64 单一架构 |
| 系统 | macOS 14.0 或更高（`APP_MINIMUM_SYSTEM_VERSION = 14.0`） |
| Intel Mac | 不在支持范围，也没有支持承诺；没有 x86_64 产物，未做验证 |
| 框架 | 只使用 Apple 系统框架（Cocoa/AppKit、WebKit、Security、CryptoKit、Foundation、Darwin）；没有第三方 Swift 包、CocoaPod 或 npm 运行时依赖 |
| 构建工具 | 系统 Swift 编译器（`swiftc`）+ Xcode Command Line Tools；`xcodebuild build/test` 需要完整 Xcode |
| 签名 | ad-hoc 签名（`codesign --sign -`），没有 Developer ID 证书，`TeamIdentifier` 为空 |
| 公证 | 未公证。Gatekeeper 默认拒绝（`spctl --assess` 返回 rejected），需要用户在“系统设置 → 隐私与安全性”里手动批准 |
| 发行状态 | 当前只有早期 alpha 基线 `0.1.0-alpha.1`（build `1`），没有稳定发行版 |
| 分发现状 | 本仓库当前不提供预编译 [Release](https://github.com/Su-luoya/pi-web-desktop/releases) 下载；alpha.1 从源码构建，ZIP 打包流程见 [发布说明](docs/releasing.md) |
| 自动更新 | 未实现。当前 alpha 不做应用内更新，也不检查更新（见 [隐私说明](docs/privacy.md) 的“版本检查”） |
| 支持承诺 | 无 SLA，无响应或修复时限。Issue 和 PR 按维护者可用时间处理 |
| 远程访问 | 默认只监听 loopback；远程访问必须自备加密隧道或 HTTPS 反向代理，密码认证 ≠ 传输加密 |

未在表中列出的组合（Intel、更旧的系统版本、稳定发行版、应用内更新）都视为未支持：文档、Issue 和 Release 说明里都不能暗示它们已经可用。

## 依赖

应用自身没有第三方运行时依赖，但被托管的服务需要用户自行安装：

- Apple Silicon Mac
- macOS 14 或更高
- Node.js `>=22.19.0`（当前 `@agegr/pi-web` 声明的 `engines.node` 下限）
- Pi CLI
- `@agegr/pi-web`

安装命令（与 `Sources/InstallCommandManifest.swift` 中的应用内建议一致，可能随上游变化，请先核对上游文档与包元数据）：

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
npm install -g @agegr/pi-web
```

应用不会自动安装这些依赖，不调用 `sudo`，也不会读取或迁移 Pi 的认证内容。Pi packages 与 extensions 可能以当前用户权限执行代码。

## 从源码构建

```bash
./Scripts/build.sh
# 产物：build/Pi-Web-Desktop.app（arm64、ad-hoc 签名）
./Scripts/check-identity.sh
open build/Pi-Web-Desktop.app
```

`Scripts/build.sh` 用系统 Swift 编译器构建 arm64、macOS 14 目标的 app，并生成 `Contents/Info.plist`、复制图标、做 ad-hoc 签名与签名校验。校验身份后可选的端到端启动验证：

```bash
./Scripts/smoke.sh
```

`Scripts/smoke.sh` 在临时 support 目录里跑“主窗口”和“诊断页”两种 smoke 模式，都必须在超时内以 0 退出并打印各自标记；它不会写真实 UserDefaults、`~/Library/Application Support` 或 `~/Library/Logs`，也不会启动真实 pi-web。完整说明见 [开发说明](docs/development.md)。

应用身份、版本与最低系统版本只有一个来源：`Configuration/AppIdentity.xcconfig`。当前 alpha 为 `0.1.0-alpha.1`（build `1`），bundle identifier `io.github.su-luoya.pi-web-desktop`，显示名 `Pi Web Desktop`，最低系统版本 `14.0`。`PiWebDesktop.xcodeproj` 通过 `baseConfigurationReference` 继承该文件，`Scripts/build.sh` 也从同一文件生成 `Info.plist`，所以 Xcode 工程、测试 target、脚本产物与 CI 不会各自漂移。任何身份或版本改动后都要重跑：

```bash
./Scripts/build.sh
./Scripts/check-identity.sh
```

`Scripts/check-identity.sh` 会比对 xcconfig、`project.pbxproj`、每个传入 bundle 的 `Info.plist` 与图标资源、本地服务默认值，并拒绝仓库里出现私人默认值（私有 VPN 主机名、tailnet DNS 后缀、CGNAT 私网地址、以 `/Users` 开头的主目录绝对路径、固定本地代理端点）和 xcconfig 之外的版本字面值。用法与检查项见 [开发说明](docs/development.md#一致性检查)。

## 安装 alpha 应用

```bash
./Scripts/install.sh
open "$HOME/Applications/Pi-Web-Desktop.app"
```

`Scripts/install.sh` 会把 `build/Pi-Web-Desktop.app` 复制到 `~/Applications/`，覆盖前把已有同名 app 改名为带时间戳的备份，然后重新做 ad-hoc 签名与校验。它要求 `~/Applications` 已存在（脚本不会创建目录），目录缺失时先执行 `mkdir -p ~/Applications`，否则复制会以 No such file or directory 失败。早期二进制未公证：macOS 可能阻止首次打开，需要在“系统设置 → 隐私与安全性”里针对这个 app 手动批准。不要全局关闭 Gatekeeper。

## 功能范围

- 启动、监控并显示本机已安装的 Pi Web 服务。
- 用原生 WebKit 窗口承载服务页面，提供启动/停止/重启、日志、诊断、上传下载、外链处理、页面查找与缩放。
- 默认使用 loopback，不在当前 alpha 基线里开启远程监听。
- 服务配置存 UserDefaults，运行文件与日志写到标准 Application Support 与 Logs 目录，远程访问密码只存 Keychain。

## 安全与隐私边界

- 不收集遥测。版本检查尚未实现；实现后会在首次启动说明中披露并允许分别关闭。
- 默认只监听 `127.0.0.1`。远程访问需要用户先在 Keychain 保存非空密码，并且需要用户自备加密传输；**密码认证只验证访问者，不等于传输加密**。
- 不要把 agent 服务暴露给不可信网络。
- 不要在公开 Issue、PR 或讨论里粘贴密码、API key、token、代理凭据、私有主机名、包含主目录绝对路径（以 `/Users` 开头）的环境信息或未脱敏日志。
- 本地数据位置与清理方式见 [隐私说明](docs/privacy.md)。WebView 使用系统默认的持久化网站数据存储，cookies、缓存与 local storage 写在 `~/Library/WebKit/<bundle id>/` 与 `~/Library/Caches/<bundle id>/` 下；应用当前没有内置的“清空网站数据”入口，只能退出应用后手动删除。

## 参与贡献

1. 先搜索[已有 Issue](https://github.com/Su-luoya/pi-web-desktop/issues)。用 [Bug 表单](https://github.com/Su-luoya/pi-web-desktop/issues/new/choose)报告可复现问题，用 Feature 表单提议用户可见能力；两者都要写清可观察的验收方式。
2. 大功能、架构调整和安全相关改动先开 Issue 并满足 Definition of Ready（见 [Orca 工作流](docs/orca-workflow.md)）。
3. 用 `issue-<number>-<slug>` 建分支，一个 Issue 对应一个分支、一个 PR。
4. PR 必须关联 Issue，并按 [PR 模板](.github/pull_request_template.md)填写变更说明、验收证据、安全与兼容性影响。维护者验证后用 squash merge 合入 `main`。
5. 提交前按 [贡献指南](CONTRIBUTING.md)运行构建、身份检查、smoke 和仓库文本（personal-data）扫描。

标签体系统一使用 `type:`（bug/feature/maintenance/documentation/security）、`area:`（app/service/diagnostics/security/updates/build-release/documentation）、`status:`（needs-decision/ready/blocked/needs-reproduction）和 `priority:`（P0–P3）。当前没有任何公开 Release，安装或升级前请先看[发布页](https://github.com/Su-luoya/pi-web-desktop/releases)是否为空白。

## 报告安全问题

不要在公开 Issue、PR 或日志中报告安全漏洞。请使用[私密漏洞报告](https://github.com/Su-luoya/pi-web-desktop/security/advisories/new)，具体流程、覆盖范围和“不承诺 SLA”的说明见 [SECURITY.md](SECURITY.md)。

## 依赖与 CI 固定策略

- 应用不引入第三方 Swift 包、CocoaPod 或 npm 运行时依赖；新增依赖前必须在 Issue 或 PR 里记录许可证、维护状态和供应链理由。
- CI 只使用 GitHub 托管的 `macos-14` runner，工作流权限是只读的 `contents: read`，不使用 secrets。
- 所有 GitHub Actions 按**提交 SHA 固定**（例如 `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`），不使用浮动 tag。
- `.github/dependabot.yml` 每周检查 GitHub Actions 固定版本的更新，并通过带 `dependencies`、`github_actions` 标签的 PR 提出升级，必须走正常评审和 CI。
- CI 目前**没有**通用 secret scanning：`.github/workflows/build.yml:54-56` 只有一条 personal-data `git grep`（几个固定字面量），`./Scripts/check-identity.sh:433-446` 用的是另一组固定模式；两者都不是凭据/密钥扫描，能力边界见 [贡献指南](CONTRIBUTING.md#personal-data-与-secret-扫描能力)。通用 secret scan 属 [#11](https://github.com/Su-luoya/pi-web-desktop/issues/11) 的范围，当前发布门槛里不含它。

## 项目文档

- [架构](docs/architecture.md)
- [开发](docs/development.md)
- [安全设计](docs/security-ownership.md)
- [发布](docs/releasing.md)
- [隐私](docs/privacy.md)
- [Orca 工作流](docs/orca-workflow.md)
- [贡献指南](CONTRIBUTING.md)
- [安全政策](SECURITY.md)
- [行为准则](CODE_OF_CONDUCT.md)

## License

MIT. See [LICENSE](LICENSE).
