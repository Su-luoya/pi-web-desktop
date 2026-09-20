# v0.1.0-alpha.5 安全评审（delta，只读）

- **审查对象**：`0.1.0-alpha.5` 相对 `0.1.0-alpha.4` 的改动，即 `git diff v0.1.0-alpha.4..838cb25`
  （12 个修复提交 + 1 个版本 bump 提交，共 55 个文件、+10547 / −1045 行）。本版**没有新增功能面**，
  全部改动是修复与加固，外加两份新文件：
  `Sources/QuitCoordinator.swift`（286 行，全新）、`Sources/ToolPath.swift`（584 行，全新）
  与对应测试 `PiWebDesktopTests/QuitCoordinatorTests.swift`、`PiWebDesktopTests/ToolPathTests.swift`（1026 行）。
- **基线**：`v0.1.0-alpha.4` → `838cb25`（`chore(release): v0.1.0-alpha.5 版本 bump 与发布说明`）。
  12 个修复提交（newest first）：`6821ecd`（#95 / PR #95）、`75b8e0d`（#94 / PR #94）、
  `9929376`（#89 / PR #91）、`25e7bea`（#83 / PR #86）、`224e4ea`（#82 / PR #85）、
  `85556e6`（#80 / PR #84）、`3d10727`（#88 / PR #90）、`b9c493f`（#81 / PR #87）、
  `bc4324e`（#73 / PR #79）、`7484760`（#75 / PR #78）、`57671fc`（#74 / PR #77）、
  `7f11313`（#72 / PR #76）。
- **性质**：**只读审查**。没有修改任何 `Sources/`、`Scripts/`、`Configuration/` 文件；没有 push、
  没有打 tag、没有执行 `Scripts/build.sh` / `Scripts/package-release.sh` / `xcodebuild` / `smoke.sh`。
  本报告只写能在当前 `HEAD`（`838cb25`）核对到的事实，行号一律以本地文件为准（PR 正文里的行号
  属 rebase 前版本，未被本报告采用）。
- **结论摘要**：**阻塞项 0 项**（B1–B9 全部未触发，见 §2）。本版新增 1 条”中”级发现（M-1，
  启动路径的有界主线程阻塞）与 7 条”低”级发现（L-1 … L-7），
  另有 3 条“信息”级记录。alpha.4 的 **N-1、N-2、N-5 在本版部分缓解**；**N-3、N-4、N-6 仍存在**；
  A-1 维持闭环，A-3/A-4/A-5/A-7 部分缓解，**A-2、A-6、A-8、A-9 按现状保留/接受**（见 §4.1 表格）。**本报告不构成发布批准**：CI 全绿、真机 smoke、
  checksum 等门槛仍按 [Alpha 发布门槛清单](alpha-release-checklist.md) 逐项满足。

---

## 0. 范围与方法

方法是「读 delta diff + 读当前代码 + 跑只读门禁 + 负向 grep」，**不是**动态渗透测试，也**没有**
真的执行过一次更新（本机没有 Xcode，也没有 GUI 交互环境）。

### 0.1 本次实际执行的命令与结果

| 命令 | 结果 |
| --- | --- |
| `git log --oneline v0.1.0-alpha.4..838cb25` | 13 条：12 个修复提交 + `838cb25` 版本 bump |
| `git status --short` | 空（审查开始时工作区干净） |
| `git diff --check` | 退出 0（无空白错误） |
| `sh -n Scripts/*.sh` | 退出 0 |
| `./Scripts/scan-secrets.sh --self-test` | 退出 0；`self-test: PASS (all rules fired, look-alikes stayed clean, suppression and rejection verified, untracked-file gate verified, samples cleaned up)` |
| `./Scripts/scan-secrets.sh` | **退出非 0**；`scan-secrets: error: 1 untracked file(s) exist, so this scan cannot claim the work tree is clean`，唯一未跟踪文件是本报告的草稿（`docs/security-review-alpha.5.md`）。这是脚本**故意的未跟踪门禁**（"A file that is never added is never scanned by CI either"），不是秘密发现 |
| `./Scripts/scan-secrets.sh --include-untracked` | 退出 0；`scan-secrets: suppressed 15 lines` + `scan-secrets: PASS (no matches in tracked or untracked files)` |
| `sh Scripts/check-release-version.sh v0.1.0-alpha.5` | 退出 0；`MARKETING_VERSION = 0.1.0-alpha.5, CURRENT_PROJECT_VERSION = 5`，tag ↔ 版本 ↔ build 规则三条断言全过 |
| `wc -l Sources/{ToolPath,QuitCoordinator,DiagnosticsCollector}.swift` | 584 / 286 / 352（`DiagnosticsCollector.swift` **不是**新文件，本版 +221 行） |

**本次没有执行**（因此下列结论不能从这些角度被支持或反驳）：`Scripts/build.sh`、
`Scripts/package-release.sh`、`Scripts/smoke.sh`、`Scripts/check-identity.sh`、`xcodebuild build/test`、
`codesign` / `spctl` / `ditto` 验签与解包复验（任务约束 + 本机没有 Xcode）。

### 0.2 负向证据（在 `838cb25` 工作区实际执行）

| 命令（针对本 delta 涉及的源码） | 结果 |
| --- | --- |
| `git grep -nE 'kill\(\|killpg\|SIGKILL\|posix_spawn\|Process\(\)' -- Sources/{QuitCoordinator,ToolPath,DiagnosticsCollector,LogWriter}.swift` | 5 个可执行命中：`Sources/DiagnosticsCollector.swift:178`（`Process()`）、`:221`（`kill(process.processIdentifier, SIGKILL)`）、`Sources/LogWriter.swift:767/813`（`posix_spawn` 启动 `/bin/cat` 排空进程）；`QuitCoordinator`/`ToolPath` **0 命中**。`Sources/ToolPath.swift:257` 命中 `/bin/sh`，但它是**登录 shell 候选路径列表的一项**（数据，不是命令字符串） |
| `git grep -nE 'moveItem\|copyItem\|removeItem\|unlink\(\|rmdir\|rename\(\|truncate\|write\(to:\|createFile' -- PiWeb/CLI/PackageUpdateAdapter + UpdateTransaction + UpdateVerifier + ToolPath + QuitCoordinator` | **0 命中**：这些文件不移动、不复制、不删除、不写任何被更新组件所在目录的文件 |
| `git grep -n 'sudo' -- Sources/{ToolPath,QuitCoordinator,DiagnosticsCollector,LogWriter}.swift` | 0 命中 |

### 0.3 未采用的证据

- **不采用 PR 正文与发布说明里的行号与结论措辞**作为安全结论依据；发布说明只用于交叉核对事实
  （§5.3 记录了核对结果与一处不一致）。
- 不采用本机无法复现的 CI 运行号、探针项数、`-typecheck` 结果等二手数字。

---

## 1. 本版变化摘要（按 delta 逐项，结论独立得出）

1. **退出决策状态机（#72 / PR #76，新文件 `Sources/QuitCoordinator.swift`，286 行）**：状态机的
   AppKit 回复只有 `terminateNow` / `cancelPendingDecision` 两态（`QuitCoordinator.swift:26-38`），
   不存在 `.terminateLater`；用户入口（⌘Q / 菜单）与 AppKit 终止序列入口（Dock、注销/关机、
   `terminate:`）分成两条输入，决策前一律 `cancelPendingDecision`，决策后再由状态机产生
   `.terminateApplication` 重新发起退出。等待用户决策有上限 `defaultDecisionTimeout = 5 * 60`
   （`QuitCoordinator.swift:100`），超时走 `decisionTimedOutKeepingServiceRunning`
   （保持服务运行并退出）。因此本版不存在「等待回复期间主队列不排水 / 漏回复导致退出悬空」这条路径。
2. **更新检查结论现算（#74 / PR #77）**：新增 `UpdateVersionVerdict.status(installed:upstream:)`
   （`Sources/UpdateChecker.swift:502`），由「当前本机版本 vs 上游版本」现场比较；缓存条目新增
   `installedVersion`（`:785`），schema 升到 2（`:835`）并兼容读 1（`:840`）；缓存里的 `status`
   字段不再作为可复用结论——缺 `installedVersion` 的旧条目或本机版本不可解析时统一降级为
   `unknown`（`cachedFallback`，`:1787-1830`，其中 `:1804` 的 `undecidable()` 是唯一出口）。
