# v0.1.0-alpha.6 安全评审（delta，只读）

- **审查对象**：`0.1.0-alpha.6` 相对 `0.1.0-alpha.5` 的改动，即 `git diff d6fa883..8b591c9`
  （3 个提交、10 个文件、+403 / −213 行）。本版**没有新增功能面**：只有一处界面布局修复、一组
  更新失败文案/门闩提示/放弃等待记录的语义对齐，以及一次 README 重写。
- **基线**：`v0.1.0-alpha.5` = `d6fa883`（`chore(release): v0.1.0-alpha.5 … (#98)`）→
  `8b591c9`（`main` 在发布提交创建前的 HEAD）。三个提交：
  - `3306398` `fix(settings): 设置窗口可自由缩放，表单滚动且底部按钮固定 (#100)`
  - `a47dd46` `fix(update): 更新失败文案与放弃等待记录对齐真实动作（W2 复核遗留） (#102)`
  - `8b591c9` `docs(readme): 重写为面向普通用户的安装与使用说明 (#104)`
- **本报告的性质**：由**自动化只读审查**产出（一次独立上下文的只读评审），**不是人工安全审计**。
  所有结论来自静态阅读与文本检索：未编译、未运行测试、未运行 GUI、未做动态时序实验。属于推断的
  地方标为「推断」，没有把握的地方标为「未验证」。体例沿用
  [alpha.5 安全评审](security-review-alpha.5.md) 与 [alpha.1 安全与发布审查](security-review-alpha.1.md)。

## 0. 范围与方法

### 0.1 本次实际执行的命令与结果（候选提交 `8b591c9` + 本版版本 bump 的工作区）

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 信号面 | `git grep -n "kill(" -- Sources` | 7 处：`DiagnosticsCollector.swift:221`（SIGKILL 到已知 pid）、`ProcessInspector.swift:168`/`:318`（pid）、`ServiceOwnership.swift:280`/`:285`（进程组） |
| 信号面 | `git grep -n "sendGroupSignal" -- Sources` | 调用点只有 `ServiceManager.swift:1307`（SIGTERM）、`:1313`（SIGKILL），定义在 `ServiceOwnership.swift:272`/`:278` |
| 进程组杀伤 | `grep -rn "killpg" Sources/` | 仅 `PiWebUpdateAdapter.swift:906`（`killpg(handle.processGroupIdentifier, SIGTERM)`）；全仓无 `SIGKILL` 调用 |
| 凭据面 | `git grep -ni 'password' -- Sources` / 与 `UserDefaults` 交集 | `password` 提及 126 处；对 `UserDefaults` 的写入中命中密码的行数 = 0 |
| 脱敏面 | `git grep -n "LogRedactor" -- Sources` | 79 处；实例点：`DiagnosticsCollector.swift:264`、`LogWriter.swift:78`、`PiCLIUpdateAdapter.swift:1054`、`PiPackageUpdateAdapter.swift:1577`、`PiProcessInspector.swift:445`、`PiWebUpdateAdapter.swift:1348`、`ServiceManager.swift:527` |
| 网络边界 | `git grep -n "0\.0\.0\.0\|\[::\]" -- Sources` | 通配集合仍只有 `KeychainStore.swift:230` 的 `allInterfacesHostnames`，保存路径拒绝一切解析为通配地址的写法 |
| 供应链 | `grep -n "uses:" .github/workflows/*.yml \| grep -v "@[0-9a-f]\{40\}"` | 空（Actions 全部固定完整 SHA）；`ls Package.swift` → 不存在 |
| 个人数据 | CI 的 `Check for accidental personal data` 步骤（同一条命令，先 `git add -A`；模式见 `.github/workflows/build.yml:56`） | 无匹配（本版曾命中两处真实用户路径，已改为 `~/orca/workspaces/…` 相对写法） |
| secret 扫描 | `./Scripts/scan-secrets.sh --self-test` / `./Scripts/scan-secrets.sh` | 均退出 0；`self-test: PASS (…)`；`suppressed 15 lines`（与 alpha.5 相同的测试夹具内联豁免）、`PASS (no matches in tracked files; no untracked files)` |
| 签名表述 | `codesign -dv --verbose=4` / `spctl -a -vv` | `flags=0x2(adhoc)`、`Signature=adhoc`、`TeamIdentifier=not set`；`spctl` → `rejected`（退出 3，未公证 ad-hoc 的预期结果） |
| 版本身份 | `./Scripts/check-identity.sh` / `./Scripts/check-release-version.sh v0.1.0-alpha.6` | `PASSED (45 checks)`、`PASSED`（脚本只做字符串比对，不检查 tag 是否存在） |

