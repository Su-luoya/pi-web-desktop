# 发布说明

上游归属、支持矩阵与“未承诺”事项见 [README](../README.md#支持矩阵)。发布任何二进制前都必须重新确认那份矩阵，不得在 Release 说明里扩大承诺。

## 当前状态

- 本仓库当前没有公开的预编译 Release；`0.1.0-alpha.1` 可以从源码构建，ZIP 打包流程见下。
- alpha 二进制是 **ad-hoc 签名**，没有 Developer ID 证书，**未公证**。Gatekeeper 默认拒绝打开，用户必须在“系统设置 → 隐私与安全性”里手动批准。
- 没有 x86_64 产物，也不承诺 Intel Mac 支持。
- 项目无 SLA：不承诺响应、修复或发布时限。

## 版本来源与 Git tag

应用身份与版本的唯一来源是 `Configuration/AppIdentity.xcconfig` 中的 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`；`PiWebDesktop.xcodeproj` 通过 `baseConfigurationReference` 继承该文件，`Scripts/build.sh` 也从同一文件生成 `Info.plist`。因此：

- tag 名称固定为 `v<MARKETING_VERSION>`，例如 `MARKETING_VERSION = 0.1.0-alpha.1` 对应 tag `v0.1.0-alpha.1`；tag 与该值不一致时不得发布。
- 打 tag 前先提交版本改动，再运行 `./Scripts/build.sh && ./Scripts/check-identity.sh`，确认 xcconfig、Xcode 工程、已构建 bundle 的 `Info.plist` 与本地服务默认值一致。
- `Scripts/check-identity.sh` 会拒绝 `Sources/`、`Scripts/`、`PiWebDesktop.xcodeproj/`、`PiWebDesktopTests/` 里出现 `MARKETING_VERSION` 的字面值；不要在代码、脚本或模板中复制版本号。
- 发布说明里同时写明 `CFBundleShortVersionString`（即 `MARKETING_VERSION`）、`CFBundleVersion`（即 `CURRENT_PROJECT_VERSION`）和 bundle identifier，便于用户核对下载的 ZIP。

## 打包与校验

```bash
./Scripts/build.sh
./Scripts/check-identity.sh
./Scripts/smoke.sh
ditto -c -k --sequesterRsrc --keepParent build/Pi-Web-Desktop.app Pi-Web-Desktop-alpha.zip
shasum -a 256 Pi-Web-Desktop-alpha.zip > Pi-Web-Desktop-alpha.zip.sha256
shasum -a 256 -c Pi-Web-Desktop-alpha.zip.sha256
```

- `Scripts/build.sh` 已经对 app 做 ad-hoc 签名并在结束时执行 `codesign --verify --deep --strict`；打包前可以再手动确认一次签名产物完整。
- `ditto -c -k --sequesterRsrc --keepParent` 是 CI 使用的同一条打包命令（见 `.github/workflows/build.yml` 的 `Package smoke artifact` 步骤）；`--sequesterRsrc` 会把 Finder 元数据放进 `__MACOSX/`，这是预期结果。
- 发布说明中给出 ZIP 的 SHA-256 与校验方法。用户侧只需比较 `shasum -a 256 Pi-Web-Desktop-alpha.zip` 的输出。
- 解压后可以用 `plutil -extract CFBundleShortVersionString raw -o - Pi-Web-Desktop.app/Contents/Info.plist` 核对版本，用 `codesign --verify --deep --strict Pi-Web-Desktop.app` 核对签名完整性。

## Release 前置检查

发布前必须满足：

- `main` 上的提交通过构建、测试、静态检查和 secret scan；CI 的 `build` 工作流在 GitHub 托管的 `macos-14` runner 上全绿。
- Apple Silicon + macOS 14 或以上真机完成 smoke test。
- Release Issue 记录实际测试的 macOS、CPU、Node.js、Pi 和 Pi Web 版本。
- `./Scripts/check-identity.sh` 退出 0，且 ZIP 与 tag 都对应同一个 `MARKETING_VERSION`。
- ZIP 使用 ad-hoc 签名，并在 Release 说明里明确写出 `not notarized`，同时给出 SHA-256、已知问题、安装限制和回退说明。

未公证的 ZIP 不是稳定安装包。不要建议用户全局关闭 Gatekeeper；如果用户明确下载并理解风险，说明如何针对单个应用处理 macOS 的阻止提示。

## 发布说明必须包含

- 版本号、构建号、bundle identifier 与 tag。
- ZIP 的 SHA-256。
- 支持矩阵现状：Apple Silicon、macOS 14 或以上、ad-hoc 签名、未公证、无 Intel 承诺、无 SLA。
- 已知问题与不包含的功能（例如尚未实现的自动更新）。
- 安装限制与回退方式。
- 一句明确的远程访问提示：默认只监听 loopback，密码认证不等于传输加密。

**不得**出现下列表述（这些词在本文件里只作为禁止清单出现，不作为项目现状的描述）：稳定版、已签名（指 Developer ID）、已公证、保证兼容、支持 Intel、自动更新已就绪。ad-hoc 签名只能写成“ad-hoc 签名”，并且必须与“未公证”同时出现。

## 版本门槛

- `alpha.1`：安全开源基线、依赖诊断和服务生命周期。
- `alpha.2`：桌面应用、Pi、Pi Web 和 Pi 扩展包的版本检查。
- `alpha.3`：受限自动安装、运行进程保护、更新验证和有限回滚。
- `beta.1`：根据 alpha 反馈修复，不引入大型新功能。
- `1.0.0`：需要 Developer ID 签名和 Apple 公证；没有开发者账号时不发布稳定二进制。

## 回退

更新前记录当前版本。只有安装来源和工具提供可靠恢复路径时才执行回滚；不能承诺所有 npm、Git package、本地路径或非标准安装都能自动恢复。更新失败时优先保留可运行的旧版本，并把完整但已脱敏的日志留给用户查看。

## 应用自身更新

`v0.1.0` 不实现应用内更新。应用只在后续版本检查 GitHub Release，并引导用户打开下载页。

## CI 与依赖固定策略

- GitHub Actions 全部按提交 SHA 固定，不使用浮动 tag；例如 `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`。
- `.github/dependabot.yml` 每周检查固定版本的更新，通过带 `dependencies`、`github_actions` 标签的 PR 提出升级；升级必须走 CI 和评审，不允许为了发布临时改用浮动版本。
- 发布工作流不得使用 secrets，也不得引入第三方签名、公证或上传服务；当前 `build` 工作流的权限只有 `contents: read`。
- 发布流程不依赖新的运行时依赖。应用自身没有第三方 Swift 包或 npm 依赖；新增依赖必须先按 [贡献指南](../CONTRIBUTING.md)记录许可证、维护状态和供应链理由。
