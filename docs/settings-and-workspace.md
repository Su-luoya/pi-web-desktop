# 设置、工作目录与退出行为

本文说明三件事：普通设置、运行状态与日志分别存在哪里；服务工作目录如何选择以及不可写时应用做什么；退出应用时服务如何处置。实现见 `Sources/AppConfiguration.swift`、`Sources/AppPaths.swift`、`Sources/WorkspaceDirectory.swift`、`Sources/QuitPolicy.swift`、`Sources/ServiceManager.swift` 与 `Sources/PiWebApp.swift`。

## 设置分层

| 内容 | 位置 | 说明 |
| --- | --- | --- |
| 普通设置 | UserDefaults | 键与默认值沿用既有约定（`service.hostname`、`service.port`、`service.piWebPath`、`service.allowedHosts`、`service.httpProxy`、`service.httpsProxy`、`service.noProxy`、`service.autoStart`、`service.quitBehavior`，以及工作目录 `service.workspacePath`）。读写都经 `AppConfiguration`。 |
| 远程访问密码 | macOS Keychain | service = bundle identifier，account = `remote-access-password`。密码不进入 UserDefaults、命令行、日志或诊断文本。 |
| 运行状态 | `~/Library/Application Support/Pi Web Desktop/` | `app.pid`（单实例锁）、`instance.lock`、`service-owner.json`（所有权记录）、旧 `service.pid`（启动时删除）、默认工作目录 `Workspace/`。 |
| 日志 | `~/Library/Logs/Pi Web Desktop/` | `Pi Web Desktop.log`，达到 10 MB 时轮转为 `Pi Web Desktop.1.log` … `.5.log`（保留 5 份）。菜单“打开日志”确保日志文件存在，“打开日志文件夹”只确保目录存在（目录不存在时创建，失败给出可读提示），因此从未启动过服务也能打开。轮转策略、脱敏规则与诊断导出见 [日志与诊断导出](logging-and-diagnostics.md)。 |

默认服务设置保持安全值：监听 `127.0.0.1`、代理为空、`noProxy` 只含 loopback、启动时自动启动、退出时询问。默认配置序列化到 UserDefaults 后不含任何个人代理设置或远程 hostname。

所有路径由可注入的 `AppPaths` 提供者派生（`supportDirectory` + `logsDirectory`），因此单元测试与 smoke 启动可以注入临时目录，不会写入真实 Home。`PI_WEB_DESKTOP_SMOKE=1|diagnostics` 使用 `$TMPDIR/pi-web-desktop-smoke-<pid>`，日志放在该目录的 `Logs/` 下。日志写入与轮转由 `LogWriter` 负责，写入的每一行都经过与诊断导出、错误消息、环境变量/命令行展示共用的 `LogRedactor`（见 [日志与诊断导出](logging-and-diagnostics.md)）。

### 设置窗口（单例）

菜单“设置…”/⌘, 是单例（W4 M2）：同一时刻只存在一个能写回配置的设置窗口。重复打开复用同一个控制器/窗口：窗口已经打开时只置前（不拿已保存值覆盖用户正在编辑的内容）；关闭/取消后再打开前，用当前生效配置刷新控件——上一次取消后留下的未保存输入、外部改动与刚输入的新密码都不会残留。旧实现每次新建控制器并覆盖引用，旧窗口（`isReleasedWhenClosed = false` 且不 close）会留在屏幕上、用打开时的配置快照写回，出现“两个窗口都能保存、后写覆盖前写”。需要显式丢弃时用 `ReusableControllerStore.discard`（先 close 再释放，旧实例不再被保留）。

窗口可自由缩放并记住尺寸与位置（`setFrameAutosaveName`，只有第一次打开时才居中）：表单列最小 520pt，变宽时每一行、输入框与说明文字一起变宽，多行说明按新宽度重新折行（`WrappingLabel` 在每次布局后把 `preferredMaxLayoutWidth` 更新为实际宽度；窗口最小宽度由这一列宽加两侧 24pt 边距决定，与表单列同源，不再由某一行或单行文字的内在宽度决定）。表单放在 `NSScrollView` 里且文档只受宽度约束，窗口缩得比表单矮时从顶部开始滚动，不会裁掉说明文字或底部按钮；错误提示与「恢复默认/取消/保存」固定在窗口底部、不随表单滚动，因此窗口很矮时也能直接保存或取消。

### 监听地址校验

监听地址（`service.hostname`）的校验只有一处实现：`RemoteAccessPolicy.addressVerdict(hostname:)`（`Sources/KeychainStore.swift`，结果类型 `ServiceAddressVerdict`）。同一判定同时作用于三个入口（GitHub #39 / 安全审查 R-3）：

