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
- “询问后更新”与“检查并通知”的复查节奏相同（7 天），区别只在提示文案：“询问后更新”发现新版本时询问用户是否更新（GitHub #21 之前不自动执行），两种策略都不会下载或安装。
- 启动前自动更新 Pi CLI（GitHub #21，默认关闭）：`updateChecks.pi.autoUpdateBeforeLaunch`。打开后，应用在拿到当次版本检查结果后判定一次：只有本机 Pi CLI 是“已验证的 npm/pnpm 全局安装”、目标版本已验证且高于本机版本、命令通过参数安全校验，**并且当次进程检查确认没有运行中的 Pi CLI 进程**时才会执行一次 `pi update --self`。只要有运行中的 Pi 进程（或状态不确定），本次就推迟到下次启动或下一次判定，原因写入日志与状态页，不弹框；自动尝试每个运行期最多一次，不自动重试、不自动回滚，版本未变或无法解析也算失败（写持久警告）。手动入口“立即更新 Pi CLI…”不做进程门控，但必须在确认框里确认（显示可执行文件、参数数组、当前/目标版本、每个运行中 Pi 进程的 PID/父进程/启动时间/判定依据/脱敏后的命令摘要与风险说明）。
- 运行进程保护（GitHub #21）：进程检查是只读的 libproc 枚举（`proc_listpids` / `proc_pidinfo` / `proc_pidpath` / `sysctl`），只做精确的可执行名比较（`pi-web` / `pip` / `pi-helper` 不命中；Pi CLI 以 Node 脚本形式运行时靠进程标题或脚本路径判定），结果三态：`noProcesses` / `runningProcesses` / `unknown`，**只有 `noProcesses` 允许自动更新**。应用从不向 Pi 进程发送信号，也不结束或接管任何 Pi 会话；枚举失败、权限不足等任何不确定都按不安全处理。
- 启动前自动更新 Pi Web（GitHub #20，默认关闭）：`updateChecks.piWeb.autoUpdateBeforeLaunch`。打开后，只有本机 Pi Web 是“已验证的 npm 全局安装”时才会在应用启动时尝试自动更新：目标版本必须是已验证且高于本机版本，包名必须等于静态清单里的 `@agegr/pi-web`，npm 可执行文件必须解析到，且服务不能正在运行（运行中发现的更新只安排到下次启动）。执行时用参数数组直接调用 `npm install -g <包名>@<版本>`，不使用 shell、不调用 `sudo`，有超时，安装后重新检测版本并做健康检查。其它来源（pnpm、Homebrew、nvm/mise、git checkout、本地路径、未知）仍只显示更新命令。失败时只有一条持久警告（菜单“更新检查设置”里的“Pi Web 更新告警…”条目，可展开并清除）与诊断页提示，同一次运行内不会自动重试；应用照常启动、不阻止手动启动服务，也**不会自动回滚**。手动入口“立即更新 Pi Web…”只在设置打开且来源满足时可用，并且需要先在确认框里确认。
- 忽略版本：`updateChecks.<组件>.ignoredVersion` + `.ignoredVersionAt`（版本字符串 + 时间戳）。忽略只抑制那一个具体版本，上游发布更高版本时会重新提示；忽略与安装来源无关，不实现任意版本锁定或降级。
- 兼容旧键：GitHub #17 的 `updateChecks.*.enabled` 仍会被读取（`true` → 该分类默认策略，`false` → 关闭）；保存新设置时删除旧键，不留下两套值。未知值、非法类型与非法分类组合回退默认，并写一条只含键名与结论的诊断日志（不回显原值）。
- 界面：菜单“服务 → 更新检查设置”里是状态行 + 四类快捷开关（打开 = 默认策略，关闭 = 关闭）+ “立即更新 Pi Web…”与“立即更新 Pi CLI…” + 失败告警条目 + “更新检查偏好设置…”；偏好设置窗口显示策略、每类最近检查时间、结果（最新 / 可更新 / 未知 / 失败）、被忽略版本与下次检查时间，并提供“忽略此版本”、两个启动前自动更新开关（标题写明生效范围）与一行 Pi CLI 进程保护/推迟原因状态（GitHub #21）；诊断窗口显示同一份只读状态与同一个手动更新入口。
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

