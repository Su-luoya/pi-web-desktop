# Pi Web Desktop 0.1.0-alpha.18（build 18）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.18` 面向 Apple Silicon（arm64）与 **macOS 26 或更高版本**。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版是相对 `0.1.0-alpha.17` 的一次清理发布，没有新增功能，也没有修复用户可见缺陷。改动的来源是一轮以 `macos-app-skills` 为基准的代码审查，结论是：**绝大多数 skill 条目本仓库早已满足**，真正需要动的只有两类——部署目标写错导致的死代码，以及一处用错系统 API 的注释。

**破坏性变更：最低系统从 macOS 14 提到 macOS 26。** 这是本版唯一会影响已安装用户的变化，详见下节。

## 破坏性变更：最低系统 macOS 14 → macOS 26

`Configuration/AppIdentity.xcconfig` 的 `APP_MINIMUM_SYSTEM_VERSION` 从 `14.0` 改为 `26.0`。影响：

- macOS 14 / 15 上的用户**无法安装本版**，也无法从 alpha.17 自动更新到 alpha.18（系统会拒绝部署目标更高的 bundle）；他们会留在 alpha.17。
- alpha.17 的发布资产仍然可下载，回退路径不受影响。
- 决定理由：应用的真实实现早就只覆盖 macOS 26 的接口（详见下节的死代码清理与 `posix_spawn` 一项），继续声明 14.0 会让"支持 macOS 14"成为一句无法兑现的承诺——那些 `#available(macOS 11/12/14)` 分支恰好掩盖了这一点。

如果后续决定重新支持 macOS 14/15，只需回退 `APP_MINIMUM_SYSTEM_VERSION` 这一行，其余改动（死代码删除、API 替换）需要一并回退，因为它们以 macOS 26 为编译前提。

## 本版改动

**死代码清理**

部署目标定在 macOS 26 之后，下列判断永远为真，属于不可达分支：

- `Sources/App/WebViewController.swift`：3 处 `@available(macOS 11.3, *)`；`performFind` 的 `#available(macOS 11.0)` 双分支收成单一路径；`decidePolicyFor navigationResponse` 的 `if` / `#available` / `else` 三层嵌套收成一个三元表达式（不再用 `.cancel` 兜底，因为 `.download` 分支始终可用）；
- `Sources/App/PreferencesWindowController.swift`、`Sources/Diagnostics/DiagnosticsWindowController.swift`：`NSOpenPanel.allowedContentTypes` 的 `#available(macOS 12.0, *)` 包裹。

**已废弃 API**

- 6 处 `NSApp.activate(ignoringOtherApps: true)` 改为 `NSApp.activate()`。前者在 macOS 26 SDK 头文件里已标记 `API_DEPRECATED`，后者是官方替代品，语义为"把应用激活到前台"，不再有"是否抢焦点"的参数。

**可用性边界对齐**

- `Sources/Services/DependencyChecker.swift`：`minimumMacOSVersion` 从 14.0 改为 26.0，与 xcconfig 一致。诊断页的"系统版本过低"判定因此提前到 macOS 26 以下；此前在 macOS 14 上报告"版本合格"的应用，在新下限下会明确报 outdated，而不是给出一个系统其实跑不动的通过结论。

**`posix_spawn` 工作目录**

- `Sources/Services/ServiceLaunching.swift`：把 `posix_spawn_file_actions_addchdir_np` 换成 `posix_spawn_file_actions_addchdir`。`_np` 变体自 macOS 26 起被标记废弃，正式版 `addchdir` 正是 macOS 26 引入的——在旧的 14.0 部署目标下无法使用它，这也是本次提最低系统的直接动因之一。**服务启动的进程工作目录行为不变**，只是改用非废弃入口。

**构建与文档**