3. **秘密扫描规则与抑制标记（#75 / PR #78，`Scripts/scan-secrets.sh` +651/−158）**：抑制标记改为
   逐行 `scan-secrets: allow(reason=…)`，reason 去空白后至少 8 字符（`SUPPRESS_REASON_MIN=8`），
   脚本内**没有任何文件/目录/pathspec 级豁免**；裸标记不再抑制而是报为 finding 并计入
   `rejected` 计数；每次运行打印 `scan-secrets: suppressed N lines`，且被抑制的行本身也会以
   `scan-secrets: suppressed:` 前缀打印出来（保持可见）。`--self-test` 断言了规则命中、
   look-alike 不误报、抑制/拒绝计数与未跟踪门禁。
4. **日志（#73 / PR #79，`Sources/LogWriter.swift` +665/−77）**：子进程 stdout/stderr 从
   「直接写日志文件」改为**管道 + 应用侧串行 `O_APPEND` 写入**（`openChildOutput()` `:223`、
   `writerHandleOnQueue()` `:350`，`open(path, O_WRONLY|O_APPEND|O_CREAT|O_CLOEXEC, 0o644)`；
   句柄按 inode 校验，`:376`）。读端在专用串行队列上以 `DispatchSourceRead` + `O_NONBLOCK`
   排空（`:611`），逐块 UTF-8 lossy 解码 + 脱敏（`:700`），并用 `DispatchSemaphore(value: 64)`
   （`:123`）对 64 KiB 块（`:120`）形成背压（约 4 MB 内存上限）。轮转只影响应用侧句柄，
   管道与文件解耦。新增 `/bin/cat` 排空进程的移交（`:726`、`:756`，`POSIX_SPAWN_CLOEXEC_DEFAULT`
   + 空环境 + stdin=dup(读端) / stdout=stderr=/dev/null），只用于「退出但保持服务运行」。
5. **设置窗口单例、诊断导出后台化、argv 遮罩（#81 / PR #87）**：设置窗口改为复用同一控制器，
   每次展示前用 `update(configuration:)` 重置控件（`Sources/PreferencesWindowController.swift:209-220`）；
   诊断导出改用 `TimeoutCommandRunner`（`Sources/DiagnosticsCollector.swift:159-160`：
   3 s 超时 + 1 s 宽限，先 `terminate()` 后 `SIGKILL`，只对本次 `Process()` 启动的子进程）；
   外部监听进程的 argv 经 `maskedProcessDescription`（`:312`）交给更新路径同一套
   `PiProcessInspector.commandSummary`。
6. **隐私遮罩与依赖探针（#82 / PR #85，#84 / PR #84）**：`ProcessInspector` 增加有界超时与取消
   （`Sources/ProcessInspector.swift:198-200`，默认 10 s + 0.5 s 宽限；`cancelRunningProbe()`
   只终止本次启动的子进程）；`ServiceManager` 的启动/停止/退出回调全部加代次校验
   （`lifecycleGeneration` / 会话预算，`Sources/ServiceManager.swift:897-1199`）。
7. **发布脚本加固（#83 / PR #86）**：`Scripts/package-release.sh` +490/−22 增加标签/资产名/
   build 号白名单与 **bundle 内容白名单**（`is_allowed_bundle_path`，拒绝白名单外的条目与
   `.DS_Store`/`._*`）；`Scripts/check-release-version.sh` +287/−44 把「MARKETING_VERSION →
   build 号」规则做成了带 `--self-test` 的断言。
8. **CI 抖动（#88 / PR #90）**：只改测试的排空屏障，无生产代码变化（`3d10727` 仅触及测试）。
9. **合并工具 PATH（#89 / PR #91，新文件 `Sources/ToolPath.swift`，584 行）**：PATH 的唯一来源，
   合并顺序为 应用 PATH → 登录 shell PATH → 已知目录 → node 目录 → `npm prefix -g` 的 bin
   （`ToolPathBuilder.directories()`，`ToolPath.swift:183-201`）；`probeEnvironment()`
   （`:215`）额外丢掉 `credentialKeyWords`（`:51-58`）命中的环境变量键。登录 shell 从
   `getpwuid` → `$SHELL` → `/bin/zsh` → `/bin/sh` 里选（`:243-276`），只执行
   `printf '__PI_WEB_TOOL_PATH__%s' "$PATH"`（`:283`，固定 argv 第三个元素，无字符串拼接），
   3 s 超时（`:285`），失败后再试一次交互式 `-ilc`；结果单次缓存。`DependencyChecker`、
   `ComponentInstallation` 的探测、三个更新子进程环境与 `ServiceManager` 的启动环境全部改为
   复用它（`Sources/PiWebApp.swift:166-174`、`:221-226`；`Sources/ServiceManager.swift:149`），
   原先写死 PATH 的 `fallbackPathDirectories` 被删除。
10. **扩展包更新执行器每轮独立状态、结论不超出证据（#92 / PR #94）**：`PiPackageUpdateAdapter`
    增加 `running` 忙拒（`.executorBusy` / `.notAttempted`）、按身份登记的
    `abandonedProcesses`（跨轮次保留）、每轮独立的 stdout/stderr 句柄、有界超时重试；
    `UpdateTransaction` 新增 `UpdateRollbackEligibility.stateNotVerified`（`:364`），
    `installFailure` 不再声称「系统状态未改变」（`:496`），降级判定在缺内容哈希时**不再默认通过**
    （`:687-688` 改为 `?? false`，且两个元数据都缺失直接拒绝）；`UpdateVerifier.identityCheck`
    不再把计划里的期望包名当作检测值（`Sources/UpdateVerifier.swift:438`）。
11. **应用自更新可重入与事务门控（#93 / PR #95）**：新增 `UpdateEntryState`
    （`Sources/PiWebUpdateAdapter.swift:30-59`）、安装器级 `abandonedChildrenInFlight`（`:981`）、
    重叠 install 整体拒绝并回终态（`:1069-1075`）、门控提升到整轮事务
    （`transactionInFlight`，`:1391-1414`、`:1460`）、放弃等待后读端保留到 EOF（`:1228-1240`）。
12. **版本 bump**：`Configuration/AppIdentity.xcconfig` 的 `MARKETING_VERSION = 0.1.0-alpha.5`、
    `CURRENT_PROJECT_VERSION = 5`（只读核对，未执行打包）。

### 1.1 每项的攻击面变化（本 delta）

| 项 | 攻击面方向 | 依据 |
| --- | --- | --- |
| 1 退出状态机 | 中性偏好：不再有「无人回复 → 终止序列永久悬空」这条可用性面，新增 5 分钟上限 | `Sources/QuitCoordinator.swift:26-38`、`:100` |
| 2 结论现算 | **收窄**：本机缓存不能再决定「有新版本」结论，旧缓存降级为不可判定 | `Sources/UpdateChecker.swift:502`、`:835-840`、`:1787-1830` |
| 3 秘密扫描 | **收窄（门禁）**：不再有文件/目录/pathspec 级豁免；裸标记不再静默抑制 | `Scripts/scan-secrets.sh:110-121` |
| 4 日志管道 | **收窄**：子进程输出不再有「轮转写旧 inode / 丢日志」面；新增管道读端、背压与 `/bin/cat` 排空进程（有界约 4 MB） | `Sources/LogWriter.swift:120-125`、`:611-720`、`:726-813` |
| 5 设置窗口/诊断导出 | **收窄**：外部进程 argv 走同一套遮罩；探针 3 s 有界且只杀自己启动的子进程 | `Sources/DiagnosticsCollector.swift:159-160`、`:312-318`；`Sources/PreferencesWindowController.swift:209-220` |
| 6 探针超时/取消、服务状态机 | **收窄**：探针不再无限等待、可取消；回调加代次校验与会话预算 | `Sources/ProcessInspector.swift:198-200`、`:292-296`；`Sources/ServiceManager.swift:897-1199` |
| 7 发布脚本 | **收窄**：bundle 内容白名单 + 标签/build 号断言（本轮未执行打包） | `Scripts/package-release.sh`、`Scripts/check-release-version.sh` |
| 8 CI 抖动 | 无（测试专用提交） | `3d10727` |
| 9 合并工具 PATH | **扩大**：更新子进程与探测的 PATH 新增多个**用户可写**目录，npm 解析按 PATH 顺序取首个可执行文件；新增一次性登录 shell 子进程 | `Sources/ToolPath.swift:23-45`、`:183-201`、`:421-446`；见 L-1、L-7、M-1 |
| 10 扩展包执行器 | **收窄**：忙拒 + 每轮独立状态；身份与回滚结论不再超出证据 | `Sources/PiPackageUpdateAdapter.swift:237`、`:370-399`；`Sources/UpdateTransaction.swift:364`、`:687-688`；`Sources/UpdateVerifier.swift:438` |
| 11 应用自更新门控 | **收窄（同一应用运行内）**：整轮事务门控、拒绝也有终态回调；跨重启仍只有持久记录（L-3） | `Sources/PiWebUpdateAdapter.swift:30-59`、`:1069-1075`、`:1460` |
| 12 版本 bump | 无功能变化（校验链见信息 I-2） | `Configuration/AppIdentity.xcconfig` |

