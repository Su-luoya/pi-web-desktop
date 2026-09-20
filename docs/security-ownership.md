# 服务所有权与外部服务只读策略

本文说明 Pi Web Desktop 如何证明一个 `pi-web` 进程确实由自己启动，从而只对可验证的托管进程组执行停止操作；以及这套机制覆盖和未覆盖的威胁。实现见 `Sources/ServiceOwnership.swift`、`Sources/ServiceManager.swift` 和 `Sources/ProcessInspector.swift`。

## 保证

1. 只有“本应用实例启动、且所有权记录对当前进程逐项验证通过”的服务进程组会收到 `SIGTERM`/`SIGKILL`。
2. 任何外部服务——用户或其他工具启动的 `pi-web`、上一次应用运行留下的服务、只按命令行看起来像 `pi-web` 的进程、无法读取 `ps` 事实的进程——都不会收到本应用的任何信号；应用不会把状态改成“已停止”，也不打开任何会发送信号的升级路径，只保留原有的外部服务警告文案。
3. 记录过期或不匹配时只删除记录文件，绝不向对应 PID 发送信号。
4. 信号只以进程组形式发送（等同于 `kill(-pgid, sig)`），接口 `ServiceSignaling` 中不存在向单个 PID 发送信号的方法。

## 所有权记录

启动成功后写入 `~/Library/Application Support/Pi Web Desktop/service-owner.json`：

| 字段 | 来源 | 用途 |
| --- | --- | --- |
| `pid` | `posix_spawn` 返回值 | 存活检查、作为进程组 ID |
| `processGroupID` | `ps -o pgid=` | 停止信号的目标 |
| `launchedAt` | `ps -o lstart=` | 识别 PID 复用 |
| `resolvedExecutable` | 优先 libproc `proc_pidpath`，失败时回退 `ps -o comm=` | 识别可执行文件被替换/指向别的程序 |
| `resolvedExecutableSource` | 上栏实际使用的来源（`proc_pidpath` / `ps-comm`） | 标记弱证据：回退来源仍需命令摘要同时匹配 |
| `argumentsDigest` | 启动时观察到的规范化命令文本（`ps -o args=`，空白折叠）的 SHA-256 | 用实时 argv 识别参数变化（端口、hostname 等） |
| `port` | 当前配置 | 识别端口复用/配置变化 |
| `instanceID` | 每次应用运行随机 UUID | 阻止跨应用运行沿用记录 |
| `recordedAt` | 写入时刻（ISO-8601） | 审计/诊断 |

`argumentsDigest` 的输入不是“可执行路径 + 参数”拼接，而是启动后立即从子进程读到的 `ps -o args=` 文本（空白折叠为单空格后哈希）。原因是 npm 安装的 `pi-web` 是 `#!/usr/bin/env node` 脚本：内核 exec 后 `argv[0]` 是解释器，实时文本形如 `node /opt/homebrew/bin/pi-web --hostname …`，与拼接文本永远不同。验证时对同一实时文本做同样规范化后比对摘要；实时文本为空或不可解析一律视为不匹配。只有启动时读不到实时文本才会回退到拼接形式（`ServiceOwnershipRecord.commandText(executablePath:arguments:)`），而这样的记录会在即时校验中被判为不匹配并触发启动失败清理。

旧的 `service.pid` 不再作为所有权证据，应用启动时删除；只保留 `app.pid` 用于单实例锁（PID 文本 + 存活检查），它不影响任何停止决策。

启动成功后写入并立即重新验证；记录写不进去、或即时校验不通过时，刚启动的进程组会被终止（组内 `SIGTERM` → 有界等待 → `SIGKILL`）并报告启动失败，剩余存活时该子进程句柄仍被视为“已有实例”（`startDecision()` 返回 `.existingProcess`），不会重复启动第二份服务。记录只在 `ps` 能读到子进程事实、且子进程 `pgid == pid`（组长不变量）时才写入；没有可验证记录的进程一律按“不可托管”处理：应用不会向它发送信号，也不会自动重启它。

## 验证项与对应威胁

