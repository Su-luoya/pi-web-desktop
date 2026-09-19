# alpha.3 更新流水线安全审查（delta，只读）

- **审查对象**：`0.1.0-alpha.3` 相对 `0.1.0-alpha.2` 新增/变更的**更新流水线**（GitHub #16–#23），
  即工作区里的
  `Sources/PiWebUpdateAdapter.swift`、`Sources/PiCLIUpdateAdapter.swift`、
  `Sources/PiProcessInspector.swift`、`Sources/PiPackageUpdateAdapter.swift`、
  `Sources/UpdateTransaction.swift`、`Sources/UpdateVerifier.swift`、
  `Sources/UpdateSettings.swift` 与 `Sources/PiWebApp.swift` 中调用它们的部分。
- **基线**：`v0.1.0-alpha.2`（tag 指向 `7699a3b`）之后的 5 个功能/文档提交
  （`471bd2c` #53、`86eaadf` #54、`6fa22a5` #57、`dfd8043` #56、`4c53df0` #58），加上本次
  `v0.1.0-alpha.3` 发布提交（版本 bump 与文档，不改动上述功能代码）。
- **性质**：**只读审查**。没有修改任何 `Sources/` 或 `Scripts/` 代码，没有 push、没有 tag、
  没有创建 Release、没有创建 Issue。本报告只写能在当前代码里核对的事实。
- **结论摘要**：**阻断项 0 项**；新增 9 条非阻断风险（A-1 … A-9），其中 2 条判定为“低—中”，
  其余为“低”。建议由维护者创建的 follow-up issue 见 §5。

---

## 0. 方法与证据基线

本次审查的执行方式是“读代码 + 跑只读门禁 + 负向 grep”，**不是**动态渗透测试。

实际执行过、可复现的命令（全部在发布候选工作区上）：

| 命令 | 结果 |
| --- | --- |
| `./Scripts/build.sh` | 退出 0；用系统 `swiftc` 编译包含本流水线全部 6 个新源文件的构建脚本 |
| `./Scripts/check-identity.sh` | 退出 0；`check-identity: PASSED (45 checks)` |
| `./Scripts/smoke.sh` | 退出 0；启动与诊断两种模式都打印标记并退出 0 |
| `./Scripts/scan-secrets.sh --self-test` | 退出 0；`self-test: PASS` |
| `./Scripts/scan-secrets.sh` | 退出 0；`scan-secrets: suppressed 11 lines`、`scan-secrets: PASS` |
| `sh Scripts/check-release-version.sh v0.1.0-alpha.3` | 退出 0 |
| `./Scripts/package-release.sh --tag v0.1.0-alpha.3` | 退出 0；产出 ZIP、`.sha256`、证据 Markdown 与 `release-metadata.env` |
| `git grep -nE 'kill\(|killpg|SIGTERM|SIGKILL|signal\(|\.terminate\(\)' -- Sources/PiCLIUpdateAdapter.swift Sources/PiPackageUpdateAdapter.swift Sources/PiProcessInspector.swift` | 只有注释命中（3 行，均为“不发送信号”的说明），**没有调用点** |
| `git grep -nE 'process\.(executableURL|arguments|environment)|standardInput' -- Sources/Pi*UpdateAdapter.swift` | 三个执行器都是 `Process` + 参数数组 + 白名单环境 + `/dev/null` 标准输入（见 §3 各条证据） |

**本次没有做的事**（因此下列结论不能从这些角度被反驳或被支持）：

- 没有真的打开“启动前自动更新 Pi Web / Pi CLI”开关去执行一次真实 `npm` / `pi` 更新；
  执行路径的结论来自代码阅读、注入式单元测试（它们在 `$TMPDIR` 里执行测试自己写的假脚本）
  与源码负向断言，不是一次真实端到端安装演练。
- 没有做网络抓包、证书校验测试、模糊测试、内存/沙箱逃逸测试或权限提升测试。
- 没有在本机运行 `xcodebuild build` / `xcodebuild test`（本机 `xcode-select -p` 指向
  Command Line Tools），XCTest 由 CI 的 `macos-14` job 覆盖。

---

## 1. 审查范围与未覆盖范围

### 1.1 本次覆盖（更新流水线）

