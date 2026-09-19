# 架构说明

## 产品边界

Pi Web Desktop 是独立的 macOS AppKit/WebKit companion app。它启动、管理并显示用户已经安装的 Pi Web 服务；它不 fork、不打包、不维护上游 `agegr/pi-web` 的 Web 服务代码。

本仓库是社区维护的**非官方**项目，与上游 Pi Web 维护者没有隶属关系。支持平台、签名与公证限制、无 SLA 等边界见 [README 支持矩阵](../README.md#支持矩阵)；身份与版本的单一来源、构建与验证入口见 [开发说明](development.md)。

本文只描述已实现的组件边界与行为。尚未实现的组件在文末列出，不会被当作已完成能力描述。

## 组件边界

配置、进程检查和诊断文本（Issue #4 第一段）以及服务生命周期和 WebKit 交互（Issue #4 第二段）都已经从 `Sources/PiWebApp.swift` 移出；默认值、用户可见行为、菜单和窗口布局不变。

已实现：

- `AppDelegate`（`Sources/PiWebApp.swift`）：应用生命周期、菜单、窗口布局、状态栏菜单项、屏幕变化、退出确认、设置窗口协调和 smoke 启动分支。服务动作转发给 `ServiceManager`，WebKit 动作转发给 `WebViewController`；`AppDelegate` 里不再有 `Process()` 启动点，也不再有 WebKit 代理方法实现。
- `ServiceManager`（`Sources/ServiceManager.swift`）：服务生命周期状态机——启动、停止、重启、启动轮询与重试、4 秒健康检查、日志文件句柄与轮转、可验证的服务所有权记录写入与校验、退出行为（保持运行 / 退出并停止）。对外只暴露 `onStateChange`、`onLoadPage`、`onPageMessage`、`onStartupFailure` 回调和动作方法，不接触 AppKit。停止只对已验证的托管进程组发送信号；外部服务只读。
- `ServiceOwnership`（`Sources/ServiceOwnership.swift`）：所有权记录（JSON 字段、规范化命令文本的 SHA-256 摘要、可执行标识来源）、记录文件存取（`ServiceOwnershipStoring`）、逐项校验的纯逻辑（`ServiceOwnershipVerifier`）和只按进程组发送信号的接口（`ServiceSignaling` / `POSIXServiceSignaler`）。
- `WebViewController`（`Sources/WebViewController.swift`）：`WKWebView` 创建与配置、导航策略、下载、外部链接、查找栏、缩放和加载/错误状态页；加载状态页、错误页和带标题的诊断状态页（`showDependencyPage(title:message:)`）都由它拥有；通过 `onNavigationFailure`（以及 `onDownloadStarted`）回调把结果交给 `AppDelegate`，窗口由 `windowProvider` 闭包注入。
- `WebViewNavigationPolicy`（`Sources/WebViewNavigationPolicy.swift`）：本地/外链 URL 判定（`127.0.0.1`/`localhost`/`::1` 加配置端口；`about`/`blob`/`data` 视为内联），不依赖 Cocoa/WebKit，可在 unhosted 测试目标里直接测试。
- `AppConfiguration`（`Sources/AppConfiguration.swift`）与 `AppPaths`（`Sources/AppPaths.swift`）：设置分层与路径的唯一提供者——普通设置经 UserDefaults 读写，运行状态（`service-owner.json`、旧 `service.pid`、app PID、实例锁）在 `~/Library/Application Support/Pi Web Desktop/`，日志在 `~/Library/Logs/Pi Web Desktop/`，默认工作目录为其中的 `Workspace/`。两个根目录都可注入（support/log），因此测试与 smoke 运行不会写入真实目录。
- `WorkspaceDirectory`（`Sources/WorkspaceDirectory.swift`）：工作目录的解析与校验（存在、是目录、可写）与可读修复提示；默认目录首次使用时创建，自选目录必须已存在且可写，不可用时阻止启动（见 [docs/settings-and-workspace.md](settings-and-workspace.md)）。
- `QuitPlan`（`Sources/QuitPolicy.swift`）：退出行为的纯决策（询问 / 保持运行 / 停止服务），可 unhosted 测试；外部服务在任何退出行为下都不会被停止。
- `ProcessInspector`：`ps`/`lsof` 命令、监听端口 PID、进程存活判断、`pgid`/`lstart`/`comm`/`args` 事实读取和进程描述；命令执行通过 `CommandRunning` 注入，可执行标识读取（`proc_pidpath`）也可注入，解析规则是不访问进程的纯函数。它只报告事实，不做所有权判定。
- `DiagnosticsCollector`：把调用方已收集的版本、地址、状态、PID、进程描述和路径组装为诊断文本，自身不执行命令、不读磁盘。
- `DependencyChecker`（`Sources/DependencyChecker.swift`）：启动前的只读依赖诊断。检查系统（`uname` 架构与 macOS 版本）、Node.js（必须 `>= 22.19.0`，自实现语义化版本比较）、Pi CLI、Pi Web（可执行文件、版本、真实路径、符号链接目标，以及 pi-web 的 package.json `name`/`version`）、默认服务端口（本机 `bind(2)` 判定可用/被占用）和 Pi 配置目录（`~/.pi/agent`，只问“存在吗/可读吗”）。命令经 `CommandRunning` 注入，磁盘经 `DependencyFileSystemProbing` 注入，架构与系统版本经 `DependencySystemProbe` 注入，端口经 `DependencyPortProbing` 注入。它不安装、不升级、不联网、不调用 `sudo`，也不读取认证内容；路径在离开 checker 前已经完成 Home 脱敏（`~`）。
- `InstallCommandManifest`（`Sources/InstallCommandManifest.swift`）：修复建议的静态清单（Node.js 最低版本、Pi CLI 与 Pi Web 的 npm 安装命令、官方文档 URL）。纯编译期常量，不联网、不动态生成；应用只展示和复制，绝不执行。
- `FirstLaunchDiagnostics`（`Sources/FirstLaunchDiagnostics.swift`）：首次启动路由、门控控件映射、pi-web 路径选择和诊断 smoke 夹具的纯逻辑——`DiagnosticsGate`（`checking`/`ready`/`blocked`）、`ServiceControlState`（门控 → start/stop/restart 可用性）、`DiagnosticsRouting`（报告 + 首次设置状态 → `mainWindow`/`diagnostics(reasons)`）、`ServiceLaunchIntent`（首次设置刚完成 → 显式启动，否则尊重 `autoStart`）、`PiWebPathSelection` 与 `PiWebIdentityEvidence`（选中的路径 + 只读身份证据 → 新配置或可读错误）和 `DiagnosticsSmokeFixture`。不依赖 AppKit，可在 unhosted 测试目标里直接断言。
- `DiagnosticsWindowController`（`Sources/DiagnosticsWindowController.swift`）：首次启动诊断状态页（诊断项表格 + 可复制的安装命令 + “选择 pi-web 路径…”“重新检测”“开始使用 Pi Web”）。它只渲染 `DependencyReport` 和收集用户选择：选择结果经 `onSelectPiWebPath` 交给 `AppDelegate` 校验并写入配置，重新检测经 `onRecheck` 回调；窗口不执行安装命令、不写配置。
- `PreferencesWindowController`：用户设置界面；保存后由 `AppDelegate` 经 `AppConfiguration` 写回 UserDefaults。“远程访问”分区显示密码已设置/未设置，提供设置/生成/删除密码按钮，并说明密码认证不等于传输加密；删除密码会关闭远程模式并恢复默认 loopback。
- `KeychainStore`（`Sources/KeychainStore.swift`）：远程访问密码的存储与门控纯逻辑。`KeychainStoring` 协议只提供 save/load/delete/exists，生产实现是 macOS Security 的 `kSecClassGenericPassword`（service = bundle identifier，account = `remote-access-password`，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）；`RemoteAccessPassword` 给出读取与“已设置/未设置”状态文本，`RemoteAccessPolicy` 判定 loopback、hostname 校验、远程监听前置条件与“删除密码后回到 loopback”，`RemoteAccessSetup` 是设置界面的保存流程（密码只进 Keychain，配置只进 UserDefaults），`PasswordGenerator` 用 `SecRandomCopyBytes` 在本地生成不低于 24 位、含大小写字母数字符号的密码，`SecretScrubbing` 在展示前移除已知秘密。

### 注入点

`ServiceManager` 的每个副作用都经过注入的依赖，测试因此不接触真实进程、定时器或网络：

- `CommandRunning`：`ps`/`lsof`/`zsh` 等命令；`SystemCommandRunner` 是唯一真实实现。
- `ProcessInspector`：监听 PID、进程存活判断、`pgid`/`lstart`/`comm` 事实读取；其中 `processIsAlive` 闭包可注入，测试里完全不看真实进程。
- `ServiceLaunching`：全项目唯一启动服务进程的地方（`SystemServiceLauncher`）。生产实现用 `posix_spawn` + `POSIX_SPAWN_SETPGROUP` 让子进程成为独立进程组的组长，并保留日志重定向、环境变量、工作目录和 stdin 为 `/dev/null`；测试用假实现断言完整命令行与环境变量。远程模式下 `PI_WEB_PASSWORD` 只出现在这个环境字典里（见下节）。
- `ServiceOwnershipStoring`：`service-owner.json` 的读写（`FileServiceOwnershipStore`）；测试可以注入写入失败的实现来验证“启动后写不进记录就终止刚启动的进程组”。
- `ServiceSignaling`：只提供“向进程组发送信号”和“进程组是否存活”两个方法（`POSIXServiceSignaler` 用 `kill(-pgid, ...)`）；接口里没有单 PID 发送方法，测试用假实现记录收到的组信号。
- `ServiceProbing`：启动轮询与健康检查用的 HTTP 探测（`URLSessionServiceProbe`，超时经参数注入）。
- `ServiceScheduling`：主队列/后台队列、延时、重复定时器和 `sleep` 的调度；测试里即时执行，不等待真实时间。
- `AppConfiguration`、`environment` 闭包与 `FileManager`：路径、子进程环境变量和文件操作；`ServiceManager` 另外注入 `remoteAccessPassword` 闭包（默认返回 nil，即“无密码”），因此测试永远不会读到真实 Keychain。
- `DependencyFileSystemProbing` / `DependencySystemProbe` / `DependencyPortProbing`：依赖诊断的文件系统探针（可执行文件、符号链接、真实路径、文本读取、Home 目录、目录存在与可读性）、系统探针（`uname` 架构、macOS 版本）和端口探针（本机 `bind(2)`，只回“可用/占用/无法判定”）；测试注入假实现，因此不触碰真实 Home、npm 前缀、`~/.pi`、真实端口或网络。

`WebViewController` 通过构造参数接收 service URL、端口和 `windowProvider` 闭包（保存面板、打开面板和查找栏需要窗口），所以 `AppDelegate` 不持有 WebKit 状态。

尚未实现（后续 issue 范围）：

- `UpdateCoordinator`：版本检查、更新计划、用户确认和受限安装。

`DiagnosticsCollector` 只负责文本组装；脱敏由调用方保证——只传入上面列出的字段，不传入密码等秘密。

## 依赖诊断与启动门控

`AppDelegate` 在启动时（smoke 启动除外）异步运行 `DependencyChecker`：命令执行会阻塞，检查在后台队列完成，结果回到主线程后决定路由与门控；检查期间启动/停止/重启菜单项全部保持禁用。

`DependencyReport` 有两条派生规则：

- `canStartService`：Node.js、Pi CLI、Pi Web 三条硬性前置都存在，且状态均为 `ok` 时才为 true。缺少任一条目（例如空报告）或状态为 `unknown`（版本无法解析、无法核对身份）都不放行，门控默认关闭。
- `blockingFindings`：报告里存在的必需项中状态非 `ok` 的项（Node.js 缺失/过旧/无法确定，Pi CLI / Pi Web 缺失或版本无法解析）。系统项、默认端口（`被占用`/`无法确定`）和 Pi 配置目录（`缺失`/`不可读`/`无法确定`）只提示，不阻塞。报告缺项时 `blockingFindings` 里不会出现对应条目，所以门控还看 `unsatisfiedPrerequisiteKinds`，不能只用它判定。

首次启动路由（`DiagnosticsRouting`，纯函数）：输入是诊断报告和 `AppConfiguration.hasCompletedFirstLaunchSetup`，输出只有 `mainWindow` 与 `diagnostics(reasons)` 两种取值，不存在“退出应用”的分支。判定条件是 `canStartService`（必需项齐备且状态均为 `ok`），不是 `blockingFindings` 是否为空：`DependencyReport(findings: [])` 这类缺少必需条目的报告必须停留在诊断页。

- 硬性前置未通过时报告 `.unmetPrerequisites([...])`（缺项与状态非 `ok` 的必需项，顺序固定为 Node.js、Pi CLI、Pi Web），应用保留窗口、停掉健康轮询、不加载服务地址，WebView 显示诊断状态页而不是服务页。
- 硬性前置已满足但首次设置未完成时报告 `.firstLaunchSetupIncomplete`，同样先显示诊断状态页（所有行已是绿色），由“开始使用 Pi Web”或“重新检测”完成设置后进入主窗口。
- 两者都成立时进入正常主窗口：加载服务页并启动服务。普通启动尊重 `service.autoStart`（调用 `startAtLaunch()`）；如果用户刚刚完成首次设置（本次路由就是“完成设置”触发的，例如点击“开始使用 Pi Web”或在就绪后重新检测），则用 `ServiceLaunchIntent.startExplicitly` 走 `startAtLaunch(forceStart: true)` 显式启动，忽略 `autoStart`——否则用户刚修好前置却只会看到“Pi Web 服务未运行。”。

首次设置完成的唯一条件是硬性前置就绪（`DiagnosticsRouting.completesFirstLaunchSetup` = `canStartService`）。状态存在 UserDefaults（经 `AppConfiguration`），只有用户主动重新检测得到就绪报告、或在诊断页选择 pi-web 路径后重新检测、或点击“开始使用 Pi Web”时才写入；缺少前置时永远不会标记完成。端口占用与 Pi 配置目录缺失只做提示，不产生修复命令（`remediationID == nil`），TUI/WebView 文本里只给出可读说明。

服务控件可用性只有一个映射（`ServiceControlState`）：门控 `.ready` 时 start/stop/restart 全部可用；`.checking` 和 `.blocked` 时三者全部禁用。`AppDelegate` 的显式 `isEnabled` 更新与 `validateMenuItem` 都读同一个映射，所以菜单打开时和异步回调后不会出现两套规则。

`DependencyFinding.status` 取值：`ok`、`missing`、`outdated`（Node.js 低于最低版本，或 macOS 低于 14）、`unknown`（版本无法解析）。`confidence` 取整条结论各项证据里最弱的一项：探针直接确认是 `verified`，只能由候选路径或路径前缀推断是 `inferred`（pi-web 的 package.json `name` 与预期不符也计为 `inferred`），没有可用证据是 `unknown`。安装来源按固定优先级推断：Homebrew Cellar（verified）→ npm 前缀 `lib/node_modules`（verified）→ npm 前缀 `bin`（inferred）→ `~/.npm-global`（inferred）→ Homebrew 前缀（inferred）→ 用户目录（inferred）→ unknown。`remediationID` 只指向 `InstallCommandManifest` 的静态条目。

版本证据必须与报告的路径同源：Node.js 候选路径（含登录 shell 的 `command -v`）存在时只采信它自己的 `--version`，即使它不可运行也不会用 PATH 上另一个 node 的版本来放行；只有候选路径完全不存在时才按进程 PATH 重新解析（`/usr/bin/env node -p process.execPath`），并把真正产出该版本的可执行路径记入报告，解析不出可执行路径就只报 `unknown`。系统项在 `uname` 失败（`machineArchitecture()` 为 `"unknown"`）时 `confidence` 降为 `unknown`，不再声称已验证；系统项本就不阻塞启动。

门控与路由结果：

- 路由 `mainWindow`：与拆分前一致——显示“正在检查 Pi Web 服务…”，调用 `serviceManager.startAtLaunch()`；诊断窗口只在用户主动打开时显示。
- 路由 `diagnostics`：服务控件按 `ServiceControlState` 禁用（`.blocked` 时 start/stop/restart 全不可用），不调用 `startAtLaunch()`，WebView 显示诊断状态页（六个诊断项，每项都有状态、路径、版本、安装来源、可信度五个字段，缺失值用“未找到/未知”占位而不是省略整行）而不是服务地址，并打开/刷新诊断窗口。`.blocked` 时还会 `stopHealthMonitor()` 并把状态置为 stopped，避免健康检查把状态改回 running。
- “重新检测”只是重新运行一次 `DependencyChecker`（使用当前 `ServiceConfiguration.piWebPath`）；前置满足后立即打开门控、撤销控件禁用并进入主窗口，无需重启应用。“选择 pi-web 路径…”经 `NSOpenPanel` 选择文件，`PiWebPathSelection` 要求绝对路径、可执行，并且身份可核对（`--version` 能解析出版本，或沿真实路径向上找到的 package.json `name` 就是 `@agegr/pi-web`）：`/bin/echo` 这类可执行但不是 pi-web 的文件会被拒绝，失败时返回可读错误、配置不变；成功时经 `AppConfiguration` 写回 `ServiceConfiguration.piWebPath`，随后立即重新检测。身份证据由 `DependencyChecker.piWebIdentityEvidence(atPath:)` 收集，只执行 `--version` 并读 package.json 的 `name`，不安装、不联网。

`PI_WEB_DESKTOP_SMOKE=1` 在 `applicationDidFinishLaunching` 的第一个分支返回，因此启动 smoke 完全跳过依赖门控（不运行 checker、不等待后台结果），只验证窗口建立与退出路径。`PI_WEB_DESKTOP_SMOKE=diagnostics` 在另一个分支返回：它使用 `DiagnosticsSmokeFixture` 的确定性报告（固定探针，不执行命令、不读真实磁盘或 `~/.pi`、不绑定真实端口），跑真实的 `DiagnosticsRouting` 决策，渲染诊断状态页并建立诊断窗口，然后打印固定标记并以 0 退出；两者都不写真实 support 目录或 UserDefaults。

门控不只在菜单层生效：`ServiceManager.isDependencyGateOpen`（默认关闭，`AppDelegate` 在诊断期间保持关闭、结果通过后打开）是所有服务启动入口的硬前置。`startAtLaunch()`、`ensureServerIsRunning()`、`startService()`、`startManagedService()`、`reloadAfterConfigurationChange()`、启动轮询（`pollUntilReady()`）和健康检查在入口以及每个异步主队列回调执行前都重新确认门控，因此配置变更重载、启动失败重试、外部服务恢复和健康恢复都不能绕过诊断结果；门控关闭时既不启动子进程、不加载服务页，也不改变状态或报启动失败。诊断判定阻塞时 `AppDelegate` 还会调用 `stopHealthMonitor()`（健康轮询本身也在入口拒绝启动），避免健康检查把状态改回 `running`、把诊断页覆盖回服务页。

诊断文本只包含已脱敏的字段：Home 前缀替换为 `~`，URL 去掉 userinfo、query 和 fragment；不写入用户名、绝对 Home 路径、凭据、token 或查询参数。Pi 配置目录只报告路径（`~/.pi/agent`）与“存在/可读”状态：既不做目录列表，也不读取目录内任何文件，认证内容永远不会进入报告。

## 服务所有权

应用只对“由本应用实例启动、并且所有权记录仍能通过全部校验”的服务进程组发送信号。外部服务（用户手动启动的 pi-web、上一次运行留下的服务、任何无法验证的进程）对本应用只读：不发送任何 `TERM`/`KILL`，不把状态改成“已停止”，只保留原有的外部服务警告文案。完整威胁模型见 [docs/security-ownership.md](security-ownership.md)。

### 所有权记录

启动成功后，应用把以下字段写入 `~/Library/Application Support/Pi Web Desktop/service-owner.json`（`AppConfiguration.serviceOwnerURL`）：`pid`、`processGroupID`、`launchedAt`（`ps -o lstart=`）、`resolvedExecutable`（优先 libproc `proc_pidpath`，失败时回退 `ps -o comm=`）、`resolvedExecutableSource`（来源标记：`proc_pidpath` / `ps-comm`）、`argumentsDigest`（启动时观察到的规范化命令文本的 SHA-256）、`port`、`instanceID`（每次应用运行随机生成）、`recordedAt`。旧的 `service.pid` 不再作为所有权证据：应用启动时会删除它（`reconcileOwnershipRecord()`），只保留 `app.pid`（单实例锁）继续解析 PID 文本。

`argumentsDigest` 的输入文本是 `ps -o args=` 报告的实时命令行（空白折叠为单空格）。这样处理是必要的：npm 安装的 `pi-web` 是 `#!/usr/bin/env node` 脚本，内核会把 `argv[0]` 替换成解释器（`node /opt/homebrew/bin/pi-web …`），按“可执行路径 + 参数”拼接的文本永远无法与实时值匹配。只有在读不到实时命令文本时才回退到该拼接文本（`ServiceOwnershipRecord.commandText(executablePath:arguments:)`），而这样的记录在下次验证时必定因“实时命令行为空”被判为不匹配。

记录只在以下条件全部满足时才算“已托管”：`ps` 能读到子进程的 `pgid`/`lstart` 与可执行标识，且子进程的 `pgid` 等于自身 PID（`POSIX_SPAWN_SETPGROUP` 的组长不变量）。写入记录后立即重新验证一次；记录写不进去或立即校验不通过时，刚启动的进程组会被终止（组内 `SIGTERM` → 有界等待 → `SIGKILL`）并报告启动失败，不会留下无法管理的半托管子进程。在清理完成前 `startDecision()` 把仍在运行的子进程句柄视为已有实例，因此不会重复启动第二份服务。

### 启动

`SystemServiceLauncher` 用 `posix_spawn` + `POSIX_SPAWN_SETPGROUP`（`pgroup = 0`）启动 pi-web，使其成为独立进程组的组长；stdin 为 `/dev/null`，stdout/stderr 指向轮转后的日志文件，环境变量和工作目录与之前的 `Process` 实现一致。子进程由后台等待线程 `waitpid` 回收，并触发原有的终止回调。

### 验证项

`ServiceOwnershipVerifier` 逐项比对，任何一项不匹配或无法读取即判定为外部服务：记录字段自身有效（PID/PGID > 1、PGID == PID、端口范围、非空字段）→ `instanceID` 等于当前应用实例 → `port` 等于当前配置 → 记录的 PID 仍存活 → `ps` 事实可读 → 实时 `pgid`、`launchedAt` 与记录一致 → 实时 `ps -o args=` 文本的摘要等于 `argumentsDigest`（为空或不可解析即不匹配）→ 实时可执行标识等于记录值（`proc_pidpath` 优先，回退 `ps -o comm=`，回退来源在记录中标记为弱证据，仍需命令摘要同时匹配）。

### 停止与重启

只有验证通过的记录才会收到信号：先向记录的进程组发送 `SIGTERM`，在 `stopPollAttempts`（40 × 0.1 秒）内等待进程组消失，仍存活才对同一进程组发送 `SIGKILL`。`ServiceSignaling` 接口只暴露进程组形式（`kill(-pgid, ...)`），因此不存在向单个 PID 发送信号的路径。外部服务或验证失败时不发送任何信号：`stopService()` 只在验证通过后才会把状态更新为已停止，找不到可验证记录时直接完成回调、保持当前状态（例如仍显示“正在运行（外部服务）”）并删除不匹配的记录；菜单的停止/重启动作仍然先显示原有的“这是外部启动的 Pi Web 服务”警告。`stopManagedServiceOnQuit`（“退出并停止服务”，由 `QuitPlan` 决定是否调用）也只停止已验证的托管子进程，不再清理端口上的其他监听进程；外部服务在任何退出行为下都不发信号。

### 过期记录与应用重启

启动时（`startAtLaunch()` → `reconcileOwnershipRecord()`）会重新验证磁盘上的记录：进程已不存在、或记录来自上一次应用运行（`instanceID` 不同）时，只删除记录文件，绝不向对应 PID 发送信号；“退出但保持服务运行”留下的服务在下次启动时因此按外部服务处理。删除规则由 `ServiceOwnershipVerdict.shouldRemoveRecord` 决定：唯一保留记录的情况是 `ps` 事实暂时不可读，此时仍然不会发送信号，留待下次再验证。

## 远程访问与密码

远程访问的唯一前置条件是 Keychain 中存在非空密码。密码的存储、读取和状态都在 `KeychainStore`（`Sources/KeychainStore.swift`）中：

- 存储：`kSecClassGenericPassword`，`kSecAttrService` 是应用的 bundle identifier，`kSecAttrAccount` 是 `remote-access-password`，可访问性固定为 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。密码只存在于这一个条目里，不进入 UserDefaults、命令行参数、日志文件、诊断文本或错误消息；`KeychainStoreError` 只携带 notFound / OSStatus，不携带秘密。
- 读取：`RemoteAccessPassword.load(from:)` 在条目缺失、为空或读取失败时都返回 nil（fail closed：读取失败不会被当成“可以用无认证方式启动”）。
- 门控：`RemoteAccessPolicy.allowsRemoteListening(hostname:password:)`——loopback 恒允许；hostname 不是 loopback 时必须存在非空密码。`ServiceManager.isStartPermitted` 包含这个条件，所以启动、重启、配置变更重载、启动重试、启动轮询和健康检查都无法在缺密码时启动服务、探测外部服务或加载服务页；`ServiceStartDecision.missingRemotePassword` 给出可读的失败提示。
- 单次读取：`ServiceManager.startManagedService()` 在本次启动里只读一次凭证，并且把它同时传给门控和 `ServiceLaunchSpecification.make(..., remoteAccessPassword:)`（决策入口是 `startDecision(credentials:)`）。校验通过后不再读 Keychain，因此不存在“校验时有效、此后二次读取失效却仍然 `.launch`”的 fail-open 窗口（GitHub #8 复审）；读取失败或条目缺失一律按“无密码”拒绝启动。
- 保存：`RemoteAccessSetup.apply(requested:newPassword:keychain:)` 是设置界面的保存流程。`newPassword` 为 nil 表示沿用已有密码，非空则先写入 Keychain；远程 hostname 没有可用密码时返回可读错误且不返回配置，调用方因此不会写 UserDefaults。密码写入失败时错误文本会先经过 `SecretScrubbing`，即使底层错误描述意外带上密码也不会展示。
- 生成：界面上的“生成高强度密码”调用 `PasswordGenerator`（`SecRandomCopyBytes`，长度下限 24，保证大写字母/小写字母/数字/符号四类字符各至少一个，再用可注入随机源做 Fisher–Yates 洗牌），不联网、不引入依赖。
- 删除：删除 Keychain 条目后 `RemoteAccessPolicy.disablingRemoteAccess(in:)` 把 hostname 收回 `127.0.0.1`，其余字段保持不变；`AppDelegate` 经 `AppConfiguration` 保存新配置，并且当远程服务正在运行时重启它，使新的（或已删除的）`PI_WEB_PASSWORD` 生效。
- 运行中收敛：密码也可能在服务运行期间被外部删除或变成不可读，门控本身拦不住已经在跑的进程。`ServiceManager.closeRemoteAccessIfCredentialsAreUnavailable()` 是这类状态的收敛入口：配置是非 loopback 且取不到凭证时，若存在本应用启动、且仍能通过所有权验证的进程，则把 hostname 收回 `127.0.0.1`，走 `stopService()` 的既有验证路径停止该进程组（外部服务、无法验证的记录零信号），把状态改成带可读提示的 `.failed(RemoteAccessPolicy.revokedPasswordMessage)`，并通过 `onRemoteAccessClosed` 让 `AppDelegate` 持久化回落后的配置（不静默重启）。触发点是每 4 秒一次的健康轮询、所有启动入口的缺密码拒绝分支，以及依赖检查完成时（`AppDelegate.applyDependencyReport`）。没有可验证的托管进程时不改动用户配置，只给出“需要设置密码”的提示。

传输密码的路径只有一处：`ServiceLaunchSpecification.make(..., remoteAccessPassword:)`。只有当 hostname 不是 loopback 且密码非空时，子进程环境才包含 `PI_WEB_PASSWORD`；否则该变量会被从环境里删除（包括清除父进程继承来的同名变量）。命令行参数 `--hostname/--port/--no-open`、所有权记录（只有命令文本的 SHA-256 摘要）、日志文件（只有子进程的 stdout/stderr）和诊断文本（只有“已设置/未设置”）都不包含密码值或长度。

监听边界：默认值仍是 `127.0.0.1`；`0.0.0.0`、`::` 与 `[::]` 在界面保存时被拒绝，不会成为默认值也不会被一次误输入打开。保存时 `RemoteAccessPolicy.normalizedHostname(_:)` 把 IPv6 字面量统一成不带方括号的形式（`::1`，与 `--hostname` 参数和端口探测一致），拼 URL 时再由 `RemoteAccessPolicy.urlHost(for:)` 加方括号：`http://[::1]:端口/`（`URLComponents` 对未加方括号的 IPv6 host 会返回 nil，旧实现会静默回落到 `127.0.0.1`）。冒号只允许出现在合法的 IPv6 字面量里，`example.invalid:8443` 这类把端口写进地址的输入会在保存时被拒绝。密码认证只验证访问者，不是传输加密：设置界面和文档都明确要求远程访问自行配置受信任的加密隧道或 HTTPS 反向代理。

## 网络边界

默认监听 `127.0.0.1`，非 loopback 监听地址必须先在 Keychain 中设置非空密码（见上节）。远程访问还需要用户显式配置受信任的加密隧道或 HTTPS 反向代理：密码认证不等于传输加密。桌面应用不把密码写入 UserDefaults、命令行、日志或诊断信息。

## 数据位置

- 普通设置：UserDefaults（读写都经 `AppConfiguration`）。
- 远程访问密码：macOS Keychain（service = bundle identifier，account = `remote-access-password`，仅本文一处存储）。
- 运行状态和 PID：`~/Library/Application Support/Pi Web Desktop/`。
- 日志：`~/Library/Logs/Pi Web Desktop/`（`Pi Web Desktop.log`），应用执行轮转。

设置分层、默认工作目录、退出行为与不可写目录的处理见 [docs/settings-and-workspace.md](settings-and-workspace.md)。

应用不读取、复制或修改 Pi 的认证文件。