**未执行**：`xcodebuild build` / `xcodebuild test`（本机只有 Command Line Tools）、GUI 手工验收、
真实更新执行、注入时钟的时序实验。

### 0.2 负向证据（确认"某断言残留 / 某能力未引入"）

- `grep -rn "仍在使用旧版本" Sources/` → 仅 `Sources/UpdateTransaction.swift:382`（注释）、`:394`
  （`UpdateDegradationKind.displayName`）。本 delta 未改动该文件（**不在 diff 内**）。
- `grep -rn "旧版本保持不变" Sources/` → `PiCLIUpdateAdapter.swift:1255`、`PiWebUpdateAdapter.swift:1523`、
  `PiPackageUpdateAdapter.swift:1532`/`:1536`/`:1792`（日志行）。
- `grep -rn "仍在使用更新前的版本" Sources/` → `PiCLIUpdateAdapter.swift:1034`、
  `PiWebUpdateAdapter.swift:1319`、`PiPackageUpdateAdapter.swift:1517`（验证失败路径，有重检测探针）。
- `grep -n "重启应用" Sources/PiCLIUpdateAdapter.swift` → 只命中 `:639-640` 的注释，界面文案未命中。
- `grep -rn "\.abandon()" Sources/PiWebApp.swift` → 只有 `:438`（`piCLIUpdateRunner.abandon()`）。

## 1. 本版变化摘要（逐提交，结论独立得出）

### 1.1 更新语义对齐（`a47dd46`，`Sources/PiCLIUpdateAdapter.swift` +48/−9、`PiPackageUpdateAdapter.swift` +22/−1、`PiWebUpdateAdapter.swift` +3/−1）

1. **失败瞬时文案**：CLI / Web 两路从「更新失败，仍在使用旧版本」改为与扩展包一致的
   「更新失败，没有执行任何回滚动作」（`PiCLIUpdateAdapter.swift:1025-1026`、
   `PiWebUpdateAdapter.swift:1310-1311`、`PiPackageUpdateAdapter.swift:1507-1508`）。
   命令失败不能证明旧文件未被改动，旧文案是无探针支撑的断言——**这次修改方向是变保守**。
2. **扩展包忙拒绝的两种理由**：新增 `PiPackageUpdateRefusal.executorBusyAwaitingAbandonedChildExit`
   与结果字段 `awaitingAbandonedChildExit`（`PiPackageUpdateAdapter.swift:1014`/`:1024`/`:1035`/`:1186`）。
   **`startLocked` 的守卫 `guard !running, abandonedProcesses.isEmpty else`（`:1179`）原样保留**，
   新字段只决定协调器选哪个拒绝原因（`:1705-1707`）→ 文案（`:286-288`）→ 日志（`:1526`）→ 弹窗
   （`PiWebApp.swift:1984`）。菜单可用性没有新增条件（`PiWebApp.swift:2922` 仍是
   `dependencyGate == .ready`）。子进程正常退出即解除门闩（`settleAbandonedChildLocked`：
   `PiPackageUpdateAdapter.swift:1227` → `:1384-1386`）。