| 面 | 覆盖内容 |
| --- | --- |
| 命令执行面 | 三个执行器（`ProcessPiWebUpdateInstaller`、`ProcessPiCLIUpdateCommand`、`ProcessPiPackageUpdateCommand`）的可执行文件、argv、环境、标准输入、超时与终止行为 |
| 决策/前置条件面 | `PiWebUpdatePlanner`、`PiCLIUpdatePlanner`、`PiPackageUpdatePlanner` 的来源、可信度、目标版本、包名、进程状态门控 |
| 进程保护面 | `PiProcessInspector` / `LibprocPiProcessProbe` 的只读枚举、三态判定、名称匹配、argv 读取与摘要遮罩 |
| 验证/降级面 | `UpdateVerifier` 的五层检查与三态、`UpdateTransaction` 的阶段记录、指纹、降级判定与统一历史 |
| 网络面（沿用 #17 实现） | `UpdateEndpoint` 白名单、`UpdateHTTPRequest.sanitized()`、`URLSessionUpdateHTTPClient` 的 cookie/重定向/凭据配置 |
| 本地状态面 | 更新相关 UserDefaults 键（策略、开关、忽略版本、上次失败告警、统一更新历史）与 `update-check-cache.json` 的字段与读回校验 |
| 用户可见表述 | 设置窗口/确认框/诊断文本与本次发布的 README/发布说明中关于“自动更新、验证、回滚”的措辞 |

### 1.2 明确未覆盖（沿用既有审查或其他范围）

- **服务所有权、Keychain、远程访问密码、监听地址边界、日志脱敏规则本身、CI/发布脚本、
  依赖与供应链、CSP/WebKit 与网站数据**：沿用
  [alpha.1 独立安全与发布审查](security-review-alpha.1.md)（§1–§8、§9、§10 的 R-1 … R-11）。
  本次只在“更新流水线会复用这些机制”的地方做交叉引用（例如脱敏器、服务启动/健康检查路径），
  没有重新审计它们。
- **上游代码与基础设施**：`@agegr/pi-web`、`@earendil-works/pi-coding-agent`（`pi`）自身代码、
  npm CLI/registry 的行为、GitHub Releases API 的信任边界。本次只审查**本应用侧**如何调用它们、
  传什么参数、继承什么环境。
- **桌面应用自身的应用内更新**：本版本不存在该路径（不下载、不安装 `Pi Web Desktop.app`），
  因此没有可审查对象。
- **动态验证**：见 §0 的“本次没有做的事”。
- **Xcode 工程与 XCTest 执行结果**：由 CI 覆盖，本报告不引用本机未执行的测试结论。

---

## 2. 威胁模型（仅更新流水线）

### 2.1 资产

| 资产 | 位置 | 敏感性 |
| --- | --- | --- |
| 被更新的可执行组件（Pi Web / Pi CLI / Pi 扩展包） | 用户本机的 npm/pnpm 全局前缀（如 `~/.npm-global`、Homebrew 前缀下的 `lib/node_modules`） | 高（它们随后以用户身份运行） |
| 子进程可继承的环境与用户 npm/pi 配置 | `HOME`（`~/.npmrc`、`~/.pi`） | 中高（可能含 registry token、代理凭据） |
| 更新相关本地状态 | UserDefaults `updateChecks.*`、`update-check-cache.json`、应用日志 | 中低（版本号、包名、固定文案、时间戳） |
| 服务配置与重检测路径 | `ServiceConfiguration.piWebPath` + 内存中的重检测路径 | 中（决定应用启动哪个可执行文件） |

### 2.2 对手模型

| 对手 | 能力 | 是否在本次防护范围 |
| --- | --- | --- |
| **A. 上游被污染/被替换的发布**（npm 包、GitHub Release） | 在上游发布恶意版本；本机更新后被执行 | **部分在范围内**：应用限制“更新到哪个包、哪个版本、什么来源”，但**不做签名/哈希验证**（A-3） |
| **B. 同用户本地进程** | 可读写该用户的 UserDefaults、缓存文件、npm 配置与被更新目录 | 部分在范围内：应用不因此获得额外权限（对手本可直接写这些文件），但同用户可影响自动更新目标版本（A-1） |
| **C. 其它用户进程** | 不能读本用户文件；`proc_pidargs` 通常读不到 | 在范围内：读不到事实即判 `unknown`，按不安全处理（推迟/拒绝执行） |
| **D. 远程网络攻击者** | 只能影响更新检查的 HTTP 响应（在用户网络或上游被劫持时） | 在范围内：只发 GET、白名单主机、拒绝重定向、不携带凭据；但**依赖系统 TLS 与上游**（A-3） |
| **E. 误操作的用户** | 打开自动更新开关、在有 Pi 会话运行时手动更新 | 在范围内：默认关闭、确认框（取消为默认按钮）、进程保护与可读风险说明 |