**净判断**：12 项里 9 项方向收紧；1 项（#89）方向扩大，但仍落在 alpha.4 已声明的「同一用户本地进程」
对手模型内（引用它的目录全部属于该用户，没有跨用户/跨权限面的新增）；2 项中性。没有任何一项跨出
alpha.4 §2 的对手模型（A 上游被污染的发布 / B 同用户本地进程 / C 其它用户进程 / D 远程网络攻击者 /
E 误操作的用户）。

---

## 2. 结论（是否阻塞发布）

**是否有阻塞发布的发现：无。阻塞项 0 项。**

依据：alpha.1 §11 定义的 B1–B8 与本报告新增的 B9 逐条不触发（下表）；本版 delta 没有引入新的信任
边界（§1.1）；本报告记录的 M-1、L-1 … L-7 与 3 条信息记录全部落在「可用性 / 同一用户可写状态 /
证据强度 / 门禁覆盖」四类，没有一条能造成权限提升、凭据外泄、向非自己启动的进程发信号，或不可逆
的文件破坏。

| 编号 | 阻塞条件 | 判定 | 依据（`838cb25` 实际行号） |
| --- | --- | --- | --- |
| B1 | 存在「来源不可信（非 `verified`）仍会自动安装/自动执行」的路径 | 未触发 | 自动安装仍要求 `source == .npmGlobal && confidence == .verified`（`Sources/PiWebUpdateAdapter.swift:407-414`）与本次网络结论 `targetOrigin`（默认 `.unavailable`，`:388-392`）；#89 只把 PATH 换成合并结果，没有放宽这三条前置 |
| B2 | 存在无人值守的扩展包更新路径 | 未触发 | `PiPackageUpdatePlan.allowsUnattendedExecution = false`（`Sources/PiPackageUpdateAdapter.swift:377`），`isAutomaticallyExecutable` 恒等于它（`:399`）；#94 追加忙拒（`.executorBusy`，`:237`、`:281`）只会更严 |
| B3 | 更新命令经 shell 字符串执行、调用 `sudo`、或 argv 元素来自未校验的外部文本 | 未触发 | 负向 grep 在 `Sources/{ToolPath,QuitCoordinator,DiagnosticsCollector,LogWriter}.swift` 无 `sudo` 命中；登录 shell 查询是固定 argv `[shell, "-lc", "printf '__PI_WEB_TOOL_PATH__%s' \"$PATH\""]`（`Sources/ToolPath.swift:283`），PATH 值不参与构造；更新 argv 仍受字符集与 `forbiddenTokens` 限制（`Sources/PiWebUpdateAdapter.swift:160-176`） |
| B4 | 任一更新路径向非自己启动的进程或进程组发送信号 | 未触发 | 更新路径的信号点未变（`Sources/PiWebUpdateAdapter.swift:1156-1172`：`usesOwnProcessGroup && group == pid && pid > 1` 三个前置 + `didSignalOwnProcessGroup` 至多一次）；本版新增的唯一信号点是 `Sources/DiagnosticsCollector.swift:221` 的 `kill(process.processIdentifier, SIGKILL)`，作用于同函数 `:178` 刚启动的 `Process()`（Foundation 自己回收该 pid，因此不是 alpha.4 N-4 那种 `posix_spawn` + 自行 `waitpid` 的时序窗口） |
| B5 | 凭据/秘密进入日志、诊断、更新历史或 UserDefaults | 未触发 | 写入前逐行 `redactor.redact`（`Sources/LogWriter.swift:196`、`:700`）；探测环境显式丢掉凭据键（`Sources/ToolPath.swift:51-58`、`:215`）；诊断导出复用 `PiProcessInspector.commandSummary`（`Sources/DiagnosticsCollector.swift:312-318`）；`scan-secrets.sh` 与其 `--self-test` 在包含本报告的工作区 PASS（§0.1） |
| B6 | 更新检查发出非白名单主机请求、携带 cookie/Authorization 或跟随重定向 | 未触发 | 本 delta 未触碰请求层（`UpdateRequest.sanitized()` 与拒绝重定向逻辑不在 diff 内）；#77 只改「结论怎么算」与缓存校验（`Sources/UpdateChecker.swift:502`、`:835-840`、`:988`） |
| B7 | 用户可见文案把「验证」说成「已确认代码签名 / 官方来源 / 可完整回滚」 | 未触发，且本版更严 | 安装失败文案删除了「系统状态未改变」的断言（`Sources/UpdateTransaction.swift:726-732`），降级资格新增 `.stateNotVerified`（`:364`、`:496-513`）；身份核对不再把计划里的期望包名当作检测值（`Sources/UpdateVerifier.swift:438`） |
| B8 | 回滚/降级路径移动、复制、删除文件，或卸载已安装组件 | 未触发 | 对更新事务相关文件（含本版新增的 `Sources/ToolPath.swift`、`Sources/QuitCoordinator.swift`）的负向 grep **0 命中**（§0.2） |
| B9 | 存在「向本次启动之外的进程/进程组发信号」的常规路径，或新增的持久状态能在无人值守时执行代码 | 未触发 | 信号边界见 B4；本版**没有新增持久键**（#94/#95 的新状态都在内存里：`Sources/PiWebUpdateAdapter.swift:981`、`:1391`，`Sources/PiPackageUpdateAdapter.swift` 的 `abandonedProcesses`）；`Sources/ToolPath.swift` 只产出 PATH 与子进程环境，不含执行或写入动作 |

**结论的边界**：以上是**静态**判定（读代码 + 只读门禁 + 负向 grep），不覆盖 §5 的未验证项，
**不构成发布批准**；CI 全绿、真机 smoke、checksum 与 prerelease 标记等仍按
[Alpha 发布门槛清单](alpha-release-checklist.md) 逐项满足。
**下一步建议**：M-1 与 L-1 … L-7 在 Release Issue 里逐条给出「接受 / 本版本修 / 转后续 Issue」的处置
（建议见各条末尾，汇总见 §4.2）。

---

## 3. 发现（按严重性：高 → 中 → 低 → 信息）

每条含：编号 / 位置 `file:line` / 描述 / 证据 / 当前缓解 / 残留风险 / 建议。
严重度沿用 alpha.1 / alpha.3 / alpha.4 的口径（低 / 低—中 / 中 / 高）；判据是「是否需要跨权限边界、
是否可被非同一用户触发、是否造成不可逆破坏」。

### 3.1 高

**无高严重性发现。** 判定依据（不是「没找到」而是「有正面理由」）：

- 本版没有新增攻击者可达的**跨权限**动作：所有新代码（`Sources/ToolPath.swift`、`Sources/QuitCoordinator.swift`、
  `LogWriter` 的管道与排空进程、诊断探针）都以当前用户身份运行，没有提权、没有 setuid、没有以 root
  执行、没有修改系统目录（负向 grep 见 §0.2）。
- 所有信号发送都指向本应用自己启动的子进程（B4 的依据）；没有任何按名字杀进程或对任意 PID 发信号的路径。
- 本版没有新增网络端点、没有新增持久键、没有新增 shell 字符串执行路径（B3/B6/B9）。
- 唯一方向为「扩大」的改动（#89 PATH 合并）落在同一用户对手模型内：被引用的目录
  （`~/.local/bin`、`~/.npm-global/bin`、`~/.bun/bin`、`~/.cargo/bin`、`/opt/homebrew/bin`、
  `/usr/local/bin`、`/opt/local/bin`、node 目录、npm prefix/bin）全部由该用户自己拥有，
  同用户对手本来就能直接替换被更新的可执行文件本身（L-1 详述）。

### 3.2 中

#### M-1（中，可用性）启动路径上有界但可长达约 26 秒的**主线程**同步阻塞

- **位置**：`Sources/PiWebApp.swift:166-174`（`AppDelegate.init` 内构造 `ToolPathProvider`
  并立即调用 `probeEnvironment()`）→ `Sources/ToolPath.swift:546`（`resolveLocked()`）→
  `:421-446`（`nodePathResolver`：`/usr/bin/env node -p process.execPath`；`npmPrefixResolver`：
  `/usr/bin/env npm prefix -g`）与 `:323-341`（登录 shell 查询，含 `-ilc` 交互式回退）。