决策逻辑是纯值类型 `QuitPlan`（`Sources/QuitPolicy.swift`）：`QuitPlan.plan(for:)` 把配置取值映射成 `NextStep` + `ServiceDisposition`，`AppDelegate.applicationShouldTerminate` 只负责执行计划（弹框、退出、按处置调用 `keepRunningOnQuit()` 或 `stopManagedServiceOnQuit(completion:)`）。因此三种行为、三种确认选择，以及“取消不停止任何服务”都可以在 unhosted 测试里直接断言。

- ⌘Q 与菜单“退出 Pi Web Desktop”走配置的退出行为（默认询问）；菜单里另有“退出 Pi Web Desktop（保持服务运行）”和“退出 Pi Web Desktop（停止服务）”两个显式入口，不受配置影响。
- “保持服务运行”不调用 `stopService()`，不删除 `service-owner.json`，只关闭日志句柄并停止健康轮询；应用关闭后不再有任何后台轮询。
- 外部服务（用户手动启动的 pi-web、上一次运行留下的服务、任何所有权校验失败的进程）在任何退出行为下都不会收到 `TERM`/`KILL`，也不会被改写成“已停止”。
- 应用不安装 LaunchAgent/daemon，不注册登录项，不在关闭期间执行定期更新或版本轮询。“保持服务运行”只是让 pi-web 作为独立进程继续运行，下一次启动应用时它会因为没有有效所有权记录而显示为外部服务。

## 应用重启后的认领

重启后磁盘上可能留有上一次运行写的 `service-owner.json`。`ServiceOwnershipVerifier` 逐项校验（记录字段完整、instanceID 属于当前运行实例、端口一致、进程存活、`ps` 事实可读、进程组、启动时间、实时命令文本摘要、可执行标识），再由 `ServiceOwnershipVerifier.adoption(record:verdict:)` 决定：

- `.adopt(record)`：只有全部校验通过的记录才能被重新认领，应用继续把它当作托管服务。
- `.external(mismatch)`：任何失败（包括 `instanceID` 不同，即上一次运行留下的记录）都只当作外部服务：不发信号、不改状态。可判定的不匹配记录会被删除；`ps` 事实暂时不可读时保留记录、留待下次再验证。

## 测试覆盖

unhosted 测试（注入临时目录、假探针与假 Keychain，不触碰真实用户目录、进程或网络）：