### 2.3 攻击面与缓解措施

| 攻击面 | 缓解措施（证据） | 残余风险 |
| --- | --- | --- |
| 命令注入 / argv 拼接 | 只用 `Process` + `arguments`；无 shell；参数逐项过字符集与禁用 token（§3 A-2、B3） | 无（在本次代码范围内未找到注入路径） |
| 更新到错误的包/版本 | Pi Web 包名必须等于静态清单包名；版本必须严格语义化且更高；扩展包 `pi` 参数数组形状逐项校验 | 同用户可改写缓存影响“哪个更高版本”（A-1） |
| 更新到不可信来源 | 只对 `verified` 的 npm/pnpm 全局安装执行；其它来源只展示命令文本 | “verified”只表示本机识别出来的来源类型，不等于上游可信（A-3） |
| 更新时打断运行中的会话 | 进程保护三态，只有 `noProcesses` 允许自动执行；#21/#22 不发送信号 | 手动路径有意不做门控（A-8）；被放弃的命令继续运行（A-7） |
| 子进程拿到不该拿的凭据 | 环境白名单（`PATH`/`HOME`/`TMPDIR`/`LANG`/`LC_ALL`/`LC_CTYPE`），只记键名不记值 | 继承 `HOME` 即继承用户 npm/pi 配置（A-2） |
| 更新失败后处于未知状态 | 阶段化事务 + 五层验证（三态）+ 有限降级 + 持久警告 | 验证不做签名确认（A-3）；降级依据可被同用户伪造（A-4） |
| 日志/诊断泄露 | 统一 `LogRedactor`；进程摘要有 200 字符上限并先做 token 级遮罩；历史字段校验并截断 | 模式化脱敏的既有边界（A-5、A-9） |

---

## 3. 逐条风险项

严重度沿用 alpha.1 报告的口径（低 / 低—中 / 中 / 高）；“是否阻断”见 §4。

### A-1 更新检查缓存与本地设置可影响自动更新的目标版本（低）

- **事实**：`UpdateChecker.cachedFallback(entry:at:allowStatus:)`（`Sources/UpdateChecker.swift:1433`）
  在网络失败时可以从 `update-check-cache.json` 里读回 `status = updateAvailable` 与
  `confidence = verified`（`entry.decodedConfidence`，字段见 `UpdateCacheEntry`，同文件
  `:545`、`:693`），并且 `entry.isReusable(at:ttl:)` 只检查 TTL。`PiWebApp.piWebUpdatePlanningInput`
  （`Sources/PiWebApp.swift:952`）与 `piCLIPlanningInput`（同文件 `:1242`）把这份 `confidence`
  直接作为 `targetConfidence` 传给规划器，`PiWebUpdatePlanner.decide`（`Sources/PiWebUpdateAdapter.swift:323`）
  与 `PiCLIUpdatePlanner.decide`（`Sources/PiCLIUpdateAdapter.swift:297`）据此允许自动安装。
  缓存文件在用户目录下、无完整性校验（无签名/HMAC），同用户进程可改写；`UpdateCheckSettingsMigration`
  对策略/开关的非法值会回退默认（`Sources/UpdateSettings.swift:302`），但**不会**校验缓存文件的真实性。
- **影响**：同用户对手可以让应用自动安装**同一个官方包**的任意一个已发布版本（仍需满足“目标版本可
  解析且高于本机版本”、来源为已验证的 npm/pnpm 全局安装、开关已打开）；不能换包名、不能换 registry、
  不能注入本地文件。由于对手已经能直接操作这些文件与进程，这属于“同用户威胁模型内的残余风险”，
  不是权限提升。
- **缓解（现有）**：包名来自静态清单（`InstallCommandManifest.piWebPackageName`，见 A-2 证据）、
  版本必须 `SemanticVersion` 且严格高于本机版本、默认关闭、安装后重新验证并做健康检查、
  失败只写告警且不重复自动重试。
- **残留风险**：缓存没有完整性/新鲜度绑定；“verified”在缓存回退路径上的语义弱于“本次运行刚从
  白名单主机拿到响应”。
- **建议**：见 §5 F1。

### A-2 Pi Web 自动安装不传 `--ignore-scripts`，且子进程继承 `HOME` 与用户 npm 配置（低—中）