- **描述**：`AppDelegate` 在 `Sources/main.swift:4` 于主线程构造；构造过程中就会解析 PATH 的
  全部输入，其中包含 4 次有界子进程等待：登录 shell `-lc`（3 s）+ 交互式回退 `-ilc`（3 s）+
  `npm prefix -g`（`SystemCommandRunner.defaultTimeout = 10`，`Sources/ProcessInspector.swift:198`）
  + `/usr/bin/env node -p process.execPath`（同上 10 s）。单次启动最坏约 **26 秒**主线程不返回。
- **证据**：`Sources/PiWebApp.swift:166-172` 用 `ProcessInfo.processInfo.environment` +
  `NSHomeDirectory()` + 注入的 `commandRunner` 构造 provider，紧接 `:174` 调用
  `toolPathProvider.probeEnvironment()`；`probeEnvironment()`（`Sources/ToolPath.swift:492`）
  → `builder()` → `resolveLocked()`，两个解析器各自最多一次；`LoginShellPathQuery` 的超时是
  3 s（`:285`），交互式回退在上一次拿不到值时再执行一次（`:323-341`，注释自陈「交互式 rc 可能有副作用、
  可能很慢」）；`SystemCommandRunner` 的默认 10 s 见 `Sources/ProcessInspector.swift:198`
  （超时后 `terminate()`，0.5 s 宽限后 `forceTerminate()`，`:200`）。
- **触发条件（推测，未实测）**：用户的登录 shell rc 有阻塞（例如 `read`、等待网络挂载、慢的
  `nvm`/`conda` 初始化、`mise` 下载），或 `npm prefix -g`/`node` 位于已卸载的网络卷。此时应用
  启动后长时间不出现窗口，且依赖门控与服务启动都被推迟到同一段时间之后。
- **当前缓解**：每个子进程都有硬超时（3 s / 10 s），超时不抛错、以「拿不到值」降级
  （`resolveLocked()` 把失败写成 nil，`:546-552`）；结果单次缓存（`:323-325`），同一次运行内不会
  重复付出这个代价；失败只影响 PATH 的丰富度，不影响应用继续启动（`path()` 仍返回已有目录）。
- **残留风险**：最坏 26 s 的界面无响应与启动延迟在「无人值守/自动化点击」场景里会被读成应用卡死；
  这属于自伤型可用性风险，不改变权限边界。**未实测**：本机没有 GUI 环境，无法测出真实启动耗时。
- **建议**：把 PATH 解析从 `AppDelegate.init` 移到首次使用点或后台队列（保留「注入结果可被读取」
  的语义），或给登录 shell 查询设一个更小的上限（例如 1 s）并把交互式回退改成显式用户动作。
  需要证据才能判定严重度上限：一台有真实用户 rc（含慢初始化）的机器上的 launch→首窗口时间。

### 3.3 低

#### L-1（低，同一用户对手）合并 PATH 让更新子进程多了一批用户可写搜索目录，npm 解析取 PATH 首个可执行文件

- **位置**：`Sources/ToolPath.swift:23-45`（`knownAbsoluteDirectories` / `knownHomeRelativeDirectories` /
  `systemDirectories`）、`:183-201`（合并顺序）、`:124-144`（候选目录）、`:421-446`（node/npm 解析）；
  `Sources/PiWebUpdateAdapter.swift:203-211`（更新子进程 PATH）、`:550-573`（`PiWebUpdateNPMResolver`
  的候选与 `resolve`）。
- **描述**：本版起，更新子进程与依赖探测共用合并 PATH，顺序为 应用 PATH → 登录 shell PATH →
  已知目录 → node 目录 → npm prefix/bin，去重。相对 alpha.4 的更新子进程
  （`fallbackPathDirectories` = Homebrew/`/usr/local`/系统目录，见 `git show v0.1.0-alpha.4:Sources/PiWebUpdateAdapter.swift:126-163`），
  新增了 `~/.local/bin`、`~/.npm-global/bin`、`~/.bun/bin`、`~/.cargo/bin`、`/opt/local/bin`、
  `node` 所在目录、`npm prefix -g` 的 `bin`，并且这些目录排在 `/usr/bin`、`/bin` **之前**。
  `PiWebUpdateNPMResolver.resolve` 只做 `fileSystem.isExecutableFile(atPath:)`，取**第一个**
  可执行候选（`:571-573`）——也就是说「PATH 里最先出现的 `npm`」就是自动更新会执行的那个二进制；
  同理 `#!/usr/bin/env node` 的 shebang 由内核按 PATH 解析 `node`，应用不校验它解析到哪一个。
- **证据**：合并顺序在 `ToolPathBuilder.directories()`（`:183-201`）里是四组固定顺序；候选目录由
  `ToolPath.executableCandidates`（`:136-144`）生成；`~/.npm-global/bin` 与 `~/.local/bin` 等
  相对 Home 展开（`:102-111`）且只做「存在 + 是目录」判定（`defaultDirectoryIsUsable`，`:373-378`），
  **没有**所有权、权限位、symlink 目标或「不可被非属主写入」的检查；npm 解析没有 pin 到
  「与检测到的 `pi-web` 同一前缀」这一优先项之外的位置（前缀推导候选在 `:556-562`，找不到时回退到
  按 PATH 顺序）。
- **当前缓解**：工具自己所在目录被排在最前（`path(prioritizing:)`，`:209`、`:487-490`），
  因此 npm 升级用的 `node` 更可能是「npm 旁边那个」而不是 PATH 里任意一个；`probeEnvironment()`
  （`:215`）显式丢掉凭据类环境键；更新子进程最终只用白名单键（`Sources/PiWebUpdateAdapter.swift:184`）；
  自动安装仍需 `.npmGlobal` + `.verified` + 本次网络结论（B1）。
- **残留风险**：同一用户（或该用户下任意被攻陷的进程/扩展）在 `~/.local/bin`、`~/.npm-global/bin`
  等目录放一个同名 `npm`/`node`，就能影响更新子进程实际执行的代码。**这不构成权限提升**：
  这些目录属于该用户，且该用户本来就能直接改写被更新的 `pi-web`/`pi` 可执行文件（alpha.4 A-9 的同类边界）。
- **建议**：给合并进来的**用户级**目录加一条「不可被非属主写入」的检查（不满足就丢弃或降级为提示），
  或在自动安装路径上把 npm 固定为「与检测到的安装同一前缀的 npm」，把 PATH 回退只留给手动路径。
  需要证据才能判定影响面：本机未做「伪造 npm 是否真的被自动安装路径采用」的动态复现。

#### L-2（低，可靠性/状态）应用退出时更新子进程的 stdout/stderr 读端不移交

- **位置**：`Sources/PiWebUpdateAdapter.swift:1228-1240`（`finishLocked` 保留读端）、`:1266`
  （`drainOutput`）、`:981`（`abandonedChildrenInFlight`）；`Sources/LogWriter.swift:726-756`（唯一的
  移交实现）；`Sources/ServiceManager.swift:1373`（唯一的移交调用点）。
- **描述**：#95 解决了「放弃等待后立刻关闭读端 → 子进程下一次写 stdout 收到 SIGPIPE/EPIPE」，
  但那只覆盖**同一次应用运行内**的放弃等待。应用**退出**时，更新子进程的 stdout/stderr 写端仍然
  只有应用进程持有读端（`handle.outputDescriptor` → `attempt.outputHandle`），退出即关闭。
  下一次写入会让子进程收到 `EPIPE`（Node 把它变成 `process.stdout` 的 `error` 事件）或 `SIGPIPE`，
  可能让正在执行的 `npm install -g …` 中途死掉。
- **证据**：`handOffChildOutputToDrainer()` 是唯一的「把读端交给 `/bin/cat` 继续排空」实现，
  全仓库只有一个调用点（`git grep -n handOffChildOutputToDrainer` → `Sources/LogWriter.swift:726`
  定义、`Sources/ServiceManager.swift:1373` 调用），且它服务于**托管服务**的输出管道（注释自陈用途是
  「退出但保持服务运行」）。退出协调器（`Sources/QuitCoordinator.swift`）与
  `applicationShouldTerminate`（`Sources/PiWebApp.swift:464`）里没有「更新进行中」这个输入：
  `isUpdateInProgress` 只出现在菜单/手动入口的门控读取点（`Sources/PiWebApp.swift:1386`、`:1426`、
  `:1593`、`:1647`）。
- **当前缓解**：更新子进程有 5 分钟上限与超时记录（`Sources/PiWebUpdateAdapter.swift` 的
  `defaultTimeout = 300`）；放弃等待会写持久记录，重启后自动路径会拒绝并提示（alpha.4 N-2/N-6 的机制）；
  更新完成前的部分写入可由「重新安装」恢复（不涉及本报告的能力断言）。