3. **排水宽限窗口内的 `abandon()` 守卫**：CLI `PiCLIUpdateAdapter.swift:617-630`（新守卫 `:623-624`：
   `guard !attempt.finished, attempt.pendingFinish == nil, attempt.process?.isRunning != false else { return }`）、
   扩展包 `PiPackageUpdateAdapter.swift:1155-1164`（新守卫 `:1161`）。被守卫拦下的一轮仍会结算：
   `finishLocked`（CLI `:819-839`、包 `:1355-1361`）+ `scheduleDrainDeadlineLocked`（CLI `:840-853`、
   包 `:1397-1404`，含 `self.drainTimer === timer` 身份检查）。CLI 另加超时排期的同型守卫与有界让出：
   `defaultPipeDrainGrace = 0.5`（`:513`）、`timeoutRetryDelay = 0.2`（`:516`）、`maxTimeoutRetries = 5`（`:517`），
   包侧同值（`PiPackageUpdateAdapter.swift:1084`/`:1088`/`:1089`）；重试分支 `PiCLIUpdateAdapter.swift:730-732`、
   `PiPackageUpdateAdapter.swift:1285-1287`。
4. **测试**：新增 5 个确定性用例（CLI 59 行、包 94 行），含
   `testRealExecutorAbandonDuringDrainGraceKeepsSuccessfulExit`（两个执行器各一份）、
   `testBusyRunAwaitingAbandonedChildExitReportsRecoverableReason` 与对照组
   `testBusyRunWithoutUnconfirmedChildReportsExecutorBusy`。

**攻击面变化**：无新增执行路径、权限或网络出口；两处行为改动都朝更保守方向（多一个更准确的拒绝理由、
不再在排水窗口写失实的「已放弃」记录）。信号语义未变（`killpg` 仍只在 Pi Web 安装器，且只对本次启动的
进程组发一次 SIGTERM；CLI 与扩展包不发信号）。

### 1.2 设置窗口布局（`3306398`，`Sources/PreferencesWindowController.swift` +127/−24）

逐条检查后全部落在布局：`formMinimumWidth = 520`（`:9`）、`rowFieldMinimumWidth = 200`（`:15`）、
`windowMinimumContentSize`、`FlippedDocumentView`、`WrappingLabel`（每次布局更新
`preferredMaxLayoutWidth`）、`styleMask` 增加 `.resizable`/`.miniaturizable`、`contentMinSize`、
表单进 `NSScrollView`、底部 `footer` 固定 `errorLabel` 与取消/保存按钮、`setFrameUsingName` /
`setFrameAutosaveName("PiWebDesktopPreferencesWindow")`。对 diff 做
`UserDefaults|Key|keychain|Keychain|ServiceConfiguration|validate|range` 过滤后，命中全部是**未改行**
（`onSave: ((ServiceConfiguration) -> Void)?`、`private let keychain: KeychainStoring`、
`autoStartButton.target/action`）或 `invalidateIntrinsicContentSize()`；没有字段集合、取值范围、校验、
Keychain 项、存储键的改动。**唯一新增持久化是窗口尺寸/位置的自动保存（非敏感 UI 状态）。**

### 1.3 README 重写（`8b591c9`，`README.md`）

只做了安全相关浏览：无遥测；出站仅 `api.github.com` 与 `registry.npmjs.org`；不调用 `sudo`；
明确不要求关闭 Gatekeeper/SIP；写明「密码认证不等于传输加密」并建议 SSH 隧道或 HTTPS 反向代理；
诊断包自带脱敏但声明「脱敏不能保证万无一失」；默认只监听 `127.0.0.1` 且拒绝 `0.0.0.0`/`::`；
自动更新默认关闭；写明 Pi Web 自动更新会以用户权限执行上游安装脚本。未发现新增能力或弱化安全表述。
**局限**：未与 alpha.5 的 README 逐字对照，未审计外链与「下载物附带校验和」的可获得性。

## 2. 结论（是否阻塞发布）