- 偏好窗口保存：`PreferencesWindowController` 保存前调用 `hostnameValidationMessage`，`RemoteAccessSetup.apply` 也先拒绝非法地址（先于密码写入），配置与 Keychain 都不会被写入。
- 配置加载：`ServiceConfiguration.load` 执行同一判定，`[::1]` 规范化为 `::1`；非法值原样保留并由 `ServiceConfiguration.hostnameProblem` 标记为不可用，不会静默回退到 loopback 或其他地址。
- 启动决策：`ServiceManager.startDecision(credentials:)` 与 `isStartPermitted` 要求地址可用；非法地址返回 `.invalidAddress`，不启动进程、不探测外部服务、不加载服务页，失败提示给出非法值与允许范围。

允许 loopback（`127.0.0.0/8`、`localhost`、`*.localhost`、`::1`）与用户显式配置的具体地址；拒绝 `0.0.0.0`、`::`、`[::]`、`*` 等通配地址、空地址、前后空白、协议/路径/端口混写等非法字符，方括号只允许用于 IPv6 字面量。`getaddrinfo` 会解析成 `0.0.0.0`/`::` 的写法（`0`、`0x0`、`000.000.000.000`、`0.0.0.0.`、`0:0:0:0:0:0:0:0`、`::ffff:0.0.0.0` 等）与歧义的数值写法同样被拒绝：只接受规范点分四段、规范 IPv6 字面量与主机名。非 loopback 地址还必须已有非空密码（见 [architecture.md](architecture.md) 的“远程访问与密码”一节）。因此直接改写 UserDefaults 绕过界面校验不再能进入启动流程。

## 更新检查设置

四类组件（桌面应用、Pi CLI、Pi Web、Pi 扩展包）各自一份检查策略，与启动前自动更新开关、忽略版本、更新失败警告一起存在 UserDefaults，读写都经 `AppConfiguration`（见 [隐私说明](privacy.md) 的“版本检查、提示与忽略版本”）：

| 组件 | 可选策略 | 默认 | 键 |
| --- | --- | --- | --- |
| 桌面应用 / Pi CLI / Pi Web | 关闭 / 每日 / 每周 | 每日（24 小时） | `updateChecks.desktopApp.policy`、`updateChecks.pi.policy`、`updateChecks.piWeb.policy` |
| Pi 扩展包 | 关闭 / 检查并通知 / 询问后更新 | 检查并通知（7 天） | `updateChecks.piPackages.policy` |

