<!--
docs/release-notes-v0.1.0-alpha.5.md — v0.1.0-alpha.5 草稿 Release 的正文。

可以直接粘贴为 GitHub Release 说明（本注释在 GitHub 上不渲染）。发布前必须：
  * 把“校验值”一节的占位符换成草稿资产里实际的 ZIP 名、SHA-256 与字节数；
  * 核对资产名称、版本与 build 和草稿一致（命名规则见下文“校验值”与 releasing.md）；
  * 不要在本文件或发布说明里声称“已签名”“已公证”，也不要指导关闭 Gatekeeper；
  * 不要写入主机名、用户名、凭据、代理端点或真实用户绝对路径；
  * 发布前删除文末“发布时需要补全的值清单”一节。

相关文档：[发布流程](releasing.md)、[Alpha 发布门槛清单](alpha-release-checklist.md)、
[Release notes 模板](release-notes-template.md)、[隐私说明](privacy.md)、
[架构说明](architecture.md)、[日志与诊断导出](logging-and-diagnostics.md)、
[设置、工作目录与退出行为](settings-and-workspace.md)、[开发说明](development.md)、
[alpha.1 安全与发布审查](security-review-alpha.1.md)、
[alpha.3 更新流水线安全审查](security-review-alpha.3.md)、
[alpha.4 更新流水线安全审查（delta）](security-review-alpha.4.md)、
[v0.1.0-alpha.4 Release 说明](release-notes-v0.1.0-alpha.4.md)。

本版改动来自仓库外的内部代码审查记录（W2A / W2B / W3 / W4）；这些审查报告不在本仓库内，
PR #94 与 PR #95 的正文包含完整的 file:line 与验证证据。

注意：当前 `.github/workflows/release.yml` 渲染的是 `docs/release-notes-template.md`，不会读本文件；
本文件是 v0.1.0-alpha.5 的现成正文，要把实测值、已知问题与回退说明放进草稿 Release 时，在草稿
编辑页粘贴本文件并把校验值换成草稿资产的实际值（若要改成由 workflow 渲染版本化文件，需要单独
修改 `.github/workflows/release.yml`，超出本文件的改动范围）。
-->

# Pi Web Desktop 0.1.0-alpha.5（build 5）— Apple Silicon alpha（未公证）

## 摘要 / Summary

Pi Web Desktop `0.1.0-alpha.5` 是面向 **Apple Silicon（arm64）、macOS 14 或更高版本** 的第五个
alpha 预览。它启动、监控并显示本机已安装的 Pi Web 服务，默认只监听 loopback。相对
`0.1.0-alpha.4`，本版本是一个**正确性与稳定性修复版**，不新增功能：12 个修复提交全部合入
（issue #72–#93 / PR #76–#95），其中两条重点修复针对更新执行器——**应用内触发的 Pi Web / Pi CLI
自更新现在可以重入，并且门控覆盖整轮更新事务**（#93），**扩展包更新执行器的每轮运行状态互相
隔离**（#92）。其余十项覆盖退出路径、更新检查缓存回退、秘密扫描、子进程日志、服务状态机、
设置窗口与诊断导出、CI 抖动、隐私遮罩与依赖探针、发布脚本，以及 **Finder 启动下的工具 `PATH`
合并**（#89：Homebrew 安装的 `pi` 不再被判成 `unknown`）。

ZIP 里的应用仍然是 **ad-hoc 签名、未公证** 的：没有 Developer ID 证书，也没有 Apple 公证，
因此 Gatekeeper 默认会阻止直接双击打开，需要用户针对这一个应用手动放行。本版本没有 Intel 支持、
没有 SLA，**不承诺所有安装来源都能回滚**，远程访问的密码认证也**不等于传输加密**。更新验证仍然
**不做代码签名确认、不确认官方来源、不做安装包内容比对**。