`ServiceOwnershipVerifier` 是纯函数，逐项检查，任何一项不匹配或无法读取即判定为外部服务：

1. 记录字段有效：`pid > 1`、`processGroupID > 1`、`processGroupID == pid`、非空字符串、端口在 `1...65535`。
2. `instanceID` 等于当前应用实例 → 覆盖“应用重启后沿用旧记录”“其他实例的记录”。
3. `port` 等于当前配置 → 覆盖“端口复用/配置已经改变”。
4. 实时 `ps -o args=` 文本的摘要等于 `argumentsDigest`（对实时文本做空白折叠后比对；输出为空或不可解析即不匹配）→ 覆盖“参数/命令变化”“进程被换掉”。
5. 记录的 PID 仍存活（`kill(pid, 0)`）→ 覆盖“记录指向已退出的进程”。
6. `ps` 事实可读 → 覆盖“无权检查的进程”（例如其他用户的进程，需要 `sudo` 才能读；应用不使用 `sudo`）。
7. 实时 `pgid` 等于记录值 → 覆盖“PID 被复用后属于别的进程组”。
8. 实时 `launchedAt` 等于记录值 → 覆盖“PID 复用”。
9. 实时可执行标识等于记录值 → 覆盖“可执行文件/路径不同”；来源为 `ps-comm` 时属弱证据，仍需第 4 项同时通过。

不匹配的裁决由 `ServiceOwnershipVerdict.shouldRemoveRecord` 决定是否删除记录；唯一的例外是第 6 项（`ps` 暂时失败）：记录保留，但本次仍然不发送信号，留待下次重新验证。

## 停止流程

1. 重新验证所有权记录；失败时直接完成回调，不发送信号，也不把状态改成已停止（保持当前状态，例如仍显示“正在运行（外部服务）”）。
2. 验证通过：向记录的进程组发送一次 `SIGTERM`。
3. 在 `stopPollAttempts`（40 次 × 0.1 秒）内用 `kill(-pgid, 0)` 等待进程组消失。
4. 仍然存活才对同一进程组发送一次 `SIGKILL`。
5. 删除记录文件、清理子进程句柄并更新状态。

因此一次停止最多发送两个信号，且都针对同一进程组。

## 威胁模型

### 已覆盖

- **启动失败清理**：写不了记录或即时校验不通过时，应用终止的是它刚刚创建、且 `pgid == pid` 的进程组（本次启动专用，与启动回调一一对应），不会误伤其他进程；等不到存活确认时也不会再启动第二份服务。
- **PID 复用**：`launchedAt`（`ps -o lstart=`）、实时命令行摘要与可执行标识同时比对；即使新进程同样叫 `pi-web`，启动时间不同即判为外部。
- **参数/命令变化**：用启动时读到的实时 `ps -o args=` 文本做摘要并在停止前重新比对，不再拿“当前配置会生成的参数”当依据；实时输出为空或不可解析即不匹配。
- **端口复用**：记录校验 `port`、`instanceID`、实时命令行摘要，端口上出现同名监听进程不构成所有权。
- **弱命令行匹配**：应用删除了“命令行包含 `pi-web` 就发信号”的路径（原 `stopExternalListener` / `stopRemainingListener`）。静态检查中，`Sources/` 内不存在以命令行子串匹配为前提的 `kill` 调用。
- **进程组（pgid）复用/混淆**：记录必须是组长（`pgid == pid`），实时 `pgid` 必须与记录一致，且进程组只有在全部检查通过后才会被发送信号。
- **旧记录沿用**：`instanceID` 每次应用运行随机生成；应用重启后旧记录必然不匹配，只被清理。
- **过期记录**：进程不存在时只删除记录文件，不向 PID 发送信号。
- **误伤自身或系统进程**：`pid > 1`、`pgid > 1`，并且只发送组信号，不会退化为 `kill(0, ...)` 或 `kill(-1, ...)`。

### 未覆盖 / 已知限制

