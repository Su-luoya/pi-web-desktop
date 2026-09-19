<!--
docs/release-notes-v0.1.0-alpha.4.md — v0.1.0-alpha.4 草稿 Release 的正文。

可以直接粘贴为 GitHub Release 说明（本注释在 GitHub 上不渲染）。发布前必须：
  * 把“校验值”一节的 `<发布后由协调者填写>` 换成草稿资产里实际的 SHA-256；
  * 核对资产名称、版本与 build 和草稿一致；
  * 不要在本文件或发布说明里声称“已签名”“已公证”，也不要指导关闭 Gatekeeper；
  * 不要写入主机名、用户名、凭据、代理端点或真实用户绝对路径。

相关文档：[发布流程](releasing.md)、[Alpha 发布门槛清单](alpha-release-checklist.md)、
[Release notes 模板](release-notes-template.md)、[alpha.1 安全与发布审查](security-review-alpha.1.md)、
[alpha.3 更新流水线安全审查](security-review-alpha.3.md)、
[alpha.4 更新流水线安全审查（delta）](security-review-alpha.4.md)、
[v0.1.0-alpha.3 Release 说明](release-notes-v0.1.0-alpha.3.md)。

注意：当前 `.github/workflows/release.yml` 渲染的是 `docs/release-notes-template.md`，不会读本文件；
本文件是 v0.1.0-alpha.4 的现成正文，要把实测值、已知问题与回退说明放进草稿 Release 时，在草稿
编辑页粘贴本文件并把校验值换成草稿资产的实际 SHA-256（若要改成由 workflow 渲染版本化文件，
需要单独修改 `.github/workflows/release.yml`，超出本文件的改动范围）。
-->

# Pi Web Desktop 0.1.0-alpha.4（build 4）— Apple Silicon alpha（未公证）

## 摘要 / Summary

Pi Web Desktop `0.1.0-alpha.4` 是面向 **Apple Silicon（arm64）、macOS 14 或更高版本** 的第四个
alpha 预览。它启动、监控并显示本机已安装的 Pi Web 服务，默认只监听 loopback。相对
`0.1.0-alpha.3`，本版本是一个**更新流水线加固版**，不新增功能：五处改动都针对上一版安全审查
（[alpha.3 更新流水线安全审查](security-review-alpha.3.md) 的 A-1 … A-9）与既有行为边界——
**检查结果现在标注来源**（本次网络响应 / 本机缓存回退 / 无可用结果），缓存文件在读取时逐项校验
结构与形状，并且**只有本次网络结果可以驱动自动安装**（#59）；Pi Web 自动安装是否传
`--ignore-scripts` 的结论与**只读静态证据**被写进代码、日志与文档（#60）；进程保护改为
**先筛选候选进程再读 argv**，并补齐短开关、已知凭据前缀与长不透明串的遮罩（#61）；有限降级的
证据升级为 **inode + 可执行文件内容哈希 + npm `integrity`**，并给出证据等级与不再暗示来源可信的
文案（#63）；超时/放弃等待变成一条**「已放弃」记录**（结束时间未知、跨启动保留），同一组件在
清除前不再自动执行，Pi Web 的 npm 子进程改为**独立进程组**并且只对这一个自己的进程组发一次
`SIGTERM`（#62）。

ZIP 里的应用仍然是 **ad-hoc 签名、未公证** 的：没有 Developer ID 证书，也没有 Apple 公证，
因此 Gatekeeper 默认会阻止直接双击打开，需要用户针对这一个应用手动放行。本版本没有 Intel 支持、
没有 SLA，**不承诺所有安装来源都能回滚**，远程访问的密码认证也**不等于传输加密**。更新验证仍然
**不做代码签名确认、不确认官方来源、不做安装包内容比对**。