- **事实**：自动安装的 argv 固定为 `["install", "-g", "<包名>@<目标版本>"]`
  （`PiWebUpdateInstallPlan.make`，`Sources/PiWebUpdateAdapter.swift:177`，argv 字面量在 `:190`），
  包名必须等于静态清单里的 Pi Web 包名（同函数第 181–186 行的前置校验）。环境白名单
  （`PiWebUpdateEnvironment.allowedKeys`，同文件 `:110`）包含 `HOME`，因此 npm 会按用户自己的
  `~/.npmrc`（registry、proxy、token）与 npm 默认语义运行。argv 里没有 `--ignore-scripts`，
  所以该包的生命周期脚本会按 npm 的默认行为执行（本机 npm 11.19.0）。执行器确认只用参数数组
  （`ProcessPiWebUpdateInstaller.startLocked`，同文件 `:579-582`：`executableURL` / `arguments` /
  `environment` / 标准输入 `/dev/null`），没有 shell、没有 `sudo`。
- **对照**：同一份发布说明的安装指引对 `@earendil-works/pi-coding-agent` 使用
  `--ignore-scripts`，对 `@agegr/pi-web` 使用普通安装；应用不执行安装指引里的任何命令。
- **影响**：若上游包（或用户 npm 配置指向的 registry）被污染，安装步骤可以在用户权限下执行任意
  脚本。应用既不传 `--ignore-scripts`，也不校验包内容或签名，因此这一条完全依赖上游与用户配置。
- **缓解（现有）**：只对已验证的 npm 全局安装、已验证且更高的目标版本执行；参数数组、无 shell、
  无 `sudo`、环境白名单、5 分钟超时；安装后重新检测版本 + 健康检查，失败不重试。
- **残留风险**：安装期脚本执行、registry 选择与凭据使用都由 npm 与用户配置决定，应用不干预也不
  审计。
- **建议**：见 §5 F2。

### A-3 “更新后验证”不等于“来源可信”（低—中）

- **事实**：验证只有五条检查——可执行文件存在且带可执行位、解析后的真实路径可读、版本能被 #16
  识别器重新检测并达到目标、`package.json` 的 `name` 与期望包名一致、服务健康检查
  （`UpdateVerificationCheck`，`Sources/UpdateVerifier.swift:106`；边界文案 `capabilityBoundary` `:124`；
  实现 `verify(_:probe:)` `:256`、`executableCheck` `:321`、`versionCheck` `:390`、
  `identityCheck` `:426`）。代码里显式列出**不做**的验证（`notVerifiedCapabilities`，`:138`）：
  不做代码签名验证、不声称能验证官方签名或发布来源、不做安装包内容哈希或上游文件比对。
  `UpdateVerificationCheckStatus` 有第三种状态 `notChecked`（`:145`），`isVerified`（`:196`）
  要求版本检查必须明确通过、健康检查不得失败，但允许文件/身份检查为“未验证”。
- **影响**：上游被污染、或安装后的文件被替换时，验证仍可能给出“通过”。用户可见文案（设置窗口、
  确认框、README、本次发布说明）已写明不做签名确认，因此这是**已声明**的能力边界，不是隐藏能力。
- **缓解（现有）**：`notVerifiedCapabilities` 与 `capabilityBoundary` 与展示文案同源；发布说明与
  README 的“已知限制”明确了这一点。
- **残留风险**：把“验证通过”读成“已确认安全/官方来源”的误解风险。
- **建议**：见 §5 F5（与 A-4 合并处理）。

### A-4 有限降级的判定依据可被同用户伪造（低）

- **事实**：`UpdateDegradationPlanner.verificationFailure`（`Sources/UpdateTransaction.swift:328`）
  只有在以下条件全部成立时才产出 `degradedToPreviousArtifact`：来源是 `.npmGlobal`；指纹里有
  更新前版本与路径（`UpdateArtifactFingerprint`，`:110`）；探针可用；旧路径仍带可执行位、文件大小
  与 mtime 与指纹一致；且重新检测到的路径与旧路径不同。任一条不满足就写
  `cannotAutomaticallyRollback`（`UpdateRollbackEligibility`，`:226`；降级类别 `:250`）。
  生产侧的应用动作只有两处：`PiWebApp.applyPiWebUpdateDegradation`（`Sources/PiWebApp.swift:1110`）
  把 `ServiceConfiguration.piWebPath` 与重检测路径指回旧文件；`applyPiCLIUpdateDegradation`
  （同文件 `:1121`）只改重检测路径。
