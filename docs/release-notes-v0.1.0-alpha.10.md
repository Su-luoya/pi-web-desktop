# Pi Web Desktop 0.1.0-alpha.10（build 10）— Apple Silicon alpha（未公证）

## 摘要 / Summary

Pi Web Desktop `0.1.0-alpha.10` 是面向 **Apple Silicon（arm64）、macOS 14 或更高版本** 的第十个
alpha 预览。它启动、监控并显示本机已安装的 Pi Web 服务，默认只监听 loopback。相对
`0.1.0-alpha.9`，本版本只有 **1 个代码提交**（PR #136：一个新功能，连同它的用户可见文档与用例，
关闭 1 个 issue），除此之外只有发布提交本身（版本 bump 与四份文档：发布说明、安全评审、本次执行
记录、`docs/architecture.md` 注记），没有修复面变化：

1. **最近工作目录与快速切换**（#134 / PR #136）：服务菜单新增「最近工作目录」子菜单，按最近使用
   排序、按标准化路径去重、最多 10 条，当前目录打勾，另有「在 Finder 中打开当前工作目录」与
   「清除历史记录」。除了菜单，把文件夹拖到应用图标或窗口、`open -a "Pi Web Desktop" <目录>`、
   Finder 的「打开方式」也会走同一条校验与确认路径。
2. **只接受可用的绝对路径**：相对路径与 `~` 一律拒绝；目录必须存在、是目录、可写。任何一项不通过
   都不写状态、不创建目录，只给可读提示。
3. **切换的生效与边界**：与当前目录不同时先确认；服务由应用托管且正在运行时按钮为「切换并重启」，
   新目录写入 `service.workspacePath` 后进入 `ServiceConfiguration.runtimeSignature`，托管服务按新
   目录重启；服务是外部进程时按钮只是「切换」，应用不停止也不重启它。
4. **文档与用例**：`docs/settings-and-workspace.md` 新增一节并记录 `CFBundleDocumentTypes` 的代价，
   `docs/privacy.md` 补 `workspace.recentPaths`，`docs/architecture.md` 与 `README.md` 各补一条；
   新增 `PiWebDesktopTests/RecentWorkspaceTests.swift`。

ZIP 里的应用仍然是 **ad-hoc 签名、未公证** 的：没有 Developer ID 证书，也没有 Apple 公证，
因此 Gatekeeper 默认会阻止直接双击打开，需要用户针对这一个应用手动放行。本版本没有 Intel 支持、
没有 SLA，**不承诺所有安装来源都能回滚**，远程访问的密码认证也**不等于传输加密**。更新验证仍然
**不做代码签名确认、不确认官方来源、不做安装包内容比对**。

Pi Web Desktop `0.1.0-alpha.10` is the tenth alpha preview for **Apple Silicon (arm64) Macs running
macOS 14 or later**. It starts, monitors and displays a locally installed Pi Web service and listens
on loopback by default. Compared with `0.1.0-alpha.9` this release contains **a single code commit**
(PR #136: one new feature together with its user-visible documentation and unit tests, closing one
issue) and nothing else besides the release commit itself. The Service menu now lists the most
recently used working directories (most recent first, de-duplicated by normalised absolute path, up
to 10 entries, the current one ticked), can reveal the current directory in Finder and clear the
history; a folder can also be handed to the app by dropping it on the icon or window, with
`open -a`, or through Finder's "Open With", and all of those entries go through the same validation
(absolute path only, must exist, must be a directory, must be writable) and the same confirmation.
Switching writes `service.workspacePath`, which enters `ServiceConfiguration.runtimeSignature`, so a
service managed by the app is restarted on the new directory; a service that is an external process
is never stopped or restarted by the switch. The app inside the ZIP is still **ad-hoc signed and not
notarised**: without a Developer ID certificate and Apple notarisation, Gatekeeper blocks a plain
double-click by default, so the user has to allow this one app manually. There is no Intel support
and no SLA, **not every install source can be rolled back**, and password authentication for remote
access is **not transport encryption**. Update verification still **does not confirm code
signatures, does not confirm the official source, and does not compare installer contents**.

