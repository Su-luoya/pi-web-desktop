# alpha.4 更新流水线安全审查（delta，只读）

- **审查对象**：`0.1.0-alpha.4` 相对 `0.1.0-alpha.3` 的改动，即 GitHub #59–#63（PR #68、#69、
  #66、#67、#70）涉及的更新流水线代码与文档：
  `Sources/UpdateChecker.swift`（来源标注与缓存校验）、
  `Sources/PiWebUpdateAdapter.swift`（生命周期脚本策略、独立进程组、超时终止、「已放弃」记录接线）、
  `Sources/PiProcessInspector.swift`（候选筛选与遮罩边界）、
  `Sources/UpdateTransaction.swift`（指纹证据等级与降级判定）、
  `Sources/UpdateVerifier.swift`（内容哈希与 npm `integrity` 探针）、
  `Sources/UpdateAbandonedAttempt.swift`（新增：记录类型、存储、重叠防护、展示）、
  `Sources/PiCLIUpdateAdapter.swift` / `Sources/PiPackageUpdateAdapter.swift`（来源硬前置与记录接线）、
  `Sources/UpdateSettings.swift` / `Sources/AppConfiguration.swift`（新的持久键）与
  `Sources/PiWebApp.swift` 中调用它们、以及菜单/诊断/确认框的部分，另有 `README.md` 与 `docs/` 的
  同步改动。
- **基线**：`v0.1.0-alpha.3`（tag 指向 `e367e06`）之后的 5 个功能/文档提交——
  `333928b`（#61 / PR #66）、`f799d98`（#63 / PR #67）、`2b4a42f`（#59 / PR #68）、
  `893fc80`（#60 / PR #69）、`1c5210c`（#62 / PR #70）——加上本次 `v0.1.0-alpha.4` 发布提交
  （版本 bump 与文档；**不改动**上述功能代码）。
- **性质**：**只读审查**。没有修改任何 `Sources/` 或 `Scripts/` 代码，没有 push、没有 tag、
  没有创建 Release、没有创建 Issue。本报告只写能在当前代码里核对的事实。
- **结论摘要**：**阻断项 0 项**（B1–B9 全部未触发）；本版新增 6 条非阻断风险（N-1 … N-6，全部
  为“低”）；上一版
  [alpha.3 审查](security-review-alpha.3.md) 的 A-1 … A-9 中，**A-1 在本版闭环**、A-6/A-7 的自动路径
  闭环（保留记账式残余）、A-3/A-4/A-5 部分闭环、A-2/A-8/A-9 按现状接受。建议由维护者创建的
  follow-up issue 见 §7。

---

## 0. 方法与证据基线

本次审查的方法是“读 alpha.3 → alpha.4 的 diff + 读当前代码 + 跑只读门禁 + 负向 grep”，
**不是**动态渗透测试，也**没有**真的执行过一次更新。

在 `v0.1.0-alpha.4` 候选工作区（版本 bump 之后、文档改动之前）实际执行过、可复现的命令：

| 命令 | 结果 |
| --- | --- |
| `git diff --check` | 退出 0（无空白错误） |
| `sh -n Scripts/*.sh` | 退出 0 |
| `./Scripts/build.sh` | 退出 0；`Mach-O 64-bit executable arm64` |
| `./Scripts/check-identity.sh` | 退出 0；`check-identity: PASSED (45 checks)`（bundle 为 `0.1.0-alpha.4` / build `4`） |
| `./Scripts/smoke.sh` | 退出 0；启动与诊断两种模式都打印标记并退出 0（`items=6 blockers=3`） |
| `./Scripts/scan-secrets.sh --self-test` | 退出 0；`self-test: PASS` |
| `./Scripts/scan-secrets.sh` | 退出 0；`scan-secrets: suppressed 11 lines`、`scan-secrets: PASS` |
| `sh Scripts/check-release-version.sh v0.1.0-alpha.4` | 退出 0；tag、`MARKETING_VERSION` 与预发布计数均一致 |
| `./Scripts/package-release.sh --tag v0.1.0-alpha.4` | 退出 0；产出 ZIP、`.sha256`、证据 Markdown 与 `release-metadata.env`，版本 `0.1.0-alpha.4` / build `4` |
| ZIP 包内身份复验（`ditto` 解压 + `plutil` + `codesign --verify --deep --strict`） | `CFBundleShortVersionString=0.1.0-alpha.4`、`CFBundleVersion=4`；解压出的 bundle 签名校验退出 0 |

负向证据（在候选工作区实际执行）：

| 命令 | 结果 |
| --- | --- |
| `git grep -nE 'kill\(|killpg|SIGTERM|SIGKILL|signal\(|\.terminate\(\)' -- Sources/` | 更新流水线里只有**一个**调用点：`Sources/PiWebUpdateAdapter.swift:847` 的 `killpg(handle.processGroupIdentifier, SIGTERM)`；其余命中都是注释，或服务所有权路径（`ProcessInspector` / `ServiceOwnership` / `ServiceManager` 的既有代码，不属于本次 delta） |
| `git grep -nE '/bin/(sh\|bash\|zsh)\|sudo\|shell' -- Sources/Pi{Web,CLI,Package}UpdateAdapter.swift Sources/Update{Transaction,Verifier,AbandonedAttempt}.swift` | 只有注释与**禁用 token 列表**的命中（例如 `PiWebUpdateAdapter.swift:99`、`PiPackageUpdateAdapter.swift:316` 的 `forbiddenTokens`），没有执行 shell 或调用 `sudo` 的代码 |
| `git grep -nE 'moveItem\|copyItem\|removeItem\|unlink\(\|rmdir\|rename\(\|truncate\|write\(to:\|createFile' -- Sources/Pi{Web,CLI,Package}UpdateAdapter.swift Sources/Update{Transaction,Verifier,AbandonedAttempt}.swift` | **0 命中**：这些文件不移动、不复制、不删除、不写任何被更新组件所在目录的文件 |
| `git grep -nE 'Process\(\)\|posix_spawn\(' -- Sources/Pi{Web,CLI,Package}UpdateAdapter.swift` | Pi Web 走 `posix_spawn`（`PiWebUpdateAdapter.swift:814`）；Pi CLI 与扩展包走 `Process()` + 固定参数数组（`PiCLIUpdateAdapter.swift:566`、`PiPackageUpdateAdapter.swift:1136`），三处都没有 shell 字符串 |