- **残留风险**：更新中途退出应用可能让全局 npm 前缀留下部分写入的包树（不可逆性有限，但会让下次启动
  的版本重检测结果不可预测）。**未验证**：没有真的在 `npm install` 期间退出应用来观测 EPIPE 行为。
- **建议**：让退出路径知道「有更新子进程在飞」，二选一：退出时把读端也交给 `/bin/cat` 排空，
  或在退出前（或确认框里）明确告知「更新正在进行，退出会中断它」。

#### L-3（低，同一用户持久状态）「放弃等待」不终止子进程，跨重启只有持久记录与用户确认

- **位置**：`Sources/PiWebUpdateAdapter.swift:1144-1155`（`stopWaitingLocked` 只登记 + 发一次信号）、
  `:1156-1172`（`terminateOwnProcessGroupLocked`，降级路径**不发信号**）、`:1174-1199`
  （`recordAbandonedAttemptLocked`，`finishedAt: nil`）、`:981`、`:1018-1024`；
  `Sources/PiPackageUpdateAdapter.swift` 的 `abandonedProcesses`（跨轮保留、`resetRunStateLocked`
  不得清空）；持久侧沿用 alpha.4 的 `UpdateAbandonedAttempt` 记录（本版未改）。
- **描述**：超时/取消只放弃等待，不给 `SIGKILL`，也不确认派生进程结束；「已放弃但未确认退出」的计数
  （`abandonedChildrenInFlight`）阻止**同一应用运行内**再次更新，但它是内存状态：应用重启后
  计数归零，只能靠持久记录 + 用户确认来防重叠。持久记录里 `finishedAt` 与
  `derivedProcessesConfirmedEnded` 仍恒为空，判定链里没有「那个进程是否还活着」的检查
  （alpha.4 N-2 的原始形态）。
- **证据**：`stopWaitingLocked` 在 `attempt.abandonedUnconfirmed` 置位时 `abandonedChildrenInFlight += 1`
  并调用 `terminateOwnProcessGroupLocked`；后者在 `usesOwnProcessGroup && group == pid && pid > 1`
  不全成立时直接返回 `.processGroupUnavailable`（**一个信号也不发**）；
  `childExitedLocked` → `settleAbandonedChildLocked`（`:1201-1213`）是唯一结清计数的路径；
  `isRunning` / `abandonedChildrenUnconfirmed`（`:1018-1025`）都读这个内存计数。
- **当前缓解**：同一次运行内保守拒绝（并给出可读原因「上一次更新未确认退出，重启应用可恢复」，
  `UpdateEntryState.menuTitleSuffix`，`:54-59`）；跨重启的自动路径会被记录挡住
  （alpha.4 已声明的 `.manualOnly(.abandonedAttemptPending)` 等拒绝）；用户可显式清除记录。
- **残留风险**：被放弃的 `npm install -g` 若在重启后仍在运行，用户确认一次手动更新就可能与它并发写
  同一个全局前缀。**无法判定**的部分：该子进程是否仍在运行——需要一次只读的进程存活检查才能判定，
  本报告没有做这种动态验证。
- **建议**：同 alpha.4 的建议（在清除/手动确认前做一次只读存活检查，或把「我确认那个命令已结束」
  写进记录），另可让「重启后首次打开」把内存计数重建为「有未确认记录 → 保守拒绝到用户确认」。

#### L-4（低，证据强度）诊断与外部进程信息的遮罩是模式化的；导出内容含本机路径

- **位置**：`Sources/DiagnosticsCollector.swift:312-318`（`maskedProcessDescription` 交给
  `PiProcessInspector.commandSummary`）、`:277-300`（采集字段）、`:159-160`、`:213-224`（超时与终止）；
  `Sources/PiProcessInspector.swift:783-840`（凭据前缀/不透明串规则）、`:935`（`commandSummary`）。
- **描述**：诊断导出把外部监听进程的 argv 按空白切分后交给与更新路径相同的遮罩
  （token 级凭据前缀、长不透明串、`LogRedactor`、长度上限），因此**没有已知前缀**、短于 32 字符的
  自由文本参数会被保留；导出内容仍包含本机路径（应用/服务/日志路径、版本、端口等）——
  这是诊断的用途本身，不是缺陷，但把导出文件贴进公开 issue 就等于公开这些路径。
- **证据**：`maskedProcessDescription` 的注释自陈「带空格的参数边界不可恢复，但遮罩只是多覆盖，
  不会少覆盖」；遮罩规则本体在 `PiProcessInspector`（`secretValuePrefixes` 等）而不是诊断模块里，
  因此两处行为一致；`TimeoutCommandRunner.terminate` 的 `kill(process.processIdentifier, SIGKILL)`
  （`:221`）只作用于本函数启动的 `Process()`。
- **当前缓解**：单命令 3 s 超时 + 1 s 宽限；失败统一渲染成「无法读取（命令超时或失败）」
  （`:146`），与「没有监听者」这类成功读到的事实区分；诊断导出的写盘/剪贴板路径有
  `diagnosticsExportInProgress` 互斥（`Sources/PiWebApp.swift:2566`）。
- **残留风险**：用户主动导出并公开分享时可能带出本机路径与未被模式覆盖的参数文本（低）。
- **建议**：在导出文件里加一行固定提示（「此文件含本机路径，分享前请检查」），或对非绝对路径/自由文本
  参数默认折叠成 `<arg>`。

#### L-5（低，门禁豁免面）`scan-secrets.sh` 的逐行 `allow(reason=…)` 仍是「任意一行可免检」

- **位置**：`Scripts/scan-secrets.sh:110-123`（标记与 `SUPPRESS_REASON_MIN=8` 的说明与定义）、
  `:522-530`（`scan_file` 的 finding/suppressed 语义）、`:1040-1105`（`--self-test` 对抑制、
  拒绝计数与「裸标记不得静默」的断言）。
- **描述**：本版确实收紧了豁免（裸标记不再抑制、reason 必须有 ≥8 字符、脚本内没有文件/目录/pathspec
  级豁免、被抑制行仍以 `scan-secrets: suppressed:` 打印、拒绝数单独计数并在非零时失败），
  但**豁免面本身还在**：任何一行只要自带合规标记就不再被报告，检查者需要在 diff 里读被抑制行
  才能发现「标记掩盖了什么」。
- **证据**：本次运行 `./Scripts/scan-secrets.sh --include-untracked` 输出
  `scan-secrets: suppressed 15 lines` 且 15 行逐条带 `scan-secrets: suppressed:` 前缀打印
  （分布：`PiWebDesktopTests/` 的 `KeychainStoreTests.swift`、`LogRedactorTests.swift`×3、
  `LogWriterTests.swift`×2、`PiWebUpdateAdapterTests.swift`×2、`ServiceManagerTests.swift`、
  `ToolPathTests.swift`×4、`UpdateTransactionTests.swift`），全部是测试夹具值，
  最终 `scan-secrets: PASS`。**未观察到新规则误伤**：本版新增的
  `PiWebDesktopTests/ToolPathTests.swift` 夹具值（如 `:330-332`、`:581` 的 `NPM_TOKEN` /
  `AWS_SECRET_ACCESS_KEY` / `PI_WEB_PASSWORD`）都带显式标记，没有出现「加了新规则就误报」的行。
- **当前缓解**：标记必须带 reason 且逐行；被抑制行与计数都打印；`--self-test` 会验证
  「look-alikes stayed clean」；CI 有两条 job 步骤跑 `--self-test` 与全量扫描
  （`.github/workflows/build.yml:58`、`:60`）。
- **残留风险**：门禁的强度取决于「谁审被抑制行」，脚本本身无法判断 reason 是否诚实；此外
  `--self-test` 只能证明「已写下的规则会触发、已写下的样本不误报」，**不能**证明规则集完备。
- **建议**：在 CI 里对「本 PR 新增的抑制标记」做一次显式 diff 打印（只读、不阻断），让 review
  一定能看到新增豁免；保持 reason 最小长度这条约束。

#### L-6（低，可用性）退出决策的 5 分钟兜底在无人值守场景会推迟注销/关机并保持服务运行

- **位置**：`Sources/QuitCoordinator.swift:100`（`defaultDecisionTimeout = 5 * 60`）、
  `Sources/PiWebApp.swift:532-534`（计时器）、`:579`（超时日志文案）、`:464-471`
  （`applicationShouldTerminate` 的回复）。
- **描述**：当退出行为要求用户确认时，AppKit 终止序列会先被 `cancelPendingDecision` 取消，
  由状态机异步弹窗等待；等待上限 5 分钟，超时按「保持服务运行并退出」处理。注销/关机等
  无人值守场景下，最坏会推迟 5 分钟，并且托管服务按设计**保持运行**（释放给系统继续运行）。