- 关闭 = 不调度、不请求；每日 / 每周 / 扩展包 7 天由 `UpdateCheckIntervals` 映射成秒数，调度器只读这一份来源（测试注入更短值 + 假时钟即可断言）。
- “询问后更新”与“检查并通知”的复查节奏相同（7 天），区别在能力：“检查并通知”只提示并给出官方命令文本，“询问后更新”在用户确认后可以执行一次扩展包更新（GitHub #22，见下条）；两种策略都不下载 tarball、不改服务配置，也都没有无人值守路径。
- 启动前自动更新 Pi CLI（GitHub #21，默认关闭）：`updateChecks.pi.autoUpdateBeforeLaunch`。打开后，应用在拿到当次版本检查结果后判定一次：只有本机 Pi CLI 是“已验证的 npm/pnpm 全局安装”、目标版本已验证且高于本机版本、**目标版本来自本次网络检查结果**（GitHub #59：缓存回退与无结果都不自动执行）、命令通过参数安全校验，**并且当次进程检查确认没有运行中的 Pi CLI 进程**时才会执行一次 `pi update --self`。只要有运行中的 Pi 进程（或状态不确定），本次就推迟到下次启动或下一次判定，原因写入日志与状态页，不弹框；自动尝试每个运行期最多一次，不自动重试、不自动回滚，版本未变或无法解析也算失败（写持久警告）。手动入口“立即更新 Pi CLI…”不做进程门控，但必须在确认框里确认（显示可执行文件、参数数组、当前/目标版本、每个运行中 Pi 进程的 PID/父进程/启动时间/判定依据/脱敏后的命令摘要与风险说明）。
- 运行进程保护（GitHub #21）：进程检查是只读的 libproc 枚举（`proc_listpids` / `proc_pidinfo` / `proc_pidpath` / `sysctl`），只做精确的可执行名比较（`pi-web` / `pip` / `pi-helper` 不命中；Pi CLI 以 Node 脚本形式运行时靠进程标题或脚本路径判定），结果三态：`noProcesses` / `runningProcesses` / `unknown`，**只有 `noProcesses` 允许自动更新**。应用从不向 Pi 进程发送信号，也不结束或接管任何 Pi 会话；枚举失败、权限不足等任何不确定都按不安全处理。
- 超时/放弃等待的「已放弃」记录与重叠防护（GitHub #62；alpha.3 安全审查 A-6、A-7）：更新命令超时、应用退出或用户取消而放弃等待时，应用写一条持久记录——组件、已脱敏的命令摘要、开始时间、超时上限、放弃原因、来源与本次对子进程实际做了什么（键：`updateChecks.piWeb.abandonedAttempt` / `updateChecks.pi.abandonedAttempt` / `updateChecks.piPackages.abandonedAttempts`）。记录里**没有结束时间**（`finishedAt` 恒为空）：应用已经停止等待，不知道那个进程什么时候结束、有没有结束，不写假时间；派生进程是否结束同样恒为“未确认”。
  - **对子进程做了什么**：Pi Web 的 npm 子进程用 `posix_spawn` 启动并要求新建独立进程组（`POSIX_SPAWN_SETPGROUP` + `pgroup = 0`，组 id 就是子进程自己的 pid），超时/取消只对这**一个自己的进程组**发一次 `SIGTERM`（尽力而为，不发 `SIGKILL`、不按名字杀进程、绝不触碰任何 Pi 进程）；无法建立独立进程组时降级为“只放弃等待”，一次信号都不发。Pi CLI 与扩展包的更新命令就是 `pi` 本身：超时、应用退出与取消一律只放弃等待，**不发送任何信号**。
  - **重叠防护（硬前置）**：同一组件存在未清除的记录时，该组件**不再自动执行**下一次更新（推迟到下次启动），原因可读并写入日志；手动入口不受影响，但确认框会先展示这条记录，需要用户显式确认后才执行一次。三个组件互相独立；只有用户显式清除，或该组件后来成功完成了一次更新，才会清除该组件的记录（失败不清除）。
  - **可见性与清除**：诊断窗口的更新状态页与“更新检查偏好设置…”窗口都展示全部记录；菜单“服务 → 更新检查设置 → 已放弃的更新记录…”可展开并显式清除（清除只删除记录，不改动任何文件、也不结束任何进程）。记录在退出与重新启动后保留。