**本次没有做的事**（因此下列结论不能从这些角度被反驳或被支持）：

- **没有真的打开“启动前自动更新 Pi Web / Pi CLI”去执行一次真实 `npm` / `pi` 更新**；也没有真的
  触发一次超时去观察进程组信号。结论来自代码阅读、注入式单元测试（它们在 `$TMPDIR` 里操作测试
  自己写的假脚本与假进程表）与源码负向断言。
- **没有做动态测试**：没有真机安装演练、没有抓包、没有模糊测试、没有内存/沙箱逃逸或提权测试，
  没有对进程组信号的 PID 复用窗口做压力复现（见 N-4，该条是**分析结论**）。
- **没有在本机运行 `xcodebuild build` / `xcodebuild test`**（本机 `xcode-select -p` 指向 Command Line
  Tools），XCTest 由 CI 的 `macos-14` job 覆盖；本报告不引用本机未执行的测试结论。
- **没有验证签名来源**：本应用与它更新的组件都没有开发者签名/公证可查，npm `integrity` 与内容
  哈希只在**本机范围**内说明“文件是否与记录一致”，不构成来源证明。

---

## 1. 审查范围与未覆盖范围

### 1.1 本次覆盖（alpha.3 → alpha.4 的改动）

| 面 | 覆盖内容 |
| --- | --- |
| 检查结果来源（#59） | `UpdateCheckOrigin` 三态与语义、`origin == .network` 硬前置、缓存回退/无结果时的拒绝文案、UI/诊断里的来源标注、缓存文件的结构与形状校验、`304` 的归类 |
| 缓存回退 | 它现在还能影响什么（提示文案、状态行）、不能再影响什么（自动安装/自动更新目标版本）、校验失败时的整份丢弃行为 |
| 生命周期脚本（#60） | 自动安装 argv 是否带 `--ignore-scripts`、结论与静态证据的存放点、环境白名单是否注入 `npm_config_ignore_scripts`、用户可见文案 |
| 进程保护读取面（#61） | 候选判定（`isCandidate`）的输入与范围、非候选进程是否还会读 argv、三态语义是否被放宽、新增遮罩形态与其已知边界 |
| 降级证据（#63） | 指纹新增字段（inode、内容哈希、npm `integrity`）、取不到时的标注、证据等级、降级判定的通过条件、文案是否暗示来源可信 |
| 「已放弃」记录与重叠防护（#62） | 记录字段与读回校验、写入时机、阻断范围（自动 vs 手动）、清除条件、可见性、Pi Web 独立进程组与信号边界、Pi CLI/扩展包是否仍不发信号 |
| 本地持久状态 | 新增键（`updateChecks.piWeb.abandonedAttempt`、`updateChecks.pi.abandonedAttempt`、`updateChecks.piPackages.abandonedAttempts`）的字段范围与读回校验 |

### 1.2 明确未覆盖（沿用既有审查或其他范围）

- **服务所有权、Keychain、远程访问密码、监听地址边界、`LogRedactor` 规则本身、CI/发布脚本、
  依赖与供应链、CSP/WebKit 与网站数据**：沿用 [alpha.1 独立安全与发布审查](security-review-alpha.1.md)
  （R-1 … R-11）。本次只在“更新流水线复用这些机制”的地方做交叉引用，没有重新审计它们。
- **alpha.3 已覆盖、本次未改动的部分**（三条执行器的参数策略、三套规划器的其它前置条件、事务阶段、
  历史存储、网络请求卫生）：沿用 [alpha.3 审查](security-review-alpha.3.md) 的 A-1 … A-9 与 B1–B8，
  本次只复核本次改动是否改变了它们的处置（见 §4）。
- **上游代码与基础设施**：`@agegr/pi-web`、`@earendil-works/pi-coding-agent`（`pi`）自身代码、
  npm CLI/registry 的行为、GitHub Releases API 的信任边界。本次只审查**本应用侧**如何调用它们、
  传什么参数、继承什么环境、记录了什么。
- **桌面应用自身的应用内更新**：本版本仍然不存在该路径，因此没有可审查对象。
- **动态验证**：见 §0 的“本次没有做的事”。

---

## 2. 威胁模型（仅本 delta）

资产与对手模型沿用 [alpha.3 审查](security-review-alpha.3.md) §2（A. 上游被污染的发布；B. 同用户本地
进程；C. 其它用户进程；D. 远程网络攻击者；E. 误操作的用户）。本版对这张表的影响：

