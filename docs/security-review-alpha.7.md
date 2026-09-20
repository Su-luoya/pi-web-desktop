# `v0.1.0-alpha.7` 安全评审（delta）

- **评审对象**：`git diff b162544..4e6e332`，即 `v0.1.0-alpha.6`（`b162544`）到本版发布提交之前的 `HEAD`
  之间的六个提交 —— 修复 `af47866`（#105 / PR #112）、`0c1610c`（#106 / PR #115）、`fbae499`
  （#107 / PR #117）、`4e6e332`（#108 / PR #116），文档同步 `be13c88`（#109 / PR #114）与发布值回填
  `9ede020`（#113）。
- **评审方式**：只读评审。评审者在一个独立上下文里工作（只读工具集：读取、`git diff/show/log -S`、
  `grep`、`sed`），不写仓库任何文件、不提交、不推送；评审过程中未运行构建或测试。本报告的落盘、
  结论引用与发布决定由发布执行者完成。
- **已知的过程瑕疵（如实记录）**：本版原计划由 Orca 编排下的独立只读工人执行这次 delta 评审
  （`task_b1489e938b4a`），该工人在读取规范后因模型账号额度不足（`403 insufficient_user_quota`）
  中断、未产出报告，其 Dispatch 停在 `stop_unknown`、任务仍标记为 dispatched；随后由发布执行者派发
  上段所述的独立只读评审完成本报告。因此本报告**不是**由发布执行者自审，但它也不是 Orca 编排记录
  里的那次任务。

## 结论