- **证据**：`QuitTerminationReply` 只有 `terminateNow` / `cancelPendingDecision`
  （`Sources/QuitCoordinator.swift:26-38`）；`appKitTermination` 在 `waitingForUserDecision` /
  `stoppingManagedService` 阶段返回 `cancelPendingDecision`（同文件「AppKit 终止序列入口」一节）；
  超时事件产出 `decisionTimedOutKeepingServiceRunning`；日志文案在 `Sources/PiWebApp.swift:579`。
- **当前缓解**：超时有界且行为是「最安全」的一种（不静默停服务、不无限挂起）；决策完成后重新发起
  退出（幂等）；⌘Q 与菜单路径不再走 AppKit 等待循环，主队列照常排水。
- **残留风险**：无人值守/自动化环境里最坏 5 分钟延迟；服务可能继续以该用户身份监听端口。
  这是设计取舍（alpha.3/alpha.4 未涉及的新代码），本报告按「低」记录，建议在文档里保持现有描述。
- **建议**：**无需修**（行为已文档化）；如未来要在无人值守场景收紧，可考虑「系统发起的终止序列
  使用更短上限」这一条独立决策，而不是改默认值。

#### L-7（低，信息一致性）登录 shell 查询子进程继承应用环境（与探测环境的「去凭据」策略不一致）

- **位置**：`Sources/ToolPath.swift:286-341`（`LoginShellPathQuery`：`runner` / `environment` 的解析与使用）、
  `:385-400`（`ToolPathProvider.init` 里 `LoginShellPathQuery(runner: commandRunner, environment: environment, …)`
  与 `self.environment = environment ?? system?.environment ?? ProcessInfo.processInfo.environment`）、
  `:215-222`（`probeEnvironment()` 才丢凭据键）、`Sources/PiWebApp.swift:166-172`（生产用的是默认
  `SystemCommandRunner()`，其 `environment` 为 nil → 继承应用环境）。
- **描述**：登录 shell 查询与 node/npm 解析用的是**应用环境**（只替换 PATH），而同一份 PATH 的其余
  消费者走 `probeEnvironment()`（先丢掉 `credentialKeyWords` 命中的键）。因此如果应用是从带凭据的
  终端环境启动的，那次 `-lc` / `-ilc` 登录 shell 子进程会继承这些变量。子进程是该用户自己的登录
  shell，且 rc 文件本来也在该用户权限下运行，因此**不构成新的信任边界**，但两套环境策略并存值得记录。
- **证据**：`ToolPathBuilder.probeEnvironment()` 是唯一做 `filter { !ToolPath.isCredentialKey($0.key) }`
  的地方（`:215-222`）；`LoginShellPathQuery.init` 把 runner 的环境（`SystemCommandRunner.environment`，
  默认 nil = 继承）当作查询子进程环境使用；`LoginShellResolver.shellPath` 只采用「绝对路径 + 可执行」
  的候选（`:252-276`），输出解析只取**最后一个**标记之后的内容（`parse`，`:343-349`），
  rc 自己打印的内容不会污染 PATH 值。
- **当前缓解**：固定 argv、3 s 超时、单次缓存、失败降级为「没有结果」；输出只取标记之后的内容；
  结果只用于 PATH 值。
- **残留风险**：**信息级**。副作用是「启动应用会执行用户自己的登录 shell rc（失败后再试交互式 rc）」，
  这对用户是预期行为，但意味着界面启动隐式依赖 rc 的健康程度（与 M-1 同因）。
- **建议**：把登录 shell 查询也改用 `probeEnvironment()` 式的最小环境（现在两处策略不一致），
  并在文档里明说「应用启动会执行一次登录 shell 以读取 PATH」。

### 3.4 信息（记录，不构成风险判定）

- **I-1 扩展包入口没有「重启应用可恢复」提示。** `UpdateEntryState.menuTitleSuffix`
  （`Sources/PiWebUpdateAdapter.swift:54-59`）只服务 Pi Web 与 Pi CLI 的菜单项；扩展包路径用
  `PiPackageUpdateRefusal` 文案（`.executorBusy`，`Sources/PiPackageUpdateAdapter.swift:281`）。
  本版发布说明已自陈这一边界，本报告确认属实（不是缺陷，是覆盖范围差异）。
- **I-2 版本/发布校验链只做了只读观察。** 本轮**没有**执行 `Scripts/package-release.sh` 与
  `Scripts/build.sh`，因此对「打包产物是否可能绕过 bundle 内容白名单」**无法判定**；能核对的只有：
  `sh Scripts/check-release-version.sh v0.1.0-alpha.5` 退出 0（tag ↔ `MARKETING_VERSION` ↔ build 5
  三条一致），`sh -n Scripts/*.sh` 退出 0，`Scripts/package-release.sh` 里存在
  `is_allowed_bundle_path` 白名单与 `.DS_Store`/`._*` 拒绝逻辑，`.github/workflows/release.yml:64-73`
  在 tag 上先跑 `check-release-version.sh` 再跑打包。另外 `AppIdentity.xcconfig` 是本版唯一版本
  来源（`MARKETING_VERSION = 0.1.0-alpha.5`、`CURRENT_PROJECT_VERSION = 5`）。
- **I-3 与发布说明的一处不一致（需要维护者同步）。** `docs/release-notes-v0.1.0-alpha.5.md:343-344`
  写「这些报告没有提交到仓库，因此本版没有新增 `docs/security-review-alpha.5.md`」。本报告提交后
  这句话不再成立；在 `838cb25` 那个提交当时它是准确的。本报告没有修改发布说明（任务限定只产出
  本文件），建议维护者在后续文档提交里改掉这句或把本报告链接进去。

---

## 4. 上一版遗留项复核

复核对象是 [alpha.4 审查](security-review-alpha.4.md) §3 的 N-1 … N-6、§4 的 A-1 … A-9 处置结论，
以及 §7 的 F1 … F6 建议。状态口径：**已缓解**（本版代码里能指出具体生效点）/
**部分缓解**（只收窄了一半，另一半仍可指认）/ **仍存在**（本版未触碰）/
**不适用**。依据里的行号一律为 `838cb25`。

### 4.1 逐条状态