- **`lstart` 只有一秒粒度**：`ps -o lstart=` 不提供亚秒精度。如果某个 PID 在同一秒内被复用、新进程的可执行路径与参数又与记录完全一致，验证无法区分。缓解：`instanceID` 使跨应用运行的记录不可采用，且同一次运行内还需要恰好在停止窗口内完成同秒复用。
- **不校验代码签名或二进制内容**：记录只保存可执行标识（`proc_pidpath` 路径或回退的 `ps -o comm=`）、启动时间和实时命令文本摘要，不校验 `pi-web` 的代码签名、哈希或来源。攻击者在应用启动服务后替换可执行文件并让进程重启时，新进程的 `launchedAt` 会变化而被判为外部；但“同一文件被替换后仍以原进程运行”的过程不在防护范围内。
- **同用户本地攻击者可以伪造记录文件**：`service-owner.json` 是普通用户文件，应用不校验其权限、所有者或签名。能够写该文件的同一用户本来就可以用 `kill(2)` 直接结束自己的进程，因此应用不额外增加能力；记录防篡改不在本次范围（也不在无 Keychain 约束下解决）。
- **需要 `sudo` 才能检查/终止其他用户的进程**：`ps` 对其他用户的进程返回失败时按不可验证处理（判为外部、不发送信号）；应用不会尝试提权。若目标进程属于其他用户，`kill(-pgid, ...)` 也会因权限失败，应用不做任何重试或提权。
- **验证与发送信号之间的 TOCTOU 窗口**：验证通过后、`kill(-pgid, SIGTERM)` 之前进程可能退出且 pgid 被复用。窗口极小，需要同用户进程在毫秒级完成 PID/PGID 复用；应用接受这一残余风险。
- **组信号的放大语义**：向进程组发送信号会波及组内所有进程。这正是设计目的（覆盖 `pi-web` 自行启动的 helper），但也意味着如果该组被塞入无关进程，它们会一起收到信号。进程组由本应用创建，普通进程无法改变自己所属的进程组。
- **启动终止的确保留残风险**：写不了记录或即时校验不通过时，应用终止的是它刚刚创建、且 `pgid == pid` 的进程组；若信号仍未能结束该组（权限/僵尸特例），应用会保留子进程句柄以免再启动第二份服务，但无法从应用侧确认它真的退出。这种情形下应用不会向该组之外的任何进程发送信号。
- **`ps -o args=` 不保留引号**：`ps` 输出的命令文本会把引号与转义去掉，因此摘要比较的是“规范化后的文本”，而不是参数边界。这不会放宽所有权：记录与实时值使用同一规范化规则，且进程组、启动时间、可执行标识与存活检查仍必须同时通过；但它无法区分“引号写法不同、规范化后文本相同”的两种启动方式。
- **npm/shebang 安装的 `argv[0]`**：`pi-web` 实际以解释器（`node`）为 `argv[0]` 运行，所以记录的 `resolvedExecutable` 是 libproc 报告的真实解释器/二进制路径，命令文本也是解释器开头的实时文本；两者都来自同一个进程，不降低证据强度。
- **`proc_pidpath` 只对同用户进程可用**：读不到时回退 `ps -o comm=`，并把来源记为 `ps-comm`。回退值是弱证据（同名进程可伪造），所以命令摘要、`pgid`、`launchedAt` 与存活检查仍必须全部通过。
- **`ps`/`kill` 是同一用户可见性模型**：不处理 App Sandbox、EndpointSecurity、`launchd` 托管的 `pi-web`、受 SIP 保护的进程，也不读取 `proc_pidinfo` 的微秒级启动时间（当前实现按 issue 要求使用 `ps -o lstart=`）。这些都属于 macOS 平台限制或后续范围。
- **“退出但保持服务运行”之后**：下一次启动应用时，上一次启动的服务会被判为外部（`instanceID` 不同），应用不再能停止它，只能由用户手动停止。这是有意的设计取舍。
- **不固定可执行文件位置、不校验签名（`PATH` 即信任边界）**：更新时用到的 `pi` / `pi-web` / `npm` 都按 `PATH`（以及检测结果推导出的前缀目录）解析，应用只要求候选是绝对路径、不含 `.`/`..` 段与 shell 元字符，并确认可执行位；不把可执行文件钉在某个固定路径，也不校验代码签名或哈希。能写这些目录的用户本来就能直接决定跑哪个二进制，因此这不扩大能力；但应用也不会在 `PATH` 被改写时阻止使用被换掉的程序，只能把最终解析到的路径写进更新计划并展示给用户。