**阻断项 0。**中危 2 项（`F1`、`F2`），低危 4 项（`F3` – `F6`）。六项都不改变信号语义、文件操作、
权限范围或凭据处理，全部登记在
[#121](https://github.com/Su-luoya/pi-web-desktop/issues/121)，其中 `F1`、`F2` 建议在下一个版本处理。

与 `v0.1.0-alpha.6` 的关系：本次 delta 的输入就是 alpha.6 那两份独立复核（W2A / W2B）与 alpha.6
delta 评审（`docs/security-review-alpha.6.md`）的结论；本版没有引入新的能力面，因此评审只针对
「修复本身是否引入新问题」。

## 逐面结论

**(a) 子进程启动与参数构造 — 无发现（净加固）。** argv 固定为 `["install","-g","name@version"]`
（`Sources/PiWebUpdateAdapter.swift:331`），先过 `PiWebUpdateArgumentPolicy.isSafe`（`:332`），再以 argv
数组交给 `posix_spawn`（`:929-937`）；没有 shell 字符串、没有 `sudo`。对整个 `Sources` diff 搜索
`SIGTERM|SIGKILL|sudo|ignore-scripts|--prefix|shell|system(|popen|/bin/sh|/bin/bash` 为 0 命中。本次
delta 只**增加**拒绝分支（`:526-532`），未引入新的参数插值路径。

**(b) 信号语义 — 无发现。** delta 内没有 `SIGTERM` / `SIGKILL` 的文本变更。Pi Web 仍然只在能自证
「子进程独享进程组」时向该组发一次 `SIGTERM`（`Sources/PiWebUpdateAdapter.swift:848` 及
`terminateOwnProcessGroupLocked`），否则记 `processGroupUnavailable` 且不发信号；Pi CLI 与扩展包路径
始终不发信号（`childProcessAction: .waitedWithoutSignals`）。唯一的方向性变化是 `4e6e332` 新增的
「进程退出后把读端保留到 EOF」（`:1345-1352`、`:1363-1371`），它**降低**被放弃子进程遭遇 `SIGPIPE`
的概率 —— 更保守，且被 `testProcessInstallerKeepsTailWrittenAfterParentExit` 覆盖。

**(c) 有界性 — 基本合格，一处时长无界（`F4`）。** 新增的硬上限：`package.json` 512 KiB、锁文件
4 MiB（`Sources/UpdateVerifier.swift:71-72`、`:158-193`）、输出尾巴 2000 字符
（`Sources/PiWebUpdateAdapter.swift:1021`、`:1312-1314`）、解码器暂存 ≤3 字节（`:24-45`）、排水宽限
0.5s（`:1023`、`:1324-1336`）。超时：Pi Web 单次 300s 不重试（`:1499`），Pi CLI 与扩展包
`maxTimeoutRetries = 5`（`Sources/PiCLIUpdateAdapter.swift:517/732`、
`Sources/PiPackageUpdateAdapter.swift:1103/1311`）→ 最坏 6 次，有界但成倍；两处都是既有设计，本 delta
没有放宽。真正「时间无界」的只有 `F4` 的 FIFO 读。

**(d) 可执行文件解析与 `PATH` — 无新漏洞，但保证有限（`F3`）。** 新增项都是收紧：`candidates` 跳过
空项与非 `/` 开头项（`Sources/PiWebUpdateAdapter.swift:612-623`），planner 在 npm 路径为空且 `PATH`
含相对项时给出明确拒绝（`:526-530`），并对已解析路径再做一次形状校验（`:531-532`）。局限见 `F3`。

**(e) 文件 / JSON / 锁文件解析边界 — 无新漏洞（配合 `F4`）。** 三个上限足以拒绝超大文件，且
`readBoundedData` 以 `maximumSize + 1` 读取以侦测「读前变大」（`Sources/UpdateVerifier.swift:158-193`）；
损坏 JSON 让 `JSONSerialization` 失败即返回 nil，不会崩。符号链接：`attributesOfItem` 跟随链接，大小
上限作用于目标，大文件仍被拒。`integrity` 取值确定化正确：`packages["node_modules/<name>"]` 命中即
返回、**不回退**（`:280-283`），后缀歧义计数 >1 时返回 nil（`:285-291`），有条目版本时要求版本严格
相等（`:264-279`）。

**(f) 权限与 npm 语义 — 无变化。** 没有新增 `--ignore-scripts`、`--prefix`、提权，也没有改变全局安装
语义：仍是 `install -g <name>@<version>`（`Sources/PiWebUpdateAdapter.swift:331`），并且刻意不传
`--ignore-scripts` 并附了理由（`:283-293`、`:328`）；`Sources/InstallCommandManifest.swift:37`、`:60`
的手动命令文案未改。生命周期脚本照旧执行 —— 这是既有取舍，不是本 delta 引入。

**(g) 日志与脱敏 — 新增日志均脱敏；一处既有类型边界未脱敏（`F6`）。** 新增的写入路径：`logOutputTail`
（`Sources/PiWebUpdateAdapter.swift:1799-1804`，脱敏后写）、`logOutcome`（各适配器内都过
`redactor.redact`，例如 `Sources/PiPackageUpdateAdapter.swift:1776`）、「已放弃」摘要走
`makeCommandSummary(redactingWith:)`（`Sources/PiWebUpdateAdapter.swift:1260-1263`）。跨越读取块的凭据
在**组装完成后**才脱敏，新解码器让重建更完整，脱敏反而更可靠，没有发现绕过。

**(h) 回滚 / 删除 / 安装作用域 — 未扩大。** 对 `Sources` diff 搜索
`removeItem|unlink|delete|rm -|trash` 为 0 命中：没有新增删除或卸载动作。降级语义只改「标签与归档
状态」（`applied` / `recordedOnly` / `notPossible`，`Sources/UpdateTransaction.swift:81-86`、`:889-905`），
回滚仍不删文件、只改指向或记状态；扩展包的生产 `applyDegradation` 仍是显式 no-op
（`Sources/PiWebApp.swift:312-316`）。

**(i) 测试覆盖。** 已覆盖的新分支：Web / CLI 跨块 UTF-8
（`testProcessInstallerPreservesUTF8SplitAcrossChunks`、`testRealExecutorPreservesUTF8SplitAcrossChunks`）、
排水期间 `cancel()` 保留退出码（`testProcessInstallerAbandonDuringDrainGraceKeepsSuccessfulExit`）、
父进程退出后仍保留尾部（`testProcessInstallerKeepsTailWrittenAfterParentExit`）、进程保护优先于
「已放弃」确认（`testProcessRefusalOutranksAbandonedAttemptConfirmation`）、读状态喂给菜单
（`testExecutorReadStateFeedsTheMenuEntryState`）、降级恰好一次
（`testInstallFailureAppliesDegradationExactlyOnce`、
`testVerificationFailureStillAppliesDegradationAndSuccessNeverDoes`）、`integrity` 精确路径 / 版本不符 /
歧义（`testIntegritySelectionPrefersExactPathAndRejectsVersionMismatchOrAmbiguity`）、超大文件预检
（`testBoundedMetadataReadsRejectOversizedFilesBeforeOpening`）、不可解析目标版本
（`testVersionReachedRejectsUnparseableTarget`）、探针归因
（`testUnavailableProbeIsAttributedToTheProbeNotToChangedEvidence`）、降级状态映射、成功历史带健康检查
（`testSuccessfulUpdateHistoryRecordsPassedHealthCheck`）、相对 `PATH` 过滤
（`testRelativePATHEntryIsFilteredAndReportedPrecisely`）。

**未见对应测试的新分支**：`readBoundedData` 的「读取过程中文件变大 → nil」路径；Web planner 对
「绝对但非法路径」的 `unsafeExecutablePath` 守卫（`Sources/PiWebUpdateAdapter.swift:531`，现有测试只覆盖
npm 路径为 nil 的情形）；排水宽限**到期**分支（现有两条测试的 EOF 都在宽限内到达或与宽限赛跑，未
确定性地触发截止路径）；`recordVerification` 重复调用的覆盖写不变量
（`Sources/UpdateTransaction.swift:846`）；以及 `F2` 的扩展包跨块解码。
`PiWebDesktopTests/UpdateAbandonedAttemptTests.swift` 只加了 2 行
（给 `RecordingPiPackageRunner` 补 `isRunning` / `abandonedChildrenUnconfirmed` 存根），没有新断言。

## 发现

### F1（中）主线程读扩展包执行器状态可能长时间阻塞

`Sources/PiWebApp.swift:2902-2906`、`:2935-2937` 在**主线程**读扩展包执行器的 `isRunning` /
`abandonedChildrenUnconfirmed`，两者走 `stateQueue.sync`；而同一个 `stateQueue` 上跑着协调器整条
安装后同步链（`detectPackageVersion` 同步起 `pi list` 子进程、`UpdateVerifier.verify` 现场探针、写
历史），因为 `completeLocked` 在 `stateQueue` 上直接调用 `completion?(result)`
（`Sources/PiPackageUpdateAdapter.swift:1468`）。菜单刷新因此可能被阻塞数秒 —— 正是更新进行中用户最
可能打开菜单的时刻。

修法：让扩展包执行器像 Pi Web / Pi CLI 一样在独立投递队列上交结果（参考
`Sources/PiWebUpdateAdapter.swift:1363-1371`、`Sources/PiCLIUpdateAdapter.swift:923-929`），或把两个读
状态改成非阻塞原子快照。

### F2（中）扩展包执行器仍在有损解码路径上

`Sources/PiPackageUpdateAdapter.swift:1367` 仍然是
`guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }`：一次读把多字节
字符截断时，整块（含其前面已完整的文本）被静默丢弃。`4e6e332` 恰好在 Pi Web / Pi CLI 修掉了这一类
问题（`Sources/PiWebUpdateAdapter.swift:6-45`、`Sources/PiCLIUpdateAdapter.swift:565-566`、`:798-799`），
扩展包执行器被留在有损路径上。

修法：在 `ProcessPiPackageUpdateCommand.receive` 复用 `IncrementalUTF8Decoder`，并补一条与 Pi Web /
Pi CLI 同构的「跨块 UTF-8」测试。

### F3（低）`PATH` 目录本身是信任边界，路径校验只能做形状检查

`Sources/PiCLIUpdateAdapter.swift:166`（被 `Sources/PiWebUpdateAdapter.swift:531` 的新守卫调用）与
`Sources/PiWebUpdateAdapter.swift:590-637` 的校验只要求绝对路径、字符集合法、无 `..`，不校验存在性、
是否可执行、文件属主、目录是否可写；`candidates` 也只过滤相对项与空项。`resolve()` 的
`isExecutableFile(atPath:)` 到 `posix_spawn` 之间仍有 TOCTOU 窗口：能在某个绝对 `PATH` 目录里写入
`npm` 的攻击者会被执行。

修法：明示信任模型（`PATH` 目录即信任边界），或补 `lstat` 属主 / 目录可写性检查，并在计划里记录
实际解析结果。

### F4（低）有界读只约束字节数，不约束时长

`Sources/UpdateVerifier.swift:151-193`、`:259-264` 的 `fileSize` 走 `attributesOfItem`；若
`package.json` / 锁文件被替换为 FIFO（或指向 FIFO 的符号链接），大小可读为 0 通过
`size <= maximumSize`，随后 `FileHandle.read` 阻塞，`verify()` 会无超时地挂住（代码可证
`readBoundedData` 没有超时参数；FIFO 语义为推断，评审时未在本机复现）。

修法：读取前用 `lstat` 拒绝非常规文件，或把探针读取放到带超时的后台队列。

### F5（低）排水宽限窗口内的 `cancel()` 静默失效

`Sources/PiWebUpdateAdapter.swift:1124-1127` 新增 `attempt.pendingFinish == nil` 守卫后，排水宽限窗口
（≤0.5s）内的 `cancel()` 会静默失效：调用方以为取消了，结果却是 `cancelled == false` 加真实退出码
（`testProcessInstallerAbandonDuringDrainGraceKeepsSuccessfulExit` 固化了该行为）。语义可辩护（子进程
已退出、没有可发的信号），但无法区分「取消被忽略」与「没来得及取消」。

修法：在结果里带一个「取消请求落在收尾窗口内」的标记，或至少在日志里说明。

### F6（低，既有行为）Pi Web 安装失败的 outcome 携带未脱敏输出尾巴

`Sources/PiWebUpdateAdapter.swift:1647`（对照 `:1799-1804`）：Pi Web 安装失败时 outcome 携带**未脱敏**
的 `result.outputTail`，而日志路径 `logOutputTail` 是脱敏的。当前只有 Pi CLI 分支在 UI 展示尾部，且
用的是已脱敏串（`Sources/PiCLIUpdateAdapter.swift:1291-1298` → `Sources/PiWebApp.swift:1692-1693`），
Pi Web 的未脱敏值暂未被展示，但未脱敏值已经越过类型边界。属既有行为，不是本 delta 引入。

修法：构造 outcome 前统一过一次 redactor，避免后续消费者直接输出。

## 证据不足 / 无法确认（不作猜测）

1. **`F1` 的死锁部分未确认**：已确证「主线程 → `stateQueue.sync` 可能长时间阻塞」，但没有找到在同一
   `stateQueue` 上同步回环的调用（`isUpdateInProgress` 只被 Pi Web / Pi CLI 协调器使用，扩展包协调器
   没有该属性；其 completion 体内没有 `runner.isRunning` 调用）。是否真能死锁，证据不足。
2. **没有运行构建或测试**：本次是纯只读评审，没有执行 `swift test` 或任何构建；所有「测试覆盖 /
   未覆盖」结论来自源码阅读，不含运行结果。
3. **`F1` 的阻塞时长量级是推断**：没有实测 `pi list` 与探针在目标机器上的耗时，只证明了「同一队列上
   有同步子进程与文件 IO」。
4. **`F4` 没有实际复现**：没有在本机构造 FIFO 验证 `FileHandle.read` 阻塞；代码层面可证
   `readBoundedData` 无超时参数且不校验文件类型。
5. **`F6` 的实际机密暴露概率未知**：某个 npm 版本的输出是否真会包含 token 取决于 npm 版本与
   `.npmrc` 内容，未实测；只确认了该值未经 redactor。
6. **提交归属**：`F1` 与 `piPackageUpdateEntryState` 归 `fbae499`（PR #117 / #107，`git log -S` 确认）；
   `hasRelativePATHEntry` / `unsafeExecutablePath` / 排水宽限与解码器归 `4e6e332`（PR #116 / #108）。
   其余文件级归属没有逐条用 `-S` 复核。

## 发布决定

阻断项为 0，`F1` – `F6` 都不影响本次发布的行为边界（不扩大文件操作、信号、权限与凭据处理），因此
`v0.1.0-alpha.7` 按当前提交发布；六项登记在
[#121](https://github.com/Su-luoya/pi-web-desktop/issues/121)，其中 `F1`、`F2` 建议在下一个版本修掉。