**无阻断项。** 计数：中 1 条（M-1）、低 5 条（L-1 … L-5）、信息 5 条（I-1 … I-5），**0 条阻断**。
判定规则见 [alpha 发布门槛清单](alpha-release-checklist.md#安全门槛14-审查结论映射) 与
[alpha.1 报告](security-review-alpha.1.md) §11.2。

理由：

1. **无新增能力面**：没有新的执行路径、信号调用、权限或网络出口；`killpg` 仍只出现在 Pi Web 安装器
   （`Sources/PiWebUpdateAdapter.swift:906`）。
2. **两处行为改动都更保守**：扩展包忙时拒绝只增加了一个更准确的拒绝理由（守卫条件未变）；排水窗口的
   `abandon()` 守卫阻止了失实历史记录。
3. **唯一的布局改动不含配置/存储/权限语义**，新增持久化仅为窗口 frame。
4. **发现的 6 条问题全部是文案/一致性问题**（M-1、L-1、L-2、L-3、L-5）或有界记录瑕疵（L-4），
   不改变文件操作、进程信号或权限语义。
5. M-1 建议作为下一次文案修正处理；它不构成发布阻断。

## 3. 发现（按严重性：中 → 低 → 信息）

### 3.1 中

#### M-1（中，用户可见一致性）：`UpdateTransaction.swift:394` 的 displayName 与同一弹窗里的新文案互相矛盾

- 证据：残留断言 `Sources/UpdateTransaction.swift:394`
  （`.installFailedKeepingPreviousVersion → "更新失败，仍在使用旧版本"`，同文件 `:382` 的注释同义）；
  与它同时出现在一个弹窗里的新文案是 `Sources/UpdateTransaction.swift:732-734`
  （`UpdateWarningText.installFailed` → 「…更新失败，没有执行任何回滚动作（更新前版本 …，目标版本 …；原因：…）。
  应用不声称更新成功，也未核对更新前的文件是否被改动。」）。
  展示路径：`Sources/PiWebApp.swift:1350-1355` 的 `latestUpdateDegradationText()`
  （`kind` 来自 `updateHistory().first.degradationKind`，定义 `Sources/UpdateTransaction.swift:1001`、
  字段 `:1012`、写入 `:923`、持久化 `:1134`/`:1155`）拼进 `Sources/PiWebApp.swift:1248`、`:1263`、
  `:1675`、`:1689`、`:1984` 的同一个失败弹窗。
- 项目自身标准反证：同一文件 `Sources/UpdateTransaction.swift:954-955`
  （`UpdateHistoryDescription.rollbackDescription`，即拼在 displayName 后面的 `detail`）写
  「安装失败，未尝试回滚（命令失败不证明旧文件未被改动，因此不断言系统状态未改变）」。
- 影响：用户在同一弹窗读到两条互斥结论；后一条无探针支撑。属「失败文案去断言」修复的漏网，
  不改变任何动作、权限或文件操作。**`Sources/UpdateTransaction.swift` 不在本 delta 内**，是既有代码。
- 建议：把 `:394` 的 `.installFailedKeepingPreviousVersion` 文案改为「更新失败，没有执行任何回滚动作」，
  或让 `latestUpdateDegradationText()` 只用 `rollbackDescription`、不再拼 `displayName`。
  **不要动 `:395`**（`.stillUsingPreviousArtifact`，该路径有探针证据，见同文件 `:703` 的指纹证据描述）。
- 可验证方式：`grep -rn "仍在使用旧版本" Sources/`；`grep -rn "仍在使用更新前的版本" Sources/`。

### 3.2 低

#### L-1（低）：三路日志仍写「旧版本保持不变」

- 证据：`Sources/PiCLIUpdateAdapter.swift:1255`、`PiWebUpdateAdapter.swift:1523`、
  `PiPackageUpdateAdapter.swift:1532`/`:1536`/`:1792`。日志对用户可读（菜单「打开日志」见
  `Sources/PiWebApp.swift:724`；README 给出 `~/Library/Logs/Pi Web Desktop/…` 路径）。
- 影响：命令失败（非零退出/超时/放弃等待/验证失败）时写下的日志同样在断言外部镜像文件的版本状态，
  而这条断言没有探针核对——正是 B-6 想消除的一类，只是出现在日志而不是弹窗。
- 建议：日志行与弹窗统一（「没有执行任何回滚动作；未核对旧文件是否被改动」），或显式注明
  「日志只记录命令事实，不代表文件状态」。

#### L-2（低，遗留）：`detectedVersion == nil` 时「仍在使用更新前的版本」句内不自洽

- 证据：`Sources/PiCLIUpdateAdapter.swift:1034`、`PiWebUpdateAdapter.swift:1319`、
  `PiPackageUpdateAdapter.swift:1517`：`"更新后验证失败，仍在使用更新前的版本：…重新检测到的版本是 \(detectedVersion ?? "未知")，未达到目标版本"`。
- 影响：`detectedVersion == nil` 时，同一句一边断言「仍在使用更新前的版本」，一边承认「检测到的版本：未知」。
  本 delta 只改了 install 失败路径，这三处未被 #102 触及。**推断**：兜底说明意味着存在重检测返回 nil
  的路径（未构造运行验证）。
- 建议：nil 时改为「未能确认更新后版本，因此不断言当前版本」。

#### L-3（低，一致性）：CLI 的「更新进行中」拒绝文案独缺「重启应用可恢复」

- 证据：`Sources/PiCLIUpdateAdapter.swift:82`（`.updateAlreadyInProgress` 文案无恢复提示）；
  映射 `:1227-1230`（`failure == .alreadyRunning` → `.notAttempted(.updateAlreadyInProgress)`）；
  弹窗只显示 `"原因：\(reason.text)"`（`Sources/PiWebApp.swift:1701-1711`）；而菜单标题会给恢复路径
  （`Sources/PiWebUpdateAdapter.swift:59` 的 suffix，经 `Sources/PiWebApp.swift:2886`/`:2895` 注入
  Pi Web 与 CLI 两个入口）；扩展包对应文案有提示（`Sources/PiPackageUpdateAdapter.swift:286-288`）。
  代码注释与本实现不一致：`Sources/PiCLIUpdateAdapter.swift:639-640` 明确要求「必须给出『重启应用即可恢复』
  的可见提示」。
- 影响：同一「退出未确认」状态，菜单给恢复路径、CLI 弹窗不给；三路中只有 CLI 缺。可用性问题。
- 建议：对齐 `:82` 的文案，或在 `Sources/PiWebApp.swift:1706-1708` 的 `notAttempted` 分支补一句恢复提示。

#### L-4（低）：超时重试上限（1.0s）之后仍可能落一条失实的「已放弃」记录（有界）

- 证据：常量与重试分支见 §1.1 第 3 条；上限合计 5 × 0.2s = 1.0s，之后进入超时终态分支（写
  `timedOut` 与「已放弃」记录）。迟到的退出通知会解除门闩（`PiCLIUpdateAdapter.swift:812-817`、
  `PiPackageUpdateAdapter.swift:1384-1386`），但已落定结果不被改写（`finishLocked` 的
  `guard !attempt.finished`：`PiCLIUpdateAdapter.swift:820`、`PiPackageUpdateAdapter.swift:1356`）。
- 影响（**推断**，未做时序实验）：子进程在超时后 1s 内退出、但退出通知晚于 1s 时，会写一条
  `finishedAt == nil` 的「已放弃」记录并投递 `exitCode == nil` 的超时结果；该记录会让**下次启动**的
  自动更新被推迟、手动入口需先确认这条记录（deferral 语义见 `Sources/PiCLIUpdateAdapter.swift:92-95`）。
  记录语义是「结束时间未知」，仍然为真，因此影响是「多一次确认 + 一条不准确的历史」，不是安全缺口。
- 建议（可选）：把上限调到能覆盖常见 termination 延迟，或在记录里注明「命令可能已结束，但退出通知未到」。

#### L-5（低/信息）：扩展包 runner 退出时不 `abandon()`，重启恢复可能与仍在运行的旧 `npm` 子进程重叠

- 证据：`Sources/PiWebApp.swift` 的 `.abandon()` 只有 `:438`（CLI runner）；包 runner 在退出路径没有对应
  调用。门闩是内存态（`Sources/PiPackageUpdateAdapter.swift:1114` 声明、`:1377-1380` 注册、
  `:1384-1386` 解除、`:1179` 用作守卫）。
- 影响：退出时若包更新在飞，既不会有「已放弃」记录，也不会有弹窗（子进程可能活过 App，这符合「不发信号」
  的既定语义）；提示推荐的重启会清空内存门闩，但旧 `npm i -g` 子进程可能仍在运行 → 重启后的第二次全局
  安装可能与它重叠。这与 Pi Web 侧既有做法一致（`Sources/PiWebUpdateAdapter.swift:59`/`:67` 同样建议重启），
  属已有设计权衡。
- 建议：在扩展包拒绝文案或文档里补一句「重启后如果旧命令仍在运行，可能与新命令重叠」，让恢复代价显式化。

### 3.3 信息（记录，不构成风险判定）

- **I-1**：新门闩只影响文案，不改变「能/不能执行更新」的判定（证据见 §1.1 第 2 条，包括
  `startLocked` 守卫未变、菜单可用性未变、子进程正常退出即解除）。永不退出时门闩在本次进程生命周期内
  一直关闭，但提示写明「重启应用即可恢复」，菜单项仍可点（可发现）。
- **I-2**：排水宽限窗口内的 `abandon()` 守卫**不会**造成「既不结算也不记录」（证据见 §1.1 第 3 条）。
  交互后果（记录，不算缺陷）：用户在排水窗口点击「放弃等待」会被静默忽略（命令其实已结束），
  这次点击不留痕。
- **I-3**：未引入新的用户可见执行能力；信号语义与 alpha.5 一致（见 §1.1 末尾与 §0.1 的 `killpg` 证据）。
- **I-4**：设置窗口改动仅为布局 + 窗口 frame 自动保存（证据见 §1.2）。
- **I-5**：README 的安全相关表述与既有承诺一致（未做逐字对照，见 §1.3）。

## 4. 上一版遗留项复核

| alpha.5 报告 / 发布说明里的项 | 本版状态 |
| --- | --- |
| CLI/Web 安装失败瞬时文案仍断言「仍在使用旧版本」（B-6 的 CLI/Web 两路） | **已修**（§1.1 第 1 条）；`UpdateTransaction.swift:394` 的同类残留见 M-1（仍是本版已知问题，登记 #106） |
| 扩展包执行器「已放弃等待、退出未确认」时只给「执行器忙」笼统提示 | **已修**（`executorBusyAwaitingAbandonedChildExit` + 重启恢复提示；仍是菜单门控不变，见 I-1） |
| 包 / CLI 执行器在排水宽限窗口内会写失实的「已放弃」记录 | **已修**（守卫 + 有界让出 + 可注入 `pipeDrainGrace`）；Web 执行器的同类窗口仍在（登记 #108） |
| B-4、B-5、B-8 … B-13（W2B）与 F5、F6、F7（W2A） | 未修，按范围拆成 #105 / #106 / #107 / #108（下一版处理） |
| 「旧版本引用写死 alpha.1」（`.github/ISSUE_TEMPLATE/bug_report.yml:16`、`SECURITY.md:11`、`:28`） | 仍未改，本版把长期建议落成真实 follow-up issue **#109** |
| 未公证 / ad-hoc、更新验证边界、回滚能力有限、不保证被放弃的子进程结束 | 未变（本版不涉及这些路径） |

### 4.1 处置建议（Release Issue 用）

- **M-1**：接受为本版已知问题（不阻断），列入 #106（「降级历史状态与探针归因如实化、两套失败文案收敛」），
  下一版修。
- **L-1 / L-2**：接受；建议与 M-1 同一批处理（同属「断言旧文件状态」的文案族），可并入 #106。
- **L-3**：接受；建议并入 #108 或单独一个小 PR（文案 + 一处弹窗分支）。
- **L-4**：接受（有界：最多 1.0s 窗口、一条记录）；如后续要做注入时钟的时序测试，登记到 #108。
- **L-5**：接受（既有设计权衡，与 Pi Web 侧一致）；若在 #107 里改扩展包文案，可顺带补一句重叠提醒。
- **I-1 … I-5**：仅记录，无需处置。

## 5. 能力边界与未覆盖、未验证

### 5.1 本报告的能力边界

- 报告由自动化只读审查产出，**不是人工审计**；结论强度等价于「严格的静态阅读 + 文本检索」，不含动态验证。
- 未编译、未运行任何测试、未运行 GUI、未做时序实验、未做 UI 快照/无障碍/本地化审查。
- 行号来自文本检索（`grep` / `sed` 输出），未经编译器核对。

### 5.2 未验证项清单

1. 新增的 59 + 94 行测试是否通过、其断言是否与源码一致（由 CI 覆盖，本机无 Xcode）。
2. 设置窗口的缩放/滚动/按钮固定的实际行为、窗口 frame 自动保存键的实际落盘。
3. M-1 的用户可见性：`latestUpdateDegradationText()` 依赖 `updateHistory().first` 有 `degradationKind`；
   写入（`Sources/UpdateTransaction.swift:923`）与持久化（`:1134`/`:1155`）路径已核对，但未运行到该分支，
   弹窗必然包含该段文字属**按代码路径推断**。
4. L-4 的时序结论为代码推断（未做注入时钟实验）。
5. L-5：「包 runner 退出时不 `abandon()`」是否为 alpha.4 / alpha.5 已记录项，未回溯核对（本次只审 delta）。
6. README 未逐字对照 alpha.5，未审计外链与发布物校验和的可获得性。
7. 三条更新失败路径的实际弹窗拼接效果未观察（未运行 GUI）。

## 6. 参考

- 本仓库文档：[alpha.1 安全与发布审查](security-review-alpha.1.md)、[alpha.5 安全评审](security-review-alpha.5.md)、
  [alpha 发布门槛清单](alpha-release-checklist.md)、[v0.1.0-alpha.6 Release 说明](release-notes-v0.1.0-alpha.6.md)、
  [架构](architecture.md)、[日志与诊断导出](logging-and-diagnostics.md)、[隐私说明](privacy.md)、
  [SECURITY.md](../SECURITY.md)。
- 本 delta 引用行号的主要源码：`Sources/PiCLIUpdateAdapter.swift`、`Sources/PiPackageUpdateAdapter.swift`、
  `Sources/PiWebUpdateAdapter.swift`、`Sources/UpdateTransaction.swift`、`Sources/PiWebApp.swift`、
  `Sources/PreferencesWindowController.swift`、`Sources/ServiceOwnership.swift`、`Sources/ServiceManager.swift`、
  `Sources/KeychainStore.swift`、`Sources/LogWriter.swift`、`Sources/DiagnosticsCollector.swift`、
  `PiWebDesktopTests/PiCLIUpdateAdapterTests.swift`、`PiWebDesktopTests/PiPackageUpdateAdapterTests.swift`。
- 审查范围：`git diff d6fa883..8b591c9`（3 个提交、10 个文件、+403 / −213 行）。
- 复现方式（只读）：`git diff d6fa883..8b591c9`、`grep -rn …`（见 §0.1、§0.2 的各条命令）；
  签名与身份复现：`./Scripts/build.sh && ./Scripts/check-identity.sh && codesign -dv --verbose=4 build/Pi-Web-Desktop.app`。