- **影响**：大小与 mtime 都是同用户可设置的文件属性，对手可以伪造“旧文件仍然是更新前那份”。
  但对手本来就能直接替换该路径下的文件，因此不构成额外权限；真实风险是**降级指向的并不是真正
  的旧版本**，用户界面会显示“已降级”而实际文件可能已被替换。
- **缓解（现有）**：只对 npm 全局来源；只在路径不同时降级；不移动/复制/删除文件；用户可见文案
  区分“仍在使用更新前的版本 / 已降级 / 无法自动回滚”（`UpdateWarningText`，同文件 `:435`）。
- **残留风险**：指纹强度不足（无内容哈希）；同用户伪造可让“已降级”的表述与事实不符。
- **建议**：见 §5 F5。

### A-5 进程保护会读取本机可读进程的 argv，摘要遮罩基于固定模式（低）

- **事实**：`LibprocPiProcessProbe.snapshot(of:)`（`Sources/PiProcessInspector.swift:137`）对枚举出的
  每个 PID 都调用 `arguments(of:)`（`:193`，`sysctl KERN_PROCARGS2`，上限 1 MiB）；image path 来自
  `proc_pidpath`（`:181`）。判定为 Pi 以后，`makeRecord` 只保留脱敏后的记录
  （`PiProcessInspector.classify` `:474`、`classifyInterpreterProcess` `:519`、`commandSummary` `:683`），
  摘要有 200 字符上限（`PiProcessRecord.commandSummaryLimit`，`:281`），先做 token 级遮罩
  （`maskSensitiveTokens`，`:643`：敏感键名片段、`键=值`、裸开关、URL 查询串交给 `LogRedactor`），
  再整体过 `LogRedactor`；`KEY=VALUE` 形状的环境片段被丢弃（`isEnvironmentAssignment`，`:591`）。
  这些记录只用于诊断页、手动确认框与日志，**不写入磁盘**（更新相关的持久化字段里没有进程信息，
  见 A-9）。
- **影响**：应用在内存里短暂读取本机可读进程的 argv（其它用户进程通常读不到，因权限失败被记为
  `unknown`）；只有被判定为 Pi 的进程会进入摘要。遮罩是模式化的：不符合“敏感键名片段/键值/查询串”
  形状的秘密（例如某些短开关后的位置参数）可能不被替换而进入摘要。这与 alpha.1 R-1/R-2（脱敏规则
  覆盖范围）同源。
- **缓解（现有）**：只读、无信号、不落盘；摘要有长度上限并经过两级脱敏；`PiWebDesktopTests/PiProcessInspectorTests.swift`
  有专门的遮罩用例与源码负向断言（`:466`“源码负向断言（没有信号、没有 shell、没有 sudo）”）。
- **残留风险**：读取面比“只看 JS 运行时进程”更大（对所有 PID 读 argv）；模式化脱敏的非键值形态
  可能残留。
- **建议**：见 §5 F3。

### A-6 `#20` 的超时终止只覆盖自己启动的子进程，不覆盖 npm 派生的子进程（低）

- **事实**：`PiWebUpdateInstaller.terminateLocked`（`Sources/PiWebUpdateAdapter.swift:623`）先
  `process.terminate()`（向该子进程发 `SIGTERM`），2 秒宽限期（`defaultTerminationGrace`）后
  仍 `isRunning` 才 `kill(pid, SIGKILL)`；`scheduleTimeoutLocked` 只在超时路径调用它（5 分钟，
  `defaultTimeout`，`:771`）。它针对的是本次启动的那个进程，**不覆盖该进程自己派生的子进程**，
  也没有使用进程组。
- **影响**：超时后 npm 派生的子进程（例如它启动的 node 子进程）可能短暂继续运行，占用网络/CPU
  并继续写同一个全局前缀。它与 #21/#22 的“放弃等待”不同：这里确实会向自己的子进程发信号。
- **缓解（现有）**：只对自己启动的子进程；有界宽限期；结果按超时失败处理并写告警；不重试。
- **残留风险**：派生进程的清理不完整；退出后应用不再观测它们。
- **建议**：见 §5 F4。

### A-7 `#21` / `#22` 的被放弃命令可能继续运行并与后续尝试重叠（低）