- `.github/workflows/build.yml`、`.github/workflows/release.yml`：`runs-on` 从 `macos-14` 改为 `macos-26`（runner 的系统版本不能低于部署目标）。
- `Scripts/build.sh`、`Scripts/package-release.sh`：补充注释说明为什么保留 `codesign --deep`。上游对这个参数的反对意见针对的是带 SPM / XCFramework 依赖的 bundle（会以错误 entitlements 重签嵌套代码），而本 bundle 的两个 Frameworks build phase 都为空、没有 package product dependency，`--deep` 实际只走一个 Mach-O。删除它只会改变重试之间对 `build/` 里陈旧嵌套 bundle 的重新签名方式，而这条路径已由 `--force` 尝试循环覆盖。
- `README.md`、`Docs/development.md`、`Docs/releasing.md`、`Docs/release-notes-template.md`：最低系统表述同步为 macOS 26。历史发布说明与 `Docs/security-review-*.md` 是当时的实测记录，保持原样。

## 目标平台与安装

| 项目 | 值 |
| --- | --- |
| CPU | Apple Silicon（arm64）；不支持 Intel（x86_64） |
| 最低系统 | macOS 26.0 |
| 应用包 | `Pi-Web-Desktop.app` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 签名 | ad-hoc；没有 Developer ID 证书 |
| 公证 | 无 |

ZIP 下载后请先使用配套的 `.zip.sha256` 校验，再将应用放入 `~/Applications` 或 `/Applications`。不要为了运行本 alpha 关闭 Gatekeeper；首次打开时在 Finder 中右键选择"打开"，或在"系统设置 → 隐私与安全性"中针对该应用放行。

应用不打包 Node.js、Pi CLI 或 `@agegr/pi-web`，这些依赖需要用户自行安装。应用内桌面自更新仍只允许用户确认后执行，并且只支持位于 `/Applications/Pi-Web-Desktop.app` 的安装；它不是无人值守更新，也不提供新版本启动失败后的自动回滚。

## 验证

- 本地 `xcodebuild test`：951 个测试，0 失败；
- `./Scripts/build.sh`：成功，`LSMinimumSystemVersion=26.0`；
- `./Scripts/check-identity.sh`：`PASSED (45 checks)`；
- `./Scripts/check-release-version.sh`：`PASSED (tag v0.1.0-alpha.18, MARKETING_VERSION 0.1.0-alpha.18, CURRENT_PROJECT_VERSION 18)`；
- `./Scripts/smoke.sh`：两种模式均 OK；
- `./Scripts/scan-secrets.sh`：PASS；
- `git diff --check`：通过；
- CI：`build` workflow 在 `macos-26` runner 上 14 个步骤全部成功（含 `xcodebuild test`、身份校验、个人数据检查、secret 扫描自检、smoke 启动与打包）。

## 变更边界

本版没有新增第三方 Swift 包、npm 运行时依赖或服务控制路径，没有新增 UserDefaults 键，没有改动信任边界、权限判定或更新事务链。`Sources/` 的改动全部是删除不可达分支、替换已废弃 API、以及对齐版本下限；服务进程的启动参数、工作目录与信号处理语义保持不变。

非 loopback 访问仍是明文 HTTP；密码认证不等于传输加密。自动更新使用既有的 GitHub / npm 检查与发布边界，不把同源 SHA-256 校验描述成开发者身份验证。

## 回退

保留上一版 `v0.1.0-alpha.17` 的 ZIP 与 checksum。若本版应用不可用，手动解压上一版并替换应用包；应用没有系统级常驻组件。

**注意：回退到 alpha.17 之后不要再次更新到 alpha.18，除非你的机器已经跑在 macOS 26 或更高版本。**

## 已知限制

- ad-hoc、未公证，首次手动安装需要用户放行；
- 最低系统 macOS 26，macOS 14 / 15 上的用户停留在 alpha.17；
- 桌面应用自更新仅支持 `/Applications`，需要用户确认；
- 自更新失败会保留旧安装，但新版本安装后启动失败不会自动回滚；
- GUI 菜单与设置窗口的实际观感只有源码级断言覆盖，没有自动化真机验证；
- `Sources/Diagnostics/` 尚未做过独立审计；
- 解压器对恶意归档路径的处理与 `/Applications` 写权限探针的 TOCTOU 属继承项，本轮未重新审计；
- `flock` 在网络家目录（NFS / SMB）上的语义未测试；
- alpha 版本不提供 SLA。