## 发布信息

| 项目 | 值 |
| --- | --- |
| 版本（tag） | `v0.1.0-alpha.10` |
| `CFBundleShortVersionString` | `0.1.0-alpha.10` |
| `CFBundleVersion` | `10` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 应用包 | `Pi-Web-Desktop.app` |
| 架构 | arm64（Apple Silicon）；**不支持 Intel（x86_64）** |
| 最低系统 | macOS 14.0 |
| 签名 | ad-hoc（`codesign --sign -`），没有证书，`TeamIdentifier=not set` |
| 公证 | 无。Gatekeeper 默认拒绝，需要用户手动放行这一个应用 |
| 发布类型 | GitHub **prerelease**（alpha 预览） |
| 上一版 | `v0.1.0-alpha.9`（build `9`），资产仍在 Releases 中可下载 |
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

## `0.1.0-alpha.10` 相对 `0.1.0-alpha.9` 的新增与变更

本版本的代码改动只有一个提交（PR #136，关闭 [#134](https://github.com/Su-luoya/pi-web-desktop/issues/134)），内容是「最近工作目录与快速切换」这一个新功能面；随后是纯文档同步，以及本版发布提交本身。

### 1. 「服务 → 最近工作目录」（#134 / PR #136）

- 子菜单列出最近用过的目录，**最近使用优先**、按标准化路径**去重**、**最多 10 条**，当前工作目录带勾选标记；列表为空时显示一条禁用的「无最近工作目录」，末尾是「清除历史记录」。完整绝对路径就是菜单标题，超过 40 个字符时中段省略（完整值仍在确认框与拒绝提示里）。
- 同处还有「在 Finder 中打开当前工作目录」（`NSWorkspace.shared.open`），它只打开当前目录，不改变任何状态。

### 2. 把文件夹交给应用的四个入口走同一条路径

- 菜单选择、把文件夹拖到应用图标或窗口、`open -a "Pi Web Desktop" <目录>`、Finder 的「打开方式」都进入 `AppDelegate.application(_:open:)`，只取第一个 URL（`urls.count > 1` 时其余静默忽略）。拖放不新增剪贴板代码：Launch Services 把拖放转成 open 事件，应用不读剪贴板、也不新增自己的拖放解析。
- 为接收文件夹，`Scripts/build.sh` 的 Info.plist 拼装与两个 app target 都声明了 `CFBundleDocumentTypes`（`public.folder`，role `Editor`）。**代价**：Finder 的「打开方式」会为任意文件夹列出本应用；应用因此多了一个「被要求打开某个目录」的入口，行为与菜单切换完全相同（同样的校验、同样的确认、同样的托管服务重启），已在 `docs/settings-and-workspace.md` 写明。

### 3. 校验、确认与生效语义

- `RecentWorkspaceStore`（`Sources/RecentWorkspace.swift`）负责持久化、去重、置顶与上限；`WorkspaceSwitchDecision.decide(requestedPath:currentPath:probe:)` 是纯逻辑决策：与当前目录相同 → `.unchanged`；不是绝对路径、目录不存在、不是目录、不可写 → `.reject(该原因)`；否则 `.confirm`。
- 只接受绝对路径：相对路径与 `~` 都不展开、一律拒绝。校验不通过时**不写状态、不创建目录**，只显示可读提示；应用不会因为用户给了一个不存在的路径而新建目录。有专门用例断言「任何分支都不创建目录」。
- 与当前目录不同时先确认（`NSAlert`）：服务由应用托管且正在运行时文案写明「确认后将重启服务。」、按钮为「切换并重启」；服务是外部进程时按钮只是「切换」，**应用不停止也不重启它**，界面不谎称已生效。
- 切换成功后写入 `service.workspacePath`（`AppConfiguration`），因此进入 `ServiceConfiguration.runtimeSignature`，托管服务按新目录重启；停止路径复用既有的、只对已验证托管进程组生效的实现。
- 记录时机：启动时记录一次当前工作目录；切换成功或配置未变化时也记录。