- **事实**：`PiCLIUpdateRunning.abandon()`（`Sources/PiCLIUpdateAdapter.swift:442`）与
  `PiPackageUpdateRunning.abandon()`（`Sources/PiPackageUpdateAdapter.swift:970`）的文档与实现都明确
  “不发送任何信号”（实现 `:498`、`:1022`）；超时只把结果标记为 `timedOut`/`abandoned`
  （`PiCLIUpdateCommandFailure`、`PiPackageUpdateCommandFailure` 的固定文案）。三个执行器都不使用
  进程组；`git grep` 负向断言（§0 表）确认这三个文件里没有 `kill`/`signal`/`terminate` 调用点。
- **影响**：被放弃的 `pi update --self` / `pi update npm:<包名>` 可能继续在后台运行；理论上可与
  下一次尝试（下次启动的自动路径、或用户随后点的手动入口）重叠，同时写同一个全局前缀。应用无法
  观测或阻止它（这是“不发送信号”这一安全取舍的代价，且已写入用户可见文案）。
- **缓解（现有）**：自动路径每个运行期最多一次、执行前复查进程状态；结果只写告警；文档明写
  “超时只放弃等待”。
- **残留风险**：并发更新同一组件；无“正在被放弃的进程”记录。
- **建议**：见 §5 F4。

### A-8 `#21` 手动入口有意不做进程门控（低，设计取舍）

- **事实**：`PiCLIUpdateCoordinator.runManual(_:completion:)`（`Sources/PiCLIUpdateAdapter.swift:852`）
  直接执行，不检查进程状态；风险说明由 `PiCLIManualUpdateConfirmation.text`（`:1061`）在确认框里
  展示（包含运行中的 Pi 进程列表与“不会结束或暂停任何 Pi 会话”）。自动路径则在
  `runAutomatic` 里做执行前复查（`:861` 起）。扩展包路径的手动入口**仍要求** `noProcesses`
  （`PiPackageUpdateCoordinator.runPlans`，`Sources/PiPackageUpdateAdapter.swift:1374`）。
- **影响**：用户可以在有 Pi 会话运行时手动更新 Pi CLI，正在运行的会话可能读到被替换后的文件。
  这是有意保留的用户选择（也是唯一能做到“现在就更新”的路径），且已在确认框里写明；不构成越权。
- **缓解（现有）**：必须显式确认（取消为默认按钮）；确认框展示进程与风险；不发信号。
- **残留风险**：运行中的会话行为可能改变（属于上游组件与用户选择的组合）。
- **建议**：不需要新 issue；如果维护者想收紧，可在确认框里增加一次“二次确认”或默认推迟。

### A-9 本地持久状态可被同用户读取/改写，且依赖模式化脱敏（低）

- **事实**：更新相关的持久数据只有三类——策略/开关/忽略版本（`Sources/UpdateSettings.swift:68`
  起的键常量）、上次失败告警（`PiWebUpdateWarningStore` 等，`Sources/PiWebUpdateAdapter.swift:1061`
  起的实现）、统一更新历史（`UpdateHistoryStore`，`Sources/UpdateTransaction.swift:722`，最多 20 条，
  `sanitize(_:)` `:756` 会丢弃非法包名/版本、截断长文本、剔除控制字符）。历史/告警字段是固定枚举、
  已校验版本号/包名与固定原因文案；`UpdateHistoryPresenter`（`:877`）只做展示，不触发任何动作。
  `update-check-cache.json` 的字段范围见 A-1。
- **影响**：这些值未加密，同用户进程可读可写；对历史的改写只会影响展示（读取时会被 sanitize），
  不会变成执行指令。日志/诊断的脱敏仍依赖 `LogRedactor` 与上述 token 遮罩的既有规则边界
  （与 alpha.1 R-1/R-2 同源）。
- **缓解（现有）**：字段白名单 + 读回校验 + 长度上限 + 控制字符剔除；展示与执行解耦；
  `scan-secrets.sh` 退出 0（11 条抑制行都在既有测试夹具里，本次没有新增内联标记）。
- **残留风险**：非敏感元数据可被同用户观测；脱敏是模式化的（见 A-5）。
- **建议**：不需要新 issue；如需加固可在后续版本给更新历史加签名或改为只读日志。

---

## 4. 阻断条件判定