| 变化 | 方向 |
| --- | --- |
| 缓存文件从“可以驱动自动安装的输入”降级为“只影响提示的输入” | **风险下降**（对手 B 能造成的最大后果从“让应用自动装某个版本”变成“让应用显示一条提示”） |
| 新增一类持久记录（「已放弃」）且它能阻断自动执行 | **风险略升**（对手 B 多了一处可写的状态；写坏最多造成“不让自动更新”与展示受控文本，见 N-6） |
| Pi Web 超时终止从“只对子进程发信号”改为“只对子进程自己的进程组发一次 `SIGTERM`” | **风险下降但引入新面**（覆盖 npm 派生的子进程；新增进程组 id 与时序约束，见 N-4） |
| 降级证据加入 inode 与内容哈希 | **风险下降**（内容哈希可检出同尺寸同 mtime 的替换）；未记录内容哈希时仍退回元数据（见 N-1） |
| 进程保护不再对非候选进程读 argv | **风险下降**（读取面收窄）；候选集合包含所有 JS 运行时形状的进程，遮罩仍是模式化（见 §4 A-5） |

---

## 3. 本版新增风险项

严重度沿用 alpha.1/alpha.3 报告的口径（低 / 低—中 / 中 / 高）；“是否阻断”见 §5。

### N-1 未记录内容哈希时，降级仍可用 size/mtime 元数据通过（低）

- **事实**：`UpdateDegradationPlanner.verificationFailure`（`Sources/UpdateTransaction.swift:571`）在
  身份名称与 inode 通过之后，若 `evidence.contentHashVerified == false`
  （`UpdateTransaction.swift:672` 起的回退分支）只比对 `fileSize` 与 `modificationDate` 是否与指纹
  一致；内容哈希可能因为文件超过上限（`UpdateArtifactProbe.contentHashSizeLimitBytes = 16 MiB`，
  `Sources/UpdateVerifier.swift:70`）、文件不可读或没有探针而缺失，缺失原因会写进
  `UpdateContentHashUnavailableReason`（`UpdateTransaction.swift:125`）。同一分支的文案会写明
  “不校验旧文件内容”（`UpdateTransaction.swift:429` 的 `contentVerificationClause`）。
- **影响**：同用户对手只要**就地把旧文件改写**（保留 inode）、并把大小与 mtime 恢复成指纹里的值，
  就能让应用把“已降级”指向一个已经不是更新前那份内容的文件。文案已如实写明不校验内容，因此这
  不是“隐瞒”，而是**证据强度不足**；对手本来就能直接改这个路径下的文件，不构成额外权限。
- **缓解（现有）**：身份名称必须一致；记录了 inode 时必须一致；记录了内容哈希时必须重新计算并
  一致（此时 size/mtime 不再参与，`UpdateTransaction.swift:540-556`）；证据等级写进历史并在界面
  展示（`UpdateArtifactEvidenceLevel`，`:107`）；“已降级”文案明确只是把调用方指回旧路径
  （`UpdateTransaction.swift:723` 起的 `UpdateWarningText.verificationFailed`）。
- **残留风险**：16 MiB 以上的可执行文件、读不到内容或没有探针时，旧文件内容不被校验。
- **建议**：见 §7 F1。

### N-2 「已放弃」重叠防护是记账式的，不检测被放弃的进程是否仍在运行（低）

- **事实**：`UpdateAbandonedAttemptGate.allowsAutomaticExecution`（`Sources/UpdateAbandonedAttempt.swift:377`）
  只看已存记录是否存在；记录里 `finishedAt` 与 `derivedProcessesConfirmedEnded` **恒为空**
  （`:82`、`:88` 的字段文档与 `:277` 的 `valid(_:)` 校验），判定链里没有对“那个进程是否还活着”的
  任何检查。清除只发生在用户显式清除（`PiWebApp.swift:1043` 的 `clearAllAbandonedAttempts`）或
  该组件后来成功完成一次更新（`PiWebApp.swift:1007`；三个适配器分别在
  `PiWebUpdateAdapter.swift:1386`、`PiCLIUpdateAdapter.swift:1092`、`PiPackageUpdateAdapter.swift:1647`
  调用 `clearAbandonedAttempt`）。
- **影响**：被放弃的 `npm install -g …` / `pi update …` 若仍在后台运行，在用户清除记录、或该组件
  后来成功完成一次更新之后，应用就允许下一次自动尝试，两者可能同时写同一个全局前缀。应用无法
  观测前者（这是 #21/#22“不发信号”取舍的直接代价）。
- **缓解（现有）**：记录跨退出与重启保留；自动路径在清除前一律拒绝并写入可读原因；手动入口虽然
  不受阻断，但确认框会先展示记录并要求显式确认（`UpdateAbandonedAttemptPresenter.confirmationBlock`，
  `UpdateAbandonedAttempt.swift:442`）；三个组件互相独立，残留被限制在单个组件。
- **残留风险**：防护是“记得放弃过什么”，不是“确认那个进程结束了”。
- **建议**：见 §7 F2。

### N-3 npm `integrity` 是展示用附加证据，且来自本机可改写文件（低）

- **事实**：`UpdateArtifactProbe.readNpmIntegrity`（`Sources/UpdateVerifier.swift:187`）从可执行文件
  向上最多 6 层查找 `package-lock.json` / `.package-lock.json` / `node_modules/.package-lock.json`
  （单个锁文件上限 4 MiB），`isIntegrityValue`（`:168`）只校验形状（已知算法名 + base64 字符集 +
  长度 ≤ 200）。值存进指纹的 `npmIntegrity`（`UpdateTransaction.swift:177`），只通过
  `npmIntegrityEvidenceText`（`:199`）与证据摘要（`:423`）展示；`evaluateRollbackEvidence`
  （`:528`）的通过条件**不包含**它——判定只看身份名称、inode 与内容哈希（`:540-556`）。
