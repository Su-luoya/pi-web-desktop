<!--
docs/release-notes-v0.1.0-alpha.3.md — v0.1.0-alpha.3 草稿 Release 的正文。

可以直接粘贴为 GitHub Release 说明（本注释在 GitHub 上不渲染）。发布前必须：
  * 把“校验值”一节的 `<发布后由协调者填写>` 换成草稿资产里实际的 SHA-256；
  * 核对资产名称、版本与 build 和草稿一致；
  * 不要在本文件或发布说明里声称“已签名”“已公证”，也不要指导关闭 Gatekeeper；
  * 不要写入主机名、用户名、凭据、代理端点或真实用户绝对路径。

相关文档：[发布流程](releasing.md)、[Alpha 发布门槛清单](alpha-release-checklist.md)、
[Release notes 模板](release-notes-template.md)、[alpha.1 安全与发布审查](security-review-alpha.1.md)、
[alpha.3 更新流水线安全审查（delta）](security-review-alpha.3.md)、
[v0.1.0-alpha.2 Release 说明](release-notes-v0.1.0-alpha.2.md)。

注意：当前 `.github/workflows/release.yml` 渲染的是 `docs/release-notes-template.md`，不会读本文件；
本文件是 v0.1.0-alpha.3 的现成正文，要把实测值、已知问题与回退说明放进草稿 Release 时，在草稿
编辑页粘贴本文件并把校验值换成草稿资产的实际 SHA-256（若要改成由 workflow 渲染版本化文件，
需要单独修改 `.github/workflows/release.yml`，超出本文件的改动范围）。
-->

# Pi Web Desktop 0.1.0-alpha.3（build 3）— Apple Silicon alpha（未公证）

## 摘要 / Summary

Pi Web Desktop `0.1.0-alpha.3` 是面向 **Apple Silicon（arm64）、macOS 14 或更高版本** 的第三个
alpha 预览。它启动、监控并显示本机已安装的 Pi Web 服务，默认只监听 loopback。相对
`0.1.0-alpha.2`，本版本把“只读版本检查”（#17/#18）扩展成**三条受限更新路径**：Pi Web 依赖的
**启动前受限自动安装**（#20，仅限来源为“已验证的 npm 全局安装”，默认关闭）、**Pi CLI 的受限
启动前自动更新与运行进程保护**（#21，有 Pi 进程在运行或状态不确定时一律推迟，**不向任何进程
发送信号**）与 **Pi 扩展包“询问后更新”**（#22，必须用户确认，**没有无人值守路径**）。三条更新路径
共用一套**阶段化更新事务、验证能力边界与有限降级**（#23）：失败时保留旧版本语义、
只把服务或版本重检测指回应用保留且仍可用的更新前 npm 全局可执行文件，其它情况一律写“无法
自动回滚”。**验证不包含代码签名确认**，也不比对安装包内容；桌面应用自身仍然不做应用内更新。

ZIP 里的应用是 **ad-hoc 签名、未公证** 的：没有 Developer ID 证书，也没有 Apple 公证，因此
Gatekeeper 默认会阻止直接双击打开，需要用户针对这一个应用手动放行。本版本没有 Intel 支持、
没有 SLA，**不承诺所有安装来源都能回滚**，远程访问的密码认证也**不等于传输加密**。