## 测试证据

`PiWebDesktopTests/ServiceOwnershipTests.swift` 与 `PiWebDesktopTests/ServiceManagerTests.swift` 覆盖：

| 场景 | 测试 |
| --- | --- |
| PID 复用（PID 相同、`launchedAt` 不同） | `testReusedPIDWithDifferentLaunchTimeIsExternal`、`testReusedPIDWithADifferentLaunchTimeIsNeverSignalled` |
| 端口复用（端口相同、`instanceID`/记录不匹配） | `testReusedPortWithDifferentInstanceIsExternal`、`testRecordedPortChangeMakesTheRunningServiceExternal` |
| 参数改变（实时命令文本摘要不匹配） | `testChangedArgumentsAreExternal`、`testChangedLiveCommandLineIsExternal`、`testReorderedArgumentsAreExternal`、`testChangedLiveCommandLineMakesTheServiceExternalAndSendsNoSignal` |
| 实时命令行为空/不可解析 | `testEmptyLiveCommandLineIsExternal`、`testStartManagedServiceWithoutArgumentsProvenanceIsRejectedAndTerminated` |
| 实时命令文本空白归一化 | `testLiveCommandLineWhitespaceRunsAreNormalized`、`testCommandDigestIsStableAndNormalizesWhitespace` |
| 可执行标识改变 / 来源可注入 | `testChangedExecutableIsExternal`、`testChangedResolvedExecutableMakesTheServiceExternalAndSendsNoSignal`、`testProcPidPathProvenanceIsRecordedWhenAvailable`、`testFallbackExecutableSourceStillRequiresTheCommandLineToMatch` |
| 记录写入/即时校验失败 → 终止进程组 | `testOwnershipRecordWriteFailureTerminatesTheFreshGroupAndBlocksASecondLaunch`、`testNonLeaderChildIsTerminatedInsteadOfBeingAdopted`、`testStartManagedServiceWithoutArgumentsProvenanceIsRejectedAndTerminated` |
| 外部服务停止不改变状态 | `testExternalServiceStopKeepsTheRunningStateAndSendsNoSignal`、`testStopServiceWithoutAVerifiedRecordSendsNothingAndKeepsTheState`、`testReusedPIDWithADifferentLaunchTimeIsNeverSignalled`、`testRecordedPortChangeMakesTheRunningServiceExternal` |
| /dev/null 描述符保护（fd ≤ stderr） | `testSpawnDescriptorAboveStandardErrorIsPassedThrough`、`testSpawnDescriptorAtOrBelowStandardErrorIsDuplicatedAboveIt` |
| 启动时间改变（`launchedAt` 不匹配） | `testChangedLaunchTimeIsExternal` |
| 过期记录（进程不存在） | `testRecordWhoseProcessIsGoneIsExternal`、`testStaleOwnershipRecordIsRemovedWithoutSignals` |
| 外部服务路径（从不发送信号） | `testExternalListenerIsNeverSignalled`、`testStopAllServicesLeavesAnExternalServiceRunning`、`testUnverifiableProcessFactsAreNeverSignalledAndKeepTheRecord` |
| 托管服务停止（只对组、最多两次信号） | `testStopServiceSendsOneGroupSignalAndRemovesTheRecord`、`testStopServiceEscalatesToTheSameProcessGroupAfterTheBoundedWait`、`testStopAllServicesStopsTheVerifiedChildAndInvokesTheCompletion` |

所有测试使用假的 `ps`/`lsof` 输出、注入的存活判定与可执行标识读取、注入的 `ServiceSignaling` 与临时目录，不启动、不结束任何真实进程（描述符保护测试也只复制/关闭自己创建的副本）。`ServiceSignaling` 没有单 PID 发送方法，因此测试中“向单个 PID 发送信号”无法被表达；生产实现 `kill(-pgid, ...)` 也不接受单个 PID。