- **影响**：同用户对手可以改写本机锁文件，让“npm 完整性已记录（…）”这一行显示一个任意但形状
  合法的值。它不会改变任何通过/失败结论，也不会改变升级目标（目标版本仍来自本次网络检查）；
  但用户可能把这行读成“来源已被校验”。
- **缓解（现有）**：取值有界、形状校验、取不到时明确写“npm 完整性未获取”；文档（README“已知限制”、
  `docs/architecture.md`）写明它只是本机记录、不证明发布时间/发布者/来源。
- **残留风险**：展示层可被同用户置入自定义文本（受形状与长度约束）。
- **建议**：见 §7 F3。

### N-4 进程组终止与 `waitpid` 回收之间存在窄窗口，理论上可能对复用的 PID 发信号（低，分析结论）

- **事实**：`ProcessPiWebUpdateInstaller.startLocked`（`Sources/PiWebUpdateAdapter.swift:955`）在
  `spawn` 之后把 `waitForExit` 派发到单独的 `waitQueue`（`:993-997`），再在 `stateQueue` 上安排
  超时（`scheduleTimeoutLocked`，`:1002`）。超时处理 `stopWaitingLocked`（`:1017`）经
  `terminateOwnProcessGroupLocked`（`:1023`）调用 `POSIXPiWebUpdateChildSpawner.terminateOwnProcessGroup`
  （`:840`），后者在 `usesOwnProcessGroup && processGroupIdentifier == processIdentifier && pid > 1`
  三个条件都成立时执行 `killpg(handle.processGroupIdentifier, SIGTERM)`（`:847`）。子进程被回收后，
  只有 `finishLocked`（`:1083`）会清掉 `handle`（`:1104`）并把 `finished` 置真。
- **影响（推理，未经动态验证）**：如果 `waitpid` 已经返回（内核已回收该 PID），而“退出已处理”这一
  步尚未在 `stateQueue` 上执行，此时超时处理先运行，`handle` 仍然非空、`didSignalOwnProcessGroup`
  仍为假，于是会对一个**可能已被复用的 PID** 调用 `killpg`。要造成影响需要同时满足：极窄的时序
  窗口、PID 恰好被复用、且复用者是新进程组的组长。窗口很窄（`waitQueue` 在 `waitpid` 返回后立即
  派发），且只会发一次 `SIGTERM`、不发 `SIGKILL`、不按名字杀进程。
- **缓解（现有）**：三个前置条件把“共享进程组/降级句柄”排除在外（`:1029-1036`）；一次尝试至多
  一次信号（`didSignalOwnProcessGroup`，`:1031-1033`）；没有 `SIGKILL`、没有按名杀进程、不触碰
  任何 Pi 进程；测试用替身断言“超时只出现一次 `terminateOwnProcessGroup` 调用且参数是本次子进程”
  （`PiWebDesktopTests/PiWebUpdateAdapterTests.swift` 的超时用例）。
- **残留风险**：理论上的 PID 复用；本次没有动态复现，也没有用测试覆盖这个时序。
- **建议**：见 §7 F4。

### N-5 缓存回退仍可被同用户改写以影响提示文案（低）

- **事实**：`UpdateCacheEntry.validationRejection`（`Sources/UpdateChecker.swift:911`）与
  `UpdateCheckCacheFile.validated`（`:947`）只校验结构、形状与一致性（分类/包名/目标 id 匹配、
  枚举已知、语义化版本规范化、时间戳不在未来、条件请求字段长度受限），**不做**真实性校验；
  `cachedFallback`（`:1709`）会读回 `status = updateAvailable` 与 `decodedConfidence ??
  .unknown`（`:797`、`:1743`），`UpdateCategoryStatusBuilder`（`Sources/UpdateSettings.swift:635-644`）
  在没有本次结果但缓存里有版本时也标成 `cachedFallback`，`UpdateStatusPresenter.line`
  （`:704` 起）与 `UpdateCheckResult.cacheOriginAnnotation`（`UpdateChecker.swift:653`）会标注
  “来源：本机缓存（写入于 …）；缓存不是可信输入，只用于提示，不用于自动安装”。
- **影响**：对手 B 可以改写缓存让应用提示“官方包有 9.9.9 版本”。包名/目标 id 必须与静态清单/校验
  规则一致，因此不能借此换成别的包或别的 registry；自动安装与自动更新有 `origin == .network` 硬
  前置（`UpdateChecker.swift:563`；`PiWebUpdateAdapter.swift:410`、`PiCLIUpdateAdapter.swift:349`、
  `PiPackageUpdateAdapter.swift:819`），缓存回退不参与；手动入口需要用户确认，且 Pi Web 的手动入口
  也走同一条 `decide`（因此同样要求本次网络结果）。
- **缓解（现有）**：整份缓存在任何一项不合法时被丢弃（`:947` 起，返回 `.empty` 与固定拒绝原因）；
  来源标注与缓存写入时间同时展示；缓存不含凭据、URL 或响应体。
- **残留风险**：提示层可被同用户投喂；这是 alpha.3 A-9 的同类边界在本版的具体形态。
- **建议**：见 §7 F5。

### N-6 「已放弃」记录可被同用户写入，用于阻断自动更新并展示最多 200 字符的自定义文本（低）