- 启动前自动更新 Pi Web（GitHub #20，默认关闭）：`updateChecks.piWeb.autoUpdateBeforeLaunch`。打开后，只有本机 Pi Web 是“已验证的 npm 全局安装”时才会在应用启动时尝试自动更新：目标版本必须是已验证且高于本机版本，**且来自本次网络检查结果**（GitHub #59：缓存回退与无结果都不自动执行），包名必须等于静态清单里的 `@agegr/pi-web`，npm 可执行文件必须解析到，且服务不能正在运行（运行中发现的更新只安排到下次启动），并且不能有未清除的「已放弃」记录（GitHub #62，见上条）。执行时用参数数组直接调用 `npm install -g <包名>@<版本>`（`posix_spawn`，独立进程组），不使用 shell、不调用 `sudo`，有超时，安装后重新检测版本并做健康检查。其它来源（pnpm、Homebrew、nvm/mise、git checkout、本地路径、未知）仍只显示更新命令。失败时只有一条持久警告（菜单“更新检查设置”里的“Pi Web 更新告警…”条目，可展开并清除）与诊断页提示，同一次运行内不会自动重试；应用照常启动、不阻止手动启动服务，也**不会自动回滚**。手动入口“立即更新 Pi Web…”只在设置打开且来源满足时可用，并且需要先在确认框里确认（有记录时先展示记录）。
- 扩展包更新确认流（GitHub #22，默认只通知）：菜单“服务 → 更新检查设置 → 查看 Pi 扩展包更新…”显示本次检测到的 Pi 扩展包（#16 的 `pi list` 结果：包名与本机版本）、来源与可信度、目标版本与逐个结论。只有来源为**已验证的 npm 全局安装**、目标版本经上游验证且高于本机版本、**目标版本来自本次网络检查结果**（GitHub #59：缓存回退只提示、不给执行入口）、当次进程检查为 `noProcesses` 时才提供执行入口；确认框显示包名、当前/目标版本、来源与可信度、可执行文件路径（Home 段显示为 `~`）、参数数组、完整命令、风险说明与每个运行中 Pi 进程的 PID/父进程/启动时间/判定依据/脱敏命令摘要，**取消是默认按钮**，未确认就不执行，也不改任何状态。判定顺序上进程保护先于「已放弃」记录（GitHub #107）：当次进程检查不是 `noProcesses` 时直接拒绝执行，不会先要求确认一条执行不下去的记录。非 npm 全局来源只显示官方命令文本 `pi update --extensions`（由 Pi 自己决定实际更新哪些包），不提供执行入口；应用不调用 npm/pnpm、不拼 shell 字符串、不调用 `sudo`，命令固定为参数数组 `["update", "npm:<包名>"]`。
- 扩展包更新的进程保护与失败语义（GitHub #22）：计划生成后、真正执行前会再用 `PiProcessInspector` 检查一次，只要出现运行中的 Pi 进程或状态不确定就拒绝执行、并停止剩余计划（原因写入日志、诊断与状态行），**绝不结束、暂停或接管任何 Pi 进程，也不向它们发送任何信号**；一次确认最多执行一次，退出码非零、超时、启动失败、用户放弃等待与“退出码 0 但版本没变化”都算失败，写一条持久告警（菜单里的“Pi 扩展包更新告警…”条目，可展开并清除；只存类别、包名、旧/新/目标版本、固定原因文案与时间戳），不重试、不声称回滚。执行器上还有一次命令没结束时本次记为「未执行」（不写告警）；若那一次已放弃等待而退出尚未确认，拒绝原因里会写明“重启应用即可恢复”。安装失败与验证失败走同一条降级路径（GitHub #107 / W2B B-13）：都产出降级结论并调用注入的 `applyDegradation`（扩展包没有可重新指向的可执行文件，所以只把结论写进日志与历史），成功路径只记「无需降级」、不调用。
- 忽略版本：`updateChecks.<组件>.ignoredVersion` + `.ignoredVersionAt`（版本字符串 + 时间戳）。忽略只抑制那一个具体版本，上游发布更高版本时会重新提示；忽略与安装来源无关，不实现任意版本锁定或降级。
- 更新事务与有限回滚（GitHub #23）：三条更新路径共用阶段化事务（准备 → 执行 → 验证 → 启用/提交 → 失败降级）与统一历史（`updateChecks.updateHistory`，单键 JSON，最多 20 条）。验证只覆盖能验证到的事实：可执行文件、真实路径可读、版本重检测达到目标、`package.json` 名称与期望包名一致、服务健康检查；没有探针或证据时记为“未验证”，不伪造“通过”。自动降级只在一种情况下发生：来源是已验证的 npm 全局安装，且应用自己保留的更新前可执行文件路径与版本证据在安装后仍然存在、可执行且指纹一致；否则一律写“无法自动回滚”，并展示静态清单里的手动命令或指引（只展示、不执行）。pnpm / Homebrew / nvm / mise / git checkout / 本地路径 / 未知来源从不回滚。历史与诊断只存时间、组件、来源、从/到版本、阶段结果与固定原因文案，不含路径、环境变量值、凭据或子进程输出。
- 兼容旧键：GitHub #17 的 `updateChecks.*.enabled` 仍会被读取（`true` → 该分类默认策略，`false` → 关闭）；保存新设置时删除旧键，不留下两套值。未知值、非法类型与非法分类组合回退默认，并写一条只含键名与结论的诊断日志（不回显原值）。
- 界面：菜单“服务 → 更新检查设置”里是状态行 + 四类快捷开关（打开 = 默认策略，关闭 = 关闭）+ “立即更新 Pi Web…”与“立即更新 Pi CLI…” + 失败告警条目 + “已放弃的更新记录…” + “更新检查偏好设置…”；偏好设置窗口显示策略、每类最近检查时间、结果（最新 / 可更新 / 未知 / 失败）、被忽略版本与下次检查时间，并提供“忽略此版本”、两个启动前自动更新开关（标题写明生效范围）与一行 Pi CLI 进程保护/推迟原因状态（GitHub #21）；另有“查看 Pi 扩展包更新…”与一行 Pi 扩展包状态（策略、本次检测到的包数、可更新的包、需要先看「已放弃」记录再确认的包、拒绝原因与上次执行失败告警，GitHub #22 / #62）；设置窗口与诊断页还展示全部「已放弃」记录（GitHub #62）；菜单项本身在命令进行中或上一次更新退出未确认时置灰并加后缀说明（GitHub #107：“（正在更新）” / “（上一次更新未确认退出，重启应用可恢复）”）。诊断窗口显示同一份只读状态与手动更新入口。
- 提示方式：发现可用更新时使用应用内提示框（`NSAlert`），不使用 `UNUserNotificationCenter`、不申请通知权限；提示内容只含组件名与版本，不含路径或凭据。取舍说明见 [隐私说明](privacy.md)。
- 不写秘密：这一组键只有策略字符串、布尔与版本/时间戳；访问密码只在 Keychain，两者不交叉。

