# 发布说明

## Alpha

版本使用 SemVer，例如 `v0.1.0-alpha.1`。发布前必须满足：

- `main` 上的提交通过构建、测试、静态检查和 secret scan。
- Apple Silicon + macOS 14 或以上真机完成 smoke test。
- Release Issue 记录实际测试的 macOS、CPU、Node.js、Pi 和 Pi Web 版本。
- ZIP 使用 ad-hoc 签名，并明确写出 `not notarized`。
- Release 同时提供 SHA-256 checksum、已知问题、安装限制和回退说明。

未公证的 ZIP 不是稳定安装包。不要建议用户全局关闭 Gatekeeper；如果用户明确下载并理解风险，说明如何针对单个应用处理 macOS 的阻止提示。

## 版本来源与 Git tag

应用身份与版本的唯一来源是 `Configuration/AppIdentity.xcconfig` 中的 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`；`PiWebDesktop.xcodeproj` 通过 `baseConfigurationReference` 继承该文件，`Scripts/build.sh` 也从同一文件生成 `Info.plist`。因此：

- tag 名称固定为 `v<MARKETING_VERSION>`，例如 `MARKETING_VERSION = 0.1.0-alpha.1` 对应 tag `v0.1.0-alpha.1`；tag 与该值不一致时不得发布。
- 打 tag 前先提交版本改动，再运行 `./Scripts/build.sh && ./Scripts/check-identity.sh`，确认 xcconfig、Xcode 工程、已构建 bundle 的 `Info.plist` 与本地服务默认值一致。
- `Scripts/check-identity.sh` 会拒绝 `Sources/`、`Scripts/`、`PiWebDesktop.xcodeproj/`、`PiWebDesktopTests/` 里出现 `MARKETING_VERSION` 的字面值；不要在代码、脚本或模板中复制版本号。
- 发布说明里同时写明 `CFBundleShortVersionString`（即 `MARKETING_VERSION`）与 `CFBundleVersion`（即 `CURRENT_PROJECT_VERSION`），便于用户核对下载的 ZIP。

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