- **事实**：`UpdateAbandonedAttemptStore.save`（`Sources/UpdateAbandonedAttempt.swift:196`）与
  `valid(_:)`（`:277`）只做形状校验——结束时间必须为空、摘要非空且无控制字符、上限 200 字符、
  超时在 `(0, 24h]`、时间不早于固定起点、动作必须与组件匹配（只有 Pi Web 可能出现“发送过信号”的
  记录，`:349` 起的 `isRecordable(for:)`（定义在 `:352`））；扩展包包名必须通过 npm 包名校验（`:124` 的
  `hasRecordableComponent`）。记录存在时，自动路径分别返回
  `.manualOnly(.abandonedAttemptPending)`（`PiWebUpdateAdapter.swift:384-386`）、
  `.deferred(.abandonedAttemptPending)`（`PiCLIUpdateAdapter.swift:375-377`）与
  `.awaitingAbandonedConfirmation`（`PiPackageUpdateAdapter.swift:908-910`）；展示文本经
  `UpdateAbandonedAttemptPresenter`（`:391` 起）出现在诊断页、偏好设置窗口与手动确认框。
- **影响**：对手 B 可以直接写 UserDefaults 造一条记录，后果有两种：(1) 该组件的自动更新被暂停
  （拒绝服务，且对手本来就能通过其它方式阻止更新）；(2) 应用自己的界面里显示最多 200 字符的
  攻击者文本（无控制字符、不含绝对路径要求以外的约束）。二者都不触发任何文件或进程动作，因此
  不是权限提升。
- **缓解（现有）**：字段白名单 + 读回校验 + 长度/控制字符过滤 + 组件与动作一致性；展示与执行
  完全解耦（记录不携带可执行内容）；用户可以随时显式清除；自动路径的拒绝原因可读并写入日志。
- **残留风险**：同用户可写的持久状态（与 A-9 同源），本版新增一类键。
- **建议**：见 §7 F6。

---

## 4. 上一版 A-1 … A-9 的复核

下表逐条给出本版（alpha.4）的处置与证据。证据里的文件与行号都是当前工作区的实际位置。

| 编号 | alpha.3 结论 | 本版处置 | 证据 |
| --- | --- | --- | --- |
| **A-1** 缓存可影响自动更新的目标版本 | 低 | **闭环（自动安装面）** | `UpdateCheckOrigin.isEligibleForAutomaticInstall` 只接受 `.network`（`UpdateChecker.swift:563`）；三条路径新增硬前置（`PiWebUpdateAdapter.swift:407-414`、`PiCLIUpdateAdapter.swift:349`、`PiPackageUpdateAdapter.swift:819`）；缓存读取先做整体校验（`UpdateChecker.swift:911`、`:947`）；拒绝文案含“缓存不是可信输入”（`:568`）。缓存现在最多影响提示：见 N-5 |
| **A-2** 自动安装不传 `--ignore-scripts` 且继承 `HOME` | 低—中 | **按现状接受，本版明示化** | argv 仍是 `["install", "-g", "<静态包名>@<版本>"]`（`PiWebUpdateAdapter.swift:236`）；结论与静态证据单点放在 `PiWebUpdateLifecycleScriptPolicy`（`:195-201`），并在展示/日志输出（`displayLines` 在 `:252`，生命周期脚本行在 `:256`）；环境白名单不含任何 `npm_config_*`（`:124`）；README 与 `docs/privacy.md` 写明“由你自己的 npm 执行、会运行包声明的脚本”。**本版没有做行为改变，也没有真的跑过一次安装**：残留风险与 alpha.3 相同（安装期脚本 + registry/凭据由 npm 与用户配置决定） |
| **A-3** “更新后验证”不等于“来源可信” | 低—中 | **部分闭环（措辞与边界），核心边界不变** | `UpdateVerificationCheck.notVerifiedCapabilities` 现在显式说明内容哈希只用于判断旧文件是否仍是同一份、不证明来源（`UpdateVerifier.swift:285`）；成功检查改写成具体事实（`:321` 的 `factText`）；`UpdateWarningText` 区分“仍在使用旧版本 / 已降级 / 无法自动回滚”且“已降级”写明不校验旧文件内容（`UpdateTransaction.swift:723`）。验证仍无法确认发布者身份（本身不提供该能力） |
| **A-4** 降级判定依据可被同用户伪造（size/mtime） | 低 | **部分闭环** | 指纹新增 `fileInode`、`contentHash`、`npmIntegrity`（`UpdateTransaction.swift:163-177`）与证据等级（`:187`）；`evaluateRollbackEvidence` 要求身份名称一致、inode 一致（`:540-545`）、内容哈希一致（`:546-552`）；任一不一致 → `cannotAutomaticallyRollback`（`:571` 起的 `verificationFailure`）。**残留**：未记录内容哈希时退回 size/mtime（`:672` 起），详见 N-1；`npmIntegrity` 不参与判定，详见 N-3 |
| **A-5** 进程保护读取 argv 的面与遮罩边界 | 低 | **部分闭环（读取面收窄）** | 快照不再读 argv（`PiProcessInspector.swift:470` 起的 `inspect` 只对候选进程补 argv；`LibprocPiProcessProbe.snapshot` 返回空 argv）；候选判定 `isCandidate`（`:642`）只看镜像路径与内核进程名（`pi` 或 JS 运行时名/前缀，`:621`）；遮罩补齐短开关、已知凭据前缀与长不透明串（`:723`、`:733`、`:745`、`:772`）。**残留**：候选集合覆盖所有 `node*`/`bun`/`deno` 形状的进程（开发机上数量可能不少），且遮罩仍是模式化的（短于 32 字符、无已知前缀的自由文本会保留，已在 `docs/privacy.md` 与 `PiProcessInspectorTests.swift` 断言） |
| **A-6** #20 的超时终止不覆盖派生子进程 | 低 | **主要部分闭环** | 子进程以 `POSIX_SPAWN_SETPGROUP` + `pgroup = 0` 成为独立进程组（`PiWebUpdateSpawnPolicy`，`PiWebUpdateAdapter.swift:673-692`）；超时/取消只对该组发一次 `SIGTERM`（`stopWaitingLocked` `:1017` → `terminateOwnProcessGroupLocked` `:1023` → `killpg` `:847`），句柄无法确认是自己的组时不发信号（`:1029-1036`），一次尝试至多一次（`:1031-1033`）。**残留**：`SIGTERM` 尽力而为、不发 `SIGKILL`、不确认派生进程结束；另有 N-4 的窄时序窗口 |
| **A-7** #21/#22 被放弃的命令可能继续运行并重叠 | 低 | **自动路径闭环（记账式）** | 新增记录类型/存储/阻断判定（`UpdateAbandonedAttempt.swift:26`、`:160`、`:367`）；三条自动路径在记录存在时拒绝执行（`PiWebUpdateAdapter.swift:384-386`、`PiCLIUpdateAdapter.swift:375-377`、`PiPackageUpdateAdapter.swift:908-910`）；记录跨重启保留、只在显式清除或成功后清除（`PiWebApp.swift:1007`、`:1043`；三个适配器的 `clearAbandonedAttempt` 调用点）。**残留**：不检测进程存活（N-2）；手动入口仍可能重叠（这是 A-8 的有意取舍，确认框会先展示记录） |
| **A-8** #21 手动入口有意不做进程门控 | 低（设计取舍） | **未改变，维持接受** | `PiCLIUpdateCoordinator.runManual`（`PiCLIUpdateAdapter.swift:932`）仍不做进程门控；确认框展示运行中进程与风险说明，并在有记录时追加记录块（`:1147-1160` 附近的 `PiCLIManualUpdateConfirmation`）。本版没有收紧也没有放宽这条路径 |
| **A-9** 本地持久状态可被同用户读写、依赖模式化脱敏 | 低 | **残留，且本版新增一类键** | 新增三个键（`UpdateSettings.swift:147-152`），读写都经 `AppConfiguration`（`AppConfiguration.swift:217-233`）；写入与读回逐字段校验（`UpdateAbandonedAttempt.swift:277`）；命令摘要先脱敏再截断（`:134` 的 `makeCommandSummary`）。**残留**：同用户可写入伪造记录（N-6）；提示层的缓存回退（N-5） |

