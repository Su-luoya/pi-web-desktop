# Pi Web Desktop 0.1.0-alpha.16（build 16）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.16` 面向 Apple Silicon（arm64）与 macOS 14 或更高版本。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

相对 `0.1.0-alpha.15`，本版重点修复自动更新检查链路的并发、停止和超时问题：

- `UpdateChecker` 的状态转换统一在检查调度器上串行处理；
- 停止检查后不再继续发起排队或在途检查的后续请求；
- inventory 更新、TTL、重叠检查和 completion 合并语义得到修正；
- Pi CLI 进程收到退出通知但尚未进入状态队列时，不再被误判为超时；
- Pi CLI 与 package 更新器共用命令输出的脱敏、折叠和尾部处理逻辑；
- 补充并发、停止、inventory、重叠检查、进程退出和超时回归测试。

## 目标平台与安装

| 项目 | 值 |
| --- | --- |
| CPU | Apple Silicon（arm64）；不支持 Intel（x86_64） |
| 最低系统 | macOS 14.0 |
| 应用包 | `Pi-Web-Desktop.app` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 签名 | ad-hoc；没有 Developer ID 证书 |
| 公证 | 无 |

ZIP 下载后请先使用配套的 `.zip.sha256` 校验，再将应用放入 `~/Applications` 或 `/Applications`。不要为了运行本 alpha 关闭 Gatekeeper；首次打开时在 Finder 中右键选择“打开”，或在“系统设置 → 隐私与安全性”中针对该应用放行。

应用不打包 Node.js、Pi CLI 或 `@agegr/pi-web`，这些依赖需要用户自行安装。应用内桌面自更新仍只允许用户确认后执行，并且只支持位于 `/Applications/Pi-Web-Desktop.app` 的安装；它不是无人值守更新，也不提供新版本启动失败后的自动回滚。

## 验证

- 本地 `xcodebuild test`：859 个测试，0 失败；
- `git diff --check`：通过；
- 更新相关 Swift 文件语法解析：通过；
- 版本、身份、打包、secret scan 和 smoke 的候选版本门槛记录见本版本 Release Issue 与发布资产中的 evidence 文件。

## 变更边界

本版没有新增第三方 Swift 包、npm 运行时依赖、UserDefaults 键或服务控制路径。非 loopback 访问仍是明文 HTTP；密码认证不等于传输加密。自动更新使用既有的 GitHub / npm 检查与发布边界，不把同源 SHA-256 校验描述成开发者身份验证。

## 校验值

发布资产、SHA-256、CI run、真机 smoke 和最终 Release 链接将在发布草稿生成后从实际资产与 Release Issue 回填；不使用本地演练值代替发布值。

## 回退

保留上一版 `v0.1.0-alpha.15` 的 ZIP 与 checksum。若本版应用不可用，手动解压上一版并替换应用包；应用没有系统级常驻组件。Pi、Pi Web 和 Node.js 的版本回退由用户自行管理。

## 已知限制

- ad-hoc、未公证，首次手动安装需要用户放行；
- 桌面应用自更新仅支持 `/Applications`，需要用户确认；
- 自更新失败会保留旧安装，但新版本安装后启动失败不会自动回滚；
- alpha 版本不提供 SLA。