Pi Web Desktop `0.1.0-alpha.5` is the fifth alpha preview for **Apple Silicon (arm64) Macs running
macOS 14 or later**. It starts, monitors and displays a locally installed Pi Web service and listens
on loopback by default. Compared with `0.1.0-alpha.4` this is a **correctness and stability release**
with no new features: twelve fixes are included (issues #72–#93 / PRs #76–#95). The two highlights
concern the update executors — app-triggered Pi Web and Pi CLI self-updates are now **re-entrant and
gated over the whole update transaction** (#93), and the Pi package update executor now keeps
**per-run state instead of one-shot state** (#92). The other ten fixes cover the quit path, cached
update-check fallback, the secret scanner, subprocess logging, the service state machine, the
settings window and diagnostics export, CI flakiness, privacy masking and dependency probes, the
release scripts, and **merged tool `PATH` for subprocesses** (#89: a Homebrew-installed `pi` is no
longer classified as `unknown` when the app is launched from Finder).

The app in the ZIP is **ad-hoc signed and not notarized**: there is no Developer ID certificate and
no Apple notarization, so Gatekeeper blocks a plain double-click and the user has to approve this
app explicitly. This release has no Intel support, no SLA, **no promise that every install source can
be rolled back**, and for remote access the password authentication is **not transport encryption**.
Update verification still **does not confirm code signatures, does not confirm an official source and
does not compare package contents**.

## 发布信息

| 项目 | 值 |
| --- | --- |
| 版本（tag） | `v0.1.0-alpha.5` |
| `CFBundleShortVersionString` | `0.1.0-alpha.5` |
| `CFBundleVersion` | `5` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 应用包 | `Pi-Web-Desktop.app` |
| 架构 | arm64（Apple Silicon）；**不支持 Intel（x86_64）** |
| 最低系统 | macOS 14.0 |
| 签名 | ad-hoc（`codesign --sign -`），没有证书，`TeamIdentifier=not set` |
| 公证 | 无。Gatekeeper 默认拒绝，需要用户手动放行这一个应用 |
| 发布类型 | GitHub **prerelease**（alpha 预览） |
| 上一版 | `v0.1.0-alpha.4`（build `4`），资产仍在 Releases 中可下载 |
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

## alpha.5 相对 alpha.4 的新增与变更

本版本没有新增功能面，只有修复与文档同步。12 个修复提交（issue #72–#93 / PR #76–#95）全部合入，
日期均为 **2026-09-20**；本版本是它们的第一个对外构建。`v0.1.0-alpha.4` 已有的 #59–#63 行为与
能力边界见 [alpha.4 Release 说明](release-notes-v0.1.0-alpha.4.md)。

### 1. 退出不再卡死：退出决策移出 AppKit 终止序列（#72 / PR #76）

- **问题**：`applicationShouldTerminate` 的三条分支都返回 `.terminateLater`，但代码里从未调用
  `reply(toApplicationShouldTerminate:)`。AppKit 因此一直等不到回复，主队列也不排水：应用既不
  退出、也没有可用的确认对话框；点“退出并停止服务”时连服务都不会停。
- **行为变化**：新增 `Sources/QuitCoordinator.swift`（退出决策状态机，286 行），**从不返回
  `.terminateLater`**，只返回 `.terminateNow` 或 `.terminateCancel`；`PiWebApp` 在收到决策后立即
  回复 AppKit。等待用户决策有超时兜底（`QuitCoordinator.defaultDecisionTimeout = 5 * 60` 秒，
  `Sources/QuitCoordinator.swift:100`），超时按最安全的行为处理：保持服务运行并退出；取消决策后
  应用继续可用。
- **用户可见后果**：⌘Q / 关闭应用不再出现“点了没反应、应用挂在半死状态”；“退出并停止服务”
  会真的停服务，选择相反分支则服务继续运行。
- **边界与未验证**：本轮未做 GUI 手工验收（没有执行 GUI 交互测试）；脚本构建产物
  `build/Pi-Web-Desktop.app` 已在本机生成，签名与打包复验见“构建与签名验证记录”；退出决策状态机有单元测试
  （`QuitCoordinatorTests`，由 CI 运行）。退出行为说明同步到
  [架构说明](architecture.md) 与 [设置、工作目录与退出行为](settings-and-workspace.md)。

### 2. 更新检查：缓存回退结论按当前本机版本现算（#74 / PR #77）

- **问题**：读取缓存回退时沿用条目里当时写下的结论（`decodedStatus`）。用户后来升级或降级了
  本机版本，缓存仍按写入时的判断显示“已是最新”或“有新版本”，与本机实际版本脱节。
- **行为变化**：缓存条目新增“写入时的本机版本”，读取时要求该字段存在（旧缓存缺字段 →
  `undecidable()`，按“结果不可用/unknown”处理）；结论改用与 `304 Not Modified` 相同的
  `UpdateVersionVerdict.status(installed:upstream:)` **现算**；可信度只在本机版本与当前一致时沿用。
- **用户可见后果**：菜单与“更新检查偏好设置”里的版本结论不再与本机实际版本脱节（不会出现
  “已是最新”但本机低于上游，或“有新版本”但本机与上游相同）。
- **边界**：旧缓存文件会整体降级为“不可判定”，下一次网络检查或清缓存后恢复；来源语义
  （`network` / `cached-fallback` / `unavailable`）与“**缓存回退只提示、不驱动自动安装**”的既有
  约束不变。说明同步到 [架构说明](architecture.md) 与 [隐私说明](privacy.md)。

### 3. 秘密扫描：规则补齐、抑制标记收紧（#75 / PR #78）

- **问题**：扫描器漏报 `AWS_SECRET_ACCESS_KEY=…`、`PASSWORD=` / `API_KEY=` / `SECRET_KEY=`、
  `DATABASE_URL=postgres://user:pass@host`、`Authorization: Bearer <jwt>`、JSON `{"password": …}`、
  YAML/TOML `password: value`、`xoxb-…`、`sk_live_…` 等形状；而且任意行只要带
  `# scan-secrets: allow` 就能静默通过。
- **行为变化**：键值匹配改为大小写不敏感并覆盖 JSON / YAML / TOML；新增连接串口令、Bearer
  token、`gh[pousr]_`、`xoxb-` / `xoxp-`、`sk_live_` / `sk-proj-`、`AKIA…`、age 私钥与
  PEM/OpenSSH 私钥头等规则；抑制标记必须写成 `# scan-secrets: allow(reason=…)` 且理由非空，
  **被抑制的行仍会打印并计入摘要**，被拒绝的抑制标记也算命中；`--self-test` 为每条新规则
  增加了“命中样例”与“近似样例不命中”。
- **用户可见后果**：CI 的 `scan-secrets` 门禁更容易拦住真实凭据形状，不再能靠一句注释静默绕过；
  按 `CONTRIBUTING.md` 的清单，审阅者还要核对结尾的 `scan-secrets: suppressed N lines` 与是否
  出现 `scan-secrets: rejected` 行。
- **边界**：仍是**模式化规则**，不覆盖所有秘密形态；`allow(reason=…)` 是刻意保留的显式豁免
  路径，需要逐条评审。

### 4. 日志：子进程输出改走管道 + 应用侧串行 O_APPEND 写入（#73 / PR #79）

- **问题**：①日志轮转只做 `moveItem` + 新建文件，而子进程的 stdout/stderr 仍是旧 inode 上的
  文件描述符（服务启动时 `dup2` 过），轮转后子进程继续写入已被 unlink 的文件：日志看不到，
  磁盘占用也没有上限。②应用侧用自己的 fd + `seekToEnd()` + `write`（不是 `O_APPEND`）写日志，
  并发写互相覆盖；审查实测约 **3%** 的应用侧写入被吃掉。
- **行为变化**：子进程 stdout/stderr 改为管道，应用侧用**一条串行队列**完成读取 → 脱敏 →
  写入，所有写入走同一个 `O_APPEND` 句柄；并把“整份读取 + 逐行脱敏 + 原子重写”的历史日志
  迁移从启动路径移出主线程（原来会造成约 **3.9 s** 的主线程冻结）。
- **用户可见后果**：轮转后不再丢日志；应用启动更快；并发日志写入不再互相覆盖。
- **边界**：轮转语义、保留份数与脱敏规则都没有放宽——每份上限 10 MB、保留 5 份
  （`Sources/LogWriter.swift:9-10`）。机制说明同步到
  [日志与诊断导出](logging-and-diagnostics.md)。

### 5. 设置窗口单例、诊断导出后台化、外部进程 argv 遮罩（#81 / PR #87）

- **问题**：①每次打开设置都会新建窗口控制器并覆盖引用，旧窗口残留且仍可写回配置；
  ②“诊断导出”在主线程串行运行外部命令（没有超时），导出文本还会包含外部监听进程的完整
  argv；③⌘W 只是把主窗口 `orderOut` 隐藏，退出确认 sheet 会把隐藏的窗口拉回来。
- **行为变化**：设置窗口用单例复用（`ReusableControllerStore`，打开前用当前配置刷新控件）；
  诊断导出改为“提醒 → 后台串行队列探测（**单命令 3 秒超时**，超时后 `SIGTERM`/`SIGKILL`
  降级，且只针对自己启动的进程）→ 回主线程组装并复制”；外部进程 argv 复用
  `PiProcessInspector.commandSummary` 遮罩；失败字段统一为“无法读取（命令超时或失败）”；
  主窗口被 ⌘W 隐藏时，退出确认改用应用级模态。
- **用户可见后果**：设置窗口不会重复堆积、旧窗口不会改坏新配置；诊断导出不再长时间冻结界面，
  也不会把其它进程的命令行原样带进诊断文本；隐藏主窗口后退出确认仍然可见。
- **边界**：探针只服务于诊断展示，命令超时后不强杀无关进程；单命令超时 3 秒。开发中遇到过
  GitHub push protection 拒绝测试夹具里的凭据字面量（repository rule violation），最终改成
  运行时拼接；本地 `allow(reason=…)` 豁免只对本仓库的离线扫描有效。

### 6. CI 抖动：后台日志断言改用确定性排空屏障（#88 / PR #90）

- **问题**：同一个提交在不同 run 上时通时不通；失败点是
  `PiWebDesktopTests/LogWriterTests.swift:327`
  （`XCTAssertTrue failed - 至少要轮转过 3 次`）与
  `PiWebDesktopTests/ServiceManagerTests.swift:1810`
  （`XCTAssertTrue(log.contains("启动失败"), log)`）。四个并行 PR 中三个被无关失败拦下。
  根因是 #73 把日志写入/轮转移到了后台串行队列，测试在副作用落地之前就做了断言。
- **行为变化**：在断言前用生产代码里的排空原语与新增的测试/退出路径屏障等待写入完成，**不用
  固定 `sleep`**，也不放宽断言；同类断言在全仓库统一加固；测试约定记录在
  [开发说明](development.md)。
- **用户可见后果**：CI 不再因为无关抖动失败，合并更快；对应用运行时行为没有影响。
- **边界**：这是测试侧加固；排空屏障本身依赖生产代码提供的同步点。

### 7. 服务启动/停止：状态机代次校验与会话预算（#80 / PR #84）

- **问题**：①启动失败计数只在真正 launch 时清零，30 秒超时后点“重试”会立刻用旧失败结论直接
  弹窗（0 次轮询）；②异步 ready 回调没有代次校验，**停止之后才到达的 `ready=true` 会把状态改回
  running** 并加载页面；③每个入口都挂一条新的轮询链、共享同一份启动预算，多次启动会成倍耗尽
  预算并产生多份提示；④`stopService` 的提前返回分支不清理 `isStoppingService`，之后启动会被
  永久拒绝。
- **行为变化**：为启动/停止/重启引入代次（`lifecycleGeneration`，`Sources/ServiceManager.swift:554`、
  `:897`），所有异步回调先校验代次，过期回调只记日志、不改状态；启动预算按“一次启动会话”记账
  （`isCurrentStartupSession`，`Sources/ServiceManager.swift:1194`），重试重新开始轮询；同一次启动
  只允许一条轮询链；停止路径用 `defer` 集中清理停止标志。
- **用户可见后果**：不再出现“状态显示运行中但其实没跑”、重复弹窗、“重试”直接失败、启动按钮
  永久灰掉。
- **边界**：只影响状态机与提示；服务进程的启动方式与超时值没有变化。

### 8. 隐私遮罩与依赖探针：补齐开关形态、非绝对路径判 `unknown`、超时与取消（#82 / PR #85）

- **问题**：①命令遮罩只覆盖小写 `-p` / `-t` / `-s` 的“紧跟”形态，`-p=VALUE`、`-P VALUE` 这类
  在两层脱敏之后仍会原样进入命令摘要（可能出现在诊断文本与手动更新确认框）；②非绝对路径的
  `pi` 脚本被归为 `.notPi`（应为“无法确定”）；③依赖探针没有超时与取消，探针挂住就会永久关闭
  启动门控，界面也没有任何提示。
- **行为变化**：短开关大小写不敏感，覆盖 `-p VALUE`、`-p=VALUE`、`-pVALUE`、多字母短开关，
  长开关及其 `=` 形态一并覆盖；非绝对路径或无法解析镜像的候选一律判 `unknown`，并补了相对路径、
  断链、无执行位用例；探针加超时与取消（可注入），超时按“不可用”处理并给出可读原因。
- **用户可见后果**：诊断导出与手动更新确认框里不会出现未脱敏的敏感开关；相对路径脚本不会再被
  误判成“没有安装 pi”；探针卡死时不再无声地禁止启动。
- **边界**：遮罩仍是**模式化**的，不符合形状的自由文本会原样保留——不要把秘密直接放进命令行；
  探针超时的判据是“本次探测没有结论”，不是“依赖不存在”。

### 9. 发布脚本加固（#83 / PR #86）

- **问题**：①`check-release-version.sh` 只对预发布 tag 校验 `CURRENT_PROJECT_VERSION`，正式版
  tag 不校验；②发布路径沿用 swiftc 默认 `-Onone`；③`smoke.sh` 的看门狗被 kill 后会留下孤儿
  `sleep`；④`package-release.sh` 对包内容没有白名单，资产名也不含 build 号。
- **行为变化**：正式版 tag 也参与 build 校验（tag↔build 规则写进 [发布流程](releasing.md)，含
  错配必失败的用例）；`build.sh` 发布路径启用优化（`-O -wmo`，附改前/改后产物大小对比）；
  `smoke.sh` 看门狗清理；`package-release.sh` 增加**包内容白名单**，资产名改为
  `<App>-<MARKETING_VERSION>+build.<BUILD>.zip`（`Scripts/package-release.sh:900`），
  `.sha256` 与 `.evidence.md` 使用同一前缀。
- **用户可见后果**：资产名里直接带 build 号，下载页与证据文件不用解包 `Info.plist` 就能发现
  build 与 tag 不一致；包内出现白名单之外的文件会在打包阶段失败，而不是发到 Releases。
- **边界**：命名规则只对**新**资产生效，历史 Release 的旧名字（不含 `+build.N`）不回写；
  `CFBundleVersion` 必须是十进制整数，否则打包直接失败。

### 10. 依赖探测：子进程统一使用合并后的工具 `PATH`（#89 / PR #91）

- **问题**：用户报告从 Finder 启动时，Homebrew 安装的 `pi` 检测不通过、应用停在诊断页。最小
  复现（在 main `b9c493f` 上）：

  ```bash
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=$HOME ./probe
  # canStartService=false；pi status=unknown；node 不受影响
  ```

  原因：`pi` / `pi-web` / `npm` 是 `#!/usr/bin/env node` 包装脚本，探测子进程继承了 Finder
  launchd 的最小 `PATH`，找不到 `node` 就直接 exit 127 → 被判 `unknown` → 启动门控拦住。
  服务启动路径自带一份 `PATH` 拼装，依赖探测路径此前没有，两处不一致；本版起三处（依赖探测、
  更新子进程、服务启动环境）共用 `Sources/ToolPath.swift` 的结果（服务启动环境在
  `Sources/ServiceManager.swift:149` 注入）；`node` 本身是 Mach-O 二进制，所以不受影响。
- **行为变化**：新增 `Sources/ToolPath.swift` 作为唯一来源构造子进程 `PATH`，顺序为：应用 `PATH`
  → 登录 shell `PATH` → 已知目录（Homebrew arm64/Intel、MacPorts、用户级前缀）→ `node` 所在
  目录 → `npm prefix -g` 的 bin；去重，不引入凭据类变量。登录 shell 不写死 zsh（用户数据库 →
  `$SHELL` → `/bin/zsh`），带超时、单次缓存，拿不到值时再试交互式查询。`DependencyChecker`、
  `ComponentInstallation` 的所有只读探测、Pi CLI 与扩展包更新命令、`ServiceManager` 的服务启动
  环境全部复用同一份 `PATH`；探测失败仍给出可读原因。
- **用户可见后果**：Finder 启动下 Homebrew 安装的 `pi` 不再被判 `unknown`。同一复现命令在修复后
  得到 `canStartService=true`，`node` / `pi` / `pi-web` 均为 `ok` + `verified`
  （证据见 PR #91；本版本机未重跑该探针）。
- **边界**：新增一次登录 shell `PATH` 查询（本机只读、不联网）；`PATH` 合并只解决“工具找不到”，
  不改变依赖必须自行安装这一前置。

### 11. 扩展包更新执行器：每轮独立状态、身份与回滚结论不超出证据（#92 / PR #94）

本项与下一项是本版的重点修复。审查（W2 B 组，16 条）中本版处理 **B-1 / B-2 / B-3 / B-6 / B-7**，
其余条目见“已知问题”。

- **问题**：
  - **B-1**：执行器是一次性的。第一次运行后终态标志不再复位，第二次点确认会被**静默丢弃**、
    也不投递 completion → `piPackageUpdateInProgress` 永远为真，此后所有入口失效，只能重启应用；
    批量更新时第 2 个包起不会执行。
  - **B-2**：超时与排水宽限竞态。命令在 deadline 前 ≤ 0.5 s 以 0 退出、但管道还没读到 EOF
    （有后台/孙进程持有 stdout 写端）时，成功会被判成超时，并写一条不实的“已放弃”记录。
  - **B-3**：身份校验同义反复——把“计划里期望的包名”当成“检测到的包名”传入核对，等于没有核对。
  - **B-6**：安装失败时断言“仍在使用旧版本”这类没有探针支撑的结论。
  - **B-7**：没有内容哈希时，size/mtime 缺失被当成“一致”。
- **行为变化**：每轮运行有独立的运行状态（`resetRunStateLocked()`，
  `Sources/PiPackageUpdateAdapter.swift:1227`），忙时**拒绝但必须回调** `.notAttempted`
  （`Sources/PiPackageUpdateAdapter.swift:1164`，回调在 `:1168`）；被放弃但退出未确认的旧子进程跨轮保留在
  `abandonedProcesses` 中，退出确认前同样按忙拒绝；超时判定在有“待完成”进程时不生效
  （`pendingFinish`），只在 `exitCode == nil` 时保留 `timedOut`，超时计时有界让出（0.2 s × 5），
  排水宽限可注入；协调器不再把计划包名当检测值（`Sources/UpdateVerifier.swift:438`）；安装失败
  新增回滚资格 `.stateNotVerified`（`Sources/UpdateTransaction.swift:364` 等）；无内容哈希时缺失的
  size/mtime 判“未验证”，两者都缺 → `.cannotAutomaticallyRollback`
  （`Sources/UpdateTransaction.swift:680`）。
- **证据（PR #94 正文记录，本机未复跑）**：修复前第二次 completion 不到达、`exit=0` 却
  `timedOut=true`、`failure=timedOut`、已放弃记录=1；修复后两次都到达（`exit=0`、`timedOut=false`、
  `abandoned=false`、`failure=nil`、已放弃记录=0），批量两批都 `succeeded`、历史条目=2。
- **用户可见后果**：扩展包可以连续更新多次、批量更新每个包都会执行；正常退出不再被误记成“已
  放弃”；安装失败后的文案不再声称“仍在使用旧版本”或“系统状态未改变”；无法自动回滚时明确写
  “没有执行任何回滚动作”（`Sources/PiPackageUpdateAdapter.swift:1489-1490`）。
- **边界**：B-2 有固有边界——子进程结束回调的投递延迟超过 0.2 s × 5 时仍按超时处理；旧子进程
  永不退出时门控保持关闭，后续计划返回 `.notAttempted`（重启应用即复位，命令实例是应用级的，
  `Sources/PiWebApp.swift:225`）。

### 12. 应用自更新安装器可重入、事务门控、菜单不跨组件误伤（#93 / PR #95）

审查（W2A，A-1 … A-8 + 测试质量）在本版全部处理，并在复核后补修 F1–F4。

- **问题**：
  - **A-1**：安装器一次性——第二次 `install()` 被静默丢弃且永不回调，界面永远停在“正在更新”。
  - **A-2**：重叠 install 会真的再启动一个子进程并覆盖共享状态（实测启动 2 个子进程、只收到
    1 个回调），旧定时器还会用新句柄 `killpg` 误杀。
  - **A-3**：放弃等待后立刻关闭读端，运行中的子进程下一次写 stdout 会死于 `SIGPIPE` 或
    `EPIPE`——与“绝不向子进程发信号”的契约在效果层面矛盾。
  - **A-4**：手动更新入口没有“更新进行中”门控；**A-5**：检测安装状态的同步调用排在取消之后；
    **A-6**：非 UTF-8 分块整段丢弃；**A-7**：参数策略不是注入防线；**A-8**：测试质量（每个测试
    都用新实例，没有“第二次 install”用例）。
- **行为变化**：每次 `install` 有独立的 `Attempt`（`Sources/PiWebUpdateAdapter.swift:985`）；同一
  对象在上一轮结束后**可以再次安装**；真正重叠时整体拒绝并回调 `alreadyRunning`
  （`Sources/PiWebUpdateAdapter.swift:1073`），不启动第二个子进程；放弃等待后**不再关闭读端**，
  句柄保留到 EOF（`Sources/PiWebUpdateAdapter.swift:1266`、`Sources/PiCLIUpdateAdapter.swift:880`）；
  门控提升到**整轮更新事务**（安装 + 更新后重检测 + 启动服务 + 健康检查）；手动入口与菜单项在
  此期间明确提示“更新正在进行”并给出原因（`Sources/PiWebApp.swift:1388`、`:1428`、`:1595`、
  `:1649`），自动路径记 `.notAttempted(.updateAlreadyInProgress)` 并延后；菜单的禁用状态只由本
  组件自己的三个输入合成（`UpdateEntryState`，`Sources/PiWebUpdateAdapter.swift:30`），避免跨
  组件误伤；分块输出改用 lossy 解码，不再丢弃整块（`Sources/PiWebUpdateAdapter.swift:1217`、
  `Sources/PiCLIUpdateAdapter.swift:757`）。
- **证据（PR #95 正文记录，本机未复跑）**：swiftc `-typecheck` 退出 0、error 0；三个独立探针
  共 45 项全过（含“第二次 install 也有终态回调”“重叠 install 延迟 0.000 s 拒绝、子进程数=1”
  “放弃后子进程仍能写 stdout”“非 UTF-8 分块 lossy 保留”“npm 非绝对路径被拒”）；复核补修后再跑
  18 项全过。本机没有 Xcode，未能运行 `xcodebuild test`。
- **用户可见后果**：一次更新结束后可以立刻再更新，不必重启应用；并发点击不会留下“永远正在
  更新”的界面；放弃等待不会把仍在运行的子进程写死；菜单被置灰时会说明原因——“（正在更新）”
  或“（上一次更新未确认退出，重启应用可恢复）”（`Sources/PiWebUpdateAdapter.swift:59`）。
- **边界**：web 侧保留“未确认退出的子进程”计数，子进程永不退出时会保守拒绝到重启；菜单里的
  “重启应用可恢复”提示目前只覆盖 CLI / Web 两个入口，扩展包门闩一路没有；`UpdateEntryState`
  初版放在 `Sources/PiWebApp.swift`，因不属于 `PiWebDesktopTests` target 导致 CI 编译失败
  （`Cannot find 'UpdateEntryState' in scope`，run `35490732248`），最终移到
  `Sources/PiWebUpdateAdapter.swift:30`。

### 13. 文档与仓库同步

- [架构说明](architecture.md)（74 行变更）、[日志与诊断导出](logging-and-diagnostics.md)（106）、
  [隐私说明](privacy.md)（29）、[发布流程](releasing.md)（100）、[开发说明](development.md)（32）、
  [设置、工作目录与退出行为](settings-and-workspace.md)（14）随实现同步更新，覆盖退出协调、
  缓存结论现算、日志管道与 `O_APPEND`、遮罩与探针边界、测试排空屏障约定、tag↔build 规则、
  包内容白名单与资产名带 build 号。
- `CONTRIBUTING.md`（15 行变更）、[orca 工作流](orca-workflow.md)、
  [Alpha 发布门槛清单](alpha-release-checklist.md) 同步了秘密扫描的抑制标记格式与 `rejected`
  行核对要求（由 #78 引入）。
- 新增本文件；版本与 build 在 `Configuration/AppIdentity.xcconfig` 中更新为 `0.1.0-alpha.5` / `5`。
- 本版改动来源是仓库外的内部代码审查记录（W2A / W2B / W3 / W4）；这些报告本身没有提交到仓库。
  本版**新增并提交了** [alpha.5 更新流水线与工具 PATH 安全审查（delta）](security-review-alpha.5.md)：
  范围是 alpha.4 → alpha.5 的改动，结论为**阻断项 0 项**（B1–B9 未触发），另有 1 条中危（M-1，
  启动路径上的有界主线程阻塞）与 7 条低危（L-1 … L-7）非阻断发现，以及 3 条信息级记录。

## 更新检查访问的域名、频率与关闭方式

只读版本检查**不是遥测**：请求只用于比较“本机版本”与“上游最新版”，不携带使用数据、会话内容、
认证信息或诊断报告。**本版没有改变域名、频率或关闭方式**（`Sources/UpdateChecker.swift:119-120`
的两个主机常量未变）；#77 只修正了缓存回退结论的现算方式。

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
  时间戳、条件请求字段与**写入时的本机版本**；读取时逐项校验结构（见上文 #77）。忽略版本、
  更新开关、失败警告、更新历史与「已放弃」记录在 UserDefaults（`updateChecks.*`）。
- 上游服务会看到请求的源 IP、`User-Agent` 与请求时间，按各自隐私政策处理接入日志。完整说明见
  [隐私说明](privacy.md)。

## 自动更新的准确边界

**会做的**（两个开关默认关闭，且都要求组件来源可信 + 目标版本来自**本次网络**检查结果 + 没有
未清除的「已放弃」记录）：

| 路径 | 触发方式 | 命令（参数数组） | 前置条件 | 超时行为 |
| --- | --- | --- | --- | --- |
| Pi Web（#20/#62） | 应用启动时，设置打开 | `npm install -g @agegr/pi-web@<目标版本>` | 来源 `npmGlobal` + `verified`；目标 `verified` 且更高；检查结果来源 `network`；托管服务未运行；无未清除的「已放弃」记录；没有进行中的更新事务 | 5 分钟；只对本次启动的**独立 npm 子进程组**发一次 `SIGTERM`，不发 `SIGKILL`，未确认派生进程结束 |
| Pi CLI（#21/#62） | 拿到当次检查结果后，设置打开 | `pi update --self` | 来源 `npmGlobal`/`pnpmGlobal` + `verified`；目标 `verified` 且更高；检查结果来源 `network`；当次检查为 `noProcesses`；无未清除的「已放弃」记录；没有进行中的更新事务 | 10 分钟；**只放弃等待，不发送任何信号** |
| Pi 扩展包（#22/#62） | 用户在确认框里显式确认 | `pi update npm:<包名>` | 来源 `npmGlobal` + `verified`；目标 `verified` 且更高；检查结果来源 `network`；当次检查为 `noProcesses`；用户确认（有记录时先展示记录）；执行器不忙 | 10 分钟；**只放弃等待，不发送任何信号** |

**本版新增的门控与可重入语义**（#93 / PR #95、#92 / PR #94）：

- 一次更新 = **整轮更新事务**：安装（或执行 `pi update`）+ 更新后重检测 + 启动服务 + 健康检查。
  事务进行中的手动入口与菜单项会被门控挡住并显示原因；自动路径记为“未执行（已有更新正在
  进行）”并延后，而不是静默丢弃。
- **可重入**：同一组件上一轮结束后可以立刻开始下一轮，不需要重启应用；真正并发时整体拒绝，
  不会启动第二个安装进程。
- **放弃等待但退出未确认**的子进程：在确认退出前保守拒绝新一轮更新（web / CLI 的菜单会显示
  “（上一次更新未确认退出，重启应用可恢复）”）；重启应用后这个未确认窗口不保留。
- **放弃等待不再关闭读端**，运行中的子进程可以继续写到 EOF，不会被管道断裂间接杀死。
- 扩展包路径：忙时也必须回调 `.notAttempted`（“更新命令未被执行（执行器上一次运行尚未
  结束）”，`Sources/PiPackageUpdateAdapter.swift:989`）；在排水宽限窗口内以 0 退出的命令不再
  被误记成“已放弃”；安装失败不再写“仍在使用旧版本”，无法回滚时写“没有执行任何回滚动作”。
- 信号语义不变：Pi Web 只对自己启动的独立进程组发一次 `SIGTERM`；Pi CLI 与扩展包**不发任何
  信号**。

**不会做的**：

- 不会下载或安装桌面应用自身（`Pi Web Desktop.app`）的新版本。
- 不会在来源不可信（Homebrew、nvm/mise、git checkout、本地路径、未知，或可信度不是“已验证”）时
  自动安装；这些来源只显示命令文本或按来源文档提示。
- 不会用本机缓存回退的结果自动安装或自动更新（缓存回退只提示，并标注来源、缓存写入时间与
  写入时的本机版本）。
- 不会在无人值守时更新 Pi 扩展包：不点确认就不会执行（取消或直接关闭对话框都不执行）。
- 不会结束、暂停、接管任何 Pi 会话，也不会向任何 Pi 进程发送信号（#21 / #22 的接口里没有这类
  方法；#20 的唯一信号是它自己启动的 npm 子进程组，见 #62；#95 进一步保证放弃等待不会通过
  关闭管道间接杀死子进程）。
- 不会保证更新成功、不保证所有来源都能回滚，也不会在失败后卸载新版本或恢复旧文件内容。
- 不会校验被放弃的进程是否已经结束，也不保证 `SIGTERM` 一定让 npm 子进程结束。

## 本机实测环境与版本（可追溯）

下表来自维护者一台 Apple Silicon 真机的实测输出，**不是 CI runner**；每一行的值都能用第三列的
命令复现。CI runner 的版本不会写进本说明。

| 项目 | 实测值 | 实测命令（本机输出摘要） |
| --- | --- | --- |
| 机器与芯片 | Apple M4（`Mac16,10`） | `sysctl -n machdep.cpu.brand_string` → `Apple M4`；`sysctl -n hw.model` → `Mac16,10` |
| macOS | 27.0（BuildVersion `26A428`），满足 `>= 14` | `sw_vers` |
| 架构 | arm64 | `uname -m` → `arm64` |
| Node.js | v24.21.0 | `node --version` → `v24.21.0` |
| npm | 11.19.0；全局前缀 `/opt/homebrew` | `npm --version` → `11.19.0`；`npm prefix -g` → `/opt/homebrew` |
| Pi CLI（`@earendil-works/pi-coding-agent`） | 0.86.0 | `pi --version` → `0.86.0`；`npm ls -g --depth=0` → `@earendil-works/pi-coding-agent@0.86.0` |
| `@agegr/pi-web` | 0.9.1 | `npm ls -g --depth=0` → `@agegr/pi-web@0.9.1` |
| Swift 编译器 | Apple Swift 6.4（`swiftlang-6.4.0.34.1 clang-2100.3.34.1`，target `arm64-apple-macosx27.0.0`） | `swift --version` |
| Xcode | 无 Xcode，只有 Command Line Tools | `xcode-select -p` → `/Library/Developer/CommandLineTools`（`xcodebuild` 在本机不可用） |
| 应用包身份 | 本机脚本构建产物实测 `CFBundleShortVersionString=0.1.0-alpha.5`、`CFBundleVersion=5`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon`、`CFBundleExecutable=PiWebDesktop`；`./Scripts/check-identity.sh` → `check-identity: PASSED (45 checks)` | `Configuration/AppIdentity.xcconfig`；`./Scripts/build.sh` 后用 `./Scripts/check-identity.sh` 与 `plutil -p` 复核（Xcode 构建产物与 `.xctest` bundle 仍由 CI 覆盖，本机没有 Xcode） |

`pi-web` 当前（0.9.1）没有 `--version` 选项（执行会报 `Unknown option '--version'`），核对版本
请用 `npm ls -g @agegr/pi-web` 或读取该包 `package.json` 的 `version`。

## 安装

1. 从本 Release 的 assets 下载 `{{ZIP_NAME}}` 与它的 `.sha256`、证据 Markdown。按
   [发布流程](releasing.md) 的命名规则，本版资产名预期为
   `Pi-Web-Desktop-0.1.0-alpha.5+build.5.zip`（**以 assets 实际名称为准**）。
2. 校验下载的 ZIP（在下载目录执行；文件名以上一步的实际值为准）：

   ```bash
   shasum -a 256 -c {{ZIP_NAME}}.sha256
   ```

   输出必须包含 `{{ZIP_NAME}}: OK`；不一致就不要安装。
3. 解压：

   ```bash
   ditto -x -k {{ZIP_NAME}} .
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
- **本版起探测子进程使用合并后的工具 `PATH`**（`Sources/ToolPath.swift`，见上文 #89）：应用
  `PATH` → 登录 shell `PATH` → 已知目录 → `node` 目录 → npm 全局 bin。因此在 Finder 启动
  （launchd 最小 `PATH`）下，Homebrew 安装的 `pi` 不再被误判成 `unknown`；依赖探测、更新命令与
  服务启动环境使用的是同一份 `PATH`。
- **探针超时与取消**（#82）：依赖探测带超时与取消，超时按“不可用”处理并给出可读原因，不会
  静默永久关闭启动门控；非绝对路径或无法解析镜像的候选一律判 `unknown`。
- 硬性前置（Node.js / Pi CLI / pi-web）缺失、报告缺项或版本无法解析时，应用停在依赖诊断页：
  列出要处理的项与下一步，启动/停止/重启按钮全部禁用。缺项、`unknown` 与“缺失”一样不放行。
- 前置满足但首次设置未完成时，同样先显示诊断页；点“开始使用 Pi Web”或“重新检测”后进入主窗口。
  启动前自动更新（#20）在这条启动路径上先判定：需要时先完成一次覆盖 Pi Web 的版本检查，再决定
  安装还是照常启动服务；检查失败只会跳过自动更新，不影响服务启动。
- 诊断窗口可随时从菜单“服务 → 依赖与环境诊断…”打开；“复制安装命令”只复制静态命令，
  应用不会执行安装命令、不调用 `sudo`、不联网、不读取凭据。诊断导出在后台串行运行探针
  （单命令 3 秒超时），不再阻塞主线程（#81）。
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

发布产物由 `.github/workflows/release.yml` 在 tag 上打包时生成，**发布值以 Release 草稿与 assets
为准**（同一提交反复打包会得到不同的 SHA-256，原因见 [发布流程](releasing.md#可复现性与诚实的边界)）。
本机演练（同步目录之外的临时 worktree，提交 `838cb25`；演练后已清理）的对应值记在“构建与签名验证
记录”一节，只用于追溯，**不用于发布核对**。

- 资产：`{{ZIP_NAME}}`（按命名规则预期为 `Pi-Web-Desktop-0.1.0-alpha.5+build.5.zip`；以及同前缀的
  `.sha256`、证据 Markdown，名称以 Release assets 为准）
- 字节数：`<发布后由协调者填写>`（本机演练值为 1,506,741 字节，仅供追溯）
- SHA-256：`<发布后由协调者填写>`（本机演练值为 `fb71823f68a4b9588ea08e31c4729b1891f8c452dea4a90e5fff1f28955fcbe1`，仅供追溯）
- 校验命令（下载目录执行）：

  ```bash
  shasum -a 256 -c {{ZIP_NAME}}.sha256
  ```

- 校验失败时不要安装，请在 Release Issue 或普通 Issue 中报告。
- **不要使用本机演练值当发布值**：发布值由 `release.yml` 在 tag 上运行
  `Scripts/package-release.sh` 生成，写在 `dist/release-metadata.env`（`ZIP_NAME` / `SHA256` /
  `COMMIT`）里；Release 草稿的正文与 checksum 必须从该 workflow 产物复制。

另外，`package-release.sh` 生成的 evidence Markdown 会记录 `codesign`/`spctl` 原始输出、ZIP 名称、
SHA-256、构建提交与打包环境；它明确标注打包环境不等于真机实测环境。本文件里的哈希与字节数只有
本节这两行，且都标注为本机演练值；其它任何地方都不写具体值（清单见文末）。

## 构建与签名验证记录（本机演练）

**本版（v0.1.0-alpha.5）在提交前的同一工作区上跑了一遍本机门槛**：`sh -n`、空白检查、脚本构建、
身份检查、tag/版本比对、`codesign` 验签与 `-dv`、`spctl`、`smoke.sh` 两种模式、秘密扫描（自检 +
仓库扫描）、打包与 ZIP/checksum/解包复验。下表是本次的实际输出；**打包与签名类步骤在同步目录之外
的临时 worktree（`/tmp/alpha5-rehearsal`，提交 `838cb25`）执行**，原因见下方“iCloud/File Provider
边界”。`xcodebuild build` / `xcodebuild test`、GUI 手工验收、真实更新执行仍不在本机范围内。

| 命令 | 结果 |
| --- | --- |
| `sh -n Scripts/*.sh` | 退出 0（无输出） |
| `git diff --check` | 退出 0（无输出） |
| `./Scripts/build.sh` | 首次在 `~/Documents`（iCloud 同步）内失败：`resource fork, Finder information, or similar detritus not allowed`；`rm -rf build/Pi-Web-Desktop.app` + `xattr -cr build` 后重跑退出 0：`Built: build/Pi-Web-Desktop.app`、`Mach-O 64-bit executable arm64` |
| `./Scripts/check-identity.sh` | `check-identity: PASSED (45 checks)`；bundle `CFBundleShortVersionString=0.1.0-alpha.5`、`CFBundleVersion=5`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`LSMinimumSystemVersion=14.0`、`CFBundleIconFile=ApplicationIcon` |
| `sh Scripts/check-release-version.sh v0.1.0-alpha.5` | 退出 0：`check-release-version: PASSED (tag v0.1.0-alpha.5, MARKETING_VERSION 0.1.0-alpha.5, CURRENT_PROJECT_VERSION 5)`。脚本只做字符串比对，**不检查 git tag 是否存在**（本次 tag 尚未创建） |
| `codesign --verify --deep --strict build/Pi-Web-Desktop.app` | 同步目录内两次失败（`code has no resources but signature indicates they must be present`、`resource fork, Finder information, or similar detritus not allowed`）；在 `/tmp/alpha5-rehearsal` 的打包流程内通过：`valid on disk`、`satisfies its Designated Requirement` |
| `codesign -dv --verbose=4 build/Pi-Web-Desktop.app` | `Identifier=PiWebDesktop`、`Format=app bundle with Mach-O thin (arm64)`、`flags=0x20002(adhoc,linker-signed)`、`Signature=adhoc`、`TeamIdentifier=not set`、`Info.plist=not bound`、`Sealed Resources=none`（脚本构建产物的 linker 签名）；演练 worktree 打包后的 bundle 为 `Identifier=io.github.su-luoya.pi-web-desktop`、`Sealed Resources version=2 rules=13 files=1` |
| `spctl -a -vv build/Pi-Web-Desktop.app` | 输出 `rejected`；`spctl exited with status 3: Gatekeeper did not accept the bundle, which is the expected result for an ad-hoc, non-notarized app`（未公证 ad-hoc 产物的预期结果） |
| `./Scripts/smoke.sh`（启动模式） | app exit 0 after 0s；标记 `smoke: ready` |
| `./Scripts/smoke.sh`（诊断模式） | app exit 0 after 1s；标记 `smoke: diagnostics items=6 blockers=3` 与 `smoke: diagnostics ready`；脚本整体退出 0 |
| `./Scripts/scan-secrets.sh --self-test` | 退出 0；`self-test: PASS (all rules fired, look-alikes stayed clean, suppression and rejection verified, untracked-file gate verified, samples cleaned up)` |
| `./Scripts/scan-secrets.sh` | 退出 0；`scan-secrets: suppressed 15 lines`、`scan-secrets: PASS (no matches in tracked files; no untracked files)`。本版 suppressed 行数比 alpha.4 记录的 11 行多 4 行，逐行清单：`KeychainStoreTests.swift:496`、`LogRedactorTests.swift:76/83/126`、`LogWriterTests.swift:143/176`、`PiWebUpdateAdapterTests.swift:444/878`、`ServiceManagerTests.swift:1865`、`ToolPathTests.swift:242/330/331/332/581`、`UpdateTransactionTests.swift:859`（全部是测试夹具的内联 `allow(reason=…)` 豁免）。计数口径：`git grep -c 'scan-secrets: allow'` 在本版测试目录下有 25 处标记，扫描器只把落在候选行上的 15 行计为 suppressed；上一版记录只给了总数、没有逐行清单，因此这里不做逐条归因 |
| `./Scripts/package-release.sh --tag v0.1.0-alpha.5` | 同步目录内两次失败（先是 `code has no resources…`，重试后 `Disallowed xattr com.apple.FinderInfo found on …/build/Pi-Web-Desktop.app`）；在 `/tmp/alpha5-rehearsal`（提交 `838cb25`）成功：`package-release: OK`，产出 `Pi-Web-Desktop-0.1.0-alpha.5+build.5.zip`、`.zip.sha256`、`.evidence.md`、`release-metadata.env`（`VERSION=0.1.0-alpha.5`、`BUILD=5`、`COMMIT=838cb25…`），ZIP 1,506,741 字节、SHA-256 `fb71823f68a4b9588ea08e31c4729b1891f8c452dea4a90e5fff1f28955fcbe1`（演练值） |
| `unzip -l`（演练 ZIP） | 9 项：`Pi-Web-Desktop.app/` 及其 `Contents/{,_CodeSignature,MacOS,Resources}` 与 `Contents/Info.plist`、`Contents/MacOS/PiWebDesktop`、`Contents/Resources/ApplicationIcon.icns`、`Contents/_CodeSignature/CodeResources`；无 `__MACOSX/`，无源码、测试、日志或个人路径 |
| `shasum -a 256 -c`（演练 ZIP） | `Pi-Web-Desktop-0.1.0-alpha.5+build.5.zip: OK`（退出 0） |
| `ditto -x -k` + `plutil -p` + `codesign --verify --deep --strict` | 解压到 `mktemp -d` 后：`CFBundleShortVersionString=0.1.0-alpha.5`、`CFBundleVersion=5`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon`；解压出的 bundle 签名校验退出 0（临时目录已删除） |
| `./Scripts/check-identity.sh` 第 6 节（版本字面值回归） | `ok   no hardcoded MARKETING_VERSION outside Configuration/AppIdentity.xcconfig` |
| `xcodebuild build` / `xcodebuild test` / GUI 手工验收 / 真实更新执行 | 本机未执行：`xcode-select -p` → `/Library/Developer/CommandLineTools`，没有 Xcode；GUI 手工验收本轮未执行。由 CI 的 `macos-14` job 与维护者真机验收覆盖 |
| CI（提交 `6821ecd`，v0.1.0-alpha.5 的内容） | `build.yml`：PR #95 的 run `35491176141` 与 main push 的 run `35491357493` 均为 **success**；覆盖 `xcodebuild build` / `xcodebuild test`、`build.sh`、`check-identity.sh --test-bundle`、`smoke.sh`、秘密扫描与 `sh -n Scripts/*.sh` 等 |

**iCloud / File Provider 边界（为什么打包与签名复验在 `/tmp` 的 worktree 上执行）**：本机工作区在
`~/Documents`（iCloud 同步目录）内，File Provider 会把 `com.apple.FinderInfo` 贴回 bundle；该扩展
属性会让 `codesign --verify --deep --strict` 失败（`code has no resources but signature indicates
 they must be present`），并使 `package-release.sh` 在打包阶段中断
（`Disallowed xattr com.apple.FinderInfo found on …`）。这与 alpha.1 记录的 #15 是同类问题，`build.sh` /
`package-release.sh` 的清理与重试只能覆盖它被贴回的时机。因此打包与随后的 ZIP/checksum/解包复验在
同步目录之外、同一提交（`838cb25`）的临时 worktree 里执行（本机路径 `/tmp/alpha5-rehearsal`；该
worktree 与本次门禁日志在记录完成后已清理，可复现的持久标识是提交 `838cb25` 与本节输出摘要）。
这只影响本机演练记录：CI runner 在干净 checkout 上运行、不在同步目录内，不受影响；发布流程与产物
命名不变。

`./Scripts/smoke.sh`（在 CI 中）只验证窗口、诊断页与退出路径：两种模式都在临时 support 目录里
运行，不写真实 UserDefaults / Application Support / Logs，也不启动真实 pi-web；它不替代
`xcodebuild test`。

## 已知问题

- **更新执行器审查的剩余条目（W2B，本版只修 B-1 / B-2 / B-3 / B-6 / B-7）**：B-4、B-5、B-8 … B-13
  未修（同一份审查共 16 条；详细描述与证据见 PR #94 正文；本仓库没有该审查报告文件）。
- **应用自更新审查的剩余条目（W2A）**：**F5**（分块切断多字节 UTF-8 序列时诊断文本里会出现
  U+FFFD 替换字符）、**F6**、**F7** 未处理（编号与内容见 PR #95 正文的复核记录）。web 侧
  `Sources/PiWebUpdateAdapter.swift:968` 的全局投递队列保留（每轮只投一次终态，暂不影响语义）。
- **安装失败文案仍有两套**：CLI 与 Web 两路仍写“更新失败，仍在使用旧版本”
  （`Sources/PiCLIUpdateAdapter.swift:996`、`Sources/PiWebUpdateAdapter.swift:1310`），而扩展包
  一路已改为“更新失败，没有执行任何回滚动作：…”
  （`Sources/PiPackageUpdateAdapter.swift:1489-1490`）；`Sources/UpdateTransaction.swift:394` 与
  `:513` 两套文案也都还在。**这不是一句措辞问题**：前三处没有“旧文件没被改动”的探针支撑，本版
  修扩展包一路时正是因为这一点才改文案，CLI/Web 两路需在后续版本一并处理。
- **扩展包执行器的读状态接口仍缺 `isRunning`**：协议 `PiPackageUpdateRunning`
  （`Sources/PiPackageUpdateAdapter.swift:1051-1060`）只有 `run` 与 `abandon`，调用方无法查询
  “是否忙”，只能从 `.notAttempted` 结果得知。**注意**：该执行器本身的运行状态已按轮次复位
  （`resetRunStateLocked()`，`Sources/PiPackageUpdateAdapter.swift:1227`；`completeLocked` 置
  `running = false`，`:1396`），因此“执行器只能跑一次”已不再是本版状态；真正残留的是缺少读状态
  接口、以及“退出未确认的旧子进程”只能靠重启应用复位。
- **`abandon()` 落在排水宽限窗口时仍会写一条不实的「已放弃等待」历史记录**：三处实现都是无条件
  记录——`Sources/PiWebUpdateAdapter.swift:1144`（`stopWaitingLocked`）、
  `Sources/PiCLIUpdateAdapter.swift:606`、`Sources/PiPackageUpdateAdapter.swift:1144`。本版只修掉了
  **超时**路径的同类竞态（#94 的 B-2：`pendingFinish` 存在时不判超时）；用户取消/应用退出触发的
  `abandon()` 仍可能在子进程刚好退出时写记录。
- **「重启应用可恢复」提示只覆盖 CLI / Web 两个入口**：该文案来自 `UpdateEntryState`
  （`Sources/PiWebUpdateAdapter.swift:30`、`:59`）；扩展包门闩一路（执行器忙 / 等待未确认退出）
  没有对应的可见恢复提示。
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
- **仍未在本机执行 / 验证的项**：`xcodebuild build` / `xcodebuild test`（`xcode-select -p` 指向
  Command Line Tools，没有 Xcode）、GUI 手工验收（本轮未执行）、真实更新执行（#94 / #95
  的证据来自 PR 正文的探针，本机未复跑）。
- **已在本机实测的项**（同一批命令的输出见上文“构建与签名验证记录”）：`sh -n Scripts/*.sh`、
  `git diff --check`、`build.sh`、`check-identity.sh`（45 checks）、`check-release-version.sh`、
  `codesign --verify --deep --strict`、`codesign -dv`、`spctl`（退出 3，预期）、`smoke.sh` 两种模式、
  `scan-secrets.sh` 自检与仓库扫描、`package-release.sh`、`unzip -l`、`shasum -a 256 -c`、解压后的
  identity 与签名复验。打包与签名类步骤在 `~/Documents` 之外的临时工作区执行（iCloud File Provider
  会把 `com.apple.FinderInfo` 贴回 bundle，导致 ad-hoc 签名校验失败，`#15` 同类问题）；CI runner 不在
  同步目录内，不受影响。

## 回退

1. 保留上一版的 ZIP 与它的 `.sha256`。回退时解压上一版（`v0.1.0-alpha.4`，资产仍在 Releases 中）
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
   `v0.1.0-alpha.6`）并在 Release 说明中给出回退路径。

## 支持边界

- 只支持 Apple Silicon（arm64）与 macOS 14 或更高版本；没有 Intel 产物。
- 没有 SLA，桌面应用没有自动更新安装，没有 Developer ID 签名、Apple 公证或 Apple 支持渠道。
- 默认只监听 loopback；远程访问必须自备加密传输，并且**密码认证不等于传输加密**。
- 更新路径的硬边界：两条自动更新默认关闭且只对来源可信的 npm/pnpm 全局安装生效，目标版本必须
  来自本次网络检查；扩展包更新必须由用户确认；验证不做代码签名确认；不承诺所有来源都能回滚；
  一次只允许一轮更新事务，放弃等待后“未确认退出”的窗口只能靠重启应用可靠恢复。
- 更新检查只访问 `api.github.com` 与 `registry.npmjs.org`，只读、可逐类关闭；除此之外应用不主动
  向任何上游发送数据（自动更新触发的网络请求由用户自己的 `npm` / `pi` 按其配置发出）。
- 依赖探测会读一次登录 shell 的 `PATH`（本机、只读、有超时），并使用合并后的 `PATH` 启动
  依赖探测、更新命令与服务进程。
- 不要在公开 Issue、PR 或 Release 评论里粘贴密码、token、私有主机名、代理凭据或未脱敏日志。

## 反馈与安全报告

- 普通问题与功能建议：使用本仓库的
  [Issue 表单](https://github.com/Su-luoya/pi-web-desktop/issues/new/choose)；请附版本、安装与依赖
  信息（脱敏后的诊断导出），以及可复现步骤。上游 Pi Web、Pi CLI 或 Pi packages 的问题请先到对应
  上游仓库确认。
- 安全漏洞：**不要**开公开 Issue、不要粘贴到 PR 或 Release 评论。请使用
  [私密漏洞报告](https://github.com/Su-luoya/pi-web-desktop/security/advisories/new)，
  范围、处理流程与“不承诺 SLA”的说明见 [SECURITY.md](../SECURITY.md)。

## 发布时需要补全的值清单（协调者，发布前删除本节）

本文件里的哈希与字节数只出现在“校验值”一节，且都标注为**本机演练值**（同步目录之外的临时
worktree，提交 `838cb25`；演练后已清理）。发布值由 `.github/workflows/release.yml` 在 tag 上运行
`Scripts/package-release.sh --tag v0.1.0-alpha.5` 时生成；请用 workflow 的实际输出核对，必要时
替换演练值：

1. `{{ZIP_NAME}}`（出现于“安装”“校验值”两节）→ ZIP 资产名，按命名规则预期为
   `Pi-Web-Desktop-0.1.0-alpha.5+build.5.zip`（本机演练产物的实际名称与之一致）。
2. 发布产物的字节数与 SHA-256 → 取 workflow 产物 `dist/release-metadata.env` 的 `ZIP_NAME` /
   `SHA256`（或 Release 草稿 assets 上的值），替换“校验值”一节里两行标注为“本机演练”的值；
   演练值为 1,506,741 字节与 `fb71823f…`，**不要**直接当作发布值（本机演练的 SHA-256 每次都不同）。
3. 证据 Markdown 的文件名（预期 `Pi-Web-Desktop-0.1.0-alpha.5+build.5.evidence.md`）与其中的
   `codesign --verify` / `codesign -dv` / `spctl -a -vv` 摘要 → 若与“构建与签名验证记录”里的演练
   摘要不同（打包环境不同），以 workflow 产物为准。
4. `release-metadata.env` 中的 `ZIP_NAME` / `EVIDENCE_NAME` / 版本 / build → 与本节 1、2、3 项
   核对一致。
5. 资产上传后，把 Release 页面上的实际 SHA-256 与字节数回填到“校验值”一节，并在发布前删除本节。