Pi Web Desktop `0.1.0-alpha.3` is the third alpha preview for **Apple Silicon (arm64) Macs running
macOS 14 or later**. It starts, monitors and displays a locally installed Pi Web service and listens
on loopback by default. Compared with `0.1.0-alpha.2` it turns the read-only version check (#17/#18)
into **three restricted update paths**: a **pre-launch install of Pi Web's npm dependency** (#20,
only for sources verified as global npm installs; off by default), a **pre-launch Pi CLI update with
running-process protection** (#21, deferred whenever a Pi process is running or the process state is
unknown; it never signals any process) and **Pi package updates only after an explicit user
confirmation** (#22 — there is no unattended path). All three share a phased **update transaction,
verification capability boundary and limited degradation** (#23): failures keep the previous version
and at most point the service / version re-detection back at a retained, still usable previous npm
global executable; anything else is reported as "cannot roll back automatically". **Verification
does not confirm code signatures** and does not compare package contents, and the desktop app itself
still has no in-app update.

The app in the ZIP is **ad-hoc signed and not notarized**: there is no Developer ID certificate and
no Apple notarization, so Gatekeeper blocks a plain double-click and the user has to approve this
app explicitly. This release has no Intel support, no SLA, **no promise that every install source can
be rolled back**, and for remote access the password authentication is **not transport encryption**.

## 发布信息

| 项目 | 值 |
| --- | --- |
| 版本（tag） | `v0.1.0-alpha.3` |
| `CFBundleShortVersionString` | `0.1.0-alpha.3` |
| `CFBundleVersion` | `3` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 应用包 | `Pi-Web-Desktop.app` |
| 架构 | arm64（Apple Silicon）；**不支持 Intel（x86_64）** |
| 最低系统 | macOS 14.0 |
| 签名 | ad-hoc（`codesign --sign -`），没有证书，`TeamIdentifier=not set` |
| 公证 | 无。Gatekeeper 默认拒绝，需要用户手动放行这一个应用 |
| 发布类型 | GitHub **prerelease**（alpha 预览） |
| 上一版 | `v0.1.0-alpha.2`（build `2`），资产仍在 Releases 中可下载 |
| 本地数据位置 | UserDefaults、`~/Library/Application Support/Pi Web Desktop/`、`~/Library/Logs/Pi Web Desktop/`、Keychain、WebKit 网站数据，见[隐私说明](privacy.md) |

版本与 build 的唯一来源是 `Configuration/AppIdentity.xcconfig`；本文件只是引用，不是来源。

## 目标平台

| 维度 | 支持范围 |
| --- | --- |
| CPU | Apple Silicon（arm64） |
| 系统 | macOS 14.0 或更高 |
| Intel Mac | 不支持，也没有 x86_64 产物 |
| 依赖 | Node.js `>=22.19.0`、Pi CLI、`@agegr/pi-web`（需用户自行安装，应用不打包也不自动安装） |
| 默认服务地址 | `http://127.0.0.1:30141/`（只监听 loopback） |

## alpha.3 相对 alpha.2 的新增与变更

四个功能 Issue 都已合入分支（PR #53、#54、#57、#58），本版本是它们的第一个对外构建；
`v0.1.0-alpha.2` 已经带有的 #16–#18（组件识别、只读版本检查、逐类策略与忽略版本）见下一节。

### 1. Pi Web 启动前受限自动更新（#20）

- **设置**：`updateChecks.piWeb.autoUpdateBeforeLaunch`，**默认关闭**。设置位在 alpha.2 只是
  预留（“尚未生效”），本版本起生效（`UpdateCheckPreferences.autoUpdateBeforeLaunchIsEffective =
  true`），但设置位只是前提。
- **四条前置条件同时成立才会安装**：设置打开；#16 的 Pi Web 识别结果是
  `source == npmGlobal` 且可信度 `verified`；#17/#18 的检查结论是“可更新”、目标版本
  `verified` 且比本机版本更高；当前没有以本应用名义运行的 Pi Web 服务（服务在运行时的更新
  只安排到下次启动，不在运行中安装）。任一不满足都只展示命令文本或按来源文档提示，**不安装**。
- **命令形态固定**：参数数组 `["install", "-g", "<静态清单包名>@<目标版本>"]`，包名必须等于
  静态清单里的 Pi Web 包名（检测结果里的包名只用于交叉验证，不会直接拼进命令），版本必须是
  可解析的语义化版本。命令经 `Process` + `arguments` 直接执行：**不使用 shell 字符串、不调用
  `sudo`**，参数逐项通过安全字符集与禁用 token（`sudo` / `sh` / `bash` / `zsh` / `eval` / `exec`
  / `env` / `-c`）校验。
- **环境白名单**：子进程只保留 `PATH` / `HOME` / `TMPDIR` / `LANG` / `LC_ALL` / `LC_CTYPE`，
  并把 npm 所在目录前置到 `PATH`；`PI_WEB_PASSWORD` 等凭据变量、`NODE_OPTIONS`、`npm_config_*`
  与代理变量都不会传递。日志与诊断只记录环境变量**键名**，不记录值。
- **有界执行**：默认超时 5 分钟，超时按失败处理；超时先向**本次自己启动的那个子进程**发
  `SIGTERM`，宽限期（2 秒）后仍未退出才发 `SIGKILL`。这不会波及任何 Pi / pi-web 进程。
- **安装后验证**：重新用 #16 的识别器检测版本，再走既有健康检查路径（0.5 秒间隔、最多 25 次）。
  版本没变、检测不到版本或健康检查失败都算失败，只保留旧版本语义、写一条持久警告并进入诊断
  状态；**不自动回滚、不卸载、不重装，也不声称更新成功**。同一次运行内不会自动重试。
- **手动入口**：菜单“立即更新 Pi Web…”同样只在上述来源条件下可用，确认框会展示可执行文件
  路径（Home 段显示为 `~`）、参数数组、当前/目标版本与来源，确认后先走所有权校验过的停止
  路径停掉本应用托管的服务，再执行同一条安装与验证路径；外部服务不会被停止。

### 2. Pi CLI 更新与运行进程保护（#21）

- **设置**：`updateChecks.pi.autoUpdateBeforeLaunch`，**默认关闭**。打开后还要同时满足：Pi CLI
  来源是 `npmGlobal` 或 `pnpmGlobal` 且可信度 `verified`；目标版本 `verified` 且更高；**当次进程
  检查结论是“没有任何 Pi 进程”**（`noProcesses`）。
- **进程保护（只读）**：应用只读地枚举本机进程（`proc_listpids` / `proc_pidinfo` / `proc_pidpath`，
  JS 运行时进程另外用 `sysctl KERN_PROCARGS2` 读 argv），判定只有三种结果：`noProcesses` /
  `runningProcesses` / `unknown`。可执行名是**精确匹配**（`pi-web`、`pip`、`pi-helper` 都不命中）；
  Pi CLI 以 `#!/usr/bin/env node` 脚本形式运行时，只有“进程标题恰好是 `pi`”或“绝对路径文件名
  恰好是 `pi` 且通过可执行位探针”才算命中，数据参数里的 `pi` 不会误报。**只要有 Pi 进程在运行，
  或者枚举/读取失败因而无法确定，就不自动更新**：推迟到下一次检查或下次启动，原因只写日志与
  状态页，不弹框。执行前会再复查一次进程状态。
- **不发送信号**：`PiCLIUpdateRunning` 接口里没有任何发信号、终止或修改进程的方法；超时（默认
  10 分钟）或应用退出只是“放弃等待”，子进程按自己的方式结束。应用不会结束、暂停或接管任何
  Pi 会话，也不修改 Pi 的任何配置文件。
- **命令与环境**：参数数组恒为 `["update", "--self"]`（不使用 shell、不调用 `sudo`、不拼 npm/pnpm
  命令），可执行文件路径必须通过安全字符集校验；子进程环境同样是上面那组白名单键，并把 `pi`
  所在目录前置到 `PATH`。
- **结果语义**：执行后用 #16 的识别器重新检测版本，只有达到目标版本才算成功；非零退出、超时、
  启动失败、版本没变或无法解析都算失败，写一条持久警告（菜单“Pi CLI 更新告警…”，只存类别、
  旧/新/目标版本、固定原因文案与时间戳）。每个运行期最多自动尝试一次，不重试、不声称回滚。
- **手动入口**：菜单“立即更新 Pi CLI…”**不做进程门控**（这是有意的：用户可能就是想在有会话
  运行时更新），但必须在确认框里看到可执行文件、参数数组、当前/目标版本、每个运行中 Pi 进程的
  PID/父进程/启动时间/判定依据/脱敏命令摘要，以及“不会结束或暂停任何 Pi 会话”的风险说明后显式
  确认；确认框里取消是默认按钮。

### 3. Pi 扩展包「询问后更新」（#22）

- **三种策略**：`off`（不检查、不通知、不执行）、`check-and-notify`（默认，只提示可用版本与官方
  命令文本）、`ask-before-update`（同样按 7 天节奏复查，发现更新时弹确认框）。设置里**没有**
  “自动更新”取值，`PiPackageUpdatePlan.isAutomaticallyExecutable` 与
  `allowsUnattendedExecution` **恒为 false**：不存在无人值守的扩展包更新路径，两个启动前自动
  更新开关也不影响扩展包。
- **执行入口的三个必要条件**：来源必须是 `npmGlobal` 且 `verified`；目标版本 `verified` 且高于
  本机版本；当次进程检查必须是 `noProcesses`。其它来源（pnpm、Homebrew、nvm/mise、git checkout、
  本地路径、未知）只展示官方命令文本 `pi update --extensions`（由 Pi 自己决定实际更新哪些包），
  不提供执行按钮。
- **命令形态固定**：参数数组恒为 `["update", "npm:<包名>"]`（Pi 官方 `pi update <source>` 的 npm
  来源形式），可执行文件基名必须是 `pi`，参数数组形状逐项校验；不使用 shell、不调用 `sudo`、
  不自行拼接 `npm install` / `pnpm add` / `brew upgrade`。
- **确认与执行**：确认框展示包名、当前/目标版本、来源与可信度、脱敏后的可执行文件路径、参数
  数组、完整命令、风险说明与每个运行中 Pi 进程的脱敏摘要；**取消是默认按钮**，取消或关闭对话框
  都按 `userCancelled` 记录，不执行也不改状态。执行前**再检查一次**进程状态，出现运行中的 Pi
  进程或状态不确定就拒绝执行并停止剩余计划；批次按顺序执行，一次确认只尝试一次。
- **失败语义**：非零退出、超时、放弃等待、启动失败、版本没变化或无法解析都算失败，写一条持久
  告警（`updateChecks.piPackages.lastUpdateWarning.*`，只存类别、包名、旧/新/目标版本、固定原因
  文案与时间戳），不重试、不声称回滚。所有拒绝原因都是固定集合，写入日志与诊断。

### 4. 更新事务、验证能力边界与有限回滚（#23）

- **阶段化事务**：#20 / #21 / #22 三条路径共用同一套阶段记录：准备（preflight）→ 执行（install）
  → 验证（verify）→ 启用/提交（commit）→ 失败降级（degrade）。每个阶段只有四种结果（成功 /
  失败 / 跳过 / 未执行）并带固定原因文案与时间；降级是失败后的恢复动作，不计入“完成阶段”。
- **五层验证与三态**：可执行文件存在且带可执行位、解析后的真实路径可读、版本能被 #16 识别器
  重新检测并达到目标（手动路径要求相对更新前发生变化）、`package.json` 的 `name` 与期望包名一致、
  服务启动后的健康检查。每条检查只有“通过 / 失败 / 未验证”；没有注入文件系统探针、缺少路径或
  缺少包名证据时记为“未验证”，**不会伪装成通过**。
- **明确不做的验证**（`UpdateVerificationCheck.notVerifiedCapabilities`）：不做代码签名验证，不
  声称能验证官方签名或发布来源，不做安装包内容哈希或上游文件比对，不验证新版本的运行时行为
  （健康检查只覆盖既有探测路径）。
- **更新前指纹**：只记录可执行文件路径、解析后真实路径、版本、`package.json` 名称与可选（不保证
  存在）的文件大小与 mtime；不读凭据、不做签名验证。扩展包没有独立可执行文件，指纹只含包名与
  版本，因此证据不足时降级判定会如实给出“无法自动回滚”。
- **有限降级**：install 失败 → 系统状态未改变，保留旧版本、不报告成功、不尝试回滚；verify 失败
  → 四种结论之一：`installFailedKeepingPreviousVersion`（安装失败，仍在使用旧版本）、
  `stillUsingPreviousArtifact`（版本未变，文件仍是旧的）、`degradedToPreviousArtifact`（已把
  服务/版本重检测指回更新前仍然可用的可执行文件）、`cannotAutomaticallyRollback`（无法自动回滚：
  写持久警告并给出来自静态清单的手动命令或指引）。**自动降级的边界只有一条**：来源是已验证的
  npm 全局安装、应用自己保留了更新前的路径与版本证据、该证据在安装后仍然存在、仍带可执行位、
  大小与 mtime 与指纹一致。pnpm / Homebrew / nvm / mise / git checkout / 本地路径 / 未知来源一律
  不回滚。整个框架**不移动、不复制、不删除任何文件**，也不向任何进程发送信号；commit 成功后
  不做自动卸载。
- **统一更新历史**：用户可见的更新历史存在 UserDefaults 单键 `updateChecks.updateHistory`（JSON，
  最多 20 条，最新在前），每条含时间、组件、来源、从/到版本、各阶段结果、失败原因与降级结论；
  读取时逐条校验并截断（非法版本号、非法包名、未知枚举丢弃），不含绝对路径、环境变量值、凭据或
  子进程输出。诊断页展示最近一次更新的完成阶段、阶段结果与建议动作（手动命令文本只展示，应用
  绝不执行）。

### 5. #16–#18 的现状（alpha.2 引入，本版未改变这些行为）

为便于对照，这里列出 alpha.2 已经发布、本版继续保留的能力；**它们不是本版新增**：

- **组件版本与安装来源识别（#16）**：诊断界面与导出给出可执行文件路径、真实路径、安装来源
  （npm/pnpm 全局、Homebrew、nvm、mise、官方安装器、Git 检出、本地路径、未知）与可信度
  （已验证 / 推断 / 未知）；探测只读，不安装、不升级、不联网、不调用 `sudo`。
- **只读版本更新检查（#17）**：只发 `GET` + JSON 解析，不下载、不安装；四类组件默认每日检查
  （扩展包每 7 天），应用退出后不检查，也不安装常驻组件。
- **逐类策略、忽略版本与设置（#18）**：桌面应用 / Pi CLI / Pi Web 可选关闭 / 每日 / 每周，
  扩展包可选关闭 / 检查并通知 / 询问后更新；“忽略此版本”只抑制那一个具体版本。alpha.2 里
  “启动前自动更新”的两个设置位只保存值、不产生行为，**本版起由 #20 / #21 让它生效**。

### 6. 文档与仓库同步

- README 已重写为面向非开发者的安装与使用指南（#55 / PR #56），本版把其中“已知限制”“更新与
  隐私”里与 #22 / #23 有关的表述改成与实现一致（扩展包有“询问后更新”但仍无无人值守更新；
  回滚能力有限的准确表述；更新验证不做代码签名确认）。
- 仓库内新增本版说明与一份针对更新流水线的独立安全审查（delta）：
  [alpha.3 更新流水线安全审查](security-review-alpha.3.md)。
- 与更新流水线有关的架构、设置与发布文档（`docs/architecture.md`、
  `docs/settings-and-workspace.md`、`docs/releasing.md`、`docs/privacy.md`、
  `docs/development.md`）已随功能提交同步到与实现一致的表述。

## 更新检查访问的域名、频率与关闭方式

只读版本检查**不是遥测**：请求只用于比较“本机版本”与“上游最新版”，不携带使用数据、会话内容、
认证信息或诊断报告。

| 检查对象 | 域名与请求 | 请求内容 |
| --- | --- | --- |
| 桌面应用（本应用） | `api.github.com`：`GET /repos/Su-luoya/pi-web-desktop/releases?per_page=20` | 只解析最新 release 的版本 |
| Pi CLI、Pi Web、Pi 扩展包 | `registry.npmjs.org`：`GET /<包名>/latest` | 只解析 `version` 字段 |

- 只有 `GET` + JSON 解析；`User-Agent` 固定为应用名 + 版本 + bundle identifier（来自应用自身的
  Info.plist，不含用户名或主机名）。不发送 cookies、账号凭据、会话内容或诊断字段；应用侧客户端
  不跟随重定向，因此请求不会落到这两个域名之外。
- **关闭方式**：菜单“服务 → 更新检查设置”里的四类快捷开关（打开 = 默认策略，关闭 = 关闭），或
  “服务 → 更新检查设置 → 更新检查偏好设置…”里逐类改成“关闭 / 每日 / 每周”。四类全部关闭时应用
  不发任何请求，也不安排复查，两个启动前自动更新开关也不会执行任何安装（它们仍需要一份“可更新”
  的检查结果）。
- 结果缓存在 `~/Library/Application Support/Pi Web Desktop/update-check-cache.json`，只含版本号、
  时间戳与 etag 等条件请求字段；忽略版本、更新开关、失败警告与更新历史在 UserDefaults
  （`updateChecks.*`）。
- 上游服务会看到请求的源 IP、`User-Agent` 与请求时间，按各自隐私政策处理接入日志。完整说明见
  [隐私说明](privacy.md) 的“版本检查、提示与忽略版本”。

## 自动更新的准确边界

**会做的**（两个开关默认关闭，且都要求组件来源可信）：

| 路径 | 触发方式 | 命令（参数数组） | 前置条件 | 超时行为 |
| --- | --- | --- | --- | --- |
| Pi Web（#20） | 应用启动时，设置打开 | `npm install -g @agegr/pi-web@<目标版本>` | 来源 `npmGlobal` + `verified`；目标 `verified` 且更高；托管服务未运行 | 5 分钟；先 `SIGTERM` 自己的子进程，宽限期后 `SIGKILL` |
| Pi CLI（#21） | 拿到当次检查结果后，设置打开 | `pi update --self` | 来源 `npmGlobal`/`pnpmGlobal` + `verified`；目标 `verified` 且更高；当次检查为 `noProcesses` | 10 分钟；**只放弃等待，不发送任何信号** |
| Pi 扩展包（#22） | 用户在确认框里显式确认 | `pi update npm:<包名>` | 来源 `npmGlobal` + `verified`；目标 `verified` 且更高；当次检查为 `noProcesses`；用户确认 | 10 分钟；**只放弃等待，不发送任何信号** |

**不会做的**：

- 不会下载或安装桌面应用自身（`Pi Web Desktop.app`）的新版本。
- 不会在来源不可信（Homebrew、nvm/mise、git checkout、本地路径、未知，或可信度不是“已验证”）时
  自动安装；这些来源只显示命令文本或按来源文档提示。
- 不会在无人值守时更新 Pi 扩展包：不点确认就不会执行（取消或直接关闭对话框都不执行）。
- 不会结束、暂停、接管任何 Pi 会话，也不会向任何 Pi 进程发送信号（#21 / #22 的接口里没有这类
  方法；#20 的终止只针对它自己启动的那个 npm 子进程）。
- 不会保证更新成功、不保证所有来源都能回滚，也不会在失败后卸载新版本或恢复旧文件内容。

## 本机实测环境与版本（可追溯）

下表来自维护者一台 Apple Silicon 真机的实测输出，**不是 CI runner**；每一行的值都能用第三列的
命令复现。CI runner 的版本不会写进本说明。

| 项目 | 实测值 | 实测命令（本机输出摘要） |
| --- | --- | --- |
| 机器与芯片 | Apple M4（Mac mini，`Mac16,10`） | `sysctl -n machdep.cpu.brand_string` → `Apple M4`；`system_profiler SPHardwareDataType` → `Chip: Apple M4` |
| macOS | 27.0（BuildVersion `26A428`），满足 `>= 14` | `sw_vers` |
| 架构 | arm64 | `uname -m` → `arm64` |
| Node.js | v24.21.0 | `node --version` → `v24.21.0` |
| npm | 11.19.0 | `npm --version` → `11.19.0` |
| Pi CLI（`@earendil-works/pi-coding-agent`） | 0.85.1 | `pi --version` → `0.85.1`；`npm ls -g --depth=0` → `@earendil-works/pi-coding-agent@0.85.1` |
| `@agegr/pi-web` | 0.9.1 | `npm ls -g @agegr/pi-web` → `@agegr/pi-web@0.9.1` |
| Swift 编译器 | Apple Swift 6.4（`swiftlang-6.4.0.34.1 clang-2100.3.34.1`） | `swift --version` |
| 应用包身份 | `CFBundleShortVersionString=0.1.0-alpha.3`、`CFBundleVersion=3`、`LSMinimumSystemVersion=14.0` | `./Scripts/check-identity.sh` → `check-identity: PASSED (45 checks)` |

`pi-web` 当前（0.9.1）没有 `--version` 选项，核对版本请用 `npm ls -g @agegr/pi-web` 或读取该包
`package.json` 的 `version`；诊断逻辑会先尝试 `--version`，失败后回落到 `package.json`，并在
诊断界面标出安装来源与可信度。

## 安装

1. 从本 Release 的 assets 下载 `Pi-Web-Desktop-0.1.0-alpha.3.zip` 与它的 `.sha256`、证据 Markdown。
2. 校验下载的 ZIP（在下载目录执行；文件名以 assets 实际名称为准）：

   ```bash
   shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.3.zip.sha256
   ```

   输出必须包含 `Pi-Web-Desktop-0.1.0-alpha.3.zip: OK`；不一致就不要安装。
3. 解压：

   ```bash
   ditto -x -k Pi-Web-Desktop-0.1.0-alpha.3.zip .
   ```

4. 把 `Pi-Web-Desktop.app` 移到 `~/Applications` 或 `/Applications`。
5. 首次打开：在 Finder 中按住 Control 点按（或右键）应用 → “打开” → 再确认一次“打开”。
   如果系统不再提供这个选项，请打开“系统设置 → 隐私与安全性”，找到刚被拦截的条目并选择
   “仍要打开”。**不要关闭 Gatekeeper**，也不要执行全局关闭的指令。
6. 安装依赖（应用不打包也不自动安装它们）：

   ```bash
   npm install -g --ignore-scripts @earendil-works/pi-coding-agent
   npm install -g @agegr/pi-web
   ```

   需要 Apple Silicon Mac、macOS 14+、Node.js `>=22.19.0`。应用不会调用 `sudo`，也不会读取或
   迁移 Pi 的认证内容。

## 依赖前置与首次启动诊断

- 应用**不打包** Node.js、Pi CLI 和 `@agegr/pi-web`；这三项必须在 `PATH`（或用诊断窗口里的
  “选择 pi-web 路径…”指定）上可执行，且 Node.js 版本不低于 `22.19.0`。
- 启动时 `DependencyChecker` 会检查 Apple Silicon / macOS 14+、Node.js 版本、Pi CLI、
  pi-web（可执行文件、版本、真实路径与符号链接目标、`package.json` 名称）、默认端口
  （只做本机 `bind(2)`，不连网）和 Pi 配置目录 `~/.pi/agent`（只判断存在/可读，不读取内容）；
  六项诊断条目还会给出安装来源与可信度。
- 硬性前置（Node.js / Pi CLI / pi-web）缺失、报告缺项或版本无法解析时，应用停在依赖诊断页：
  列出要处理的项与下一步，启动/停止/重启按钮全部禁用。缺项、`unknown` 与“缺失”一样不放行。
- 前置满足但首次设置未完成时，同样先显示诊断页；点“开始使用 Pi Web”或“重新检测”后进入主窗口。
  启动前自动更新（#20）在这条启动路径上先判定：需要时先完成一次覆盖 Pi Web 的版本检查，
  再决定安装还是照常启动服务；检查失败只会跳过自动更新，不影响服务启动。
- 诊断窗口可随时从菜单“服务 → 依赖与环境诊断…”打开；“复制安装命令”只复制静态命令，
  应用不会执行安装命令、不调用 `sudo`、不联网、不读取凭据。
- 手工排查的只读命令：

  ```bash
  node --version
  npm prefix -g
  pi --version
  npm ls -g @agegr/pi-web
  pi-web --help
  ```

## 未公证、ad-hoc 与 Gatekeeper

- ZIP 内应用只有 ad-hoc 签名：能证明 bundle 打包后未被改动（`codesign --verify --deep --strict`
  通过、`satisfies its Designated Requirement`），但**不包含开发者身份**，Apple 也没有对它做过公证。
- `codesign -dv --verbose=4` 显示 `Signature=adhoc` 与 `TeamIdentifier=not set`；`spctl -a -vv`
  以非 0 退出码（本机为 3）输出 `rejected`，这是未公证 ad-hoc 产物的预期结果。
- 未公证的后果：无法验证发布者身份，也无法使用依赖 Developer ID 的能力。这一点同样适用于更新
  验证：#23 的验证**不确认代码签名**，只检查可执行文件、真实路径、版本号、`package.json` 名称与
  健康检查。
- 放行是“针对这一个应用”的决定，系统会把它记录在“隐私与安全性”里；重新下载（quarantine 属性
  存在时）可能需要再次确认。
- 安装说明在这里给出的 Gatekeeper 处理只有两条：右键/Control 点按后选择“打开”，或在
  “系统设置 → 隐私与安全性”中针对被拦截的应用选择“仍要打开”。本项目不会建议关闭 Gatekeeper。
- 本项目不会把 ad-hoc 签名或“本机校验通过”描述成“已签名”或“已公证”。

## 校验值

- 资产：`Pi-Web-Desktop-0.1.0-alpha.3.zip`（以及 `Pi-Web-Desktop-0.1.0-alpha.3.zip.sha256`、
  签名与公证证据 Markdown，名称以 Release assets 为准）
- SHA-256：`<发布后由协调者填写>`（草稿发布前从资产或 workflow 摘要复制；同一个值也会记录在
  Release Issue 中。**不要**使用任何在别处看到的哈希，包括本机演练产物——本机演练的 SHA-256
  每次都不同。）
- 校验命令（下载目录执行）：`shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.3.zip.sha256`
- 校验失败时不要安装，请在 Release Issue 或普通 Issue 中报告。

另外，`package-release.sh` 生成的 evidence Markdown 会记录 `codesign`/`spctl` 原始输出、ZIP 名称、
SHA-256、构建提交与打包环境；它明确标注打包环境不等于真机实测环境。

## 构建与签名验证记录（本机演练）

下表是本机演练的实际命令与结果（`spctl` 的退出码 3 是预期结果）。完整记录见
[Alpha 发布门槛清单](alpha-release-checklist.md) 的“本次发布执行记录（v0.1.0-alpha.3）”一节。

| 命令 | 结果 |
| --- | --- |
| `sh -n Scripts/*.sh` | 退出 0 |
| `git diff --check` | 退出 0（无空白错误） |
| `./Scripts/build.sh` | 退出 0；`Mach-O 64-bit executable arm64` |
| `./Scripts/check-identity.sh` | 退出 0；`check-identity: PASSED (45 checks)` |
| `codesign --verify --deep --strict build/Pi-Web-Desktop.app` | 退出 0；`valid on disk` / `satisfies its Designated Requirement` |
| `codesign -dv --verbose=4 build/Pi-Web-Desktop.app` | `Signature=adhoc`、`TeamIdentifier=not set`、`Format=app bundle with Mach-O thin (arm64)` |
| `spctl -a -vv build/Pi-Web-Desktop.app` | 输出 `rejected`，退出 3（未公证的预期结果；本机 `spctl` 不打印拒绝原因） |
| `./Scripts/smoke.sh`（启动模式） | 退出 0；标记 `smoke: ready` |
| `./Scripts/smoke.sh`（诊断模式） | 退出 0；标记 `smoke: diagnostics items=6 blockers=3` 与 `smoke: diagnostics ready` |
| `./Scripts/scan-secrets.sh --self-test` | 退出 0；`self-test: PASS` |
| `./Scripts/scan-secrets.sh` | 退出 0；`scan-secrets: suppressed 11 lines`、`scan-secrets: PASS` |
| `sh Scripts/check-release-version.sh v0.1.0-alpha.3` | 退出 0；tag 与 `MARKETING_VERSION` 一致、预发布计数 `3` 与 `CURRENT_PROJECT_VERSION` 一致 |
| `./Scripts/package-release.sh --tag v0.1.0-alpha.3` | 退出 0；产出 ZIP、`.sha256`、evidence 与 `release-metadata.env`，版本为 `0.1.0-alpha.3` / build `3` |

`./Scripts/smoke.sh` 只验证窗口、诊断页与退出路径：两种模式都在临时 support 目录里运行，不写真实
UserDefaults / Application Support / Logs，也不启动真实 pi-web；它不替代 `xcodebuild test`。本机
`xcode-select -p` 指向 Command Line Tools，因此没有在本机运行 `xcodebuild build` / `xcodebuild test`
（由 CI 的 `macos-14` job 覆盖，见门槛清单）。

## 已知问题

更新流水线（#16–#23）的独立安全审查见 [alpha.3 更新流水线安全审查](security-review-alpha.3.md)：
**阻断项 0 项**，下列为按现状接受的非阻断项。alpha.1 审查（服务、Keychain、脱敏、网络、发布、
依赖）的非阻断项（R-4、R-5、R-6、R-8、R-10）继续有效；本次 delta 审查新增的残留风险编号为
A-1 … A-10，其中与本版行为直接相关的几条摘录如下（完整证据与缓解措施见审查报告）：

- **A-1（低）**：更新检查缓存文件与 UserDefaults 可被同用户进程改写；缓存回退路径可以把
  `updateAvailable` + `verified` 带进自动更新判定，从而让应用安装**同一个官方包**的某个具体
  版本。缓解：包名必须等于静态清单包名、目标版本必须可解析且高于本机版本、两个开关默认关闭、
  安装后重新验证并做健康检查。缓存没有完整性校验（签名/HMAC），这是同一用户威胁模型下的残余风险。
- **A-2（低—中）**：Pi Web 自动安装的 argv 固定为 `["install", "-g", "<包名>@<版本>"]`，不包含
  `--ignore-scripts`；npm 默认会在安装时执行该包的生命周期脚本，子进程继承了 `HOME`，因此使用
  用户自己的 npm 配置（registry / proxy / token）。应用不做包内容或签名校验。缓解：只使用参数
  数组、无 shell/sudo、环境白名单、来源与版本前置条件。
- **A-5（低）**：进程保护会读取本机可读进程的 argv（`KERN_PROCARGS2`，其它用户进程通常读不到），
  只对判定为 Pi 的进程生成最长 200 字符、经 `LogRedactor` 与 token 级遮罩处理的摘要，且不落盘；
  遮罩基于固定键名片段，非键值形状的秘密可能不被替换。
- **A-6（低）**：Pi Web 安装器的超时终止只针对它自己启动的子进程（不覆盖 npm 自己派生的子进程），
  超时后 npm 的子进程可能短暂继续运行。
- **A-7（低）**：Pi CLI 与扩展包的超时/放弃等待**不发送信号**，被放弃的命令可能继续在后台运行，
  并可能与后续尝试重叠（应用无法观测它）。
- **未公证**：首次打开必须手动放行，见上文“未公证、ad-hoc 与 Gatekeeper”。
- **更新验证有边界**：不确认代码签名、不确认公证、不做安装包内容比对；`package.json` 名称检查
  只防“换成了别的包名”，不等于发布者身份验证。
- **回滚能力有限**：只有“已验证的 npm 全局安装 + 应用保留的更新前证据仍在原位且指纹一致”这一种
  情况会做自动降级（把服务/重检测指回旧可执行文件）；其它来源与证据缺失/被覆盖的情况一律写
  “无法自动回滚”，只给手动命令。应用**不恢复文件内容、不卸载新版本**。
- **依赖需要自行安装**：缺失时应用只显示诊断信息，不会自动安装（除非用户打开 Pi Web 或 Pi CLI
  的启动前自动更新开关，且来源条件满足）。
- **无 Intel 支持**：只支持 Apple Silicon（arm64），Intel Mac 不在支持范围。
- **无 SLA**：alpha 预览按“现状”提供，不承诺响应时间或修复时限。
- **远程访问**：默认只监听 `127.0.0.1`；远程访问必须自备加密隧道或 HTTPS 反向代理。**密码认证
  只验证访问者，不等于传输加密**，也没有暴力破解防护（上游 pi-web 范围，审查 R-4）。
- **日志轮转只保留 5 份**（每份上限 10 MB），超过上限的旧日志会被删除（见
  [日志与诊断导出](logging-and-diagnostics.md)）。

## 回退

1. 保留上一版的 ZIP 与它的 `.sha256`。回退时解压上一版（`v0.1.0-alpha.2`，资产仍在 Releases 中）
   并替换当前的 `Pi-Web-Desktop.app`，然后用 `codesign --verify --deep --strict` 复核（未公证的
   ad-hoc 产物仍会被 `spctl` 拒绝，这是预期结果）。
2. 卸载 / 回退应用包：应用没有系统级常驻组件或 LaunchAgent，删除应用包不会残留其他系统文件。
   退出应用后：

   ```bash
   rm -rf "$HOME/Applications/Pi-Web-Desktop.app"
   ```

   安装在 `/Applications` 时把路径换成 `/Applications/Pi-Web-Desktop.app`。
3. 需要清理用户目录中的残留数据时才执行（会丢失服务配置、日志、更新检查设置、更新历史与网站
   数据；删除 Keychain 条目会自动关闭远程模式并让监听地址回到 `127.0.0.1`）：

   ```bash
   defaults delete io.github.su-luoya.pi-web-desktop        # 服务配置、首次设置状态、窗口位置、更新检查设置、忽略版本、更新告警与更新历史
   rm -rf "$HOME/Library/Application Support/Pi Web Desktop" # 运行状态、所有权记录与更新检查缓存
   rm -rf "$HOME/Library/Logs/Pi Web Desktop"                # 日志与轮转文件
   rm -rf "$HOME/Library/WebKit/io.github.su-luoya.pi-web-desktop" \
          "$HOME/Library/Caches/io.github.su-luoya.pi-web-desktop"  # WebKit 网站数据
   security delete-generic-password -s io.github.su-luoya.pi-web-desktop -a remote-access-password
   ```

   以上路径与删除方式以[隐私说明](privacy.md#本地数据一览与删除)为准；删除这些不会影响 Pi Web、
   Pi CLI 或 Node.js 自身的数据。
4. 组件版本回退：应用最多把服务/版本重检测指回它保留的旧 npm 全局可执行文件，不承诺恢复第三方
   包的旧版本，也不提供通用自动回滚。需要固定某个 Pi CLI / Pi Web / 扩展包版本时，请用对应包
   管理器手动安装，并在升级前记录当前版本。
5. 已经发布的版本不会静默替换 ZIP 或 checksum；新版本有问题时发布新的 alpha（例如
   `v0.1.0-alpha.4`）并在 Release 说明中给出回退路径。

## 支持边界

- 只支持 Apple Silicon（arm64）与 macOS 14 或更高版本；没有 Intel 产物。
- 没有 SLA，桌面应用没有自动更新安装，没有 Developer ID 签名、Apple 公证或 Apple 支持渠道。
- 默认只监听 loopback；远程访问必须自备加密传输，并且**密码认证不等于传输加密**。
- 更新路径的硬边界：两条自动更新默认关闭且只对来源可信的 npm/pnpm 全局安装生效；扩展包更新
  必须由用户确认；验证不做代码签名确认；不承诺所有来源都能回滚。
- 更新检查只访问 `api.github.com` 与 `registry.npmjs.org`，只读、可逐类关闭；除此之外应用不主动
  向任何上游发送数据（自动更新触发的网络请求由用户自己的 `npm` / `pi` 按其配置发出）。
- 不要在公开 Issue、PR 或 Release 评论里粘贴密码、token、私有主机名、代理凭据或未脱敏日志。

## 反馈与安全报告

- 普通问题与功能建议：使用本仓库的
  [Issue 表单](https://github.com/Su-luoya/pi-web-desktop/issues/new/choose)；请附版本、安装与依赖
  信息（脱敏后的诊断导出），以及可复现步骤。上游 Pi Web、Pi CLI 或 Pi packages 的问题请先到对应
  上游仓库确认。
- 安全漏洞：**不要**开公开 Issue、不要粘贴到 PR 或 Release 评论。请使用
  [私密漏洞报告](https://github.com/Su-luoya/pi-web-desktop/security/advisories/new)，
  范围、处理流程与“不承诺 SLA”的说明见 [SECURITY.md](../SECURITY.md)。