## 默认工作目录

- 默认值：`~/Library/Application Support/Pi Web Desktop/Workspace`，首次使用时由应用创建。
- 高级用法：偏好窗口“工作目录”可以选择其他目录（`NSOpenPanel`，只允许目录）；留空表示跟随默认目录。选择的目录必须已存在且可写，校验不通过时设置不会保存，界面给出可读错误。
- 生效路径由 `AppConfiguration.workspaceDirectory(for:)` 解析：`service.workspacePath` 非空时用它，否则用默认目录。该值进入 `ServiceConfiguration.runtimeSignature`，修改后保存设置会让托管服务用新目录重启。
- pi-web 会在工作目录写入运行文件，因此目录必须可写。

### 目录不存在或不可写

`WorkspaceDirectory.prepare(configuredPath:defaultPath:probe:)` 做一次探测：

- 默认目录缺失时应用尝试创建（首次使用，或用户删掉后重新检测）；自选目录不会被静默重建。
- 目录不存在、路径不是目录、目录不可写都会得到 `WorkspaceDirectoryProblem`，并生成可读修复提示（指出路径、原因，以及“在设置…里改选一个可写目录”）。

不可用时应用进入诊断状态而不是带着坏目录启动：

- 启动前会再校验一次：`ServiceManager.startManagedService()` 在真正启动前调用 `WorkspaceDirectory.prepare` 重新探测。健康监控运行期间用户删掉自选目录时，既不会静默重建目录，也不会启动进程，而是通过 `onWorkspaceProblem` 通知 `AppDelegate` 重新路由到诊断状态。
- 只有应用默认工作目录允许被自动创建（`WorkspaceDirectory.usesDefaultLocation(configured:)`）：默认目录缺失时补建，用户自选目录缺失时一律视为不可用。
- `ServiceManager.setWorkspaceAvailability(problem:path:)` 关闭启动门控。`startAtLaunch()`、`startService()`、`ensureServerIsRunning()`、`reloadAfterConfigurationChange()`、启动轮询、健康恢复和 `startManagedService()` 全部拒绝启动或加载页面，并给出可读失败提示。
- 启动/停止/重启菜单项由 `ServiceControlState(gate:workspaceIsReady:)` 统一置灰；`DiagnosticsRouting` 的报告里会出现 `.unusableWorkspace` 原因，WebView 显示诊断状态页（含依赖报告与工作目录修复提示），诊断窗口中也会显示同一提示。
- 已经运行的托管服务不会被这个门控停止：门控只阻止启动入口；停止与退出行为仍然只对通过所有权校验的进程组动作。
- 目录修好后点击“重新检测”即可重新校验并打开门控，无需重启应用。

## 退出行为

偏好窗口“行为 → 退出行为”提供三种取值（默认“每次退出时询问”）：

| 设置 | 退出时的行为 | 是否停止服务 |
| --- | --- | --- |
| 每次退出时询问（默认） | 弹出确认框（保持服务运行 / 退出并停止服务 / 取消） | 用户选择“退出并停止服务”时 |
| 退出但保持服务运行 | 直接退出 | 否 |
| 退出并停止服务 | 直接退出并停止托管服务 | 是（仅托管服务） |

决策逻辑是两层纯值类型（GitHub #72）：`QuitPlan`（`Sources/QuitPolicy.swift`）把配置取值映射成 `NextStep` + `ServiceDisposition`；`QuitCoordinator`（`Sources/QuitCoordinator.swift`）是退出状态机，把请求、用户选择、超时与服务状态变成需要执行的副作用（弹确认框 / 停止托管服务 / 退出应用）。`AppDelegate` 只负责执行副作用（`presentQuitDecisionAlert()` / `stopManagedServiceOnQuit(completion:)` / 异步重新发起 `NSApp.terminate(nil)`）。因此三种行为、三种确认选择、“取消不停止任何服务”、重复触发与超时兜底都可以在 unhosted 测试里直接断言。