Pi Web Desktop `0.1.0-alpha.4` is the fourth alpha preview for **Apple Silicon (arm64) Macs running
macOS 14 or later**. It starts, monitors and displays a locally installed Pi Web service and listens
on loopback by default. Compared with `0.1.0-alpha.3` this is a **hardening release for the update
pipeline** with no new features; the five changes all address the previous security review's
findings (A-1 … A-9) and existing capability boundaries: check results now carry a **provenance**
label (network / cached fallback / unavailable), the cache file is structurally validated on read,
and **only a network result can drive an automatic install** (#59); the decision to deliberately not
pass `--ignore-scripts` to the Pi Web install is recorded with **read-only static evidence** in code,
logs and docs (#60); the process guard now **filters candidate processes before reading argv** and
extends the masking rules (#61); limited degradation evidence is upgraded to **inode + content hash +
npm `integrity`** with explicit evidence levels and wording that no longer implies a trusted source
(#63); and a timed-out or abandoned update now leaves a persisted **"abandoned" record** (end time
unknown, survives restarts) that blocks further automatic attempts for that component until cleared,
while the Pi Web npm child now runs in its **own process group** that alone receives a single
`SIGTERM` (#62).

The app in the ZIP is **ad-hoc signed and not notarized**: there is no Developer ID certificate and
no Apple notarization, so Gatekeeper blocks a plain double-click and the user has to approve this
app explicitly. This release has no Intel support, no SLA, **no promise that every install source can
be rolled back**, and for remote access the password authentication is **not transport encryption**.
Update verification still **does not confirm code signatures, does not confirm an official source and
does not compare package contents**.

## 发布信息

| 项目 | 值 |
| --- | --- |
| 版本（tag） | `v0.1.0-alpha.4` |
| `CFBundleShortVersionString` | `0.1.0-alpha.4` |
| `CFBundleVersion` | `4` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 应用包 | `Pi-Web-Desktop.app` |
| 架构 | arm64（Apple Silicon）；**不支持 Intel（x86_64）** |
| 最低系统 | macOS 14.0 |
| 签名 | ad-hoc（`codesign --sign -`），没有证书，`TeamIdentifier=not set` |
| 公证 | 无。Gatekeeper 默认拒绝，需要用户手动放行这一个应用 |
| 发布类型 | GitHub **prerelease**（alpha 预览） |
| 上一版 | `v0.1.0-alpha.3`（build `3`），资产仍在 Releases 中可下载 |
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

## alpha.4 相对 alpha.3 的新增与变更

本版本没有新增功能面，只有更新流水线的加固与文档同步。五个功能/加固提交都已合入（PR #66、#67、
#68、#69、#70），本版本是它们的第一个对外构建；`v0.1.0-alpha.3` 已有的 #16–#23 行为见
[alpha.3 Release 说明](release-notes-v0.1.0-alpha.3.md)。

### 1. 检查结果来源标注与缓存校验（#59 / PR #68）

- **结果现在带来源**：每个 `UpdateCheckResult` 带 `origin`，取值三档——`network`（本次运行刚从
  白名单主机取得的响应）、`cached-fallback`（版本值来自本机缓存文件）、`unavailable`（没有可用
  结果）。条件请求命中 `304 Not Modified` 时网络往返是成功的，但版本值仍来自本机缓存，因此来源是
  `cached-fallback`：`304` 只说明“缓存里的那个版本仍是上游最新”，不能让一个本机可改写的版本
  字符串变成自动安装的目标。
- **只有本次网络结果可以驱动自动更新**：Pi Web、Pi CLI 与 Pi 扩展包三条路径在原有前置条件之前
  新增一条硬前置 `origin == network`；缓存回退或没有结果一律拒绝自动执行，只保留手动入口（命令
  文本，仅展示由用户自己执行）。拒绝原因是固定文案，包含“本机缓存”与缓存写入时间，**不写
  “已验证/官方”之类会被读成“本次已由上游确认”的措辞**。手动“检查更新…”的结果汇总、诊断页与
  “更新检查偏好设置”窗口里的状态行会标注“来源：本机缓存（写入于 …）；缓存不是可信输入，只用于
  提示，不用于自动安装”。
- **缓存读取先校验结构与形状**：读取 `update-check-cache.json` 时先看文件大小上限（1 MiB），再
  逐项校验——JSON 与字段类型可解码、`schemaVersion` 与当前版本一致、条目数不超上限（200）、
  分类/包名/目标 id 互相一致、枚举值已知、版本字符串是**规范化的语义化版本**、时间戳不落在未来
  （允许小幅时钟偏移）、条件请求字段长度受限（etag / last-modified 各 512 字符内、HTTP 状态码在
  100–599）。任何一项不合法就丢弃**整份**缓存（不部分采用、不崩溃），写一条只含固定原因的日志
  （不回显缓存内容、不打印路径），并按“没有可用缓存”（`unavailable`）处理。
- **缓存仍然不是可信输入**：缓存文件位于用户自己的 Application Support 下，同一用户（或任何能
  以该用户身份写文件的程序）可以改写它，应用不做签名/HMAC 校验。加固后它能影响的最大范围是
  **提示文案**，不再是自动安装的目标版本。
- **缓存写入不受影响**：写失败仍然静默，不影响检查结果、服务与退出路径；缓存内容仍只有版本号、
  时间戳与条件请求字段。

### 2. Pi Web 自动安装的生命周期脚本策略（#60 / PR #69）

- **结论：argv 刻意不传 `--ignore-scripts`**，保持 `["install", "-g", "<静态包名>@<目标版本>"]`。
  这条结论与理由单点记在 `PiWebUpdateLifecycleScriptPolicy`，同时输出到日志、诊断与手动确认框：
  “不传 `--ignore-scripts`（按上游包声明的安装期脚本执行；用你本机的 npm 与 npm 配置）”。
- **静态证据（只读，不是实跑结果）**：评估时只读检查了本机 npm 全局安装目录里上游包的
  `package.json`（声明 `postinstall`，`files` 白名单含 `bin` 与 `.next`）、`bin/prepare-terminal.js`
  （在 macOS 上只给依赖 `node-pty` 的 `spawn-helper` 二进制补可执行位）与依赖 `node-pty` 自己的
  `install` / `postinstall`（选择预编译原生模块，必要时 `node-gyp rebuild`）。npm 的
  `--ignore-scripts` 会跳过**所有**生命周期脚本，包括依赖的 `install`，可能留下缺少可执行位的
  终端辅助二进制或未就绪的原生模块，反而破坏上游包自己的安装。
- **应用不替用户决定脚本策略**：argv 不带该开关，环境白名单也**不注入** `npm_config_ignore_scripts`
  或任何 `npm_config_*`（既有行为不变）。安装由**用户自己的 npm**、按用户自己的 npm 配置执行，
  与用户在终端里自己装时执行的脚本是同一批；想避免脚本在无人确认时执行，就把这个开关保持关闭
  （手动入口会在确认框里先展示命令与版本，确认后才执行同一批脚本），或完全按上游文档自行安装。
- **不夸大的边界**：这是对已安装包文件的静态评估，**没有真的执行过一次安装**，也没有验证安装后
  的运行行为。

### 3. 进程保护：只对候选进程读 argv，并补齐遮罩（#61 / PR #66）

- **读取面收窄为两步**：`PiProcessProbing.snapshot(_:)` 只取便宜的身份事实（父 PID、启动时间、
  镜像路径、内核进程名），argv 由单独的 `arguments(_:)` 读取，并且**只有候选进程会被读**
  （`KERN_PROCARGS2`）。候选判定只用镜像路径与内核进程名的最后一段：可执行基名恰好是 `pi`，或
  像已知的 JS 运行时（`node` / `nodejs` / `bun` / `deno` / `tsx` / `ts-node`，以及 `node24`、
  `npm-cli` 这类已知前缀）。系统守护进程、编译器、编辑器等非候选进程的命令行不再被读取。
- **候选判定只是读取优化，不是安全判断**：镜像路径与内核进程名都读不到、权限不足或枚举失败
  仍然按“不确定”处理（不自动更新，推迟到下次判定）；分类规则（精确可执行名比较、`pi` 脚本的
  进程标题或脚本路径判定、`pi-web` / `pip` / `pi-helper` 不命中）与三态语义都没有放宽。
- **遮罩补齐**：命令摘要先按 token 边界遮罩，再经 `LogRedactor` 整体脱敏，最后截断到 200 字符。
  新增的遮罩形态包括：`--token=<值>` 这类键值（保留键）、`-p<值>` / `-t<值>` / `-s<值>` 这类短开关
  紧跟值（保留开关）、裸长开关与裸 `-p` / `-t` / `-s`（带分隔符时无法可靠区分值与下一个开关，
  因此连尾巴一起隐藏）、已知凭据前缀（`sk-` / `ghp_` / `xoxb-` / `glpat-` / `npm_` / `AKIA` 等）、
  长度 ≥ 32 且只由 base64/十六进制字符组成的位置参数，以及 URL 查询串；`KEY=VALUE` 形状的环境
  片段仍然直接丢弃，Home 路径换成 `~`。
- **已知边界（如实说明）**：这是**模式化遮罩**，不是“凡秘密必被遮”。不符合上述形状的自由文本会
  原样保留（例如短于 32 字符、又没有已知前缀或敏感键名的位置参数），因此不要把秘密直接放进
  命令行；这一点在 `docs/privacy.md` 与 `PiWebDesktopTests/PiProcessInspectorTests.swift` 里都是
  明确断言，不是遗漏。

### 4. 降级证据升级与文案修正（#63 / PR #67）

- **更新前指纹新增三层证据**：`st_ino`、可执行文件**内容哈希**（SHA-256、流式读取、上限 16 MiB）、
  以及从本机 npm 锁文件有界读取的 **npm `integrity`**（单个锁文件上限 4 MiB、取值经过
  `<算法>-<base64 形状>` 校验、长度上限 200 字符）。取不到内容哈希时 `contentHash` 为空并带固定
  原因（超过大小上限 / 文件不可读 / 本机没有该能力 / 本次运行没有文件系统探针 / 没有可执行文件
  路径），取不到 npm `integrity` 时如实写“npm 完整性未获取”，**绝不伪造**。
- **证据等级写进历史**：`evidenceLevel` 固定为 `pathOnly`（仅路径与元数据）、`inode`（inode +
  元数据）、`contentHash`（inode + 内容哈希）之一，历史记录与诊断页一起展示证据说明（是否做了
  内容哈希、npm 完整性是“已记录”还是“未获取”）。
- **自动降级的判定变严（全部满足才算“已降级”）**：来源必须是已验证的 npm 全局安装；应用保留了
  更新前的可执行文件路径与版本证据；旧路径仍存在且带可执行位；旧路径所在包的 `package.json`
  名称与更新前记录/期望包名一致；**指纹记录了 inode 时必须一致**；**指纹记录了内容哈希时必须
  重新计算并一致**。任一读不到或不一致 → `cannotAutomaticallyRollback`，绝不写“已降级”。
- **明示的等价规则**：内容哈希是比 size/mtime 更强的证据——哈希一致时不再要求 size/mtime 相同。
  没有内容哈希（超限/不可读/无探针）时降级仍可能发生，但只能退回 size/mtime 元数据比对，并在
  文案与历史里写明“**不校验旧文件内容**”与“未做内容哈希”。
- **“已降级”不再暗示来源可信**：文案明确写“这只是把调用方指回更新前记录的路径”，不复制、不
  移动、不恢复文件内容、不卸载新版本；成功路径的检查记录改写成具体事实（“版本与目标版本一致”
  “身份名称一致”），不再使用“验证通过”“来源可信”“安全检查已通过”这类会被读成更强结论的措辞。
- **npm `integrity` 的定位（不夸大）**：它是**附加证据**，只出现在证据说明里，**不参与降级判定**
  的通过/失败（判定仍以身份名称、inode、内容哈希为准）。它来自本机锁文件，同一用户可改写，
  因此不能当作发布者身份或来源证明。内容哈希同样只说明“旧文件是否仍是同一份”，不证明发布者、
  发布时间或来源。

### 5. 超时/放弃等待的「已放弃」记录与重叠防护（#62 / PR #70）

- **一条持久记录**：更新命令超时、应用退出或用户取消而放弃等待时，应用写一条记录
  （UserDefaults 单键 JSON：`updateChecks.piWeb.abandonedAttempt`、`updateChecks.pi.abandonedAttempt`、
  `updateChecks.piPackages.abandonedAttempts`），字段固定为组件（扩展包带已校验包名）、**已脱敏**
  的命令摘要（Home 段 → `~`、凭据键值 → `<redacted>`、剔除控制字符、上限 200 字符）、开始时间、
  超时上限（可接受上界 24 小时）、放弃原因（`timedOut` / `abandonedWaiting`）、来源、本次对子进程
  实际做了什么与记录时间。**`finishedAt` 恒为空**：应用已经停止等待，不知道那个进程什么时候结束、
  有没有结束，因此不写一个假的时间；派生进程是否结束同样恒为“未确认”。
- **读回校验**：写入与读回都逐字段校验（结束时间必须为空、摘要非空且无控制字符、超时在范围内、
  时间戳不早于固定起点、动作必须与组件匹配——只有 Pi Web 可能出现“发送过信号”的记录），任何一个
  字段不可信就**丢弃整条记录**，不把不受控文本展示给用户。
- **记录不对子进程做任何事**：只有用户显式清除（菜单“服务 → 更新检查设置 → 已放弃的更新记录…”），
  或该组件后来**成功**完成了一次更新，才会清除该组件的记录（失败不清除）。清除只删除记录，
  不改动任何文件、也不结束任何进程。记录跨退出与重新启动保留。
- **重叠防护**：同一组件存在未清除的记录时，该组件**不再自动执行**下一次更新（推迟到下次启动，
  原因可读并写入日志）；手动入口不受影响，但确认框会先展示这条记录并需要显式确认。三个组件互相
  独立，一个组件的记录不影响其它组件。
- **Pi Web 的 npm 子进程改为独立进程组**：子进程用 `posix_spawn` 启动并要求新建独立进程组
  （`POSIX_SPAWN_SETPGROUP` + 组 id = 子进程自己的 pid），并设 `POSIX_SPAWN_CLOEXEC_DEFAULT`；
  超时/取消时**只对这一个新进程组发送一次 `SIGTERM`**（`killpg`，尽力而为），**不发 `SIGKILL`**、
  不按进程名杀进程、绝不触碰任何 Pi 进程。句柄无法确认“那是自己的独立进程组”（降级启动、组 id 与
  pid 不一致、pid ≤ 1）时**不发送任何信号**，只放弃等待。`cancel()` 与超时两条路径共享同一份
  “至多一次”的状态，不会出现第二次信号。
- **Pi CLI 与扩展包仍不发送任何信号**：它们的更新命令就是 `pi` 本身，超时、应用退出与取消一律
  只放弃等待，接口里没有发信号、终止或修改进程的方法（源码负向断言仍然覆盖）。
- **可见性**：诊断窗口的更新状态页、“更新检查偏好设置…”窗口与手动确认框展示同一份文本（组件、
  命令摘要、开始时间、超时上限、“结束时间未知”、实际动作、来源、记录时间），全部是固定文案与
  已校验字段，不含可执行内容。
- **仍然不承诺的**：应用不确认被放弃的进程是否已经结束；`SIGTERM` 是请求而不是保证；“同一组件不再
  自动重复”是一条**记账式**防护，不是对进程存活状态的检测——记录被用户清除或该组件后来更新成功
  后，就允许下一次自动尝试。

### 6. 文档与仓库同步

- README“更新与隐私”补上本版新增的三条事实：缓存回退只提示、不参与自动更新；自动更新由用户
  自己的 npm 执行、会运行包声明的安装脚本（不想这样就把开关保持关闭）；一次更新超时会被记成
  「已放弃、结束时间未知」的记录，下次启动仍会展示并且不会自动重复。
- [隐私说明](privacy.md)、[架构说明](architecture.md)、[设置、工作目录与退出行为](settings-and-workspace.md)、
  [日志与诊断导出](logging-and-diagnostics.md)与本版实现保持一致（尤其是「已放弃」记录的可见性与
  清除位置、超时语义、缓存来源标注与 `--ignore-scripts` 结论）。
- 新增本版说明与一份针对 alpha.3 → alpha.4 改动的只读安全审查（delta）：
  [alpha.4 更新流水线安全审查](security-review-alpha.4.md)。

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
  不发任何请求，也不安排复查，两个启动前自动更新开关也不会执行任何安装（它们仍需要一份**本次
  网络**的“可更新”结果）。
- 结果缓存在 `~/Library/Application Support/Pi Web Desktop/update-check-cache.json`，只含版本号、
  时间戳与 etag 等条件请求字段；读取时逐项校验结构（见上文 #59）。忽略版本、更新开关、失败警告、
  更新历史与「已放弃」记录在 UserDefaults（`updateChecks.*`）。
- 上游服务会看到请求的源 IP、`User-Agent` 与请求时间，按各自隐私政策处理接入日志。完整说明见
  [隐私说明](privacy.md) 的“版本检查、提示与忽略版本”。

## 自动更新的准确边界

**会做的**（两个开关默认关闭，且都要求组件来源可信 + 目标版本来自**本次网络**检查结果 + 没有
未清除的「已放弃」记录）：

| 路径 | 触发方式 | 命令（参数数组） | 前置条件 | 超时行为 |
| --- | --- | --- | --- | --- |
| Pi Web（#20/#62） | 应用启动时，设置打开 | `npm install -g @agegr/pi-web@<目标版本>` | 来源 `npmGlobal` + `verified`；目标 `verified` 且更高；检查结果来源 `network`；托管服务未运行；无未清除的「已放弃」记录 | 5 分钟；只对本次启动的**独立 npm 子进程组**发一次 `SIGTERM`，不发 `SIGKILL`，未确认派生进程结束 |
| Pi CLI（#21/#62） | 拿到当次检查结果后，设置打开 | `pi update --self` | 来源 `npmGlobal`/`pnpmGlobal` + `verified`；目标 `verified` 且更高；检查结果来源 `network`；当次检查为 `noProcesses`；无未清除的「已放弃」记录 | 10 分钟；**只放弃等待，不发送任何信号** |
| Pi 扩展包（#22/#62） | 用户在确认框里显式确认 | `pi update npm:<包名>` | 来源 `npmGlobal` + `verified`；目标 `verified` 且更高；检查结果来源 `network`；当次检查为 `noProcesses`；用户确认（有记录时先展示记录） | 10 分钟；**只放弃等待，不发送任何信号** |

**不会做的**：

- 不会下载或安装桌面应用自身（`Pi Web Desktop.app`）的新版本。
- 不会在来源不可信（Homebrew、nvm/mise、git checkout、本地路径、未知，或可信度不是“已验证”）时
  自动安装；这些来源只显示命令文本或按来源文档提示。
- 不会用本机缓存回退的结果自动安装或自动更新（缓存回退只提示，并标注来源与缓存写入时间）。
- 不会在无人值守时更新 Pi 扩展包：不点确认就不会执行（取消或直接关闭对话框都不执行）。
- 不会结束、暂停、接管任何 Pi 会话，也不会向任何 Pi 进程发送信号（#21 / #22 的接口里没有这类
  方法；#20 的唯一信号是它自己启动的 npm 子进程组，见 #62）。
- 不会保证更新成功、不保证所有来源都能回滚，也不会在失败后卸载新版本或恢复旧文件内容。
- 不会校验被放弃的进程是否已经结束，也不保证 `SIGTERM` 一定让 npm 子进程结束。

## 本机实测环境与版本（可追溯）

下表来自维护者一台 Apple Silicon 真机的实测输出，**不是 CI runner**；每一行的值都能用第三列的
命令复现。CI runner 的版本不会写进本说明。

| 项目 | 实测值 | 实测命令（本机输出摘要） |
| --- | --- | --- |
| 机器与芯片 | Apple M4（Mac mini，`Mac16,10`） | `sysctl -n machdep.cpu.brand_string` → `Apple M4`；`sysctl -n hw.model` → `Mac16,10` |
| macOS | 27.0（BuildVersion `26A428`），满足 `>= 14` | `sw_vers` |
| 架构 | arm64 | `uname -m` → `arm64` |
| Node.js | v24.21.0 | `node --version` → `v24.21.0` |
| npm | 11.19.0 | `npm --version` → `11.19.0` |
| Pi CLI（`@earendil-works/pi-coding-agent`） | 0.85.1 | `pi --version` → `0.85.1`；`npm ls -g --depth=0` → `@earendil-works/pi-coding-agent@0.85.1` |
| `@agegr/pi-web` | 0.9.1 | `npm ls -g @agegr/pi-web` → `@agegr/pi-web@0.9.1` |
| Swift 编译器 | Apple Swift 6.4（`swiftlang-6.4.0.34.1 clang-2100.3.34.1`） | `swift --version` |
| 应用包身份 | `CFBundleShortVersionString=0.1.0-alpha.4`、`CFBundleVersion=4`、`LSMinimumSystemVersion=14.0` | `./Scripts/check-identity.sh` → `check-identity: PASSED (45 checks)` |

`pi-web` 当前（0.9.1）没有 `--version` 选项，核对版本请用 `npm ls -g @agegr/pi-web` 或读取该包
`package.json` 的 `version`；诊断逻辑会先尝试 `--version`，失败后回落到 `package.json`，并在
诊断界面标出安装来源与可信度。

## 安装

1. 从本 Release 的 assets 下载 `Pi-Web-Desktop-0.1.0-alpha.4.zip` 与它的 `.sha256`、证据 Markdown。
2. 校验下载的 ZIP（在下载目录执行；文件名以 assets 实际名称为准）：

   ```bash
   shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.4.zip.sha256
   ```

   输出必须包含 `Pi-Web-Desktop-0.1.0-alpha.4.zip: OK`；不一致就不要安装。
3. 解压：

   ```bash
   ditto -x -k Pi-Web-Desktop-0.1.0-alpha.4.zip .
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
   迁移 Pi 的认证内容。上面第二条命令由**你自己**执行，脚本是否运行由你的 npm 配置与上游包的
   声明决定（与 #60 的自动安装结论一致）。

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
  启动前自动更新（#20）在这条启动路径上先判定：需要时先完成一次覆盖 Pi Web 的版本检查，再决定
  安装还是照常启动服务；检查失败只会跳过自动更新，不影响服务启动。
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
  验证：#23/#63 的验证**不确认代码签名**，只检查可执行文件、真实路径、版本号、`package.json` 名称
  与健康检查；内容哈希只用于判断“更新前的旧文件是否仍是同一份”。
- 放行是“针对这一个应用”的决定，系统会把它记录在“隐私与安全性”里；重新下载（quarantine 属性
  存在时）可能需要再次确认。
- 安装说明在这里给出的 Gatekeeper 处理只有两条：右键/Control 点按后选择“打开”，或在
  “系统设置 → 隐私与安全性”中针对被拦截的应用选择“仍要打开”。本项目不会建议关闭 Gatekeeper。
- 本项目不会把 ad-hoc 签名或“本机校验通过”描述成“已签名”或“已公证”。

## 校验值

- 资产：`Pi-Web-Desktop-0.1.0-alpha.4.zip`（以及 `Pi-Web-Desktop-0.1.0-alpha.4.zip.sha256`、
  签名与公证证据 Markdown，名称以 Release assets 为准）
- SHA-256：`<发布后由协调者填写>`（草稿发布前从资产或 workflow 摘要复制；同一个值也会记录在
  Release Issue 中。**不要**使用任何在别处看到的哈希，包括本机演练产物——本机演练的 SHA-256
  每次都不同。）
- 校验命令（下载目录执行）：`shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.4.zip.sha256`
- 校验失败时不要安装，请在 Release Issue 或普通 Issue 中报告。

另外，`package-release.sh` 生成的 evidence Markdown 会记录 `codesign`/`spctl` 原始输出、ZIP 名称、
SHA-256、构建提交与打包环境；它明确标注打包环境不等于真机实测环境。

## 构建与签名验证记录（本机演练）

下表是本机演练的实际命令与结果（`spctl` 的退出码 3 是预期结果）。完整记录见
[Alpha 发布门槛清单](alpha-release-checklist.md) 的“本次发布执行记录（v0.1.0-alpha.4）”一节。

| 命令 | 结果 |
| --- | --- |
| `git diff --check` | 退出 0（无空白错误） |
| `sh -n Scripts/*.sh` | 退出 0 |
| `./Scripts/build.sh` | 退出 0；`Mach-O 64-bit executable arm64` |
| `./Scripts/check-identity.sh` | 退出 0；`check-identity: PASSED (45 checks)`，bundle 为 `0.1.0-alpha.4` / `4` |
| `codesign --verify --deep --strict build/Pi-Web-Desktop.app` | 退出 0；`valid on disk` / `satisfies its Designated Requirement` |
| `codesign -dv --verbose=4 build/Pi-Web-Desktop.app` | `Signature=adhoc`、`TeamIdentifier=not set`、`Format=app bundle with Mach-O thin (arm64)` |
| `spctl -a -vv build/Pi-Web-Desktop.app` | 输出 `rejected`，退出 3（未公证的预期结果；本机 `spctl` 不打印拒绝原因） |
| `./Scripts/smoke.sh`（启动模式 + 诊断模式） | 退出 0；标记 `smoke: ready` 与 `smoke: diagnostics items=6 blockers=3` / `smoke: diagnostics ready` |
| `./Scripts/scan-secrets.sh --self-test` | 退出 0；`self-test: PASS` |
| `./Scripts/scan-secrets.sh` | 退出 0；`scan-secrets: suppressed 11 lines`、`scan-secrets: PASS` |
| `sh Scripts/check-release-version.sh v0.1.0-alpha.4` | 退出 0；tag 与 `MARKETING_VERSION` 一致、预发布计数 `4` 与 `CURRENT_PROJECT_VERSION` 一致 |
| `./Scripts/package-release.sh --tag v0.1.0-alpha.4` | 退出 0；产出 ZIP、`.sha256`、evidence 与 `release-metadata.env`，版本为 `0.1.0-alpha.4` / build `4` |
| ZIP 内容与包内版本 | 23 项（应用包 + `__MACOSX/` AppleDouble）；`ditto` 解压后 `plutil -p` 显示 `CFBundleShortVersionString=0.1.0-alpha.4`、`CFBundleVersion=4`；解压出的 bundle 通过 `codesign --verify --deep --strict` |

`./Scripts/smoke.sh` 只验证窗口、诊断页与退出路径：两种模式都在临时 support 目录里运行，不写真实
UserDefaults / Application Support / Logs，也不启动真实 pi-web；它不替代 `xcodebuild test`。本机
`xcode-select -p` 指向 Command Line Tools，因此没有在本机运行 `xcodebuild build` / `xcodebuild test`
（由 CI 的 `macos-14` job 覆盖，见门槛清单）。

## 已知问题

alpha.3 → alpha.4 的独立安全审查见 [alpha.4 更新流水线安全审查（delta）](security-review-alpha.4.md)：
**阻断项 0 项**。alpha.1 审查（服务、Keychain、脱敏、网络、发布、依赖）的非阻断项（R-4、R-5、R-6、
R-8、R-10）继续有效；alpha.3 审查的 A-1 … A-9 在本版的处理结果如下（完整证据、新增条目与残留风险
见审查报告）：

- **已闭环**：A-1（缓存回退不再驱动自动安装，#59）、A-7 的自动路径（被放弃的命令留下记录并阻止该
  组件自动重复，#62）、A-6 的主要部分（超时终止从“只杀自己的子进程”升级为“只对自己的独立进程
  组发一次 `SIGTERM`”，覆盖 npm 自己派生的子进程）。
- **部分闭环**：A-4（降级证据升级为 inode + 内容哈希，但未记录内容哈希时仍只能退回 size/mtime 并
  明确写“不校验旧文件内容”）、A-5（非候选进程不再读 argv，遮罩形态补齐，但仍是对 JS 运行时形状的
  候选进程读 argv，且遮罩是模式化的）、A-3（“验证通过”措辞改成具体事实，但验证仍不等于来源可信）。
- **按现状接受**：A-2（Pi Web 自动安装仍不传 `--ignore-scripts`，本版把结论、静态证据与用户可见
  选择写清楚）、A-8（Pi CLI 手动入口有意不做进程门控）、A-9（更新相关的本地持久状态仍可被同用户
  读写；本版新增的记录本身也受这一边界约束）。
- **本版新增/转化出的非阻断条目**（编号 N-1 … N-6 与等级见审查报告）：内容哈希不可得时的元数据
  回退仍可被同用户伪造；「已放弃」重叠防护是记账式的、不检测被放弃的进程是否仍在运行；npm
  `integrity` 只是展示用附加证据、来自本机可改写文件；进程组信号与 `waitpid` 之间有一个窄窗口、
  理论上存在 PID 复用风险（分析结论，未动态验证）；缓存回退的提示文案仍可被同用户改写缓存影响
  （只影响提示，不影响自动安装）；「已放弃」记录本身也属于同用户可写状态，最多暂停该组件的自动
  更新并向应用界面提供受长度与控制字符约束的文本。
- **未公证**：首次打开必须手动放行，见上文“未公证、ad-hoc 与 Gatekeeper”。
- **更新验证有边界**：不确认代码签名、不确认公证、不做安装包内容比对；`package.json` 名称检查只防
  “换成了别的包名”，不等于发布者身份验证；内容哈希与 npm `integrity` 都只证明“本机文件是否仍是
  同一份 / 本机记录了什么”，**不证明来源可信**。
- **回滚能力有限**：只有“已验证的 npm 全局安装 + 应用保留的更新前证据仍在原位、身份名称一致、
  inode 与（若记录过）内容哈希一致”这一种情况会做自动降级（把服务/重检测指回旧可执行文件）；
  其它来源与证据缺失/被覆盖的情况一律写“无法自动回滚”，只给手动命令。应用**不恢复文件内容、
  不卸载新版本**。
- **更新失败不保证子进程结束**：Pi Web 只对本次启动的独立进程组发一次 `SIGTERM`（尽力而为），
  Pi CLI 与扩展包只放弃等待；应用不确认被放弃的进程是否结束、什么时候结束。
- **依赖需要自行安装**：缺失时应用只显示诊断信息，不会自动安装（除非用户打开 Pi Web 或 Pi CLI
  的启动前自动更新开关，且全部前置条件满足）。
- **无 Intel 支持**：只支持 Apple Silicon（arm64），Intel Mac 不在支持范围。
- **无 SLA**：alpha 预览按“现状”提供，不承诺响应时间或修复时限。
- **远程访问**：默认只监听 `127.0.0.1`；远程访问必须自备加密隧道或 HTTPS 反向代理。**密码认证
  只验证访问者，不等于传输加密**，也没有暴力破解防护（上游 pi-web 范围，审查 R-4）。
- **日志轮转只保留 5 份**（每份上限 10 MB），超过上限的旧日志会被删除（见
  [日志与诊断导出](logging-and-diagnostics.md)）。

## 回退

1. 保留上一版的 ZIP 与它的 `.sha256`。回退时解压上一版（`v0.1.0-alpha.3`，资产仍在 Releases 中）
   并替换当前的 `Pi-Web-Desktop.app`，然后用 `codesign --verify --deep --strict` 复核（未公证的
   ad-hoc 产物仍会被 `spctl` 拒绝，这是预期结果）。
2. 卸载 / 回退应用包：应用没有系统级常驻组件或 LaunchAgent，删除应用包不会残留其他系统文件。
   退出应用后：

   ```bash
   rm -rf "$HOME/Applications/Pi-Web-Desktop.app"
   ```

   安装在 `/Applications` 时把路径换成 `/Applications/Pi-Web-Desktop.app`。
3. 需要清理用户目录中的残留数据时才执行（会丢失服务配置、日志、更新检查设置、更新历史、
   「已放弃」记录与网站数据；删除 Keychain 条目会自动关闭远程模式并让监听地址回到
   `127.0.0.1`）：

   ```bash
   defaults delete io.github.su-luoya.pi-web-desktop        # 服务配置、首次设置状态、窗口位置、更新检查设置、忽略版本、更新告警、更新历史与「已放弃」记录
   rm -rf "$HOME/Library/Application Support/Pi Web Desktop" # 运行状态、所有权记录与更新检查缓存
   rm -rf "$HOME/Library/Logs/Pi Web Desktop"                # 日志与轮转文件
   rm -rf "$HOME/Library/WebKit/io.github.su-luoya.pi-web-desktop" \
          "$HOME/Library/Caches/io.github.su-luoya.pi-web-desktop"  # WebKit 网站数据
   security delete-generic-password -s io.github.su-luoya.pi-web-desktop -a remote-access-password
   ```

   以上路径与删除方式以[隐私说明](privacy.md#本地数据一览与删除)为准；删除这些不会影响 Pi Web、
   Pi CLI 或 Node.js 自身的数据。只想清掉「已放弃」记录时不必删这些：用菜单“服务 → 更新检查设置 →
   已放弃的更新记录…”清除即可（只删除记录，不改动任何文件、也不结束任何进程）。
4. 组件版本回退：应用最多把服务/版本重检测指回它保留的旧 npm 全局可执行文件，不承诺恢复第三方
   包的旧版本，也不提供通用自动回滚。需要固定某个 Pi CLI / Pi Web / 扩展包版本时，请用对应包
   管理器手动安装，并在升级前记录当前版本。
5. 已经发布的版本不会静默替换 ZIP 或 checksum；新版本有问题时发布新的 alpha（例如
   `v0.1.0-alpha.5`）并在 Release 说明中给出回退路径。

## 支持边界

- 只支持 Apple Silicon（arm64）与 macOS 14 或更高版本；没有 Intel 产物。
- 没有 SLA，桌面应用没有自动更新安装，没有 Developer ID 签名、Apple 公证或 Apple 支持渠道。
- 默认只监听 loopback；远程访问必须自备加密传输，并且**密码认证不等于传输加密**。
- 更新路径的硬边界：两条自动更新默认关闭且只对来源可信的 npm/pnpm 全局安装生效，目标版本必须
  来自本次网络检查；扩展包更新必须由用户确认；验证不做代码签名确认；不承诺所有来源都能回滚。
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
