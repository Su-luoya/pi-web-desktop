# Pi Web Desktop 0.1.0-alpha.17（build 17）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.17` 面向 Apple Silicon（arm64）与 macOS 14 或更高版本。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版把 `0.1.0-alpha.16` 之后积累的两批修复一起发布：第二阶段只读审计报告里的 40+ 项缺陷修复，以及针对四条自动更新链路（桌面自更新 / Pi CLI / Pi Web / 应用扩展包）的稳定性审查修复。相对 `0.1.0-alpha.16` 的主要变化：

**更新链路**

- 周期更新检查计时器改挂 `RunLoop` 的 `.common` 模式：菜单跟踪、拖动滑杆、sheet 与 `runModal()` 期间主运行循环不再服务默认模式，原先的每日/每周复查会被静默吞掉一次且不留日志；
- 桌面自更新在下载窗口期内不再能被重复触发；手动更新期间不再消耗这一轮的自动更新额度；
- 桌面自更新校验和取不到时不再把整轮卡在忙碌态（此前菜单入口会永久置灰，只能重启应用）；
- 桌面自更新解压失败不再在临时目录残留 staging 目录；`NSApp.terminate` 改由主线程调用；
- 桌面自更新失败路径统一走同一套收尾，入口在所有失败分支都会恢复可用。

**服务与应用生命周期**

- 单实例互斥改为内核 `flock`（PID 文件只作快速路径），锁文件 `0600`、位于当前用户 support 目录；
- 空命令行不再造成永久降级；
- 设置窗口可见时保存不再写回旧配置并重启服务；
- 退出确认的状态机与超时计时器统一到 `.common` 模式，超时不再因 sheet 而失效。

**安全与信任边界（只收紧）**

- 外链打开从“任意 scheme”收紧为 `http` / `https` / `mailto` 三项白名单，其余一律拦截；
- 服务停止与存活判定继续“宁可报失败也不误杀”：`EPERM` 判为存活，确认退出后才发信号；
- Keychain 读取三态化，凭据缺失时优先收回 loopback 监听；
- 文档与注释里曾被 `check-identity.sh` 抓到的示例假值（CGNAT 地址、绝对 home 路径）已修正。

完整的逐项清单与验证记录见 [第二阶段缺陷修复汇总](bugfix-round-2.md)。

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

- 本地 `xcodebuild test`：951 个测试，0 失败（其中 5 个为桌面更新失败路径的结构守卫，见 `PiWebDesktopTests/DesktopAppUpdateFailurePathTests.swift`）；
- `./Scripts/build.sh`：成功；
- `./Scripts/check-identity.sh`：`PASSED (45 checks)`；
- `./Scripts/check-release-version.sh`：tag 与 build 号一致；
- `./Scripts/smoke.sh`：两种模式均 OK；
- `./Scripts/scan-secrets.sh`：PASS；
- `git diff --check`：通过。

真机 smoke、CI run 与 checksum 记录已回填到 `docs/alpha-release-checklist.md` 的「Release v0.1.0-alpha.17 执行记录」；不使用本地演练值代替发布值。

端到端更新验证（真实发布资产）：按发布页直链下载 → `shasum -a 256 -c` `OK` → 生产 ditto 参数解包 → `CFBundleIdentifier`/`CFBundleShortVersionString=0.1.0-alpha.17` 校验 → `codesign --verify --deep --strict` 通过 → 在沙盒里用生产替换脚本逻辑把 alpha.16 换成 alpha.17（staging 与备份均清理干净）。剩下唯一未做的是在 `/Applications` 里用菜单点击跑一次真实自更新。

## 变更边界

本版没有新增第三方 Swift 包、npm 运行时依赖或服务控制路径。新增的 UserDefaults 写入仍在既有的读-改-写互斥锁内，没有新增键。非 loopback 访问仍是明文 HTTP；密码认证不等于传输加密。自动更新使用既有的 GitHub / npm 检查与发布边界，不把同源 SHA-256 校验描述成开发者身份验证。

## 校验值

- 资产：`Pi-Web-Desktop-0.1.0-alpha.17+build.17.zip`（`1731217` 字节）
- SHA-256：`60610064370a8ec0d17764a3f2b727c300e22c4d1ae10411f6a63e8c55b8102a`
- 校验命令（下载目录执行）：`shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.17+build.17.zip.sha256`

## 回退

保留上一版 `v0.1.0-alpha.16` 的 ZIP 与 checksum。若本版应用不可用，手动解压上一版并替换应用包；应用没有系统级常驻组件。Pi、Pi Web 和 Node.js 的版本回退由用户自行管理。

## 已知限制

- ad-hoc、未公证，首次手动安装需要用户放行；
- 桌面应用自更新仅支持 `/Applications`，需要用户确认；
- 自更新失败会保留旧安装，但新版本安装后启动失败不会自动回滚；
- GUI 菜单与设置窗口的实际观感只有源码级断言覆盖，没有自动化真机验证；
- `Sources/Diagnostics/` 尚未做过独立审计；
- 解压器对恶意归档路径的处理与 `/Applications` 写权限探针的 TOCTOU 属继承项，本轮未重新审计；
- `flock` 在网络家目录（NFS / SMB）上的语义未测试；
- alpha 版本不提供 SLA。