- 退出决策在 AppKit 终止序列之外完成：菜单/⌘Q 先弹普通确认框，决策完成后才重新发起退出（`DispatchQueue.main.async` 里的 `NSApp.terminate(nil)`）。`applicationShouldTerminate` 只返回 `.terminateNow`（已决策）或 `.terminateCancel`（未决策/正在停止服务），**从不返回 `.terminateLater`**，因此不需要也不存在漏掉的 `reply(toApplicationShouldTerminate:)`（GitHub #72 / W4 G1），也不在 sheet 回调里重入退出序列（W4 M4）。
- 确认框的呈现方式与窗口可见性一致（W4 L5）：主窗口可见时挂 sheet；主窗口被 ⌘W（`windowShouldClose` → `orderOut`，应用继续运行）隐藏时改用应用级模态（`NSAlert.runModal`），窗口保持隐藏。`beginSheetModal` 挂在不可见窗口上会让 AppKit 把窗口重新显示出来，与“窗口已被隐藏”的用户状态不一致；主动恢复窗口则会打断用户刚做的隐藏动作，因此选择应用级模态（取舍：确认框不再锚定在主窗口上，但窗口可见性不受影响；两种模式下确认结果与超时行为完全相同）。
- 等待用户选择有上限：默认 5 分钟（`QuitCoordinator.defaultDecisionTimeout`，可注入）。超时后按最安全行为处理：保持服务运行并退出，并写入日志（不发信号、不删 `service-owner.json`），避免注销/关机被无限挂起。
- 取消后应用继续正常运行，下一次 ⌘Q/菜单退出重新走完整决策；等待期间的重复触发不叠加确认框、不重复停服务，迟到的回调被忽略。
- ⌘Q 与菜单“退出 Pi Web Desktop”走配置的退出行为（默认询问）；菜单里另有“退出 Pi Web Desktop（保持服务运行）”和“退出 Pi Web Desktop（停止服务）”两个显式入口，不受配置影响。
- “保持服务运行”不调用 `stopService()`，不删除 `service-owner.json`，只关闭日志句柄并停止健康轮询；应用关闭后不再有任何后台轮询。子进程的 stdout/stderr 是应用持有的管道（GitHub #73），退出时会把读端交给一个只做排空的 `/bin/cat`（输出丢弃，服务退出时它随之退出）：否则读端随应用退出消失，服务的下一次 stdout 写入会收到 `EPIPE` 并可能让服务退出。服务在应用退出后写出的内容不会进入日志文件；重新启动应用并重启该服务后恢复正常记录（见 [日志与诊断导出](logging-and-diagnostics.md)）。
- 外部服务（用户手动启动的 pi-web、上一次运行留下的服务、任何所有权校验失败的进程）在任何退出行为下都不会收到 `TERM`/`KILL`，也不会被改写成“已停止”。
- 应用不安装 LaunchAgent/daemon，不注册登录项，不在关闭期间执行定期更新或版本轮询。“保持服务运行”只是让 pi-web 作为独立进程继续运行，下一次启动应用时它会因为没有有效所有权记录而显示为外部服务。

## 应用重启后的认领

重启后磁盘上可能留有上一次运行写的 `service-owner.json`。`ServiceOwnershipVerifier` 逐项校验（记录字段完整、instanceID 属于当前运行实例、端口一致、进程存活、`ps` 事实可读、进程组、启动时间、实时命令文本摘要、可执行标识），再由 `ServiceOwnershipVerifier.adoption(record:verdict:)` 决定：

- `.adopt(record)`：只有全部校验通过的记录才能被重新认领，应用继续把它当作托管服务。
- `.external(mismatch)`：任何失败（包括 `instanceID` 不同，即上一次运行留下的记录）都只当作外部服务：不发信号、不改状态。可判定的不匹配记录会被删除；`ps` 事实暂时不可读时保留记录、留待下次再验证。

## 测试覆盖

unhosted 测试（注入临时目录、假探针与假 Keychain，不触碰真实用户目录、进程或网络）：