判定规则与 [alpha.1 审查](security-review-alpha.1.md#11-阻断条件与判定)相同：任一阻断条件触发就不应
push tag；非阻断风险必须在 Release Issue 里显式处置。

| 编号 | 阻断条件 | 判定 | 证据 |
| --- | --- | --- | --- |
| B1 | 存在“来源不可信（非 `verified` 的 npm/pnpm 全局）仍会自动安装/自动执行”的路径 | 未触发 | `PiWebUpdatePlanner.decide`（`PiWebUpdateAdapter.swift:323`）与 `PiCLIUpdatePlanner.decide`（`PiCLIUpdateAdapter.swift:297`）在来源/可信度不满足时只返回 `manualOnly`/`unavailable`；扩展包 `PiPackageUpdatePlan.make` 要求 `source == .npmGlobal && confidence == .verified`（`PiPackageUpdateAdapter.swift:402`）；两个开关默认关闭（`UpdateSettings.swift:228`） |
| B2 | 存在无人值守的扩展包更新路径 | 未触发 | `allowsUnattendedExecution = false`（`PiPackageUpdateAdapter.swift:351`）、`isAutomaticallyExecutable` 恒为 false（`:373`）、策略集合只有三种（`:36`）；规划器没有任何“直接执行”分支（`decide` `:700` 只在 `awaitingConfirmation` 后由用户确认触发 `runConfirmed`）；测试断言确认前零执行 |
| B3 | 更新命令经 shell 字符串执行、调用 `sudo`、或 argv 元素来自未校验的外部文本 | 未触发 | 三个执行器都 `process.arguments = plan.arguments`（`PiWebUpdateAdapter.swift:580`、`PiCLIUpdateAdapter.swift:519`、`PiPackageUpdateAdapter.swift:1043`）；参数白名单与禁用 token（`PiWebUpdateAdapter.swift:82/85`、`PiPackageUpdateAdapter.swift:284/289`）；Pi Web 包名必须是静态清单名、版本必须严格语义化；Pi CLI argv 必须精确等于 `["update", "--self"]`（`PiCLIUpdateAdapter.swift:137`）；扩展包 argv 必须精确等于 `["update", "npm:<包名>"]`（`PiPackageUpdateAdapter.swift:418`） |
| B4 | 任一更新路径向非自己启动的进程发送信号、结束 Pi 会话或修改 Pi 配置 | 未触发 | §0 的负向 grep（#21/#22/inspector 无调用点）；`#20` 的 `terminateLocked`（`PiWebUpdateAdapter.swift:623`）只作用于 `self.process`；三处 `applyDegradation` 只改本应用配置/重检测路径（`PiWebApp.swift:1110`、`:1121`，扩展包为 no-op `PiWebApp.swift:254-257`） |
| B5 | 凭据/秘密进入日志、诊断、更新历史或 UserDefaults | 未触发 | 环境白名单只记键名（`keyDescription`）；历史读回 sanitize（`UpdateTransaction.swift:756`）；告警字段固定；`scan-secrets.sh` 与 `--self-test` 退出 0（§0） |
| B6 | 更新检查发出非白名单主机请求、携带 cookie/Authorization 或跟随重定向 | 未触发 | `UpdateHTTPRequest.sanitized()`（`UpdateChecker.swift:241`）、`URLSessionConfiguration.ephemeral` + 清空 cookie/凭据存储（`:298-302`）、`willPerformHTTPRedirection` 一律拒绝（`:350`）、`UpdateEndpoint`（`:155`）只生成 GitHub/npm 两个端点 |
| B7 | 用户可见文案把“验证”说成“已确认代码签名 / 官方来源 / 可完整回滚” | 未触发 | `UpdateVerificationCheck.notVerifiedCapabilities`（`UpdateVerifier.swift:138`）与 `capabilityBoundary`（`:124`）；README“已知限制”与本次发布说明都写明不做签名确认、不承诺所有来源可回滚；`updateChecks` 相关文案里没有“已签名/已公证”表述 |
| B8 | 回滚/降级路径移动、复制、删除文件，或卸载已安装组件 | 未触发 | `UpdateDegradationPlan` 只携带路径与文案；`applyDegradation` 的唯一动作是改配置/重检测路径；代码注释与用户文案都声明“不移动、不复制、不卸载” |

### 4.1 最终结论

**阻断项 0 项。** 更新流水线（#16–#23）在本版实现下不构成发布阻断；本报告的非阻断风险
A-1 … A-9 及 alpha.1 的 R-4、R-5、R-6、R-8、R-10 应在 Release Issue 里逐条给出“接受 / 本版本修 /
转后续 Issue”的处置。**本审查结论不构成发布批准**：CI 全绿、真机 smoke、checksum 与 prerelease
标记等门槛仍按 [Alpha 发布门槛清单](alpha-release-checklist.md) 逐项满足。

---

## 5. 建议的 follow-up issue（由协调者创建，worker 不创建）

以下 5 条对应 §3 的残留风险。每条都只描述建议范围，不预设实现方案；优先级由维护者决定。

**F1 — `update: 为更新检查缓存增加完整性/新鲜度约束，避免缓存回退直接驱动自动安装`**（对应 A-1）
内容：`UpdateChecker.cachedFallback` 在网络失败时可以把缓存的 `updateAvailable` + `verified`
带进 `PiWebUpdatePlanner` / `PiCLIUpdatePlanner`。建议在自动安装判定里要求“本次运行刚从白名单
主机拿到的结果”，或给缓存文件加与应用绑定的完整性校验（例如 HMAC 或随进程启动轮换的随机盐），
并在文档里写明缓存回退不允许单独触发自动安装。

**F2 — `update: 评估 Pi Web 自动安装是否需要 --ignore-scripts，并在文档写明 npm 生命周期脚本语义`**（对应 A-2）
内容：当前 argv 是 `["install", "-g", "<包名>@<版本>"]`，不传 `--ignore-scripts`；npm 默认会执行包的
生命周期脚本，子进程继承 `HOME`（因此使用用户 `~/.npmrc`）。建议先与上游确认 `@agegr/pi-web`
是否依赖安装期脚本，再决定是否加 `--ignore-scripts`，并把结论写进 README/隐私说明与发布说明。

**F3 — `update: 只在候选进程看起来是 JS 运行时之后再读取 argv，缩小进程保护的读取面`**（对应 A-5）
内容：`LibprocPiProcessProbe.snapshot` 目前对每个 PID 都读 `KERN_PROCARGS2`。建议先按 image path /
内核进程名判定，只有“可能是 JS 运行时”的进程才读 argv；同时补充非键值形状秘密的遮罩用例
（例如 `-p<值>`、位置参数形式），把已知边界写进 `docs/privacy.md`。

**F4 — `update: 明确超时/放弃等待之后子进程的行为，并防止同一组件的重叠更新`**（对应 A-6、A-7）
内容：`#20` 的超时终止不覆盖 npm 派生的子进程；`#21`/`#22` 的超时只放弃等待，被放弃的命令可能
继续运行并与后续尝试重叠。建议至少做到：在状态里记录“本次运行已放弃一个命令，结束时间未知”
并在下次自动尝试前提示；评估给 `#20` 的子进程使用独立进程组（仍只对本次启动的进程组）；把
行为差异写进文档。

**F5 — `update: 加固有限降级的判定依据，避免“已降级”与实际文件不符`**（对应 A-3、A-4）
内容：降级当前依赖路径、可执行位、文件大小与 mtime。建议评估记录更强指纹（例如 inode + 内容
哈希，或在 npm 全局安装场景下记录 npm 包的 `package.json` + `integrity` 字段），并在“已降级”
的展示文案里写明这只是“把调用方指回旧路径”，不校验旧文件内容；同时评估是否需要在 UI 上把
“验证通过”改成不含“安全/官方来源”暗示的措辞。

---

## 6. 复现方式

```sh
# 证据基线（与本次审查相同的工作区）
git log --oneline v0.1.0-alpha.2..HEAD

# 只读门禁（§0 表）
sh -n Scripts/*.sh
git diff --check
./Scripts/build.sh
./Scripts/check-identity.sh
./Scripts/smoke.sh
./Scripts/scan-secrets.sh --self-test
./Scripts/scan-secrets.sh
sh Scripts/check-release-version.sh v0.1.0-alpha.3
./Scripts/package-release.sh --tag v0.1.0-alpha.3

# 负向证据（#21 / #22 / 进程检查器不应出现信号调用）
git grep -nE 'kill\(|killpg|SIGTERM|SIGKILL|signal\(|\.terminate\(\)' -- \
  Sources/PiCLIUpdateAdapter.swift Sources/PiPackageUpdateAdapter.swift Sources/PiProcessInspector.swift

# 参数数组执行（三个执行器）
git grep -nE 'process\.(executableURL|arguments|environment)' -- Sources/Pi*UpdateAdapter.swift
```

本报告写完后在同一工作区重跑过上述命令（结果与 §0 表一致）；报告本身没有新增任何会被
`scan-secrets.sh` / `check-identity.sh` 命中的字面值（本文件在 `docs/` 下，且不含主机名、
私网地址、凭据与真实用户绝对路径）。