- `PiWebDesktopTests/AppConfigurationTests.swift`：三处存储位置、默认设置序列化后不含个人代理与远程 hostname、设置在重新读取后保留、smoke 使用临时目录、日志目录不存在时打开日志会先创建目录与文件（幂等、失败返回可读错误）。
- `PiWebDesktopTests/ServiceConfigurationTests.swift`：默认退出行为与默认工作目录、既有键名、无法识别的退出行为回落为“询问”、工作目录进入运行时签名；直接写入 UserDefaults 的通配地址、空值、带空白/非法字符的值加载后被标记为不可用且不被静默替换，合法地址与 `[::1]` 规范化后仍可用。
- `PiWebDesktopTests/KeychainStoreTests.swift`：地址判定与保存流程共用同一规则（通配地址即使有密码也被拒绝，且先于密码写入），加载与启动诊断包含非法值与允许范围，非 loopback 缺密码仍走 #8 的缺密码提示。
- `PiWebDesktopTests/WorkspaceDirectoryTests.swift`：默认目录首次使用时创建、自选目录不被静默重建、不存在/不是目录/不可写三种原因的校验与可读修复提示、状态页文本、设置窗口选择（相对路径、缺失、不可写被拒绝且配置不变，留空回到默认目录）。
- `PiWebDesktopTests/QuitPolicyTests.swift`：三种退出行为与三种确认选择的决策表、取消不停止服务、只有显式“退出并停止服务”才请求停止托管服务、任何行为都不停止外部服务。
- `PiWebDesktopTests/ServiceManagerTests.swift`：工作目录不可用时所有启动入口零启动零加载并给出可读提示、恢复后门控重新打开、启动前重新校验（自选目录被删后不重建且阻止启动；存在且可写的自选目录不被创建；默认目录缺失时仍创建；健康监控期间自选目录消失时受托管重启被拒绝）、三种退出行为（保持运行零信号、停止只对已验证进程组、外部服务零信号且状态不变）、关闭期间无后台轮询、校验失败的记录不被认领也不被发信号；非法监听地址（通配、空值、空白、非法字符）在所有启动入口零进程零探测并给出可读诊断，loopback 与“具体地址 + 密码”仍可启动，`0.0.0.0` 写入 UserDefaults 后无法进入启动流程。
- `PiWebDesktopTests/UpdateSettingsTests.swift`（GitHub #18）：四类策略的允许集合与默认值、菜单快捷开关映射、迁移（缺键 / 旧布尔键 / 未知与非法值 / 开关非布尔）、UserDefaults 往返只写策略、开关、警告与忽略版本且值里无路径或凭据、忽略版本只存版本与时间戳（非法版本丢弃、非法时间戳保留版本）、策略 → 间隔映射（`off` → nil）、每类状态快照与文案、通知判定（忽略 / 去重 / 关闭分类 / 非可更新状态）、提示文案与说明文本不含路径或凭据；以及 `AppConfiguration` 用注入 defaults 的设置往返。
- `PiWebDesktopTests/UpdateCheckerTests.swift`（GitHub #17 / #18）：在上面列出的注入式检查器测试之外，新增逐类关闭后请求数为 0 且无该类计时器、每日 / 每周 / 扩展包 7 天用假时钟推进后的请求次数、迁移后的旧布尔键直接决定调度、`stop()` 后假时钟推进 30 天零请求、忽略当前版本后不再提示且上游更高版本重新提示、每类状态快照带下次检查时间、启动前自动更新开关打开与关闭时请求 / 结果 / 调度完全一致。
- `PiWebDesktopTests/PiWebUpdateAdapterTests.swift`（GitHub #20）：插件式替身 + `$TMPDIR` 假安装器脚本覆盖设置关闭、来源/可信度不符、参数数组与命令策略、成功组合、安装器失败四态、版本未变、健康检查失败、服务运行中与脱敏断言；不联网、不执行真实 npm/pi-web、不写真实 Home 或 UserDefaults。
- `PiWebDesktopTests/PiProcessInspectorTests.swift`（GitHub #21）：假进程表（`PiProcessProbing.fixture`）+ 内存磁盘探针覆盖三态判定（无进程 / 运行中 / 不确定）、精确名称比较（`pi-web`/`pip`/`pi-helper`/大小写不同的 Pi 都不命中）、数据参数与编辑器参数不误报、进程标题与可执行/符号链接脚本路径命中、不可执行同名脚本与不可读 argv/身份归入 `unknown`、枚举失败与 PID 竞态、重复 PID、脱敏（Home → `~`、`token=`/`password=`/粘连形态/URL 查询串 → 占位符、环境片段丢弃、摘要上限）、状态文案，以及源码负向断言（两个新文件里没有 kill/killpg/signal/SIGTERM/SIGKILL/terminate/interrupt、没有 shell 路径与 sudo 调用，命令只用参数数组）；不枚举真实进程、不发送任何信号。
- `PiWebDesktopTests/PiCLIUpdateAdapterTests.swift`（GitHub #21）：设置默认值与键名、设置关闭零执行、前置条件（缺失/未解析/非包管理器来源/目标版本缺失或未验证或不可比较或不更高）、`noProcesses` 才自动、运行中进程与四种 `unknown` 一律推迟且不执行命令、执行前复查（新进程出现/状态变成 unknown）、一次运行只执行一次、参数数组固定为 `update --self`、环境白名单与 PATH 前置、四种失败（非零退出/超时/放弃/启动失败）与版本未变/不可解析的失败记录、成功与超过目标版本、警告持久化往返（含非法版本丢弃）与清除、手动路径（无进程门控、只要求可执行文件与版本）、不安全路径与非法版本拒绝、状态与确认文案，以及真执行器用例（`$TMPDIR` 假 `pi` 脚本：退出码与输出尾部记录、超时与 `abandon()` 后子进程仍继续运行 → 没有发送信号）；不联网、不执行真实 `pi`。
- `PiWebDesktopTests/ServiceOwnershipTests.swift`：重启认领判定表（只有 `.managed` 可认领，`instanceID` 不同、PID 复用、端口变化、`ps` 不可读等都停留在外部服务）。