- `PiWebDesktopTests/DiagnosticsCollectorTests.swift`（含 W4 M2/M3）：导出布局、脱敏上下文保留、可信度映射与组件安装区块之外，新增设置窗口控制器单例存储的复用与显式释放、探测收集器不阻塞调用方（阻塞替身 + 主线程计时）、超时终止子进程并降级、“没有监听者 ≠ 探测失败”、导出文本对外部 argv 复用更新路径遮罩（注入凭据不得出现）、失败项标注，以及 M2/M3/L5 的源码级接线断言。
- `PiWebDesktopTests/AppConfigurationTests.swift`：三处存储位置、默认设置序列化后不含个人代理与远程 hostname、设置在重新读取后保留、smoke 使用临时目录、日志目录不存在时打开日志会先创建目录与文件（幂等、失败返回可读错误）。
- `PiWebDesktopTests/ServiceConfigurationTests.swift`：默认退出行为与默认工作目录、既有键名、无法识别的退出行为回落为“询问”、工作目录进入运行时签名；直接写入 UserDefaults 的通配地址、空值、带空白/非法字符的值加载后被标记为不可用且不被静默替换，合法地址与 `[::1]` 规范化后仍可用。
- `PiWebDesktopTests/KeychainStoreTests.swift`：地址判定与保存流程共用同一规则（通配地址即使有密码也被拒绝，且先于密码写入），加载与启动诊断包含非法值与允许范围，非 loopback 缺密码仍走 #8 的缺密码提示。
- `PiWebDesktopTests/WorkspaceDirectoryTests.swift`：默认目录首次使用时创建、自选目录不被静默重建、不存在/不是目录/不可写三种原因的校验与可读修复提示、状态页文本、设置窗口选择（相对路径、缺失、不可写被拒绝且配置不变，留空回到默认目录）。
- `PiWebDesktopTests/QuitPolicyTests.swift`：三种退出行为与三种确认选择的决策表、取消不停止服务、只有显式“退出并停止服务”才请求停止托管服务、任何行为都不停止外部服务。
- `PiWebDesktopTests/QuitCoordinatorTests.swift`（GitHub #72）：三条退出路径（询问后保持运行 / 询问后停服务 / 设置直接退出）、显式菜单项不受设置影响、取消后回到 idle 且可再次正常退出、等待与停止期间的重复触发不叠加、迟到的按钮/停止回调被忽略、超时前继续等待与超时后保持服务并退出（超时可注入，默认 5 分钟）、服务未运行与外部服务不产生停止副作用、AppKit 终止请求只得到 `terminateNow` / `cancelPendingDecision` 且 `terminateNow` 不带退出副作用。
- `PiWebDesktopTests/ServiceManagerTests.swift`：工作目录不可用时所有启动入口零启动零加载并给出可读提示、恢复后门控重新打开、启动前重新校验（自选目录被删后不重建且阻止启动；存在且可写的自选目录不被创建；默认目录缺失时仍创建；健康监控期间自选目录消失时受托管重启被拒绝）、三种退出行为（保持运行零信号、停止只对已验证进程组、外部服务零信号且状态不变）、关闭期间无后台轮询、校验失败的记录不被认领也不被发信号；非法监听地址（通配、空值、空白、非法字符）在所有启动入口零进程零探测并给出可读诊断，loopback 与“具体地址 + 密码”仍可启动，`0.0.0.0` 写入 UserDefaults 后无法进入启动流程。
- `PiWebDesktopTests/UpdateSettingsTests.swift`（GitHub #18）：四类策略的允许集合与默认值、菜单快捷开关映射、迁移（缺键 / 旧布尔键 / 未知与非法值 / 开关非布尔）、UserDefaults 往返只写策略、开关、警告与忽略版本且值里无路径或凭据、忽略版本只存版本与时间戳（非法版本丢弃、非法时间戳保留版本）、策略 → 间隔映射（`off` → nil）、每类状态快照与文案、通知判定（忽略 / 去重 / 关闭分类 / 非可更新状态）、提示文案与说明文本不含路径或凭据；以及 `AppConfiguration` 用注入 defaults 的设置往返。
- `PiWebDesktopTests/UpdateCheckerTests.swift`（GitHub #17 / #18）：在上面列出的注入式检查器测试之外，新增逐类关闭后请求数为 0 且无该类计时器、每日 / 每周 / 扩展包 7 天用假时钟推进后的请求次数、迁移后的旧布尔键直接决定调度、`stop()` 后假时钟推进 30 天零请求、忽略当前版本后不再提示且上游更高版本重新提示、每类状态快照带下次检查时间、启动前自动更新开关打开与关闭时请求 / 结果 / 调度完全一致。
- `PiWebDesktopTests/PiWebUpdateAdapterTests.swift`（GitHub #20）：插件式替身 + `$TMPDIR` 假安装器脚本覆盖设置关闭、来源/可信度不符、参数数组与命令策略、成功组合、安装器失败四态、版本未变、健康检查失败、服务运行中与脱敏断言；不联网、不执行真实 npm/pi-web、不写真实 Home 或 UserDefaults。
- `PiWebDesktopTests/PiProcessInspectorTests.swift`（GitHub #21）：假进程表（`PiProcessProbing.fixture`）+ 内存磁盘探针覆盖三态判定（无进程 / 运行中 / 不确定）、精确名称比较（`pi-web`/`pip`/`pi-helper`/大小写不同的 Pi 都不命中）、数据参数与编辑器参数不误报、进程标题与可执行/符号链接脚本路径命中、不可执行同名脚本与不可读 argv/身份归入 `unknown`、枚举失败与 PID 竞态、重复 PID、脱敏（Home → `~`、`token=`/`password=`/粘连形态/URL 查询串 → 占位符、环境片段丢弃、摘要上限）、状态文案，以及源码负向断言（两个新文件里没有 kill/killpg/signal/SIGTERM/SIGKILL/terminate/interrupt、没有 shell 路径与 sudo 调用，命令只用参数数组）；不枚举真实进程、不发送任何信号。
- `PiWebDesktopTests/PiCLIUpdateAdapterTests.swift`（GitHub #21）：设置默认值与键名、设置关闭零执行、前置条件（缺失/未解析/非包管理器来源/目标版本缺失或未验证或不可比较或不更高）、`noProcesses` 才自动、运行中进程与四种 `unknown` 一律推迟且不执行命令、执行前复查（新进程出现/状态变成 unknown）、一次运行只执行一次、参数数组固定为 `update --self`、环境白名单与 PATH 前置、四种失败（非零退出/超时/放弃/启动失败）与版本未变/不可解析的失败记录、成功与超过目标版本、警告持久化往返（含非法版本丢弃）与清除、手动路径（无进程门控、只要求可执行文件与版本）、不安全路径与非法版本拒绝、状态与确认文案，以及真执行器用例（`$TMPDIR` 假 `pi` 脚本：退出码与输出尾部记录、超时与 `abandon()` 后子进程仍继续运行 → 没有发送信号）；不联网、不执行真实 `pi`。
- `PiWebDesktopTests/PiPackageUpdateAdapterTests.swift`（GitHub #22）：三种策略（`off` 连检查都不做、`checkAndNotify` 只通知且零执行、`askBeforeUpdate` 在确认前零执行且确认一次只执行一次）、来源约束（pnpm/Homebrew/nvm/mise/git/本地路径/未知来源只给命令文本，且文本就是官方 `pi update --extensions`）、进程保护（规划时有进程或状态不确定一律没有执行入口，执行前复查发现进程或状态变化则拒绝且不调用执行器、整批立即停止）、失败四态（非零退出 / 超时 / 放弃等待 / 启动失败）与“退出码 0 但版本未变”都记为失败且不重试、成功与超过目标版本、参数数组固定为 `["update", "npm:<包名>"]`（无 shell 元字符、无 `sudo`、可执行文件名必须是 `pi`）、日志与确认文案脱敏、持久告警往返与清除、输入映射，以及真执行器用例（`$TMPDIR` 假 `pi` 脚本：退出码与输出尾部、超时、`abandon()` 后子进程继续运行并用标记文件证明没有收到信号）与源码负向断言（没有 kill/signal/SIGTERM/sudo/shell 调用）；不联网、不执行真实 `pi`/npm、不写真实 Home 或 UserDefaults。
- `PiWebDesktopTests/UpdateAbandonedAttemptTests.swift`（GitHub #62）：记录字段与持久化（`finishedAt` 恒为空、展示文本含“结束时间未知”、跨“重新启动”读同一份存储仍在）、三个组件互相独立与逐个/全部清除、不可信记录一律丢弃（有结束时间、超时值越界、桌面应用、非法包名、Pi CLI/扩展包声称发过信号、空摘要）与摘要脱敏（Home → `~`、凭据 → 占位符，落盘 JSON 里也找不到）、规划与编排的硬前置（有记录时自动判定被挡住、安装/命令调用 0 次、设置位不绕过、其它组件不受影响、无记录时恢复正常）、手动入口（仍然可用、确认框先展示记录、确认后才执行一次、成功后清除该组件记录、失败不清除）、进程组启动属性（`POSIX_SPAWN_SETPGROUP` + `pgroup = 0`，降级属性不含该标志）与替身启动器的“超时/取消只终止一次自己的子进程组、降级句柄一次信号都不发”断言，以及源码负向断言（Pi CLI / 扩展包 / 记录文件里没有 kill/signal/SIGTERM/posix_spawn，Pi Web 适配器里恰好一处 `killpg` 且没有按 pid 的 `kill(`）；不执行真实 npm/pi、不联网、不向任何 Pi 进程发信号。
- `PiWebDesktopTests/ServiceOwnershipTests.swift`：重启认领判定表（只有 `.managed` 可认领，`instanceID` 不同、PID 复用、端口变化、`ps` 不可读等都停留在外部服务）。
