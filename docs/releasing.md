# 发布说明

## Alpha

版本使用 SemVer，例如 `v0.1.0-alpha.1`。发布前必须满足：

- `main` 上的提交通过构建、测试、静态检查和 secret scan。
- Apple Silicon + macOS 14 或以上真机完成 smoke test。
- Release Issue 记录实际测试的 macOS、CPU、Node.js、Pi 和 Pi Web 版本。
- ZIP 使用 ad-hoc 签名，并明确写出 `not notarized`。
- Release 同时提供 SHA-256 checksum、已知问题、安装限制和回退说明。

未公证的 ZIP 不是稳定安装包。不要建议用户全局关闭 Gatekeeper；如果用户明确下载并理解风险，说明如何针对单个应用处理 macOS 的阻止提示。

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