| 编号 | alpha.4 结论 | 本版状态 | 依据（本版实际代码） |
| --- | --- | --- | --- |
| **N-1** 未记录内容哈希时降级仍可用 size/mtime 通过 | 低（元数据回退） | **部分缓解** | #94 把「没记录的字段一律算未验证」写进判定：`fingerprint.fileSize.map { … } ?? false`、`mtimeMatches … ?? false`（`Sources/UpdateTransaction.swift:687-688`），两个元数据都缺失时直接返回 `cannotAutomaticallyRollback`/`.evidenceChangedOrMissing`（同函数上方的 `guard fingerprint.fileSize != nil || fingerprint.modifiedAt != nil`，`:679-686`）。**仍然残留**：只要 size 与 mtime **都记录过且都一致**，旧文件内容仍不被校验（`contentHashVerified == false` 分支继续走元数据比对），这与 alpha.4 N-1 的描述一致 |
| **N-2** 「已放弃」重叠防护是记账式的、不检测进程存活 | 低 | **部分缓解** | #95 在同一应用运行内把「已放弃但退出未确认」做成硬门闩：`abandonedChildrenInFlight`（`Sources/PiWebUpdateAdapter.swift:981`）→ `startLocked` 整体拒绝（`:1069-1075`）→ 只有 `childExitedLocked`/`settleAbandonedChildLocked` 才结清（`:1201-1213`）；`UpdateEntryState.component(…:abandonedChildrenUnconfirmed:)` 把「重启应用可恢复」写进菜单文案（`:41-59`）。**仍然残留**：跨重启只有持久记录 + 用户确认，记录里仍不判断被放弃的进程是否还活着（本报告 L-3） |
| **N-3** npm `integrity` 是展示用附加证据、来自本机可改写文件 | 低 | **仍存在** | 本版没有触碰 `UpdateArtifactProbe.readNpmIntegrity` / `npmIntegrity`：`git diff v0.1.0-alpha.4..838cb25 -- Sources/UpdateVerifier.swift` 只有 `identityCheck` 的一处改动（+6/−1），`evaluateRollbackEvidence` 的通过条件里仍没有它 |
| **N-4** 进程组终止与 `waitpid` 回收之间的窄窗口（理论 PID 复用） | 低（分析结论） | **仍存在** | `stopWaitingLocked`（`Sources/PiWebUpdateAdapter.swift:1144-1155`）→ `terminateOwnProcessGroupLocked`（`:1156-1172`）的调用顺序与前置条件未变，`waitQueue` 回收与 `stateQueue` 超时处理仍是两个队列；#95 只增加了「拒绝第二次安装」的计数，没有把「已回收」状态并入发信号判定 |
| **N-5** 缓存回退仍可被同用户改写以影响提示文案 | 低 | **部分缓解** | #77 让**结论**不能再沿用缓存：schema 2 + `installedVersion` 字段（`Sources/UpdateChecker.swift:785`、`:835-840`），缺字段/本机版本不可解析 → `undecidable()` → `unknown`（`:1804-1830`），且结论由 `UpdateVersionVerdict.status(installed:upstream:)`（`:502-511`）现算。**仍然残留**：缓存里的 `latestVersion` 仍是本机可写字段，同用户仍可让界面显示一个伪造的上游版本**提示**（不再能改变 `updateAvailable` 结论、也不参与自动安装；自动路径仍要求 `origin == .network`） |
| **N-6** 「已放弃」记录可被同用户写入，阻断自动更新并展示 ≤200 字符自定义文本 | 低 | **仍存在** | `Sources/UpdateAbandonedAttempt.swift` 在本版 diff 里没有改动（`git diff --stat` 未列出该文件）；写入/读回校验、展示路径与自动路径拒绝逻辑沿用 alpha.4 |
| **A-2** 自动安装不传 `--ignore-scripts` 且继承 `HOME` | 低—中（接受） | **仍存在（按现状接受）** | `PiWebUpdateLifecycleScriptPolicy.passesIgnoreScripts = false`（`Sources/PiWebUpdateAdapter.swift:241-243`）；更新子进程白名单键不变（`allowedKeys`，`:184`），不注入任何 `npm_config_*`；本版把 PATH 换成合并结果（`:203-211`），脚本执行语义未变 |
| **A-3** 「更新后验证」不等于「来源可信」 | 低—中 | **部分缓解（本版更严）** | 安装失败文案不再声称「系统状态未改变」（`Sources/UpdateTransaction.swift:726-732`），资格改为 `.stateNotVerified`（`:364`）；身份核对不再用计划里的期望包名当检测值（`Sources/UpdateVerifier.swift:438`）。来源仍然不可证明（本应用没有签名/公证能力，见 §5） |
| **A-4** 降级判定依据可被同用户伪造（size/mtime） | 低 | **部分缓解** | 同 N-1：缺元数据不再默认通过（`Sources/UpdateTransaction.swift:679-688`）；记录了内容哈希时哈希是唯一依据（alpha.4 已生效，本版未改）。未记录内容哈希时仍走元数据 |
| **A-5** 进程保护读取 argv 的面与遮罩边界 | 低 | **部分缓解（遮罩侧加严）** | #85 补齐短开关形态、非绝对路径判 `unknown`、探针超时与取消；诊断导出改为复用同一套遮罩（`Sources/DiagnosticsCollector.swift:312-318`）；遮罩规则 `secretValuePrefixes` / `isOpaqueSecretToken` / `maskSensitiveTokens`（`Sources/PiProcessInspector.swift:783-840`）。**仍然残留**：遮罩是模式化的，短于阈值且无已知前缀的自由文本会保留（本报告 L-4） |
| **A-6** #20 的超时终止不覆盖派生子进程 | 低 | **仍存在** | 仍是「独立进程组 + 一次 `SIGTERM`」（`Sources/PiWebUpdateAdapter.swift:1156-1172`），没有 `SIGKILL`、不确认派生进程结束；N-4 的时序窗口一并保留 |
| **A-7** #21/#22 被放弃的命令可能继续运行并重叠 | 低 | **部分缓解** | 同 N-2 的运行内门闩；跨重启 + 手动入口仍可能重叠（L-3） |
| **A-8** #21 手动入口有意不做进程门控 | 低（设计取舍） | **仍存在（按现状接受）** | 手动路径仍不做进程门控；本版只把手动入口纳入整轮事务门控（`Sources/PiWebUpdateAdapter.swift:1460` 的 `guard !isUpdateInProgress`），确认框行为未变 |
| **A-9** 本地持久状态可被同用户读写、依赖模式化脱敏 | 低 | **仍存在** | 本版未新增持久键（§2 B9）；`Sources/ToolPath.swift` 只产出 PATH；新增的内存状态（`transactionInFlight`、`abandonedChildrenInFlight`、`abandonedProcesses`）不落盘；模式化脱敏的边界仍由 L-4 承担 |
| **A-1** 缓存可影响自动更新的目标版本 | 低 | **已闭环（维持）** | 本版进一步收窄结论来源（N-5 的 `UpdateVersionVerdict`），自动安装的 `origin == .network` 硬前置未变 |
| **F1** 内容哈希不可得时收紧降级判定 | 建议 | **已处理（部分）** | 即 #94 的 B-7 改动（`:679-688`）；「两者都缺 → 拒绝」这一半已落地，「只有 size+mtime 时是否还叫已降级」这一半未改 |
| **F2** 让「已放弃」防护判断进程存活 / 清除时更强确认 | 建议 | **未处理** | 记录字段与判定链未变（L-3） |
| **F3** 明确 npm `integrity` 是展示证据 | 建议 | **未处理** | 本版未触碰（N-3） |
| **F4** 发进程组信号前确认子进程尚未被回收 | 建议 | **未处理** | 调用顺序未变（N-4） |
| **F5** 说明缓存回退只能影响提示 | 建议 | **部分处理** | 结论侧已现算（N-5）；提示侧的来源标注仍是 alpha.4 的文案（本版未改） |
| **F6** 为「已放弃」记录评估弱标记 | 建议 | **未处理** | 记录结构未变（N-6） |

### 4.2 处置建议（Release Issue 用）

- **建议在本版接受、不再追加修复**：A-2、A-6、A-8、L-6（都是已文档化的取舍，且都在用户可见文案里写明）。
- **建议转后续 Issue**：N-3 / F3、N-4 / F4、N-6 / F6、L-3（跨重启存活判定）、L-7（环境策略统一）。
- **建议评估是否本版本修**：M-1（启动主线程阻塞）、L-1（用户级目录的权限/所有权检查）、
  L-2（退出时更新子进程读端）、L-5（新增抑制标记的 diff 可见性）。
- **不需要新 issue**：N-1 / A-4 / F1（本版已把最弱的一半收紧，剩余部分已在 `docs/privacy.md` 与
  用户可见文案里写明「不校验旧文件内容」）。

---

## 5. 能力边界与未覆盖、未验证

### 5.1 本报告的能力边界（沿用 alpha.4 的诚实性要求）

- 本报告是**静态**评审：结论来自读代码、读 diff、跑只读门禁与负向 grep，**不是**动态渗透测试。
- 没有真机执行过一次更新：没有跑过 `npm install -g`、`pi update --self`、`pi update npm:<包名>`，
  也没有触发过超时去观察进程组信号或管道行为。
- 没有 GUI/AppKit 运行环境：退出协调器、设置窗口单例、诊断导出窗口的行为只按代码与单测断言阅读。
- 没有验证任何签名/公证：本版仍是 **ad-hoc 签名、未公证**（发布说明自陈），因此「发布者身份」
  在本应用的能力之外；本报告不把任何内容哈希或 npm `integrity` 当作来源证明（与 alpha.4 一致）。
- 未覆盖（沿用 [alpha.1](security-review-alpha.1.md) 与 [alpha.3](security-review-alpha.3.md)）：
  服务所有权与 Keychain、远程访问密码与监听地址、`LogRedactor` 规则本身、CSP/WebKit 与网站数据、
  上游 `@agegr/pi-web` / `pi` 自身代码、npm CLI 与 registry 的行为、GitHub Releases API 的信任边界。
  本报告只在「更新流水线/工具 PATH 如何调用它们」的交叉点上引用这些机制。

### 5.2 未验证项清单（含「无法判定」的条目与所需证据）