### 4. 用户可见文档同步

- `docs/settings-and-workspace.md`：新增「最近工作目录与快速切换」一节（记录与上限、路径标准化、四个切换入口、校验与拒绝语义、确认与托管重启文案、Finder 打开当前目录、`CFBundleDocumentTypes` 的代价），并在「测试覆盖」补 `RecentWorkspaceTests`。
- `docs/privacy.md`：本地数据一览的 UserDefaults 行补 `workspace.recentPaths`（最多 10 条用户自己选过的绝对路径，只用于菜单展示、确认框与「在 Finder 中打开」，不进日志或诊断导出）。
- `docs/architecture.md`：组件清单补 `RecentWorkspaceStore` 与 `WorkspaceSwitchDecision`，UserDefaults 键清单补 `workspace.recentPaths`。
- `README.md`：日常使用补菜单入口与拖放切换。
- 本版发布提交另在 `docs/architecture.md` 的 `RecentWorkspaceStore` 条目上补了一条注记（切换只写 `service.workspacePath`、复用既有托管进程停止路径、外部服务不被停止或重启，并引用 [alpha.10 安全评审](security-review-alpha.10.md) 与 [#135](https://github.com/Su-luoya/pi-web-desktop/issues/135)），并在 `docs/alpha-release-checklist.md` 新增本版执行记录。

### 5. 本版的安全审查（delta）

- 完整的 delta 安全评审见 [安全评审（alpha.10）](security-review-alpha.10.md)。
- 结论：**阻断项 0 条，非阻断性发现 4 条**。评审范围是 PR #136 的实际改动（`git diff 21ce459..09f1264`），逐处核对了新能力的边界、UserDefaults 写入内容、`CFBundleDocumentTypes` 的代价、切换路径对既有停止语义的复用与测试面。
- 四条非阻断发现（`F1` 重叠切换竞态、`F2` 外部服务文案、`F3` open 事件处理不严、`F4` 路径接受面）已在同一轮评审中登记为 [#135](https://github.com/Su-luoya/pi-web-desktop/issues/135)，**不在本版修**；评审同时提出的文档缺口 `F5` 已在本版提交内修掉。

## 更新检查与自动更新的边界（本版无变化）

本版**没有改动**更新检查的域名、频率、开关与自动更新的前置条件，也没有新增任何安装路径：
`Sources/UpdateChecker.swift` 的两个主机常量（`api.github.com`、`registry.npmjs.org`）未变，两条
自动更新开关仍然默认关闭。上一次改动这条边界的是 alpha.9（失败措辞与门闩提示），完整边界（会做/
不会做、域名与关闭方式、三种更新路径的命令与超时行为）以
[alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md) 的
“更新检查访问的域名、频率与关闭方式”“自动更新的准确边界”两节为准。

新增的最近工作目录功能**不发起任何网络请求**：它只读写 UserDefaults 的 `workspace.recentPaths`、
菜单标题、确认框与 `NSWorkspace.shared.open`（后者由 Finder 打开一个本机目录）。

## 本机实测环境与版本（可追溯）

| 项 | 值 |
| --- | --- |
| 硬件 | Apple M4（`sysctl -n machdep.cpu.brand_string`） |
| 架构 | `arm64` |
| macOS | `27.0`（`sw_vers -buildVersion` = `26A428`） |
| Node.js | `v24.21.0`（`/opt/homebrew/opt/node@24/bin/node`；构建、冒烟与打包脚本都在这条 PATH 上运行） |
| npm | `11.19.0` |
| `pi` | `0.86.1`（`/opt/homebrew/bin/pi` → `@earendil-works/pi-coding-agent`；alpha.9 记录为 `0.86.0`，本版记录到了这次升级） |
| `@agegr/pi-web` | `0.9.1`（全局 npm 包） |
| 诊断摘要 | `items=6 / blockers=3`（`Scripts/smoke.sh --diagnostics`） |

门槛脚本与冒烟脚本都在这一套版本上运行过。与 alpha.9 记录的环境相比，只有 `pi` 从 `0.86.0` 变成
`0.86.1`；其余项相同，因此门槛结果可以直接和上一版对照。

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

本节的值来自 `release.yml` 在 tag `v0.1.0-alpha.10` 上生成的发布产物，由协调者回填（与 `v0.1.0-alpha.9` 的做法一致）。

| 项 | 值 |
| --- | --- |
| 发布资产 | `Pi-Web-Desktop-0.1.0-alpha.10+build.10.zip` |
| 大小 | `1599906` 字节 |
| SHA-256 | `e8209950f7e83897ab55c4c02482b673f6d860c9a5bc8a13cd5f0b8d0c6044b6` |
| 发布提交 | `e5ff919f6cd44625668dbfa161bf484f110e351a`（`chore(release): v0.1.0-alpha.10 版本 bump、发布说明、安全评审与门槛执行记录 (#138)`，tag `v0.1.0-alpha.10` 指向该提交） |
| 校验 | `shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.10+build.10.zip.sha256` 与 Release 上的 `.zip.sha256` 一致 |

发布页：<https://github.com/Su-luoya/pi-web-desktop/releases/tag/v0.1.0-alpha.10>（prerelease，发布于 `2026-09-20T14:26:07Z`）。生成该产物的 `release.yml` 运行：<https://github.com/Su-luoya/pi-web-desktop/actions/runs/35516264609>；发布提交在 `main` 上的 CI 运行：<https://github.com/Su-luoya/pi-web-desktop/actions/runs/35516260159>（均 success）。

**本机演练值（不是发布资产）** —— 在候选工作区 `/tmp/piweb-alpha10-rehearsal2`（`ditto --norsrc
--noextattr` 副本，`HEAD = 09f1264`，工作区只有未提交的版本 bump
`Configuration/AppIdentity.xcconfig`；本文件与安全评审写于这次演练之后，没有进入该演练产物）用
`Scripts/package-release.sh --tag v0.1.0-alpha.10` 打包，用来验证打包链路与记录产物形态：

| 项 | 值 |
| --- | --- |
| 演练资产 | `Pi-Web-Desktop-0.1.0-alpha.10+build.10.zip` |
| 大小 | `1526455` 字节 |
| SHA-256 | `ff47675cc96e40a2ab0444a519df6cb8a47d4d0b53c92b22549f94044cb8fbf6` |
| 演练提交 | `09f12646a0129fe355bbd4ab6d84159076dc594d`（`dist/release-metadata.env` 的 `COMMIT`；工作区 dirty，所以这只是演练值） |
| 校验 | `shasum -a 256 -c` 通过 |

这些数值**不可复现**，只记录那一次产物：同一条命令在本机重跑会得到不同的大小与 SHA-256（可执行文件里的 ad-hoc 签名 blob、`LC_UUID` 与编译期代码字节都会变；演练产物自带的 `dist/*.evidence.md` 也写明这一点）。发布用的 ZIP 由 `release.yml` 在 tag 上重新打包（同一条 `Scripts/package-release.sh`），大小与校验值以 Release 上的 `.zip.sha256` 与本节的回填值为准。

## 构建与签名验证记录（本机演练）

演练对象：上一节的演练 ZIP（本机构建）。命令与结果：

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 脚本语法 | `sh -n Scripts/*.sh` | 退出 0 |
| 空白与补丁格式 | `git diff --check` | 退出 0（干净） |
| 构建 | `Scripts/build.sh` | `Built … (arm64)`；`file` 报 Mach-O 64-bit executable arm64 |
| 版本一致性 | `Scripts/check-release-version.sh v0.1.0-alpha.10` | `PASSED`（`MARKETING_VERSION = 0.1.0-alpha.10`、`CURRENT_PROJECT_VERSION = 10`；唯一来源 `Configuration/AppIdentity.xcconfig`） |
| 身份与文本扫描 | `Scripts/check-identity.sh` | `PASSED (45 checks)`，含 `no hardcoded MARKETING_VERSION` |
| 密钥扫描 | `Scripts/scan-secrets.sh --self-test`、`Scripts/scan-secrets.sh` | `--self-test` PASS；工作区扫描 `suppressed 15 lines`、`PASS (no matches in tracked files; no untracked files)`（N=15 与 alpha.5 … alpha.9 记录一致，本版没有新增抑制标记） |
| 冒烟 | `Scripts/smoke.sh`（默认与 `--diagnostics`） | 两个模式 exit 0；标记 `smoke: ready` 与 `smoke: diagnostics ready`；诊断报告 `items=6` / `blockers=3` |
| 签名校验 | `codesign --verify --deep --strict <app>` | exit 0 |
| 签名详情 | `codesign -dv <app>` | `Identifier=io.github.su-luoya.pi-web-desktop`；`Format=app bundle with Mach-O thin (arm64)`；`flags=0x2(adhoc)`；`TeamIdentifier=not set`；`Sealed Resources version=2 rules=13 files=1` |
| Gatekeeper | `spctl -a -vv <app>` | `rejected`（退出 3，预期：ad-hoc 且未公证） |
| 包内容 | `unzip -l`、`ditto -x -k` + `plutil -p` | 9 个条目、无 `__MACOSX`；包内 `CFBundleShortVersionString=0.1.0-alpha.10`、`CFBundleVersion=10`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon`；解压出的 bundle 签名校验退出 0 |
| 打包 | `Scripts/package-release.sh --tag v0.1.0-alpha.10` | `OK`；白名单 8 个条目、mtime 固定为 `200101010000`、evidence 记录 `macOS 27.0` / arm64 |
| 打包器自检 | `Scripts/package-release.sh --self-test` | `PASS`（白名单表、拒绝路径、正例端到端） |

XCTest 用例（本机 shim，串行单文件运行）：本版新增的 `RecentWorkspaceTests` **5 passed / 0 failed**
（`testHistoryDeduplicatesMovesLatestToFrontAndCapsAtTen`、`testHistoryPersistsAcrossStoreInstancesAndClears`、
`testAppConfigurationUsesItsInjectedDefaultsForHistory`、
`testSwitchDecisionSkipsCurrentRejectsInvalidAndConfirmsUsableDirectory`、
`testSwitchDecisionNeverCreatesARequestedDirectory`）。完整的 `xcodebuild test` 由 PR #136 上的 CI 承担。

**没有做**：真机 GUI 手工验收（本机只有 Command Line Tools、没有 Xcode）；更新检查与自动更新的端到端真机演练。

## 已知问题

### 1. 本版仍然存在的问题

- **未公证、ad-hoc 签名**：Gatekeeper 默认阻止直接双击打开，需要用户针对这一个应用手动放行（见「未公证、ad-hoc 与 Gatekeeper」）。本版不引入 Developer ID，也不做公证。
- **更新验证的边界**：不确认代码签名、不确认官方来源、不做安装包内容比对（见「更新检查与自动更新的边界」）。验证只看版本证据与文件身份。
- **回滚能力不均**：只有带版本证据的安装来源才走降级路径；npm 全局更新与 Pi 扩展包更新没有自动回滚，失败时只保证不声称成功、不改状态。
- **远程访问默认不加密**：Pi Web 的密码认证不等于传输加密，远程访问应只经隧道或 VPN（见「支持边界」）。
- **真机 GUI 未手工验收**：本机只有 Command Line Tools、没有 Xcode，本版的门槛是脚本（构建 / 身份 / 冒烟 / 打包 / 签名）加上 shim 上的单文件 XCTest；完整的 `xcodebuild test` 由 CI 承担。**最近工作目录这个功能面本身（菜单、确认框、拖放、重启后的实际目录）没有任何真机点击验收**，这是本版最需要补充的人工验证（见第 3 小节）。
- **切换语义的四个评审遗留**（[#135](https://github.com/Su-luoya/pi-web-desktop/issues/135)）：
  - `F1` **重叠切换竞态**：`Sources/PiWebApp.swift:2358-2361` 在停止服务的完成回调里无条件写回它捕获的配置，`ServiceManager.updateConfiguration` 没有代次校验。停止过程中再次切换（A 还没停完就选 B）时，A 的迟到回调可能把配置写回 A，与界面显示不一致。
  - `F2` 服务是外部进程时，界面没有说明「新目录要等自行重启服务后才生效」。
  - `F3` `application(_:open:)` 未检查 `url.isFileURL`，`urls.count > 1` 时静默丢弃其余 URL。
  - `F4` 路径接受面未收紧：不展开 `~`（落成 `.missing` 提示）、未显式拒绝根目录 `/`、未 `resolvingSymlinksInPath`、没有超长路径与控制字符防护。都不构成安全边界（路径只进 UserDefaults、菜单标题与 `NSWorkspace.open`）。
- **一处既往文案观察（`O-1`，仍未改）**：`Sources/PiCLIUpdateAdapter.swift:1528` 与 `Sources/PiWebUpdateAdapter.swift:1883` 的持久警告以「旧版本语义保持不变：应用不会自动回滚已替换的文件，也不声称更新成功」开头。这里说的是**语义**（冒号后即定义），不是文件位置断言；早于 alpha.9 的 delta，本版同样没有改动。

### 2. alpha.9「已知问题」在本版的状态

| 编号 | alpha.9 / 评审的发现 | 本版状态 |
| --- | --- | --- |
| `L-1` / `L-3` / `L-4` / `L-5`（[#127](https://github.com/Su-luoya/pi-web-desktop/issues/127)） | alpha.8 delta 的四条发现 | alpha.9 已全部关闭，本版没有回退或改动这些路径 |
| `F5`（文档缺口） | `workspace.recentPaths` 未进用户可见文档 | 已修：`docs/privacy.md`、`docs/settings-and-workspace.md`、`docs/architecture.md`、`README.md` 同步（本版提交内） |
| `F1` / `F2` / `F3` / `F4` | 本功能的四条评审发现 | 未修，登记为 [#135](https://github.com/Su-luoya/pi-web-desktop/issues/135) |
| `O-1` | 两行持久警告的既往措辞 | 仍未改，见上一小节 |

alpha.9 说明中列出的其余边界（路径即信任边界、不校验签名、不做内容比对、未公证）在设计上没有变化，仍按「支持边界」与「更新检查与自动更新的边界」执行。

### 3. 需要在真机验证的行为

- 把文件夹拖到应用图标与窗口上，是否与菜单选择走同一条确认与重启路径（本机只有代码复核与用例）；
- 托管服务运行期间切换目录，确认框文案与实际重启是否一致，切换后服务的实际工作目录是否为新目录；
- 「清除历史记录」后重启应用，列表是否保持为空；
- 服务是外部进程时，界面是否明确表达了「新目录要自行重启服务后才生效」（这正是 `F2` 指向的缺口）；
- 连点两个不同的最近目录（`F1` 的竞态场景），最终配置与菜单勾选是否与服务的实际目录一致。

## 回退

1. 保留上一版的 ZIP 与它的 `.sha256`。回退时解压上一版（`v0.1.0-alpha.9`，资产仍在 Releases 中）
   并替换当前的 `Pi-Web-Desktop.app`，然后用 `codesign --verify --deep --strict` 复核（未公证的
   ad-hoc 产物仍会被 `spctl` 拒绝，这是预期结果）。
2. 删除应用包即可完成卸载：应用没有系统级常驻组件或 LaunchAgent，删除应用包不会残留其他系统文件
   （退出应用后 `rm -rf "$HOME/Applications/Pi-Web-Desktop.app"`，装在 `/Applications` 时替换路径）。
3. 清理用户目录数据、删除「已放弃」记录、以及组件版本回退的具体命令与边界，见
   [alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md) 的“回退”一节与
   [隐私说明](privacy.md#本地数据一览与删除)。本版**新增**了一条本地数据：UserDefaults 的
   `workspace.recentPaths`（最多 10 条用户自己选过的绝对路径）。删除方式：
   `defaults delete io.github.su-luoya.pi-web-desktop workspace.recentPaths`，或从菜单里选
   「清除历史记录」；它不属于服务配置，删除它不影响服务启动。
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