**没有转化的条目**：A-1 与 A-7 的自动路径在本版闭环，没有留下同级的新条目；A-6 留下了 N-4（时序）
这一条与“不确认派生进程结束”的既有残留。A-2、A-8 保持原状且已在文档写明，不需要新 issue。

---

## 5. 阻断条件判定

判定规则与 [alpha.1 审查](security-review-alpha.1.md#11-阻断条件与判定) 相同：任一阻断条件触发就不应
push tag；非阻断风险必须在 Release Issue 里显式处置。B1–B8 沿用 alpha.3 的定义，B9 为本版新增。

| 编号 | 阻断条件 | 判定 | 证据 |
| --- | --- | --- | --- |
| B1 | 存在“来源不可信（非 `verified` 的 npm/pnpm 全局）仍会自动安装/自动执行”的路径 | 未触发 | 三条路径的来源/可信度前置未变（`PiWebUpdateAdapter.swift:393`、`PiCLIUpdateAdapter.swift:318`、`PiPackageUpdateAdapter.swift:718`），本版另加 `origin == .network` 硬前置（`:410`、`:349`、`:819`）；两个开关默认关闭（`UpdateSettings.swift:210`、`:226`） |
| B2 | 存在无人值守的扩展包更新路径 | 未触发 | `allowsUnattendedExecution = false` 与 `isAutomaticallyExecutable` 恒假的行为未变（`PiPackageUpdateAdapter.swift:378`、`:400`）；本版只给扩展包加了“有记录时先确认”的额外门槛（`:908-910`、`:853-855`） |
| B3 | 更新命令经 shell 字符串执行、调用 `sudo`、或 argv 元素来自未校验的外部文本 | 未触发 | 负向 grep（§0）没有 shell/`sudo` 执行路径；Pi Web argv 仍由静态包名 + 规范化语义化版本构造（`PiWebUpdateAdapter.swift:220-240`）；Pi CLI argv 恒为 `["update", "--self"]`、扩展包 argv 恒为 `["update", "npm:<包名>"]`（`PiCLIUpdateAdapter.swift:120`、`PiPackageUpdateAdapter.swift:430`），三条都只以参数数组启动（`:814`、`:566`、`:1136`） |
| B4 | 任一更新路径向非自己启动的进程发送信号、结束 Pi 会话或修改 Pi 配置 | 未触发 | 唯一的信号调用点是 `PiWebUpdateAdapter.swift:847` 的 `killpg`，它在 `handle.usesOwnProcessGroup && group == pid && pid > 1` 三个条件同时成立时才可能执行（`:1029-1036`），且只对 `posix_spawn` 时用 `POSIX_SPAWN_SETPGROUP` 新建的那个组（`:673-692`）；Pi CLI 与扩展包没有任何信号调用（负向 grep，只命中注释）；记录的动作校验还保证 Pi CLI/扩展包不可能出现“发送过信号”的记录（`UpdateAbandonedAttempt.swift:352`）。**唯一的残余是 N-4 的窄时序窗口**，它不构成常规路径 |
| B5 | 凭据/秘密进入日志、诊断、更新历史或 UserDefaults | 未触发 | 新增记录只存固定文案 + 已校验组件/包名 + 脱敏摘要 + 时间/来源（`UpdateAbandonedAttempt.swift:26`、`:124`、`:277`）；摘要先经 `LogRedactor` 再截断（`:134`）；缓存校验的拒绝原因不回显缓存内容（`UpdateChecker.swift:858`、`:876`）；`scan-secrets.sh` 与 `--self-test` 退出 0（§0） |
| B6 | 更新检查发出非白名单主机请求、携带 cookie/Authorization 或跟随重定向 | 未触发 | 本版没有改动请求层（`UpdateHTTPRequest.sanitized()`、`URLSessionConfiguration.ephemeral`、拒绝重定向、`UpdateEndpoint` 两个工厂，见 alpha.3 审查 B6 的证据，行号未变） |
| B7 | 用户可见文案把“验证”说成“已确认代码签名 / 官方来源 / 可完整回滚” | 未触发 | `notVerifiedCapabilities`（`UpdateVerifier.swift:285`）新增一句：内容哈希“只用于判断旧文件是否仍是同一份，不证明来源”；`factText`（`:321`）只用具体事实；`UpdateWarningText.verificationFailed`（`UpdateTransaction.swift:723`）在 `degradedToPreviousArtifact` 下必须写“这只是把调用方指回更新前记录的路径”并在证据等级不是内容哈希时写“不校验旧文件内容”；README 与本次发布说明写明不确认签名/来源、不承诺所有来源可回滚 |
| B8 | 回滚/降级路径移动、复制、删除文件，或卸载已安装组件 | 未触发 | 负向 grep 在本版触及的更新文件里对 `moveItem`/`copyItem`/`removeItem`/`unlink`/`rmdir`/`rename`/`truncate`/`write(to:)`/`createFile` **0 命中**（§0）；降级计划只携带路径与文案（`UpdateTransaction.swift:375` 的 `UpdateDegradationKind` 与 `:469` 的 `UpdateDegradationPlan`），应用侧动作仍只有“把服务/重检测指回旧路径”；新记录的唯一副作用是写 UserDefaults |
| **B9** | 存在“向本次启动之外的进程或进程组发送信号”的常规路径，或新增的持久状态能在无人值守时可执行代码 | 未触发 | 信号边界见 B4；新增记录不携带任何可执行内容，展示只经 `UpdateAbandonedAttemptPresenter`（`UpdateAbandonedAttempt.swift:391` 起），自动路径对记录的反应是**拒绝执行**而不是执行（`:377`）；记录不能改变 argv、包名、registry 或目标版本 |

### 5.1 最终结论

**阻断项 0 项。** alpha.3 → alpha.4 的加固不构成发布阻断；本版的非阻断风险 N-1 … N-6 与仍然残留的
A-2、A-3、A-4、A-5、A-8、A-9（A-6 与 A-7 的残余已分别转化为 N-4 与 N-2）应在 Release Issue 里逐条
给出“接受 / 本版本修 / 转后续 Issue”的处置。

本审查结论**不构成发布批准**：CI 全绿、真机 smoke、checksum 与 prerelease 标记等门槛仍按
[Alpha 发布门槛清单](alpha-release-checklist.md) 逐项满足。

---

## 6. 本版加固的净效果（对本 delta 的一句话判断）

- **可验证地变严**：自动安装/自动更新不再接受本机缓存结果（A-1）；降级判定在记录了内容哈希时能
  检出“同尺寸同 mtime 的替换”（A-4）；超时终止从“只杀自己的子进程”升级为“只对自己的独立进程组
  发一次 `SIGTERM`”（A-6）；被放弃的命令不再允许同一组件自动重复（A-7）；非候选进程不再读 argv
  （A-5）。
- **明确保留、且已经写进用户可见文案的**：安装期脚本由用户自己的 npm 执行（A-2）；手动 Pi CLI
  更新不做进程门控（A-8）；内容哈希与 npm `integrity` 都不是来源证明；被放弃的进程是否结束、
  什么时候结束仍然未知。
- **本版引入或暴露的新边界**：N-1（元数据回退）、N-2（记账式重叠防护）、N-3（展示用 integrity）、
  N-4（进程组与回收的窄窗口）、N-5（缓存回退提示可被投喂）、N-6（记录可被同用户写入）。

---

## 7. 建议的 follow-up issue（由协调者创建，worker 不创建）

以下条目对应 §3 的残留风险与 §4 里仍未闭环的部分。每条只描述建议范围，不预设实现方案。

**F1 — `update: 内容哈希不可得时收紧降级判定，或把该路径降级为“仅报告不用作已降级证据”`**（对应 N-1 / A-4 残留）
内容：`UpdateDegradationPlanner.verificationFailure` 在 `contentHashVerified == false` 时只比对
size/mtime。建议二选一：把“无法记录内容哈希”的情况从“已降级”降为“无法自动回滚（证据不足）”，
或至少在文案与历史里把该路径明确标成“元数据比对，不校验旧文件内容”（现状已写明后半句，前者更
彻底）。

**F2 — `update: 让「已放弃」重叠防护能判断被放弃的进程是否仍在运行，或在清除时要求更强确认`**（对应 N-2 / A-7 残留）
内容：记录里没有结束时间与存活证据，防护依赖用户何时清除。建议评估：清除记录前做一次只读的进程
存活检查（同一套 `PiProcessInspector`，仅用于提示/二次确认），或在清除「已放弃」记录时要求用户
确认“我确认那个命令已经结束”，并把结论写进记录。

**F3 — `update: 明确 npm integrity 是展示证据并考虑移除或升级`**（对应 N-3）
内容：`npmIntegrity` 只出现在证据说明里、不参与判定，来源是本机可改写的锁文件。建议在 UI/文档里
把它标注为“本机 npm 记录（可被同用户改写，不参与判定）”，或改成“与本次安装后重新读取的值比对”
之类的更强用法（需要真的执行安装才能验证，超出当前静态评估范围）。

**F4 — `update: 在发送进程组信号前确认子进程尚未被回收`**（对应 N-4）
内容：`terminateOwnProcessGroupLocked` 与 `waitpid` 回收之间存在窄时序窗口。建议把“子进程是否已回收”
的状态与发信号动作放在同一个串行状态里判定（例如发信号前用非阻塞回收确认，或在回收路径上先落
“已回收”标记），并补一个可控的时序回归用例。

**F5 — `update: 说明缓存回退只能影响提示，并评估提示层的完整性约束`**（对应 N-5 / A-9 残留）
内容：缓存文件本身不做真实性校验（这是设计的边界），但提示文案会展示缓存里的版本。建议在偏好设置
与诊断里把“本机缓存”标注做得更醒目（现状已标注来源与写入时间），并评估是否需要在提示框里也带上
来源标注（目前提示框只显示组件名与版本）。

**F6 — `update: 为「已放弃」记录评估一个“由本应用写入”的弱标记`**（对应 N-6 / A-9 残留）
内容：记录现在是普通的 UserDefaults JSON，同用户可手写。它不参与任何执行决策的“开启”，最多暂停
该组件的自动更新并被展示为受长度与控制字符约束的文本；文档已经在本版写明这一边界。若维护者想
降低“手工构造的记录看起来和应用自己写的一样”的程度，可以评估加一个首次运行时生成的实例标记
（同时要如实说明：同用户可以读 UserDefaults，所以这只是绊线，不是安全边界），并把不采用的原因
也写进文档。

**不需要新 issue 的条目**：A-2（`--ignore-scripts` 的取舍已在 #60 用静态证据与用户可见文案固定，
若将来上游改变脚本行为，应在对应版本的评审里重新评估）、A-8（手动入口不做进程门控是有意保留的
用户选择，确认框已写明风险）。

---

## 8. 复现方式

```sh
# 证据基线（与本次审查相同的工作区）
git log --oneline v0.1.0-alpha.3..HEAD

# 只读门禁（§0 表）
git diff --check
sh -n Scripts/*.sh
./Scripts/build.sh
./Scripts/check-identity.sh
./Scripts/smoke.sh
./Scripts/scan-secrets.sh --self-test
./Scripts/scan-secrets.sh
sh Scripts/check-release-version.sh v0.1.0-alpha.4
./Scripts/package-release.sh --tag v0.1.0-alpha.4

# 负向证据（§0 表）
git grep -nE 'kill\(|killpg|SIGTERM|SIGKILL|signal\(|\.terminate\(\)' -- Sources/
git grep -nE '/bin/(sh|bash|zsh)|sudo|shell' -- Sources/PiWebUpdateAdapter.swift \
  Sources/PiCLIUpdateAdapter.swift Sources/PiPackageUpdateAdapter.swift \
  Sources/UpdateTransaction.swift Sources/UpdateVerifier.swift Sources/UpdateAbandonedAttempt.swift
git grep -nE 'moveItem|copyItem|removeItem|unlink\(|rmdir|rename\(|truncate|write\(to:|createFile' -- \
  Sources/PiWebUpdateAdapter.swift Sources/PiCLIUpdateAdapter.swift Sources/PiPackageUpdateAdapter.swift \
  Sources/UpdateTransaction.swift Sources/UpdateVerifier.swift Sources/UpdateAbandonedAttempt.swift
git grep -nE 'Process\(\)|posix_spawn\(' -- Sources/PiWebUpdateAdapter.swift \
  Sources/PiCLIUpdateAdapter.swift Sources/PiPackageUpdateAdapter.swift

# 关键判定点的定位（本报告引用的行号）
git grep -n 'isEligibleForAutomaticInstall\|func autoInstallRefusalText' -- Sources/UpdateChecker.swift
git grep -n 'func validationRejection\|static func validated\|private func cachedFallback' -- Sources/UpdateChecker.swift
git grep -n 'enum PiWebUpdateLifecycleScriptPolicy\|terminateOwnProcessGroup\|stopWaitingLocked' -- Sources/PiWebUpdateAdapter.swift
git grep -n 'static func isCandidate\|secretValuePrefixes\|isOpaqueSecretToken\|maskSensitiveTokens' -- Sources/PiProcessInspector.swift
git grep -n 'static func evaluateRollbackEvidence\|static func verificationFailure\|contentHashVerified' -- Sources/UpdateTransaction.swift
git grep -n 'readContentHash\|isIntegrityValue\|readNpmIntegrity\|notVerifiedCapabilities' -- Sources/UpdateVerifier.swift
git grep -n 'enum UpdateAbandonedAttemptGate\|static func valid\|allowsAutomaticExecution' -- Sources/UpdateAbandonedAttempt.swift
```

设计说明：本报告写在文档提交里，没有修改任何 `Sources/`、`Scripts/` 或 `.github/` 文件；文件本身
不含主机名、私网地址、凭据或真实用户绝对路径（`./Scripts/check-identity.sh` 与
`./Scripts/scan-secrets.sh` 在包含本文件的工作区上退出 0）。