| 条目 | 状态 | 需要什么证据才能判定 |
| --- | --- | --- |
| M-1 的最坏 26 s 主线程阻塞 | **分析结论**（未实测） | 一台有真实用户 shell rc（含慢初始化）的机器上测 `launch → 首窗口出现` 的耗时；或对 `AppDelegate.init` 加时间戳日志 |
| L-1 伪造 `npm`/`node` 是否真的被自动安装路径采用 | **未实测** | 在 `$TMPDIR` 里放一个假 `npm` 并把它所在目录排到 `~/.npm-global/bin` 之类的位置，观察 `PiWebUpdateNPMResolver.resolve` 的返回与子进程实际执行的路径 |
| L-2 退出应用是否真的让 `npm install -g` 中断（EPIPE/SIGPIPE） | **未实测** | 一次真实的「正在更新时退出应用」演练，并保留子进程退出码与 npm 日志 |
| L-3 被放弃的子进程是否仍在运行 | **无法判定**（应用自身也不判定） | 需要一次只读的进程存活检查（同一套 `ProcessInspector`）作为证据 |
| L-4 遮罩是否覆盖真实凭据形态 | **无法判定（完备性）** | 需要一份真实的 argv 样本集；本报告只确认了规则集合与路径一致 |
| L-5 秘密扫描规则集的完备性 | **无法判定（完备性）** | `--self-test` 只证明「已写下的规则会触发、已写下的样本不误报」；完备性需要独立的规则评审或模糊测试 |
| N-4 的 PID 复用窗口 | **分析结论**（alpha.4 遗留） | 需要可控时序的复现（例如注入替身让 `waitpid` 与超时处理严格交错） |
| I-2 打包产物是否可绕过 bundle 白名单 | **无法判定** | 需要按发布流程真实执行 `Scripts/package-release.sh`（本机无 Xcode，任务约束下未执行） |
| 本机未重跑的门禁 | **未执行** | `Scripts/build.sh`、`Scripts/check-identity.sh`、`Scripts/smoke.sh`、`xcodebuild test`（本机 `xcode-select` 指向 Command Line Tools，无 Xcode SDK） |

### 5.3 与发布说明 / PR 正文的一致性核对（我实际核对到的事实）

- **一致**：发布说明里关于「退出不再返回 `.terminateLater`」的说法与
  `Sources/QuitCoordinator.swift:26-38` 的两种回复一致；关于「放弃等待不关闭读端」的说法与
  `Sources/PiWebUpdateAdapter.swift:1228-1240` 的注释与实现一致；关于「菜单文案只有 Pi Web/Pi CLI 有
  重启可恢复提示」的说法与 `Sources/PiWebApp.swift:1386`、`:1426`、`:1593`、`:1647` 的门控读取点一致
  （扩展包入口走 `PiPackageUpdateRefusal`）；关于「PATH 三处共用」的说法与
  `Sources/PiWebApp.swift:166-174`、`:221-226`、`Sources/ServiceManager.swift:149` 一致。
- **不一致（唯一一处）**：`docs/release-notes-v0.1.0-alpha.5.md:343-344` 声明本版没有新增
  `docs/security-review-alpha.5.md`；本报告提交后该句不再成立（详见 I-3）。其余引用到的行号我抽查
  `Sources/PiWebUpdateAdapter.swift:1073`（`alreadyRunning: true`）、`:1217`（`String(decoding:)`）、
  `:1266`（`drainOutput`）三处，与发布说明一致。
- **无法核对**：发布说明与 PR 正文里的探针项数、`-typecheck` 结果、CI run 号等二手数字本机无法复现，
  本报告**不引用**它们作为安全结论依据。

---

## 6. 参考

### 6.1 本仓库文档（本次实际读过）

- [alpha.4 审查](security-review-alpha.4.md)（结构、严重度口径与遗留项的基准）
- [alpha.3 审查](security-review-alpha.3.md)、[alpha.1 独立安全与发布审查](security-review-alpha.1.md)
- [v0.1.0-alpha.5 发布说明](release-notes-v0.1.0-alpha.5.md)（仅用于交叉核对事实与 §5.3 的一致性检查）
- [SECURITY.md](../SECURITY.md)、[隐私说明](privacy.md)、[架构](architecture.md)、
  [发布流程](releasing.md)、[日志与诊断](logging-and-diagnostics.md)、
  [Alpha 发布门槛清单](alpha-release-checklist.md)

### 6.2 本 delta 涉及并在本报告中引用行号的源码

- 退出：`Sources/QuitCoordinator.swift`（新，286 行）、`Sources/PiWebApp.swift`（退出接线）
- 工具 PATH：`Sources/ToolPath.swift`（新，584 行）、`Sources/ProcessInspector.swift`、
  `Sources/DependencyChecker.swift`、`Sources/ComponentInstallation.swift`、`Sources/ServiceManager.swift`
- 更新检查与事务：`Sources/UpdateChecker.swift`、`Sources/UpdateTransaction.swift`、
  `Sources/UpdateVerifier.swift`、`Sources/PiWebUpdateAdapter.swift`、`Sources/PiCLIUpdateAdapter.swift`、
  `Sources/PiPackageUpdateAdapter.swift`
- 日志与诊断：`Sources/LogWriter.swift`、`Sources/DiagnosticsCollector.swift`、
  `Sources/DiagnosticsWindowController.swift`、`Sources/DiagnosticsClipboard.swift`、
  `Sources/PreferencesWindowController.swift`
- 遮罩：`Sources/PiProcessInspector.swift`（规则本体）
- 门禁与发布：`Scripts/scan-secrets.sh`、`Scripts/check-release-version.sh`、
  `Scripts/package-release.sh`、`Scripts/build.sh`、`.github/workflows/build.yml`、
  `.github/workflows/release.yml`、`Configuration/AppIdentity.xcconfig`
- 测试（只阅读，未运行）：`PiWebDesktopTests/ToolPathTests.swift`、
  `PiWebDesktopTests/QuitCoordinatorTests.swift`、`PiWebDesktopTests/UpdateTransactionTests.swift`、
  `PiWebDesktopTests/UpdateCheckerTests.swift`、`PiWebDesktopTests/UpdateSettingsTests.swift`、
  `PiWebDesktopTests/UpdateAbandonedAttemptTests.swift`

### 6.3 审查结论对应的提交范围

```
git log --oneline v0.1.0-alpha.4..838cb25
838cb25 chore(release): v0.1.0-alpha.5 版本 bump 与发布说明
6821ecd fix(update): 应用自更新安装器改为可重入并拒绝重叠 install，放弃等待不再关闭读端（审查 W2A A-1…A-8） (#95)
75b8e0d fix(update): 扩展包更新执行器每轮运行独立状态，身份与回滚结论不再超出证据（审查 W2 B-1/B-2/B-3/B-6/B-7…） (#94)
9929376 fix(deps): 子进程统一使用合并后的工具 PATH，修复 Finder 启动下的依赖误判 (GitHub #89) (#91)
25e7bea fix(release): 发布脚本补齐 build 号校验、优化构建、看门狗清理与包内容白名单 (#86)
224e4ea fix(privacy): 补齐命令遮罩开关形态、非绝对路径判 unknown、探针超时与取消 (#85)
85556e6 fix(service): 启动/停止状态机加代次校验与会话预算，停止标志集中清理 (#80) (#84)
3d10727 fix(tests): 后台日志写入断言改用确定性排空屏障，消除 CI 抖动 (#88) (#90)
b9c493f fix(app-windows): 设置窗口单例化、诊断导出后台化并补齐超时与 argv 遮罩 (#81) (#87)
bc4324e fix(log): 子进程输出改走管道 + 应用侧串行 O_APPEND 写入，轮转不再丢日志 (#79)
7484760 fix(scan): 补齐秘密扫描规则、收紧抑制标记并更新能力边界 (#78)
57671fc fix(update): 缓存回退结论按当前本机版本现算，旧缓存降级为不可判定 (#77)
7f11313 fix(quit): 退出决策移出 AppKit 终止序列并补齐超时兜底 (#76)
```

### 6.4 复现方式（只读）

```sh
git status --short && git diff --check && sh -n Scripts/*.sh
./Scripts/scan-secrets.sh --self-test
./Scripts/scan-secrets.sh --include-untracked   # 文件已跟踪后可直接 ./Scripts/scan-secrets.sh
sh Scripts/check-release-version.sh v0.1.0-alpha.5
# 负向证据
git grep -n 'sudo' -- Sources/ToolPath.swift Sources/QuitCoordinator.swift
git grep -nE 'kill\(|killpg|SIGKILL|posix_spawn' -- Sources/ToolPath.swift Sources/QuitCoordinator.swift \
  Sources/DiagnosticsCollector.swift Sources/LogWriter.swift
git grep -nE 'moveItem|copyItem|removeItem|unlink\(|rmdir|rename\(|truncate|write\(to:|createFile' -- \
  Sources/PiWebUpdateAdapter.swift Sources/PiCLIUpdateAdapter.swift Sources/PiPackageUpdateAdapter.swift \
  Sources/UpdateTransaction.swift Sources/UpdateVerifier.swift Sources/ToolPath.swift Sources/QuitCoordinator.swift
```

设计说明：本报告写在文档提交里，没有修改任何 `Sources/`、`Scripts/`、`Configuration/` 或其它文档；
文件本身不含主机名、私网地址、凭据或真实用户绝对路径（`./Scripts/scan-secrets.sh` 在包含本文件的
工作区上 PASS，见 §0.1）。
