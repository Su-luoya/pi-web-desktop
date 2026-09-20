# Pi Web Desktop 0.1.0-alpha.11（build 11）— Apple Silicon alpha（未公证）

## 摘要 / Summary

Pi Web Desktop `0.1.0-alpha.11` 是面向 **Apple Silicon（arm64）、macOS 14 或更高版本** 的第十一个
alpha 预览。它启动、监控并显示本机已安装的 Pi Web 服务，默认只监听 loopback。相对
`0.1.0-alpha.10`，本版本 **没有任何功能或行为改动**：唯一的内容是一次大幅整理重构（PR #143，已合并为
`main` 上的 `03e06f5`；关闭 [#142](https://github.com/Su-luoya/pi-web-desktop/issues/142)）——把 `Sources/` 从 36 个扁平
文件重排为 5 个领域目录下的 83 个文件，并按职责拆分大文件。类型名、默认值、日志文本、菜单与窗口
布局、注入点协议、测试断言都不变；唯一可见性层面的差异是跨文件使用的 `private` / `fileprivate`
声明提升为 `internal`（仍限于本模块），以及三个更新协调器从 `*Adapter` 改名为 `*Coordinator`。

ZIP 里的应用仍然是 **ad-hoc 签名、未公证** 的：没有 Developer ID 证书，也没有 Apple 公证，
因此 Gatekeeper 默认会阻止直接双击打开，需要用户针对这一个应用手动放行。本版本没有 Intel 支持、
没有 SLA，**不承诺所有安装来源都能回滚**，远程访问的密码认证也**不等于传输加密**。更新验证仍然
**不做代码签名确认、不确认官方来源、不做安装包内容比对**。

Pi Web Desktop `0.1.0-alpha.11` is the eleventh alpha preview for **Apple Silicon (arm64) Macs
running macOS 14 or later**. It starts, monitors and displays a locally installed Pi Web service and
listens on loopback by default. Compared with `0.1.0-alpha.10` this release contains **no functional
or behavioural change at all**: the only content is a large-scale restructuring (PR #143, merged as
`03e06f5` on `main`, closing
[#142](https://github.com/Su-luoya/pi-web-desktop/issues/142)) that rearranges `Sources/` from 36 flat
files into 83 files in five domain directories and splits the large files by responsibility. Type
names, defaults, log text, menu and window layout, injection-point protocols and test assertions are
unchanged; the only visibility-level differences are `private` / `fileprivate` declarations that are
used across files becoming `internal` (still module-private), and three update coordinators renamed
from `*Adapter` to `*Coordinator`. The app inside the ZIP is still **ad-hoc signed and not
notarised**: without a Developer ID certificate and Apple notarisation, Gatekeeper blocks a plain
double-click by default, so the user has to allow this one app manually. There is no Intel support
and no SLA, **not every install source can be rolled back**, and password authentication for remote
access is **not transport encryption**. Update verification still **does not confirm code
signatures, does not confirm the official source, and does not compare installer contents**.

## 发布信息

| 项目 | 值 |
| --- | --- |
| 版本（tag） | `v0.1.0-alpha.11` |
| `CFBundleShortVersionString` | `0.1.0-alpha.11` |
| `CFBundleVersion` | `11` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 应用包 | `Pi-Web-Desktop.app` |
| 架构 | arm64（Apple Silicon）；**不支持 Intel（x86_64）** |
| 最低系统 | macOS 14.0 |
| 签名 | ad-hoc（`codesign --sign -`），没有证书，`TeamIdentifier=not set` |
| 公证 | 无。Gatekeeper 默认拒绝，需要用户手动放行这一个应用 |
| 发布类型 | GitHub **prerelease**（alpha 预览） |
| 上一版 | `v0.1.0-alpha.10`（build `10`），资产仍在 Releases 中可下载 |
| 本地数据位置 | UserDefaults（含 `workspace.recentPaths`）、`~/Library/Application Support/Pi Web Desktop/`、`~/Library/Logs/Pi Web Desktop/`、Keychain、WebKit 网站数据，见[隐私说明](privacy.md) |

版本与 build 的唯一来源是 `Configuration/AppIdentity.xcconfig`；本文件只是引用，不是来源。

## 目标平台

| 维度 | 支持范围 |
| --- | --- |
| CPU | Apple Silicon（arm64） |
| 系统 | macOS 14.0 或更高 |
| Intel Mac | 不支持，也没有 x86_64 产物 |
| 依赖 | Node.js `>=22.19.0`、Pi CLI、`@agegr/pi-web`（需用户自行安装，应用不打包也不自动安装） |
| 默认服务地址 | `http://127.0.0.1:30141/`（只监听 loopback） |

## `0.1.0-alpha.11` 相对 `0.1.0-alpha.10` 的新增与变更

**没有功能变更。** 本版本的代码提交只有一个（PR #143，关闭
[#142](https://github.com/Su-luoya/pi-web-desktop/issues/142)），内容是文件与目录的整理重构；随后是
发布提交本身（版本 bump、本文件、安全评审、门槛执行记录）。以下逐条说明这次重构做了什么、以及
为什么可以认为行为不变。

### 1. `Sources/` 按领域分目录

| 目录 | 文件数 | 内容 |
| --- | --- | --- |
| `Sources/App/` | 21 | 应用外壳：`AppDelegate.swift` 保留生命周期与装配，其余拆成 `AppDelegate+Menus.swift`、`AppDelegate+Window.swift`、`AppDelegate+Service.swift`、`AppDelegate+Quit.swift`、`AppDelegate+Diagnostics.swift`、`AppDelegate+UpdateChecks.swift`、`AppDelegate+PreLaunchUpdates.swift`、`AppDelegate+CLIUpdate.swift`、`AppDelegate+PackageUpdates.swift`；另有 `ServiceConfiguration`、`WebViewController`、`WebViewNavigationPolicy`、`WorkspaceDirectory`、`RecentWorkspace`、`QuitPolicy` / `QuitCoordinator`、`AppConfiguration` / `AppPaths`、设置窗口控制器与 `main.swift` |
| `Sources/Services/` | 17 | 服务生命周期与系统事实读取：`ServiceManager`、`ServiceOwnership`、`ProcessInspector`、`PiProcessInspector`、`ToolPath`、`KeychainStore`、`DependencyChecker`（含依赖探针、模型与报告呈现）、`InstallCommandManifest` |
| `Sources/Diagnostics/` | 6 | 日志、脱敏与诊断导出：`LogWriter`、`LogRedactor`、`DiagnosticsCollector`、`DiagnosticsClipboard`、`DiagnosticsWindowController`、`FirstLaunchDiagnostics` |
| `Sources/Updates/` | 37 | 更新检查、计划、执行与验证：`UpdateChecker` 族、更新设置与偏好、三条更新路径各自的 `*Model` / `*Planner` / `*Command` / `*Coordinator` / `*Status` 文件、事务与验证（`UpdateTransactionModel`、`UpdateTransactionJournal`、`UpdateVerifier`、`UpdateArtifact*`、`UpdateHistory`、`UpdateRollback`）、`UpdateAbandonedAttempt`、`ComponentInstallation*` |
| `Sources/Support/` | 2 | 跨领域小工具值类型：`SemanticVersion`、`NonEmptyString` |

### 2. 大文件按职责拆分

- 最大的两个文件是原 `Sources/PiWebApp.swift`（6803 行）与 `Sources/ServiceManager.swift`
  （3157 行），本版把它们按职责切开：`AppDelegate` 的九个功能面各占一个文件，`ServiceManager` 拆成
  生命周期/配置/依赖/诊断/进程等文件，更新相关的三条路径按 `Model → Planner → Command → Coordinator
  → Status` 分层。
- 拆分的边界是**职责**，不是行数：例如停止服务的确认与重启路径仍集中在 `AppDelegate+Service.swift`，
  Keychain 的读写仍只经过 `KeychainStore`，更新执行的每一步仍在同一条 `UpdateTransaction*` 链上。
- 工程文件（`PiWebDesktop.xcodeproj/project.pbxproj`）与 `Scripts/build.sh` 都改为按整棵 `Sources/`
  收集源码（app target 83 个文件、测试 target 67 个共享源文件 + 29 个测试文件），不再需要逐文件登记。

### 3. 唯一的两类可见性差异

- **`private` / `fileprivate` → `internal`**：跨文件使用的声明（类型、成员、扩展）提升为模块内可见。
  这类改动只影响编译器可见性，不改变运行时行为；同模块内没有任何新增的调用点。
- **`*Adapter` → `*Coordinator`**：`PiCLIUpdateCoordinator`、`PiWebUpdateCoordinator`、
  `PiPackageUpdateCoordinator` 三个类改名，名字与它们在目录结构里的角色一致。`PiWebDesktopTests` 里
  的测试**文件名与测试方法名保持不变**（`PiCLIUpdateAdapterTests` 等仍沿用旧名），因此测试筛选与
  历史记录不受影响。
- 另外 `ServiceManager.currentState` 的 `private(set)` setter 放宽为 `internal`：写入点仍是原来的几处
  （服务启动/停止/失败的几处状态转换），没有新增写入面。

### 4. 用户可见文档同步

- `docs/architecture.md`：新增「源码布局」一节（五个目录各自的内容、两类可见性差异、工程与构建脚本
  按目录收集源码、历史记录文档不回改），并把组件清单里的三个 `*Adapter` 名字改为 `*Coordinator`，
  给 `ProcessInspector`、`PreferencesWindowController` 等条目补上新路径。
- `docs/development.md`、`docs/logging-and-diagnostics.md`、`docs/privacy.md`、
  `docs/security-ownership.md`、`docs/settings-and-workspace.md`：把活文档里的 `Sources/<文件名>.swift`
  引用改写到新路径（36 条映射）。
- `docs/release-notes-*`、`docs/security-review-*` 与 `docs/alpha-release-checklist.md` 的既有执行记录是
  发布当时的历史记录，**保留当时的路径，不做回改**。

### 5. 本版的安全审查（delta）

- 完整的 delta 安全评审见 [安全评审（alpha.11）](security-review-alpha.11.md)。
- 结论：**阻断项 0 条，非阻断性发现 1 条**（`R1`：`ServiceManager.currentState` 的 setter 可见性
  放宽，不构成安全边界变化，仅登记）。评审范围是 PR #143 的实际改动，逐项核对了进程启动点、网络
  访问点、Keychain 访问点、更新门闩与脚本收集范围是否被拆分改动。
- 本版**没有**新增域名、没有新增读取面或写入面、没有改动任何确认流程或门闩条件。

## 行为不变性的证据

三重核对（脚本与日志在 `/tmp/refactor/`，随本版门槛执行记录引用）：

| 核对 | 结果 |
| --- | --- |
| 归一化行多重集合恒等式 | 旧 36 个文件 23975 个非空行 / 新 83 个文件 24136 个非空行。只在旧树出现 1 处（`private(set) var currentState: ServiceState = .checking` → `var currentState…`）；只在新树出现 162 处 = 81 行新增文件头注释 + 38 `import Foundation` + 13 `import Darwin` + 9 `import Cocoa` + 1 `import CryptoKit` + 1 `import CoreFoundation` + 9 个 `extension AppDelegate {` + 9 个对应 `}` + 上面那 1 处的镜像。行多重集合对顺序不敏感，是结构证据，不是行为证明 |
| XCTest 全量用例（本机 shim，逐文件串行） | 基线树（`main` `5bd520e`，原 36 个扁平文件）：746 passed / 0 failed + `ServiceConfigurationTests` 单独重跑 12 passed / 0 failed；重构树（PR #143，已合并为 `main` 上的 `03e06f5`）：**758 passed / 0 failed（of 758 discovered）** |
| 门槛脚本 | 构建、身份（45 项检查）、密钥扫描、冒烟（两种模式）、打包器自检、打包、签名复核全部退出 0（见下） |

基线全量跑只收集到 746 条，是因为旧工程文件里 `ServiceConfigurationTests.swift` 的 BuildFile 注记写成
`in Sources`（不是 `in Test Sources`），本机的收集脚本按注记判定而漏掉这一个文件；旧工程文件的 Test
Sources 构建阶段本身包含它，所以单独重跑即为 12/12 通过。**没有做**：真机 GUI 手工验收（本机只有
Command Line Tools）；完整的 `xcodebuild test`（由 PR #143 上的 CI 承担）。

## 更新检查与自动更新的边界（本版无变化）

本版**没有改动**更新检查的域名、频率、开关与自动更新的前置条件：两个主机常量（`api.github.com`、
`registry.npmjs.org`）未变，两条自动更新开关仍然默认关闭，扩展包更新仍然必须由用户确认。本次重构
只移动了这些代码所在的文件：`UpdateChecker` 族在 `Sources/Updates/`，两条自动更新的门闩与命令拼装
在各自路径的 `*Planner` / `*Command` / `*Coordinator` 文件里。完整边界（会做/不会做、域名与关闭方式、
三种更新路径的命令与超时行为）以 [alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md) 的
“更新检查访问的域名、频率与关闭方式”“自动更新的准确边界”两节为准。

## 本机实测环境与版本（可追溯）

| 项 | 值 |
| --- | --- |
| 硬件 | Apple M4（`sysctl -n machdep.cpu.brand_string`） |
| 架构 | `arm64` |
| macOS | `27.0`（`sw_vers -buildVersion` = `26A428`） |
| Swift | `6.4`（`swift --version`，Command Line Tools） |
| Node.js | `v24.21.0`（`/opt/homebrew/opt/node@24/bin/node`） |
| npm | `11.19.0` |
| `pi` | `0.86.1`（`/opt/homebrew/bin/pi` → `@earendil-works/pi-coding-agent`） |
| `@agegr/pi-web` | `0.9.1`（全局 npm 包） |
| 诊断摘要 | `items=6 / blockers=3`（`Scripts/smoke.sh --diagnostics`） |

与 alpha.10 记录的环境相比逐项相同，因此门槛结果可以直接和上一版对照。

## 安装

安装步骤、首次启动会看到什么、依赖怎么装、以及常见问题（Gatekeeper 放行、诊断导出、卸载与清理）
都在 [README](../README.md) 里，本节不再重复。与上一版相同：ZIP 解压后把 `Pi-Web-Desktop.app`
放进 `~/Applications` 或 `/Applications`；应用不打包也不需要 Node.js / Pi CLI / `@agegr/pi-web`
之外的任何运行时。

## 依赖前置与首次启动诊断

依赖（Node.js `>=22.19.0`、Pi CLI、`@agegr/pi-web`）需要用户自己安装，应用只做探测、显示与
诊断，不会自动安装（除非用户显式打开两条“启动前自动更新”开关，且所有前置条件满足）。
首次启动的诊断页会列出每一项的状态与缺失项的安装命令，细节见
[alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md) 的“依赖前置与首次启动诊断”一节与
[README](../README.md)。

## 未公证、ad-hoc 与 Gatekeeper

本产物用 ad-hoc 签名（`codesign --sign -`），没有 Developer ID 证书，也没有经过 Apple 公证。
`spctl -a -vv` 会拒绝它（退出码 3），**这是未公证 ad-hoc 产物的预期结果，不是损坏**。首次打开需要
用户手动放行：

1. 在 Finder 里右键 `Pi-Web-Desktop.app` → “打开”，在弹窗里再确认一次“打开”。
2. 或在“系统设置 → 隐私与安全性”里对该应用选择“仍要打开”。

请只放行本仓库 Releases 页面下载、并用下文“校验值”核对过 SHA-256 的那一份 ZIP。

## 校验值

本节的值来自 `release.yml` 在 tag `v0.1.0-alpha.11` 上生成的发布产物（发布后回填，与
`v0.1.0-alpha.10` 的做法一致）。

| 项 | 值 |
| --- | --- |
| 发布资产 | `Pi-Web-Desktop-0.1.0-alpha.11+build.11.zip` |
| 大小 | （发布后回填） |
| SHA-256 | （发布后回填） |
| 发布提交 | （发布后回填） |
| 校验 | `shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.11+build.11.zip.sha256` 与 Release 上的 `.zip.sha256` 一致 |

发布页：<https://github.com/Su-luoya/pi-web-desktop/releases/tag/v0.1.0-alpha.11>（prerelease）。

**本机演练值（不是发布资产）** —— 在候选工作区副本 `/tmp/piweb-alpha11`（`ditto --norsrc
--noextattr` 副本，`HEAD = 5bd520e`，工作区含未提交的重构改动——内容等价于 PR #143 的提交——与未提交
的版本 bump；本文件与安全评审写于这次演练之后，没有进入该演练产物）用
`Scripts/package-release.sh --tag v0.1.0-alpha.11` 打包，用来验证打包链路与记录产物形态：

| 项 | 值 |
| --- | --- |
| 演练资产 | `Pi-Web-Desktop-0.1.0-alpha.11+build.11.zip` |
| 大小 | `1528627` 字节 |
| SHA-256 | `bac764ca85c3b29ce95a7d6ede11763b9888f6aec7504dcc8554141979c31a8a` |
| 演练提交 | `5bd520ec56c657d61f0e29f7cee8161b7c437b9f`（`dist/release-metadata.env` 的 `COMMIT`；工作区 dirty，所以这只是演练值） |
| 校验 | `shasum -a 256 -c` 通过 |

这些数值**不可复现**，只记录那一次产物：同一条命令在本机重跑会得到不同的大小与 SHA-256（可执行文件里
的 ad-hoc 签名 blob、`LC_UUID` 与编译期代码字节都会变；演练产物自带的 `dist/*.evidence.md` 也写明
这一点）。发布用的 ZIP 由 `release.yml` 在 tag 上重新打包（同一条 `Scripts/package-release.sh`），
大小与校验值以 Release 上的 `.zip.sha256` 与本节的回填值为准。

## 构建与签名验证记录（本机演练）

演练对象：上一节的演练 ZIP（本机构建）。命令与结果：

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 脚本语法 | `sh -n Scripts/*.sh` | 退出 0 |
| 空白与补丁格式 | `git diff --check` | 退出 0（干净） |
| 构建 | `Scripts/build.sh` | `Built … (arm64)`；`file` 报 Mach-O 64-bit executable arm64 |
| 版本一致性 | `Scripts/check-release-version.sh v0.1.0-alpha.11` | `PASSED`（`MARKETING_VERSION = 0.1.0-alpha.11`、`CURRENT_PROJECT_VERSION = 11`；唯一来源 `Configuration/AppIdentity.xcconfig`） |
| 身份与文本扫描 | `Scripts/check-identity.sh` | `PASSED (45 checks)`，含 `no hardcoded MARKETING_VERSION` |
| 密钥扫描 | `Scripts/scan-secrets.sh --self-test`、`Scripts/scan-secrets.sh` | `--self-test` PASS；工作区扫描 `suppressed 15 lines`、`PASS (no matches in tracked files; no untracked files)`（N=15 与 alpha.5 … alpha.10 记录一致，本版没有新增抑制标记） |
| 冒烟 | `Scripts/smoke.sh`（默认与 `--diagnostics`） | 两个模式 exit 0；标记 `smoke: ready` 与 `smoke: diagnostics ready`；诊断报告 `items=6` / `blockers=3`；日志里仍有 `/tmp` 路径下的 `sandbox_extension_issue_file_to_process` 提示（与 alpha.10 相同，不影响结果） |
| 签名校验 | `codesign --verify --deep --strict <app>` | exit 0 |
| 签名详情 | `codesign -dv <app>` | `Identifier=io.github.su-luoya.pi-web-desktop`；`Format=app bundle with Mach-O thin (arm64)`；`flags=0x2(adhoc)`；`TeamIdentifier=not set`；`Sealed Resources version=2 rules=13 files=1` |
| Gatekeeper | `spctl -a -vv <app>` | `rejected`（退出 3，预期：ad-hoc 且未公证） |
| 包内容 | `unzip -l` | 9 个条目、无 `__MACOSX` |
| 打包 | `Scripts/package-release.sh --tag v0.1.0-alpha.11` | `OK`；白名单 8 个条目、mtime 固定为 `200101010000`、evidence 记录 `macOS 27.0` / arm64 |
| 打包器自检 | `Scripts/package-release.sh --self-test` | `PASS`（白名单表、拒绝路径、正例端到端） |

演练里踩到的与产品无关的一点：仓库位于 `~/Documents`（iCloud 同步目录）时，`codesign --verify` 会因
`com.apple.FinderInfo` 与 `com.apple.fileprovider.fpfs#P` 扩展属性报错（退出 1），`xattr -cr` 之后同一
bundle 复核退出 0。这与 alpha.10 记录的 `xattr` 处理一致（`Scripts/build.sh` 与
`Scripts/package-release.sh` 都会清理扩展属性并重试），因此演练与发布都在非同步目录里执行。

XCTest 用例（本机 shim，串行单文件运行）：**758 passed / 0 failed**（of 758 discovered），与重构前的
基线数量一致（基线全量 746 + 单独重跑的 12，见「行为不变性的证据」）。完整的 `xcodebuild build` 与
`xcodebuild test` 由 PR #143 上的 CI 承担（本机只有 Command Line Tools，没有完整 Xcode）。

**没有做**：真机 GUI 手工验收；更新检查与自动更新的端到端真机演练。

## 已知问题

### 1. 本版仍然存在的问题

- **未公证、ad-hoc 签名**：Gatekeeper 默认阻止直接双击打开，需要用户针对这一个应用手动放行（见「未公证、ad-hoc 与 Gatekeeper」）。本版不引入 Developer ID，也不做公证。
- **更新验证的边界**：不确认代码签名、不确认官方来源、不做安装包内容比对（见「更新检查与自动更新的边界」）。验证只看版本证据与文件身份。
- **回滚能力不均**：只有带版本证据的安装来源才走降级路径；npm 全局更新与 Pi 扩展包更新没有自动回滚，失败时只保证不声称成功、不改状态。
- **远程访问默认不加密**：Pi Web 的密码认证不等于传输加密，远程访问应只经隧道或 VPN（见「支持边界」）。
- **真机 GUI 未手工验收**：本机只有 Command Line Tools、没有 Xcode，本版的门槛是脚本（构建 / 身份 / 冒烟 / 打包 / 签名）加上 shim 上的单文件 XCTest；完整的 `xcodebuild test` 由 CI 承担。alpha.10 的「最近工作目录」功能面**仍然没有真机点击验收**，这一点在本版没有变化（本版不涉及该功能面的代码改动，只涉及文件位置）。
- **切换语义的四个评审遗留**（[#135](https://github.com/Su-luoya/pi-web-desktop/issues/135)，本版未修，仅位置随重构更新）：
  - `F1` **重叠切换竞态**：`Sources/App/AppDelegate+Service.swift:144-148` 在停止服务的完成回调里无条件写回它捕获的配置，`Sources/Services/ServiceManager.swift:172` 的 `updateConfiguration` 没有代次校验。
  - `F2` 服务是外部进程时，界面没有说明「新目录要等自行重启服务后才生效」。
  - `F3` `application(_:open:)` 未检查 `url.isFileURL`（实现现位于 `Sources/App/AppDelegate+Window.swift`），`urls.count > 1` 时静默丢弃其余 URL。
  - `F4` 路径接受面未收紧：不展开 `~`、未显式拒绝根目录 `/`、未 `resolvingSymlinksInPath`、没有超长路径与控制字符防护。
- **一处既往文案观察（`O-1`，仍未改，位置更新）**：`Sources/Updates/PiCLIUpdateStatus.swift:113` 与 `Sources/Updates/PiWebUpdateCoordinator.swift:422` 的持久警告以「旧版本语义保持不变：应用不会自动回滚已替换的文件，也不声称更新成功」开头。这里说的是**语义**（冒号后即定义），不是文件位置断言；早于 alpha.9 的 delta，本版没有改动。

### 2. alpha.10「已知问题」在本版的状态

| 编号 | alpha.10 的发现 | 本版状态 |
| --- | --- | --- |
| `F1` / `F2` / `F3` / `F4`（[#135](https://github.com/Su-luoya/pi-web-desktop/issues/135)） | alpha.10 功能的四条评审发现 | 未修（本版不做行为改动）；位置已在上面更新到新路径 |
| `O-1` | 两行持久警告的既往措辞 | 仍未改，位置更新为 `Sources/Updates/PiCLIUpdateStatus.swift:113` 与 `Sources/Updates/PiWebUpdateCoordinator.swift:422` |
| `L-1` / `L-3` / `L-4` / `L-5`（[#127](https://github.com/Su-luoya/pi-web-desktop/issues/127)） | alpha.8 delta 的四条发现 | alpha.9 已全部关闭，本版没有回退或改动这些路径 |
| 未公证需手动放行 / 依赖需自装 / 无应用内更新 / 只支持 Apple Silicon | 产品边界 | 本版均无变化 |

alpha.10 说明中列出的其余边界（路径即信任边界、不校验签名、不做内容比对、未公证）在设计上没有变化，
仍按「支持边界」与「更新检查与自动更新的边界」执行。

### 3. 需要在真机验证的行为

- 本版没有行为改动，因此**没有新增的真机验收项**；alpha.10 功能面的五条真机项（拖放切换路径、
  托管服务切换后的实际工作目录、清除历史后重启、外部服务的文案、连点两个目录的竞态）仍然有效，
  仍在 [#135](https://github.com/Su-luoya/pi-web-desktop/issues/135) 跟踪。
- 打开一次本版的 `Pi-Web-Desktop.app`，确认窗口、菜单与 alpha.10 一致（本版的门槛是脚本与用例，
  没有 GUI 点击）。

## 回退

1. 保留上一版的 ZIP 与它的 `.sha256`。回退时解压上一版（`v0.1.0-alpha.10`，资产仍在 Releases 中）
   并替换当前的 `Pi-Web-Desktop.app`，然后用 `codesign --verify --deep --strict` 复核（未公证的
   ad-hoc 产物仍会被 `spctl` 拒绝，这是预期结果）。
2. 删除应用包即可完成卸载：应用没有系统级常驻组件或 LaunchAgent，删除应用包不会残留其他系统文件
   （退出应用后 `rm -rf "$HOME/Applications/Pi-Web-Desktop.app"`，装在 `/Applications` 时替换路径）。
3. 清理用户目录数据、删除「已放弃」记录、以及组件版本回退的具体命令与边界，见
   [alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md) 的“回退”一节与
   [隐私说明](privacy.md#本地数据一览与删除)。本版**没有新增任何本地数据**：重构只移动文件位置，
   UserDefaults 键、Application Support 与 Logs 的目录结构都没有变化。
4. 已经发布的版本不会静默替换 ZIP 或 checksum；新版本有问题时发布新的 alpha 并在 Release 说明中
   给出回退路径。

## 支持边界

- 只支持 Apple Silicon（arm64）与 macOS 14 或更高版本；没有 Intel 产物。
- 没有 SLA，桌面应用没有自动更新安装，没有 Developer ID 签名、Apple 公证或 Apple 支持渠道。
- 默认只监听 loopback；远程访问必须自备加密传输，并且**密码认证不等于传输加密**。
- 更新路径的硬边界（本版未变）：两条自动更新默认关闭且只对来源可信的 npm/pnpm 全局安装生效，
  目标版本必须来自本次网络检查；扩展包更新必须由用户确认；验证不做代码签名确认；不承诺所有来源
  都能回滚；一次只允许一轮更新事务，放弃等待后“未确认退出”的窗口只能靠重启应用可靠恢复。
- 更新检查只访问 `api.github.com` 与 `registry.npmjs.org`，只读、可逐类关闭；除此之外应用不主动
  向任何上游发送数据（自动更新触发的网络请求由用户自己的 `npm` / `pi` 按其配置发出）。
- 依赖探测会读一次登录 shell 的 `PATH`（本机、只读、有超时），并使用合并后的 `PATH` 启动
  依赖探测、更新命令与服务进程。
- 最近工作目录的边界：只保存用户自己选择或被要求打开的绝对路径，最多 10 条；应用**不会**因为
  条目而创建目录，也不会在目录消失时自动清理条目（切换时会拒绝并提示）。为接收文件夹声明了
  `CFBundleDocumentTypes`（`public.folder`），因此 Finder 的「打开方式」会为任意文件夹列出本应用。
- 不要在公开 Issue、PR 或 Release 评论里粘贴密码、token、私有主机名、代理凭据或未脱敏日志。

## 反馈与安全报告

- 普通问题与功能建议：使用本仓库的
  [Issue 表单](https://github.com/Su-luoya/pi-web-desktop/issues/new/choose)；请附版本、安装与依赖
  信息（脱敏后的诊断导出），以及可复现步骤。上游 Pi Web、Pi CLI 或 Pi packages 的问题请先到对应
  上游仓库确认。
- 安全漏洞：**不要**开公开 Issue、不要粘贴到 PR 或 Release 评论。请使用
  [私密漏洞报告](https://github.com/Su-luoya/pi-web-desktop/security/advisories/new)，
  范围、处理流程与“不承诺 SLA”的说明见 [SECURITY.md](../SECURITY.md)。
