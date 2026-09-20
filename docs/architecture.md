# 架构说明

## 产品边界

Pi Web Desktop 是独立的 macOS AppKit/WebKit companion app。它启动、管理并显示用户已经安装的 Pi Web 服务；它不 fork、不打包、不维护上游 `agegr/pi-web` 的 Web 服务代码。

本仓库是社区维护的**非官方**项目，与上游 Pi Web 维护者没有隶属关系。支持平台、签名与公证限制、无 SLA 等边界见[开发说明的支持矩阵](development.md#支持矩阵与非承诺)；身份与版本的单一来源、构建与验证入口见 [开发说明](development.md)。

本文只描述已实现的组件边界与行为。尚未实现的组件在文末列出，不会被当作已完成能力描述。

## 组件边界

配置、进程检查和诊断文本（Issue #4 第一段）以及服务生命周期和 WebKit 交互（Issue #4 第二段）都已经从 `Sources/PiWebApp.swift` 移出；默认值、用户可见行为、菜单和窗口布局不变。

已实现：

- `AppDelegate`（`Sources/PiWebApp.swift`）：应用生命周期、菜单、窗口布局、状态栏菜单项、屏幕变化、退出确认、设置窗口协调和 smoke 启动分支。服务动作转发给 `ServiceManager`，WebKit 动作转发给 `WebViewController`；`AppDelegate` 里不再有 `Process()` 启动点，也不再有 WebKit 代理方法实现。
- `ServiceManager`（`Sources/ServiceManager.swift`）：服务生命周期状态机——启动、停止、重启、启动轮询与重试、4 秒健康检查、可验证的服务所有权记录写入与校验、退出行为（保持运行 / 退出并停止）。日志句柄、目录创建、历史日志脱敏、按大小轮转与写入都委托给 `LogWriter`（GitHub #10，见 [日志与诊断导出](logging-and-diagnostics.md)）；错误消息在进入状态机与回调前先经 `LogWriter` 的同一个 `LogRedactor`。对外只暴露 `onStateChange`、`onLoadPage`、`onPageMessage`、`onStartupFailure` 回调和动作方法，不接触 AppKit。停止只对已验证的托管进程组发送信号；外部服务只读。
- `ServiceOwnership`（`Sources/ServiceOwnership.swift`）：所有权记录（JSON 字段、规范化命令文本的 SHA-256 摘要、可执行标识来源）、记录文件存取（`ServiceOwnershipStoring`）、逐项校验的纯逻辑（`ServiceOwnershipVerifier`）和只按进程组发送信号的接口（`ServiceSignaling` / `POSIXServiceSignaler`）。
- `WebViewController`（`Sources/WebViewController.swift`）：`WKWebView` 创建与配置、导航策略、下载、外部链接、查找栏、缩放和加载/错误状态页；加载状态页、错误页和带标题的诊断状态页（`showDependencyPage(title:message:)`）都由它拥有；通过 `onNavigationFailure`（以及 `onDownloadStarted`）回调把结果交给 `AppDelegate`，窗口由 `windowProvider` 闭包注入。
- `WebViewNavigationPolicy`（`Sources/WebViewNavigationPolicy.swift`）：本地/外链 URL 判定（`127.0.0.1`/`localhost`/`::1` 加配置端口；`about`/`blob`/`data` 视为内联），不依赖 Cocoa/WebKit，可在 unhosted 测试目标里直接测试。
- `AppConfiguration`（`Sources/AppConfiguration.swift`）与 `AppPaths`（`Sources/AppPaths.swift`）：设置分层与路径的唯一提供者——普通设置经 UserDefaults 读写，运行状态（`service-owner.json`、旧 `service.pid`、app PID、实例锁）在 `~/Library/Application Support/Pi Web Desktop/`，日志在 `~/Library/Logs/Pi Web Desktop/`，默认工作目录为其中的 `Workspace/`。两个根目录都可注入（support/log），因此测试与 smoke 运行不会写入真实目录。
- `WorkspaceDirectory`（`Sources/WorkspaceDirectory.swift`）：工作目录的解析与校验（存在、是目录、可写）与可读修复提示；默认目录首次使用时创建，自选目录必须已存在且可写，不可用时阻止启动（见 [docs/settings-and-workspace.md](settings-and-workspace.md)）。
- `QuitPlan`（`Sources/QuitPolicy.swift`）与 `QuitCoordinator`（`Sources/QuitCoordinator.swift`）：退出行为的纯决策（询问 / 保持运行 / 停止服务）与退出状态机（GitHub #72，见下文“退出状态机”），都可 unhosted 测试；外部服务在任何退出行为下都不会被停止。
- `ProcessInspector`：`ps`/`lsof` 命令、监听端口 PID、进程存活判断、`pgid`/`lstart`/`comm`/`args` 事实读取和进程描述；命令执行通过 `CommandRunning` 注入，可执行标识读取（`proc_pidpath`）也可注入，解析规则是不访问进程的纯函数。它只报告事实，不做所有权判定。
- `LogWriter`（`Sources/LogWriter.swift`）与 `LogRedactor`（`Sources/LogRedactor.swift`）：统一日志写入与统一脱敏（GitHub #10）。`LogWriter` 按大小轮转（`LogRotationPolicy`，默认 10 MB / 保留 5 份；阈值、份数、`FileManager`、时间源都可注入），打开子进程日志句柄前先就地脱敏历史日志，任何写入/轮转失败只记录在 `failureDescription`（诊断导出的“日志写入”一行）而不抛出也不崩溃。`LogRedactor` 的同一个实例用于日志行、诊断导出、错误消息、环境变量与命令行展示；规则覆盖 URL 查询串、`Authorization`/`Bearer`、敏感键值（含 `PI_WEB_PASSWORD`）、JWT、代理凭据、Home 路径、私钥块，多行输入逐行处理且幂等。
- `DiagnosticsCollector`（`Sources/DiagnosticsCollector.swift`）与 `DiagnosticsClipboard`（`Sources/DiagnosticsClipboard.swift`）：把调用方已收集的版本/构建号、Node/pi/pi-web 版本与路径可信度、服务地址与端口、状态、托管关系、监听/托管 PID、有效工作目录、配置目录、启动命令与启动环境、日志位置与写入状态、密码状态组装为诊断文本，自身不执行命令、不读磁盘；整段文本在导出前交给注入的 `LogRedactor`。菜单“复制诊断”与诊断窗口的复制按钮共用同一导出文本与同一条提醒/写剪贴板路径。字段与规则见 [日志与诊断导出](logging-and-diagnostics.md)。
- `DependencyChecker`（`Sources/DependencyChecker.swift`）：启动前的只读依赖诊断。检查系统（`uname` 架构与 macOS 版本）、Node.js（必须 `>= 22.19.0`，自实现语义化版本比较）、Pi CLI、Pi Web（可执行文件、版本、真实路径、符号链接目标，以及 pi-web 的 package.json `name`/`version`）、默认服务端口（本机 `bind(2)` 判定可用/被占用）和 Pi 配置目录（`~/.pi/agent`，只问“存在吗/可读吗”）。命令经 `CommandRunning` 注入，磁盘经 `DependencyFileSystemProbing` 注入，架构与系统版本经 `DependencySystemProbe` 注入，端口经 `DependencyPortProbing` 注入。它不安装、不升级、不联网、不调用 `sudo`，也不读取认证内容；路径在离开 checker 前已经完成 Home 脱敏（`~`）。除诊断项外，报告还带 `components`（GitHub #16 的组件安装模型，见下条），复用同一批探针结果（包括已知的 Node/pi/pi-web 版本），不重复执行 `--version`。
- `ComponentInstallation`（`Sources/ComponentInstallation.swift`）：组件版本与安装来源模型（GitHub #16）——`ComponentKind`（`desktopApp`/`piCLI`/`piWeb`/`piPackage`）、`InstallSource`（`npmGlobal`/`pnpmGlobal`/`homebrew`/`nvm`/`mise`/`officialInstaller`/`gitCheckout`/`localPath`/`unknown`）、`DetectionConfidence`（`verified`/`inferred`/`unknown`）与 `ComponentInstallation`（包名、版本、可执行文件路径、真实路径、完整符号链接链、package.json 路径、来源、可信度、证据行、建议命令）。`ComponentSourceResolver` 是证据组合的纯函数；`ComponentInstallationDetector` 通过注入的 `CommandRunning` / `DependencyFileSystemProbing` / `environment` / `homeDirectory` 收集证据：可执行位、完整符号链接链（含悬空链）、最近一层 package.json（`name`/`version`/`bin`，最多向上 6 层）、包目录内 `.git`、`npm root -g`、`pnpm root -g` 和 `pi list`（失败或无法解析时降级为 unknown，不崩溃）。它只执行只读命令（`--version`、`npm root -g`、`pnpm root -g`、`pi list`、`command -v`；`DependencyChecker` 已经解析过可执行文件，会关掉重复的 `command -v`），不执行安装/升级、不联网、不调用 `sudo`、不读认证文件、不写任何文件；建议命令只来自静态清单 `InstallCommandManifest`，且只有 npm/pnpm 全局来源且 `verified` 时才给出，其它来源只给指引文字。
- `UpdateChecker`（`Sources/UpdateChecker.swift`）：运行期只读版本检查（GitHub #17；策略、忽略版本与调度见 GitHub #18，详见“更新检查与缓存”）。四类检查（桌面应用 GitHub Releases、Pi CLI 与 Pi Web 的 npm registry、`pi list` 得到的扩展包逐个查询）各自按策略控制（关闭 / 每日 / 每周；扩展包为关闭 / 检查并通知 / 询问后更新），关闭后既不调度也不请求；只发 GET，端点由 `UpdateEndpoint` 白名单固定为 `api.github.com` 与 `registry.npmjs.org`，请求头只允许 `Accept` / `User-Agent` / `If-None-Match` / `If-Modified-Since`（`UpdateHTTPRequest.sanitized()` 丢弃其它头；生产客户端 `URLSessionUpdateHTTPClient` 用 ephemeral 配置且不跟随重定向）；`UpdateResponseParser` 是纯解析函数，`SemanticVersion` 负责含预发布标识符的语义化比较；只有“预期端点 + 结构可解析”才把上游版本标为 `verified`，解析失败、非预期主机或重定向一律 `unknown` 并保留上一次成功结果；失败只更新检查状态与提示文案，不抛出、不影响服务；没有任何安装/下载/执行路径。时钟（`UpdateClock`）、调度（`UpdateCheckScheduling`）、HTTP（`UpdateHTTPClient`）与缓存（`UpdateCacheStoring`）全部可注入，请求超时固定 15 秒。
- `InstallCommandManifest`（`Sources/InstallCommandManifest.swift`）：修复建议的静态清单（Node.js 最低版本、Pi CLI 与 Pi Web 的 npm 安装命令、官方文档 URL，以及 GitHub #16 的按来源更新的指引与 npm/pnpm 更新命令）。纯编译期常量，不联网、不动态拼接包名、不执行；应用只展示和复制，绝不执行。
- `PiProcessInspector`（`Sources/PiProcessInspector.swift`）：运行进程保护（GitHub #21）。用只读 libproc（`proc_listpids` 枚举 PID，`proc_pidinfo` / `proc_pidpath` 取内核进程名与真实镜像路径，`sysctl KERN_PROCARGS2` 取 argv 并按 argc 停在 argv 边界）回答“现在有没有 Pi CLI 进程在运行”。读取分两步（GitHub #61）：`snapshot` 只取便宜的身份事实（父 PID、启动时间、镜像路径、内核进程名），只有候选进程（镜像或内核进程名的可执行基名恰好是 `pi`，或是 `node` / `npm` / `bun` / `deno` 这类 JS 运行时）才通过 `PiProcessProbing.arguments` 读 `KERN_PROCARGS2` 的 argv，因此系统守护进程、编译器、编辑器等非候选进程不被读命令行；候选判定只是读取优化，不是安全判断，两个可执行身份都读不到、权限不足或枚举失败仍然是 `unknown`。判定只做**精确**的可执行文件名比较：`pi-web`、`pip`、`pi-helper`、编辑器里打开的 `pi` 文件都不命中；Pi CLI 是 `#!/usr/bin/env node` 脚本，内核只看到 Node，所以额外按“JS 运行时的 argv[0] 进程标题恰好是 `pi`”与“argv 里的绝对路径脚本名恰好是 `pi` 且可执行（或符号链接）”两条证据判定。结果只有三态：`noProcesses` / `runningProcesses([PiProcessRecord])` / `unknown(PiProcessInspectionUnknown)`；枚举失败、可执行身份读不到、解释器 argv 读不到、名为 `pi` 的脚本无法确认可执行都归入 `unknown`，调用方按不安全处理。进程记录在构造时已完成脱敏（Home → `~`、凭据与查询串 → 占位符、`KEY=VALUE` 环境片段丢弃、摘要上限 200 字符），原始 argv 不离开检查器；本文件不执行命令、不发送任何信号。
- `PiCLIUpdateAdapter`（`Sources/PiCLIUpdateAdapter.swift`）：Pi CLI 的受限自动更新与手动更新（GitHub #21）。`PiCLIUpdatePlanner` 是纯决策，顺序是“设置位 → Pi CLI 识别结果 → 来源必须是已验证的 npm/pnpm 全局 → 目标版本必须 `verified` 且更高 → 命令安全校验”，最后才是进程保护：**只有 `noProcesses` 允许自动执行**，`runningProcesses` 与 `unknown` 都返回 `.deferred` 并给出可读原因。`PiCLIUpdatePlan` 的参数数组恒为 `update --self`（无 shell 字符串、无额外参数、路径过安全字符集校验）；`PiCLIUpdateCoordinator` 编排“决策 → 执行前复查进程 → 执行 → 重新检测版本”；`ProcessPiCLIUpdateCommand` 用 `Process` + 参数数组执行，子进程环境只保留白名单键并把 `pi` 所在目录放到 `PATH` 最前（npm 安装的 `pi` 需要经 `env` 找到 Node），**不向任何进程发送信号**：超时或应用退出只放弃等待，子进程按自己的方式结束，管道读到 EOF 或宽限到期后才收尾。执行后必须用 GitHub #16 的识别器重新检测版本：退出码非零、超时、启动失败、版本没变化或无法解析都算失败，只写持久警告与日志、不做无上限重试（一次运行最多尝试一次）、不声称回滚。
- `PiPackageUpdateAdapter`（`Sources/PiPackageUpdateAdapter.swift`）：Pi 扩展包的更新确认流与执行边界（GitHub #22）。输入是纯数据：GitHub #16 的 `pi list` 检测结果（包名、本机版本、`InstallSource`、`DetectionConfidence`）、GitHub #17 的检查结果（目标版本与可信度）与 `PiProcessInspection`；`PiPackageUpdatePlanner.decide(...)` 是纯决策，顺序是“策略 → 包名符合 npm 规范 → 包名必须出现在本次检测结果里 → 来源必须是已验证的 npm 全局安装 → 本机版本可读、目标版本经上游响应验证、可比较且更高 → 参数数组过安全校验 → 进程保护”，输出 `PiPackageUpdatePlanSet`（逐包 `notifyOnly` / `awaitingConfirmation` / `executeBlocked` / `manualOnly` / `unavailable` 与策略级拒绝）。`PiPackageUpdatePlan.executablePath` 必须是以 `pi` 结尾的官方可执行文件，参数数组恒为 `["update", "npm:<包名>"]`（上游 `pi update <source>` 的 npm 来源形式，来源规格由 Pi 自己解析；应用不调用 npm/pnpm、不拼 shell 字符串、不调用 `sudo`），`allowsUnattendedExecution` 与 `isAutomaticallyExecutable` 恒为 `false`——扩展包更新没有无人值守路径：`checkAndNotify` 只提示并给出官方命令文本，`askBeforeUpdate` 必须由用户在确认框里显式确认（取消是默认按钮），非“已验证的 npm 全局”来源不给执行入口、只展示 `pi update --extensions` 文本。`PiPackageUpdateCoordinator.runConfirmed(...)` 在执行前用 `PiProcessInspector` **再检查一次**进程状态，`runningProcesses` 与 `unknown` 都拒绝执行并给出可读原因（每个进程的 PID、父进程、启动时间、判定依据与脱敏命令摘要），整批按顺序执行、一旦出现进程立即停止后续计划并全部记为拒绝；`ProcessPiPackageUpdateCommand` 用 `Process` + 参数数组运行，环境只保留白名单键并把 `pi` 所在目录放到 `PATH` 最前，超时或应用退出只放弃等待，**不向任何进程发送信号**。退出码非零、超时、启动失败、放弃等待与“退出码 0 但版本没变化”都算失败，只写持久告警与日志、一次确认最多尝试一次、不重试、不声称回滚；所有拒绝（策略级、来源/版本不符、进程保护、用户取消）都带固定文案原因并写入日志与诊断。
- `FirstLaunchDiagnostics`（`Sources/FirstLaunchDiagnostics.swift`）：首次启动路由、门控控件映射、pi-web 路径选择和诊断 smoke 夹具的纯逻辑——`DiagnosticsGate`（`checking`/`ready`/`blocked`）、`ServiceControlState`（门控 → start/stop/restart 可用性）、`DiagnosticsRouting`（报告 + 首次设置状态 → `mainWindow`/`diagnostics(reasons)`）、`ServiceLaunchIntent`（首次设置刚完成 → 显式启动，否则尊重 `autoStart`）、`PiWebPathSelection` 与 `PiWebIdentityEvidence`（选中的路径 + 只读身份证据 → 新配置或可读错误）和 `DiagnosticsSmokeFixture`。不依赖 AppKit，可在 unhosted 测试目标里直接断言。
- `DiagnosticsWindowController`（`Sources/DiagnosticsWindowController.swift`）：首次启动诊断状态页（诊断项表格 + 可复制的安装命令 + 组件安装区块 + “选择 pi-web 路径…”“重新检测”“开始使用 Pi Web”）。它只渲染 `DependencyReport` 和收集用户选择：选择结果经 `onSelectPiWebPath` 交给 `AppDelegate` 校验并写入配置，重新检测经 `onRecheck` 回调；窗口不执行安装命令、不执行更新命令、不写配置。
- `PreferencesWindowController`：用户设置界面；保存后由 `AppDelegate` 经 `AppConfiguration` 写回 UserDefaults。“远程访问”分区显示密码已设置/未设置，提供设置/生成/删除密码按钮，并说明密码认证不等于传输加密；删除密码会关闭远程模式并恢复默认 loopback。
- `KeychainStore`（`Sources/KeychainStore.swift`）：远程访问密码的存储与门控纯逻辑。`KeychainStoring` 协议只提供 save/load/delete/exists，生产实现是 macOS Security 的 `kSecClassGenericPassword`（service = bundle identifier，account = `remote-access-password`，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）；`RemoteAccessPassword` 给出读取与“已设置/未设置”状态文本，`RemoteAccessPolicy` 给出唯一的监听地址判定 `addressVerdict(hostname:)`（结果类型 `ServiceAddressVerdict`，保存/加载/启动共用）、loopback 判定、远程监听前置条件与“删除密码后回到 loopback”，`RemoteAccessSetup` 是设置界面的保存流程（密码只进 Keychain，配置只进 UserDefaults），`PasswordGenerator` 用 `SecRandomCopyBytes` 在本地生成不低于 24 位、含大小写字母数字符号的密码，`SecretScrubbing` 在展示前移除已知秘密。

### 注入点

`ServiceManager` 的每个副作用都经过注入的依赖，测试因此不接触真实进程、定时器或网络：

- `CommandRunning`：`ps`/`lsof`/`zsh` 等命令；`SystemCommandRunner` 是唯一真实实现，对每条命令都有超时上限（`timeout` 可注入，默认 10 秒；超时/取消时只尽力终止本次启动的子进程），并用 `CommandRunResult` 区分“超时/取消”与普通不可用。
- `ProcessInspector`：监听 PID、进程存活判断、`pgid`/`lstart`/`comm` 事实读取；其中 `processIsAlive` 闭包可注入，测试里完全不看真实进程。
- `ServiceLaunching`：全项目唯一启动服务进程的地方（`SystemServiceLauncher`）。生产实现用 `posix_spawn` + `POSIX_SPAWN_SETPGROUP` 让子进程成为独立进程组的组长，并保留日志重定向、环境变量、工作目录和 stdin 为 `/dev/null`；测试用假实现断言完整命令行与环境变量。远程模式下 `PI_WEB_PASSWORD` 只出现在这个环境字典里（见下节）。
- `ServiceOwnershipStoring`：`service-owner.json` 的读写（`FileServiceOwnershipStore`）；测试可以注入写入失败的实现来验证“启动后写不进记录就终止刚启动的进程组”。
- `ServiceSignaling`：只提供“向进程组发送信号”和“进程组是否存活”两个方法（`POSIXServiceSignaler` 用 `kill(-pgid, ...)`）；接口里没有单 PID 发送方法，测试用假实现记录收到的组信号。
- `ServiceProbing`：启动轮询与健康检查用的 HTTP 探测（`URLSessionServiceProbe`，超时经参数注入）。
- `ServiceScheduling`：主队列/后台队列、延时、重复定时器和 `sleep` 的调度；测试里即时执行，不等待真实时间。
- `AppConfiguration`、`environment` 闭包与 `FileManager`：路径、子进程环境变量和文件操作；`ServiceManager` 另外注入 `remoteAccessPassword` 闭包（默认返回 nil，即“无密码”），因此测试永远不会读到真实 Keychain。
- `DependencyFileSystemProbing` / `DependencySystemProbe` / `DependencyPortProbing`：依赖诊断的文件系统探针（可执行文件、符号链接、真实路径、文本读取、Home 目录、目录存在与可读性）、系统探针（`uname` 架构、macOS 版本）和端口探针（本机 `bind(2)`，只回“可用/占用/无法判定”）；测试注入假实现，因此不触碰真实 Home、npm 前缀、`~/.pi`、真实端口或网络。
- `ComponentInstallationDetector`：组件安装识别的命令执行（`CommandRunning`）、磁盘访问（`DependencyFileSystemProbing`）、`environment` 与 `homeDirectory` 都可注入；测试用临时目录夹具 + 假命令回答覆盖多跳/悬空符号链接、nvm 与 npm 全局共存、Homebrew、git checkout 与降级路径，不执行真实 npm/pi/pi-web。
- 更新检查（GitHub #17 / #18）：`UpdateHTTPClient`（生产 `URLSessionUpdateHTTPClient`；测试用记录请求并返回构造响应的替身）、`UpdateClock`（假时钟推进时间）、`UpdateCheckScheduling`（测试立即执行检查主体与回调，并记录/手动触发周期计时器，不使用真实 sleep）、`UpdateCacheStoring`（内存替身或临时目录文件存储）、`UpdateCheckPreferences`（策略 + 启动前自动更新布尔）与 `UpdateIgnoredVersions`（忽略版本）都可注入；因此测试不联网、不写真实 Application Support/UserDefaults。
- 启动前自动更新（GitHub #20）：`PiWebUpdateInstalling`（生产 `ProcessPiWebUpdateInstaller`，测试用记录计划与结果的替身）、版本重检测探针、启动服务与健康检查回调、`LogRedactor`、日志闭包、完成投递闭包与超时都是 `PiWebUpdateCoordinator.Environment` 的注入点；测试因此不执行真实 `npm`（只允许执行 `$TMPDIR` 里的假安装器脚本）、不启动真实服务、不写真实 UserDefaults。
- 运行进程保护与 Pi CLI 更新（GitHub #21）：`PiProcessProbing`（PID 枚举 + 单进程身份快照 + argv 读取（只对候选进程）；生产是只读的 `LibprocPiProcessProbe`，测试用 `fixture` 假进程表与记录调用次数的 argv 替身，因此“某个 PID 是否被读过 argv”是可断言的事实）、`DependencyFileSystemProbing`（脚本路径的可执行位探针）、`PiCLIUpdateRunning`（生产 `ProcessPiCLIUpdateCommand`，测试用记录调用的替身）、版本重检测闭包、`LogRedactor`、日志闭包、完成投递闭包与超时都是 `PiCLIUpdateCoordinator.Environment` 的注入点；测试因此不枚举真实进程、不执行真实 `pi`、也不发送任何信号（`PiProcessProbing` / `PiCLIUpdateRunning` 两个接口里没有任何发信号或终止进程的方法，唯一的真实子进程用例只执行 `$TMPDIR` 里的假 `pi` 脚本，用来断言“放弃等待不会终止子进程”）。

`WebViewController` 通过构造参数接收 service URL、端口和 `windowProvider` 闭包（保存面板、打开面板和查找栏需要窗口），所以 `AppDelegate` 不持有 WebKit 状态。

尚未实现（后续 issue 范围）：

- 更新流水线中仍未实现的部分：桌面应用自身的应用内更新（下载、安装 `Pi Web Desktop.app` 属于后续 issue），
  更新包的下载缓存与内容哈希/签名校验，比 GitHub #23 的“有限降级”更完整的回滚策略，以及非 npm/pnpm
  全局来源（Homebrew、nvm/mise、git checkout、本地路径）的自动更新。GitHub #20 / #21 / #22
  已实现三条受限更新路径（Pi Web 启动前自动安装、Pi CLI 启动前自动更新与运行进程保护、Pi 扩展包“询问后更新”），
  GitHub #23 给三条路径加了阶段化事务、验证能力边界与有限降级，均见下文“更新检查、设置与缓存”；
  上述未实现的能力不在本版可用范围内，其它来源仍然只显示命令、绝不自动安装。

`DiagnosticsCollector` 只负责文本组装（调用方仍然只传入可公开的字段，密码等秘密不会进入输入）；脱敏由注入的 `LogRedactor` 在导出时统一完成，见 [日志与诊断导出](logging-and-diagnostics.md)。

## 依赖诊断与启动门控

`AppDelegate` 在启动时（smoke 启动除外）异步运行 `DependencyChecker`：命令探针是同步阻塞调用（现在有超时上限），因此整份检查经 `CommandProbeDispatch.runOffMain` 放到后台队列，结果回到主队列后决定路由与门控；检查期间启动/停止/重启菜单项全部保持禁用。同一条线程约定也用于“选择 pi-web 路径…”的身份校验（`--version` 探针）：校验在后台队列完成，主队列只做配置写入与提示。

`DependencyReport` 有两条派生规则：

- `canStartService`：Node.js、Pi CLI、Pi Web 三条硬性前置都存在，且状态均为 `ok` 时才为 true。缺少任一条目（例如空报告）或状态为 `unknown`（版本无法解析、无法核对身份）都不放行，门控默认关闭。
- `blockingFindings`：报告里存在的必需项中状态非 `ok` 的项（Node.js 缺失/过旧/无法确定，Pi CLI / Pi Web 缺失或版本无法解析）。系统项、默认端口（`被占用`/`无法确定`）和 Pi 配置目录（`缺失`/`不可读`/`无法确定`）只提示，不阻塞。报告缺项时 `blockingFindings` 里不会出现对应条目，所以门控还看 `unsatisfiedPrerequisiteKinds`，不能只用它判定。

首次启动路由（`DiagnosticsRouting`，纯函数）：输入是诊断报告和 `AppConfiguration.hasCompletedFirstLaunchSetup`，输出只有 `mainWindow` 与 `diagnostics(reasons)` 两种取值，不存在“退出应用”的分支。判定条件是 `canStartService`（必需项齐备且状态均为 `ok`），不是 `blockingFindings` 是否为空：`DependencyReport(findings: [])` 这类缺少必需条目的报告必须停留在诊断页。

- 硬性前置未通过时报告 `.unmetPrerequisites([...])`（缺项与状态非 `ok` 的必需项，顺序固定为 Node.js、Pi CLI、Pi Web），应用保留窗口、停掉健康轮询、不加载服务地址，WebView 显示诊断状态页而不是服务页。
- 硬性前置已满足但首次设置未完成时报告 `.firstLaunchSetupIncomplete`，同样先显示诊断状态页（所有行已是绿色），由“开始使用 Pi Web”或“重新检测”完成设置后进入主窗口。
- 两者都成立时进入正常主窗口：加载服务页并启动服务。普通启动尊重 `service.autoStart`（调用 `startAtLaunch()`）；如果用户刚刚完成首次设置（本次路由就是“完成设置”触发的，例如点击“开始使用 Pi Web”或在就绪后重新检测），则用 `ServiceLaunchIntent.startExplicitly` 走 `startAtLaunch(forceStart: true)` 显式启动，忽略 `autoStart`——否则用户刚修好前置却只会看到“Pi Web 服务未运行。”。

首次设置完成的唯一条件是硬性前置就绪（`DiagnosticsRouting.completesFirstLaunchSetup` = `canStartService`）。状态存在 UserDefaults（经 `AppConfiguration`），只有用户主动重新检测得到就绪报告、或在诊断页选择 pi-web 路径后重新检测、或点击“开始使用 Pi Web”时才写入；缺少前置时永远不会标记完成。端口占用与 Pi 配置目录缺失只做提示，不产生修复命令（`remediationID == nil`），TUI/WebView 文本里只给出可读说明。

服务控件可用性只有一个映射（`ServiceControlState`）：门控 `.ready` 时 start/stop/restart 全部可用；`.checking` 和 `.blocked` 时三者全部禁用。`AppDelegate` 的显式 `isEnabled` 更新与 `validateMenuItem` 都读同一个映射，所以菜单打开时和异步回调后不会出现两套规则。

`DependencyFinding.status` 取值：`ok`、`missing`、`outdated`（Node.js 低于最低版本，或 macOS 低于 14）、`unknown`（版本无法解析）。`confidence` 取整条结论各项证据里最弱的一项：探针直接确认是 `verified`，只能由候选路径或路径前缀推断是 `inferred`（pi-web 的 package.json `name` 与预期不符也计为 `inferred`），没有可用证据是 `unknown`。诊断项的安装来源按固定优先级推断：Homebrew Cellar（verified）→ npm 前缀 `lib/node_modules`（verified）→ npm 前缀 `bin`（inferred）→ `~/.npm-global`（inferred）→ Homebrew 前缀（inferred）→ 用户目录（inferred）→ unknown。`remediationID` 只指向 `InstallCommandManifest` 的静态条目。

报告里的组件安装模型（`ComponentInstallation`，GitHub #16）单独用一套更严格的证据组合规则（`ComponentSourceResolver`），诊断项的来源优先级保持不变：只在真实路径命中 `/opt/homebrew`/`/usr/local` 的 `Cellar` 或 `opt` 结构时才是 `homebrew`；`nvm`/`mise` 需要路径段（如 `versions/node/<版本>`）与环境标记（`NVM_DIR`/`MISE_DATA_DIR` 或对应的安装目录段）同时成立；`gitCheckout` 需要在包目录里找到 `.git`（文件或目录）；`npmGlobal`/`pnpmGlobal` 只认 `npm root -g` / `pnpm root -g` 的输出前缀；没有任何组合命中时来源为 `unknown`，并总是带一条“未验证原因：…”证据行。仅凭 `/opt/homebrew/bin`、`~/.npm-global`、`/lib/node_modules` 这类前缀或弱证据最多只能给出 `inferred`，`verified` 必须来自直接证据；`suggestedCommand` 只在来源为 npm/pnpm 全局且可信度为 `verified` 时从静态清单取值，其它来源一律只给指引文字。

版本证据必须与报告的路径同源：Node.js 候选路径（含登录 shell 的 `command -v`）存在时只采信它自己的 `--version`，即使它不可运行也不会用 PATH 上另一个 node 的版本来放行；只有候选路径完全不存在时才按进程 PATH 重新解析（`/usr/bin/env node -p process.execPath`），并把真正产出该版本的可执行路径记入报告，解析不出可执行路径就只报 `unknown`。系统项在 `uname` 失败（`machineArchitecture()` 为 `"unknown"`）时 `confidence` 降为 `unknown`，不再声称已验证；系统项本就不阻塞启动。

门控与路由结果：

- 路由 `mainWindow`：与拆分前一致——显示“正在检查 Pi Web 服务…”，调用 `serviceManager.startAtLaunch()`；诊断窗口只在用户主动打开时显示。
- 路由 `diagnostics`：服务控件按 `ServiceControlState` 禁用（`.blocked` 时 start/stop/restart 全不可用），不调用 `startAtLaunch()`，WebView 显示诊断状态页（六个诊断项，每项都有状态、路径、版本、安装来源、可信度五个字段，缺失值用“未找到/未知”占位而不是省略整行）而不是服务地址，并打开/刷新诊断窗口。`.blocked` 时还会 `stopHealthMonitor()` 并把状态置为 stopped，避免健康检查把状态改回 running。
- “重新检测”只是重新运行一次 `DependencyChecker`（使用当前 `ServiceConfiguration.piWebPath`）；前置满足后立即打开门控、撤销控件禁用并进入主窗口，无需重启应用。“选择 pi-web 路径…”经 `NSOpenPanel` 选择文件，`PiWebPathSelection` 要求绝对路径、可执行，并且身份可核对（`--version` 能解析出版本，或沿真实路径向上找到的 package.json `name` 就是 `@agegr/pi-web`）：`/bin/echo` 这类可执行但不是 pi-web 的文件会被拒绝。校验在后台队列执行（`CommandProbeDispatch`，`--version` 探针因此不阻塞主线程），失败时主线程弹出可读提示、配置不变；成功时经 `AppConfiguration` 写回 `ServiceConfiguration.piWebPath`，随后立即重新检测。身份证据由 `DependencyChecker.piWebIdentityEvidence(atPath:)` 收集，只执行 `--version` 并读 package.json 的 `name`，不安装、不联网。

`PI_WEB_DESKTOP_SMOKE=1` 在 `applicationDidFinishLaunching` 的第一个分支返回，因此启动 smoke 完全跳过依赖门控（不运行 checker、不等待后台结果），只验证窗口建立与退出路径。`PI_WEB_DESKTOP_SMOKE=diagnostics` 在另一个分支返回：它使用 `DiagnosticsSmokeFixture` 的确定性报告（固定探针，不执行命令、不读真实磁盘或 `~/.pi`、不绑定真实端口），跑真实的 `DiagnosticsRouting` 决策，渲染诊断状态页并建立诊断窗口，然后打印固定标记并以 0 退出；两者都不写真实 support 目录或 UserDefaults。

门控不只在菜单层生效：`ServiceManager.isDependencyGateOpen`（默认关闭，`AppDelegate` 在诊断期间保持关闭、结果通过后打开）是所有服务启动入口的硬前置。`startAtLaunch()`、`ensureServerIsRunning()`、`startService()`、`startManagedService()`、`reloadAfterConfigurationChange()`、启动轮询（`pollUntilReady()`）和健康检查在入口以及每个异步主队列回调执行前都重新确认门控，因此配置变更重载、启动失败重试、外部服务恢复和健康恢复都不能绕过诊断结果；门控关闭时既不启动子进程、不加载服务页，也不改变状态或报启动失败。诊断判定阻塞时 `AppDelegate` 还会调用 `stopHealthMonitor()`（健康轮询本身也在入口拒绝启动），避免健康检查把状态改回 `running`、把诊断页覆盖回服务页。

诊断文本只包含已脱敏的字段：Home 前缀替换为 `~`，URL 去掉 userinfo、query 和 fragment；不写入用户名、绝对 Home 路径、凭据、token 或查询参数。导出前整段文本经过与日志、错误消息、环境变量/命令行展示共用的 `LogRedactor`（规则见 [日志与诊断导出](logging-and-diagnostics.md)）。Pi 配置目录只报告路径（`~/.pi/agent`）与“存在/可读”状态：既不做目录列表，也不读取目录内任何文件，认证内容永远不会进入报告。

### 探针超时与取消语义

依赖诊断与诊断导出共用的 `SystemCommandRunner` 对每条命令都有超时上限（`timeout` 可注入，默认 `SystemCommandRunner.defaultTimeout` = 10 秒；等待 SIGTERM 生效的宽限默认为 0.5 秒）。语义：

- **超时**：`waitForExit` 到期仍未退出时，只对**本次启动的**子进程发一次 `SIGTERM`，宽限后仍未退出才补一次 `SIGKILL`；绝不按名字或进程组发信号，也不触碰任何 Pi 进程。结果返回 `CommandRunResult(output: nil, timedOut: true)`；旧入口 `run(_:)` 仍返回 nil（按不可用处理），差异是超时/取消可以在带超时的入口里区分出来。
- **取消**：`cancelRunningProbe()` 只终止“取消时正在进行”的那一次子进程，取消标记不粘到后续探测。应用退出（`applicationWillTerminate`）会调用它，挂住的探针因此不会拖住退出路径。
- **按不可用处理，并给出可读原因**：`DependencyChecker` 用 `TimedProbeCommandRunner` 包一层，记下每条超时的探针，把“路径解析或 `--version` 探测超时”映射成诊断项的 `DependencyFinding.detail`（“依赖探测超时：命令在 N 秒上限内没有返回”）：状态按 `missing` / `unknown` 处理，`canStartService` 因此为 false，但门控**不会**停在 `.checking`——诊断状态页会打印原因行与“请检查登录 shell（`~/.zprofile` 等）是否会阻塞命令，然后点击‘重新检测’”的下一步。超时不是粘性状态：下一次正常探测立即恢复就绪（有单测断言）。
- **不死锁**：stdout 在等待循环里用非阻塞读排空，子进程输出超过管道缓冲（64 KiB）也不会把双方锁死。
- 测试向 `spawn` 注入 `ProbeProcess` 替身，因此“超时后先 SIGTERM、宽限后 SIGKILL”“取消只终止本次子进程且不粘住后续探测”“主线程不阻塞（`CommandProbeDispatch` 的工作不在调用线程执行、结果只经注入的交付点送达）”都在不启动真实命令的前提下可断言。

## 子进程环境与工具 PATH（GitHub #89）

应用可能由 Finder / Dock 启动，此时进程继承的 `PATH` 只有系统目录（典型值 `/usr/bin:/bin:/usr/sbin:/sbin`）。`pi`、`pi-web`、`npm` 都是 `#!/usr/bin/env node` 脚本，没有 `node` 的 `PATH` 会让它们的 `--version` 以 127 退出，诊断因此只能给出 `unknown` 并把启动门控关掉。从 GitHub #89 起，子进程的工具 PATH 只有一个来源，并且探测、组件识别、更新子进程与服务启动共用同一个实例。

`Sources/ToolPath.swift` 提供三层：

- `ToolPath`：纯静态常量与纯函数（已知目录、候选路径、PATH 字符串解析/去重、凭据键判定、登录 shell 解析、`printf` 输出解析）。
- `ToolPathBuilder`：值类型构建器，输入是应用环境、Home、`leadingDirectories`、登录 shell PATH 查询闭包、目录可用性探针、已解析的 node 可执行文件与 npm 全局 prefix；输出只有目录列表、PATH 字符串与子进程环境，纯函数、可在测试里注入。
- `ToolPathProvider`：应用级组合根，进程内单例式实例，负责“解析一次、缓存一次”：登录 shell 查询最多两次（登录 shell，拿不到值时再试一次交互式）、`npm prefix -g` 一次、node 路径一次。`PiWebApp` 在初始化时创建一个，注入给 `ServiceManager`、`DependencyChecker`、更新适配器与诊断导出。

合并顺序固定（遇到重复目录保留第一次出现的位置）：

1. `leadingDirectories`（需要抢占优先级的目录，例如工具自己所在目录）；
2. 应用进程环境里的 `PATH`；
3. 登录 shell 报告的 `PATH`；
4. 已知目录（探针回答“不存在”的会被丢掉，只增不减）：`/opt/homebrew/bin`、`/opt/homebrew/sbin`、`/usr/local/bin`、`/usr/local/sbin`、`/opt/local/bin`（MacPorts）、`~/.local/bin`、`~/.npm-global/bin`、`~/.bun/bin`、`~/.cargo/bin`、`/usr/bin`、`/bin`、`/usr/sbin`、`/sbin`；
5. 解析出的 node 可执行文件所在目录；
6. npm 全局 prefix 的 `bin` 目录。

可执行文件候选路径由同一份目录规则生成（`ToolPath.executableCandidates`）：先“经典三处”`/opt/homebrew/bin`、`/usr/local/bin`、`~/.npm-global/bin`，再按上面的固定顺序补齐其余已知目录，最后是工具 PATH 里的目录；顺序确定、去重，仍保留登录 shell `command -v` 作为最后兜底。

登录 shell 查询不写死 `zsh`：优先用户数据库里的登录 shell（`getpwuid(getuid()).pw_shell`，与 `dscl . -read ~ UserShell` 同一个数据源，不需要额外子进程），取不到时用应用环境里的 `$SHELL`，再退回 `/bin/zsh`、`/bin/sh`；只有绝对路径且可执行的值会被采用。查询命令是 `<shell> -lc 'printf '__PI_WEB_TOOL_PATH__%s' "$PATH"'`，输出用固定标记解析，用户 shell 自己打印的内容不会污染 PATH 值；等待上限 3 秒，结果单次缓存。登录查询拿不到值时，再尝试一次交互式查询（`-ilc`），覆盖“PATH 只配在 `~/.zshrc` 这类非登录 shell 的 rc 里”的情况：交互式 rc 可能有副作用或很慢，所以只试一次、同样受超时约束，并且子进程的 stdin 固定为 `/dev/null`，不会因为 rc 读 stdin 而卡住诊断。

`DependencyChecker` 用同一份 PATH 执行所有只读探测（`--version`、`npm prefix -g`、`command -v`），`ComponentInstallation` 用同一份环境执行 `pi list`、`npm/pnpm root -g`；只读约束不变：不安装、不联网、不写配置、不执行 `sudo`。`PiCLIUpdateEnvironment`、`PiPackageUpdateEnvironment`、`PiWebUpdateEnvironment` 的白名单（`PATH`、`HOME`、`TMPDIR`、`LANG`、`LC_ALL`、`LC_CTYPE`）保持不变，构建器只替换 `PATH` 的值、不新增任何键；`ServiceManager` 的启动环境同样用注入的 Provider 生成 PATH（没有 Provider 的纯单元测试场景退化为“应用环境 + 已知目录”的静态构建器，不执行任何命令），`PI_WEB_NO_OPEN`、`PI_WEB_PASSWORD`、`PI_WEB_ALLOWED_HOSTS` 与代理变量的语义不变。

拿不到版本时不再只留一个 `unknown`：`DependencyFinding.diagnosis` 记录可读原因（例如“命令无法执行：合并后的工具 PATH 里找不到 node；`pi` 是 `#!/usr/bin/env node` 脚本，没有 node 时会以 127 退出”），诊断页的行内备注、摘要文本的“诊断：…”、`DependencyReportPresenter.diagnosisText` 诊断块与日志（`依赖诊断：<条目> <原因>`）都读这一个字段，文案只由静态字符串与工具名组成，不含路径、凭据或 URL。

探测子进程的环境会去掉凭据类键（`token`/`password`/`secret`/`api_key`/`private_key`/`credential` 等词，与 `LogRedactor` 同一组词表），因此构建器既不会引入新变量，也不会把凭据转发给工具子进程。

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

只有验证通过的记录才会收到信号：先向记录的进程组发送 `SIGTERM`，在 `stopPollAttempts`（40 × 0.1 秒）内等待进程组消失，仍存活才对同一进程组发送 `SIGKILL`。`ServiceSignaling` 接口只暴露进程组形式（`kill(-pgid, ...)`），因此不存在向单个 PID 发送信号的路径。外部服务或验证失败时不发送任何信号：`stopService()` 只在验证通过后才会把状态更新为已停止，找不到可验证记录时直接完成回调、保持当前状态（例如仍显示“正在运行（外部服务）”）并删除不匹配的记录；菜单的停止/重启动作仍然先显示原有的“这是外部启动的 Pi Web 服务”警告。`stopManagedServiceOnQuit`（“退出并停止服务”，由 `QuitPlan`/`QuitCoordinator` 决定是否调用）也只停止已验证的托管子进程，不再清理端口上的其他监听进程；外部服务在任何退出行为下都不发信号。

### 生命周期代次与启动预算

服务状态机用一个单调递增的“生命周期代次”（`ServiceManager.lifecycleGeneration`）给异步结果编号：每次真正 launch、每次停止、每次放弃半托管启动都会递增它。所有异步入口——启动探测（`startAtLaunch()` / `ensureServerIsRunning()` / `startService()` / `reloadAfterConfigurationChange()`）、健康检查、进程退出回调、停止完成回调和就绪轮询——在调度时捕获当前代次，回到主队列后先比对该代次（就绪轮询还要再比对所属的启动会话号 `activeStartupSession`），不匹配的回调只写一条“忽略过期的…回调”日志，不改状态、不加载服务页、不弹提示。因此“停止完成后才到达的 `ready=true`”不会把已停止的服务改回 `running`，也不会对已停止的端口触发一次页面加载（W3 M2）；被新进程替换的旧进程退出回调也不会清空替换它的句柄（同 GitHub #9 的认领语义）。

启动预算是“一次启动会话”的预算（`activeStartupSession` + `startupAttempts`，150 × 0.2 秒 ≈ 30 秒）：真正 launch 会开启新会话；`startDecision` 返回 `.existingProcess` 时，同一个代次里已有活动会话就复用同一条轮询链（重复点“启动服务”、配置重载、健康恢复、弹窗“重试”都不会再各挂一条链，因此不会 N 倍速耗尽预算、不会产生 N 个同文案的模态框），上一轮已经结束（超时、进程退出或成功）时开启新会话并清零预算。于是“30 秒未就绪”超时后的重试会重新进入轮询，而不是立刻复用上一轮的失败结论（W3 M1/M3）；同一会话最多弹一次启动失败提示（`reportStartupFailureOnce`），重复结论只写日志。

“停止中”状态同样按代次记账：`isStoppingService` 等价于 `stoppingGeneration == lifecycleGeneration`。停止开始时把当前代次记为停止代次；`finishStopping` 只清除属于自己代次的标志；记录不可验证等提前返回分支统一调用 `clearStopping()`（`stopManagedServiceOnQuit` 不再自行预置后漏清零）。任何一次代次递增都会让旧标志自动失效，所以退出失败的停止路径不会把应用永久锁在“停止中”，后续启动入口（`startDecision`、`startManagedService`）仍然可用（W3 L1）。停止完成后应用侧的日志管道写端在 `finishStopping` 里关闭，与“进程退出回调”时代的清理等价。

### 过期记录与应用重启

启动时（`startAtLaunch()` → `reconcileOwnershipRecord()`）会重新验证磁盘上的记录：进程已不存在、或记录来自上一次应用运行（`instanceID` 不同）时，只删除记录文件，绝不向对应 PID 发送信号；“退出但保持服务运行”留下的服务在下次启动时因此按外部服务处理。删除规则由 `ServiceOwnershipVerdict.shouldRemoveRecord` 决定：唯一保留记录的情况是 `ps` 事实暂时不可读，此时仍然不会发送信号，留待下次再验证。

## 退出状态机

退出流程的决策与副作用顺序由纯值类型 `QuitCoordinator`（`Sources/QuitCoordinator.swift`，GitHub #72）描述：输入是事件（⌘Q 与菜单“退出 Pi Web Desktop”及其设置的退出行为、显式“保持服务运行/停止服务”菜单项、AppKit 终止请求、用户选择、超时、停止完成，加上当时看到的服务状态），输出是 `Phase` 与需要执行的 `QuitEffect`（弹确认框 / 停止托管服务 / 退出应用）。它不 import AppKit、不做嵌套 RunLoop、不读时钟、不起进程，因此三条路径、取消、重复触发、超时兜底与外部服务都能在 unhosted 测试里断言（`PiWebDesktopTests/QuitCoordinatorTests.swift`）。`QuitPlan`（`Sources/QuitPolicy.swift`）仍是“设置或用户选择 → 计划”的映射表，被状态机复用。

状态机只有四个阶段：`idle`、`waitingForUserDecision(deadline:service:)`、`stoppingManagedService`、`terminating`。

- **决策在 AppKit 终止序列之外**。⌘Q 与菜单动作直接把事件交给状态机：需要询问时先弹普通 alert，用户选择后再由 `terminateApplication` 重新发起退出。`applicationShouldTerminate` 只在被 AppKit（Dock 退出、注销/关机、其他进程调用 `terminate:`）调用时询问状态机，且只回答两种立即回复：`.terminateNow`（已决策、服务处置已落地）或 `.terminateCancel`（需要询问用户或先停止托管服务，异步流程完成后重新发起 `NSApp.terminate(nil)`）。**从不返回 `.terminateLater`**，因此没有“等待回复期间主队列不排水”、也没有“漏掉 `reply(toApplicationShouldTerminate:)`”而让应用无法退出的路径（GitHub #72 / 代码审查 W4 G1）。
- **不重入 AppKit 终止序列**。`terminateApplication` 只在 `DispatchQueue.main.async` 里调用 `NSApp.terminate(nil)`（GitHub #72 / W4 M4）：确认框的 sheet 回调与 `stopManagedServiceOnQuit` 的完成回调都不是 AppKit 终止序列的重入点。
- **等待停止服务用异步回调**。`.stopManagedService` → `ServiceManager.stopManagedServiceOnQuit(completion:)` → 完成回调回报 `managedServiceStopFinished` → 状态机进入 `terminating` 并产生 `terminateApplication`。全程不嵌套 RunLoop，主队列在等待期间照常排水。
- **超时兜底**。`waitingForUserDecision` 带 `deadline = 请求时间 + decisionTimeout`（默认 300 秒，可注入）；超时后无论用户是否响应，都按最安全行为处理：保持服务运行并退出（`decisionTimedOutKeepingServiceRunning` 写入日志），避免注销/关机被无限挂起。
- **取消与重复触发**。取消回到 `idle` 且不停止任何服务；等待期间的重复请求不叠加第二个确认框，停止期间的重复请求不重复停服务；迟到的按钮回调或停止回调（已 `idle` 或已 `terminating`）一律忽略。AppKit 终止请求在已有流程进行中时只返回 `.terminateCancel`。
- **外部服务**。只有当服务状态是 `managedRunning`（`ServiceManager.managedServicePID() != nil`，即通过 `ServiceOwnershipVerifier` 校验的记录）且处置为 `stopManagedService` 时，状态机才产生 `.stopManagedService`；外部服务或没有服务时“停止服务”等同于保持运行，只产生 `terminateApplication`。

## 远程访问与密码

远程访问的唯一前置条件是 Keychain 中存在非空密码。密码的存储、读取和状态都在 `KeychainStore`（`Sources/KeychainStore.swift`）中：

- 存储：`kSecClassGenericPassword`，`kSecAttrService` 是应用的 bundle identifier，`kSecAttrAccount` 是 `remote-access-password`，可访问性固定为 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。密码只存在于这一个条目里，不进入 UserDefaults、命令行参数、日志文件、诊断文本或错误消息；`KeychainStoreError` 只携带 notFound / OSStatus，不携带秘密。
- 读取：`RemoteAccessPassword.load(from:)` 在条目缺失、为空或读取失败时都返回 nil（fail closed：读取失败不会被当成“可以用无认证方式启动”）。
- 门控：`RemoteAccessPolicy.allowsRemoteListening(hostname:password:)`——loopback 恒允许；hostname 不是 loopback 时必须存在非空密码。地址本身是否合法由同一处 `addressVerdict(hostname:)` 判定（见下文“监听边界”），`ServiceManager.isStartPermitted` 同时包含地址可用与凭证两个条件，所以启动、重启、配置变更重载、启动重试、启动轮询和健康检查都无法在地址非法或缺密码时启动服务、探测外部服务或加载服务页；`ServiceStartDecision.invalidAddress` 与 `.missingRemotePassword` 分别给出可读的失败提示。
- 单次读取：`ServiceManager.startManagedService()` 在本次启动里只读一次凭证，并且把它同时传给门控和 `ServiceLaunchSpecification.make(..., remoteAccessPassword:)`（决策入口是 `startDecision(credentials:)`）。校验通过后不再读 Keychain，因此不存在“校验时有效、此后二次读取失效却仍然 `.launch`”的 fail-open 窗口（GitHub #8 复审）；读取失败或条目缺失一律按“无密码”拒绝启动。
- 保存：`RemoteAccessSetup.apply(requested:newPassword:keychain:)` 是设置界面的保存流程。监听地址先经 `addressVerdict(hostname:)` 校验（通配地址、空值、空白与非法字符即使有密码也不能保存，这一步先于密码写入）；`newPassword` 为 nil 表示沿用已有密码，非空则再写入 Keychain；远程 hostname 没有可用密码时同样返回可读错误且不返回配置，调用方因此不会写 UserDefaults。密码写入失败时错误文本会先经过 `SecretScrubbing`，即使底层错误描述意外带上密码也不会展示。
- 生成：界面上的“生成高强度密码”调用 `PasswordGenerator`（`SecRandomCopyBytes`，长度下限 24，保证大写字母/小写字母/数字/符号四类字符各至少一个，再用可注入随机源做 Fisher–Yates 洗牌），不联网、不引入依赖。
- 删除：删除 Keychain 条目后 `RemoteAccessPolicy.disablingRemoteAccess(in:)` 把 hostname 收回 `127.0.0.1`，其余字段保持不变；`AppDelegate` 经 `AppConfiguration` 保存新配置，并且当远程服务正在运行时重启它，使新的（或已删除的）`PI_WEB_PASSWORD` 生效。
- 运行中收敛：密码也可能在服务运行期间被外部删除或变成不可读，门控本身拦不住已经在跑的进程。`ServiceManager.closeRemoteAccessIfCredentialsAreUnavailable()` 是这类状态的收敛入口：配置是非 loopback 且取不到凭证时，若存在本应用启动、且仍能通过所有权验证的进程，则把 hostname 收回 `127.0.0.1`，走 `stopService()` 的既有验证路径停止该进程组（外部服务、无法验证的记录零信号），把状态改成带可读提示的 `.failed(RemoteAccessPolicy.revokedPasswordMessage)`，并通过 `onRemoteAccessClosed` 让 `AppDelegate` 持久化回落后的配置（不静默重启）。触发点是每 4 秒一次的健康轮询、所有启动入口的缺密码拒绝分支，以及依赖检查完成时（`AppDelegate.applyDependencyReport`）。没有可验证的托管进程时不改动用户配置，只给出“需要设置密码”的提示。

传输密码的路径只有一处：`ServiceLaunchSpecification.make(..., remoteAccessPassword:)`。只有当 hostname 不是 loopback 且密码非空时，子进程环境才包含 `PI_WEB_PASSWORD`；否则该变量会被从环境里删除（包括清除父进程继承来的同名变量）。命令行参数 `--hostname/--port/--no-open`、所有权记录（只有命令文本的 SHA-256 摘要）、日志文件（只有子进程的 stdout/stderr）和诊断文本（只有“已设置/未设置”）都不包含密码值或长度。

监听边界：默认值仍是 `127.0.0.1`，地址校验只有一处实现：`RemoteAccessPolicy.addressVerdict(hostname:)` 返回 `ServiceAddressVerdict`，由偏好窗口保存路径（`hostnameValidationMessage` 与 `RemoteAccessSetup.apply`）、`ServiceConfiguration.load` 与 `ServiceManager.startDecision(credentials:)` 三处共用（GitHub #39 / 安全审查 R-3）。允许 loopback（`127.0.0.0/8`、`localhost`、`*.localhost`、`::1`）与用户显式配置的具体地址；拒绝空地址、前后空白、协议/路径/端口混写等非法字符，方括号只允许用于 IPv6 字面量，也不接受会被解析成通配地址的文本：`0.0.0.0`、`::`、`[::]`、`*` 之外，`0`、`0x0`、`000.000.000.000`、`0.0.0.0.`、`0:0:0:0:0:0:0:0`、`::ffff:0.0.0.0` 等 `getaddrinfo` 会按通配/其他规则解析的写法同样被拒绝（只接受规范点分四段、规范 IPv6 字面量与主机名）。

`ServiceConfiguration.load` 读入时执行同一判定：`[::1]` 规范化为 `::1`（与 `--hostname` 参数和端口探测一致），非法值原样保留并由 `hostnameProblem` 标记为不可用，不静默替换成 loopback 或其他地址。`ServiceManager.isStartPermitted` 与 `startManagedService()` 都要求地址可用；非法地址返回 `ServiceStartDecision.invalidAddress`，不启动进程、不探测外部服务、不加载页面，并以 `.failed(非法值 + 允许范围)` 进入诊断状态。非 loopback 地址还必须已有非空密码（见上节），启动决策只使用调用方已读取的那一次凭证。拼 URL 时仍由 `RemoteAccessPolicy.urlHost(for:)` 给 IPv6 字面量加方括号：`http://[::1]:端口/`（`URLComponents` 对未加方括号的 IPv6 host 会返回 nil，旧实现会静默回落到 `127.0.0.1`）。密码认证只验证访问者，不是传输加密：设置界面和文档都明确要求远程访问自行配置受信任的加密隧道或 HTTPS 反向代理。

## 网络边界

默认监听 `127.0.0.1`，非 loopback 监听地址必须先在 Keychain 中设置非空密码（见上节）。通配地址（`0.0.0.0`、`::`、`[::]`、`*`）、空地址、前后空白与非法字符在保存、配置加载与启动决策三处都被同一个判定拒绝，直接改写 UserDefaults 不会绕过它。远程访问还需要用户显式配置受信任的加密隧道或 HTTPS 反向代理：密码认证不等于传输加密。桌面应用不把密码写入 UserDefaults、命令行、日志或诊断信息。

## 更新检查、设置与缓存

GitHub #17 的版本检查在应用运行期间只做只读查询，不下载、不安装、不修改服务配置；应用退出后不再检查（不安装 LaunchAgent）。GitHub #18 在同一模型上加了逐类策略、忽略版本、状态显示与启动前自动更新设置位。GitHub #20 让这个设置位在受限条件下生效：只有来源为已验证的 npm 全局安装的 Pi Web 才会在启动前尝试自动更新，其余来源只显示命令。

- 设置模型：`UpdateCheckPolicy` 只有一份允许集合定义（`allowed(for:)`）——桌面应用 / Pi CLI / Pi Web 允许 `off` / `daily` / `weekly`（默认 `daily`），Pi 扩展包允许 `off` / `checkAndNotify`（默认）/ `askBeforeUpdate`。`UpdateCheckPreferences` 是四类策略（始终包含全部分类，非法组合写入时拒绝）加启动前自动更新布尔的纯值类型；`UpdateCheckIntervals` 把策略映射到秒数（每日 24 小时、每周 7 天、扩展包 7 天，`off` → nil），测试注入更短的值即可用假时钟断言周期。
- 调度一致性：`UpdateChecker.restartTimers()` 只为策略非 `off` 的分类创建计时器（相同间隔去重），`appendItem` 在到期判定时再读一次策略，因此关闭 → 不调度、不请求；设置变化时立即重建计时器。`applicationWillTerminate` 调用 `stop()` 取消全部计时器，此后的任何触发（包括 `checkNow`）都被忽略。应用不安装任何随时启动的组件（无 LaunchAgent），关掉应用就没有检查。
- 启动顺序：应用启动后立即检查一次：`AppDelegate.applicationDidFinishLaunching` 先用当时已知的应用版本启动 `UpdateChecker`，依赖诊断结束后 `startUpdateChecking(with:)` 用 `UpdateCheckInventory(components:)`（#16 的识别结果）补齐 Pi / Pi Web / 扩展包版本，并对还没有检查记录（本机版本未知因而不发请求）的对象立即补检。
- 迁移与默认值：`UpdateCheckSettingsMigration.resolve(values:report:)` 是纯函数，读键顺序是“新策略键 → 旧布尔键（GitHub #17 的 `updateChecks.*.enabled`）→ 出厂默认”；值无法识别（未知字符串、非法分类组合、非布尔值）时按默认处理并记录一条只含键名与结论的诊断行（不回显原值），由 `AppConfiguration.updateCheckPreferences(diagnostics:)` 把诊断送进应用日志。`save` 写新键时删除旧布尔键，避免两套值并存。
- 忽略版本：`UpdateIgnoredVersions` 按分类只存版本字符串与时间戳（单独键，不进入缓存文件），不含安装来源或路径；`UpdateChecker` 在判定为可更新时用精确字符串比较标记 `ignoredVersion`，`UpdateNotificationPlanner` 再次用同一份记录过滤，因此忽略只抑制那一个版本，上游发布更高版本时重新进入提示名单，也不存在版本锁定或降级。
- 状态与提示：`UpdateCategoryStatusBuilder` 从注入的缓存、结果与设置算出四类状态（最近检查、结果、忽略版本、下次检查），并随 `UpdateCheckSummary.categoryStatuses` 在主线程发布；诊断窗口与“更新检查偏好设置”窗口只渲染同一份数据（`UpdateStatusPresenter`）。提示走应用内 `NSAlert`（不用 `UNUserNotificationCenter`、不申请通知权限），同一版本在一次运行里最多提示一次，文案只含组件名与版本。
- 启动前自动更新设置位：`autoUpdatePiWebBeforeLaunch` 默认 `false`。`UpdateCheckPreferences.autoUpdateBeforeLaunchIsEffective = true`（GitHub #20 起生效），但设置位本身只是前提：是否真的执行由 `PiWebUpdatePlanner` 的前置条件决定（来源必须是 `.npmGlobal` 且可信度为 `.verified`，目标版本必须是 `verified` 且高于本机版本，**判定所用的检查结果来源必须是 `UpdateCheckOrigin.network`**（本次运行刚从白名单主机取得；缓存回退与不可用一律不自动执行，只保留手动入口），包名必须等于静态清单里的 Pi Web 包名，npm 可执行文件必须解析到、服务必须没在运行）。检查器与调度器都不读这个设置位：打开它不改变请求、结果与调度，只多出一条启动前的受限安装路径。设置窗口与文档写明生效范围（仅限已验证的 npm 全局安装），不再标注“尚未生效”。
- 启动前自动更新的执行边界（GitHub #20；GitHub #62 改为独立进程组）：`PiWebUpdateInstallPlan` 只生成参数数组（`["install", "-g", "<静态包名>@<目标版本>"]`），命令用 `posix_spawn` 直接以参数数组执行（不经过 shell、不调用 `sudo`，也不使用 `Process` 对象），参数逐项过 `PiWebUpdateArgumentPolicy`（安全字符集 + 禁止 `sudo` / `sh` / `bash` / `eval` 等 token）；子进程环境只保留白名单键（`PATH` / `HOME` / `TMPDIR` / `LANG` / `LC_ALL` / `LC_CTYPE`），`NODE_OPTIONS`、`npm_config_*`、代理与任何凭据变量都不传递；stdin 接 `/dev/null`，stdout/stderr 接管道（只保留截断尾部）。启动属性由 `PiWebUpdateSpawnPolicy` 单独构造：`POSIX_SPAWN_SETPGROUP` + `pgroup = 0`（子进程成为**新的独立进程组**的组长，组 id = 它自己的 pid），并设 `POSIX_SPAWN_CLOEXEC_DEFAULT` 保证除显式重定向的 0/1/2 外不继承其它 fd；无法设置进程组属性时降级为普通启动并在句柄上标记 `usesOwnProcessGroup = false`。执行前把可执行文件路径（Home 段显示为 `~`）、参数数组、当前/目标版本与来源/可信度写入日志与诊断，并在安装开始前显示在应用页面上（手动入口还要先在确认框里确认）。安装有可注入超时：超时/取消时**只对本次启动、已确认在它自己新进程组里的子进程组发送一次 `SIGTERM`**（尽力而为，不发 `SIGKILL`、不按名字杀进程、不触碰任何 Pi 进程）；句柄无法确认“那是自己的进程组”（降级启动、组 id 与 pid 不一致、pid ≤ 1）时**不发送任何信号**，只放弃等待。两种情况都写一条持久「已放弃」记录（见下条）。安装后必须重新检测版本并做健康检查，版本没变化或健康检查失败都算失败。
- npm 生命周期脚本策略（GitHub #60，对应 alpha.3 安全审查 A-2）：自动安装的 argv 保持 `["install", "-g", "<静态包名>@<目标版本>"]`，**刻意不传 `--ignore-scripts`**，结论与只读证据单点记在 `PiWebUpdateLifecycleScriptPolicy`：npm 默认会执行包声明的生命周期脚本；评估时只读检查了本机 npm 全局安装目录里上游包的 `package.json`（声明 `postinstall`，`files` 白名单含 `bin` 与 `.next`）、`bin/prepare-terminal.js`（只给依赖 `node-pty` 的 `spawn-helper` 二进制补可执行位）与依赖 `node-pty` 自己的 `install` / `postinstall`，而 `--ignore-scripts` 会连依赖的安装脚本一起跳过、可能留下不可用的原生模块，因此应用不替用户决定脚本策略：argv 不带该开关，环境白名单也不注入 `npm_config_ignore_scripts`（`npm_config_*` 一律不传递这一条不变）。展示/日志里新增一条固定文案说明“不传 `--ignore-scripts`（按上游包声明的安装期脚本执行；用你本机的 npm 与 npm 配置）”，与可复现的参数数组同一处输出。**限制**：这是静态评估（只读了已安装包的文件），没有真的执行安装，也没有验证安装后的运行行为。
- 启动顺序与失败语义（GitHub #20）：`applicationDidFinishLaunching` 先处理待办更新（必要时先完成一次版本检查拿到目标版本），再启动服务；任何失败都只写入持久警告、记录日志并进入诊断页，不会阻塞应用启动，也不会阻止用户手动启动服务。失败路径一律保留旧版本语义（“旧版本保持不变”），不声称回滚、不自动卸载或重装；警告只存类别、旧/新/目标版本、原因与时间戳，不含路径或凭据，菜单里有一条常驻入口展示它（可展开完整说明并清除）。同一次运行内失败后不会自动重试，下次启动或手动“立即更新 Pi Web…”才会再试。手动“立即更新 Pi Web…”需要用户在确认框里确认（显示可执行文件路径、参数与版本），确认后先用所有权校验过的路径停止托管服务，再走同一条安装与验证路径。
- 日志与脱敏（GitHub #20）：决策、参数数组、退出码与前后版本都经 `LogRedactor` 写入应用日志，环境变量只记录键名、绝不记录值；安装器输出只保留截断的尾部，并与日志、警告、诊断文本一起走同一套脱敏规则（Home 路径、`token=` / `password=` 等形状）。
- Pi CLI 启动前自动更新与运行进程保护（GitHub #21）：`autoUpdatePiBeforeLaunch` 默认 `false`；打开后只对来源为已验证的 npm/pnpm 全局安装、目标版本 `verified` 且更高、**检查结果来源为本次网络结果（`UpdateCheckOrigin.network`，GitHub #59）**的 Pi CLI 生效，并且**必须有当次进程检查确认为 `noProcesses`**（`runningProcesses` 与 `unknown` 都推迟到下一次判定：下次启动或等待状态，推迟原因写入日志与状态页，不弹框）。自动尝试在拿到当次版本检查结果后判定一次，且每个运行期最多执行一次；手动“立即更新 Pi CLI…”不做进程门控，但必须先在确认框里看到可执行文件、参数数组、当前/目标版本、每个运行中 Pi 进程的 PID/父进程/启动时间/判定依据/脱敏命令摘要与风险说明后显式确认。命令是参数数组 `update --self`（不使用 shell、不调用 `sudo`），执行前把上述信息同样写入日志，超时（默认 600 秒）或应用退出只放弃等待，**不向任何 Pi 进程发送 `SIGTERM`/`SIGKILL`，也不结束或接管任何 Pi 会话**。执行后用 #16 的识别器重新检测版本：成功要求达到目标版本（手动路径只要求版本发生变化），失败或版本未变都写一条持久警告（菜单“更新检查设置”里的“Pi CLI 更新告警…”条目，可展开并清除；只存类别、旧/新/目标版本、原因与时间戳），并在诊断页与设置页显示同一份状态（进程保护结论、本次决策、推迟原因、告警）。
- 扩展包更新确认流（GitHub #22）：Pi 扩展包策略只有三种——`off`（不检查、不通知、不执行）、`checkAndNotify`（默认，只提示“有可用更新”与官方命令文本，不提供一键执行）、`askBeforeUpdate`（同样按 7 天复查，发现更新时弹确认框，用户确认后才执行一次）；设置里没有任何“自动 / 无人值守更新扩展包”的取值，`PiPackageUpdatePlan.isAutomaticallyExecutable` 与 `PiUpdateCheckPreferences` 都表达不出这种路径，因此打开任何设置组合都不会在无人确认的情况下更新扩展包，也不会因为启动前自动更新开关而更新扩展包（那两个开关只管 Pi CLI 与 Pi Web）。
- 扩展包执行入口的必要条件（GitHub #22 / #59）：来源必须是**已验证的 npm 全局安装**（`InstallSource.npmGlobal` + `DetectionConfidence.verified`）、目标版本必须经上游响应验证且高于本机版本、目标版本必须来自本次运行从白名单主机取得的检查结果（`PiPackageCheckOutcome.origin == .network`；缓存回退只给提示与手动命令文本，不给执行入口）、并且当次的 `PiProcessInspector` 检查必须是 `noProcesses`；任一不满足就只给提示或只给命令文本（不满足来源条件的展示 `pi update --extensions`，由 Pi 自己决定实际更新哪些包），不提供可点的执行入口。确认框展示包名、当前/目标版本、来源与可信度、可执行文件路径（Home 段显示为 `~`）、参数数组、完整命令、风险说明以及每个运行中 Pi 进程的 PID/父进程/启动时间/判定依据/脱敏命令摘要；取消是默认按钮，点“取消”或直接关闭对话框都按 `userCancelled` 记录，不执行也不改任何状态。判定顺序（GitHub #107）：进程保护先于「已放弃」记录——只要当次进程检查不是 `noProcesses` 就直接拒绝执行，不会先要求用户确认一条注定执行不下去的记录。
- 扩展包更新的拒绝与失败语义（GitHub #22）：拒绝原因是固定集合——策略关闭 / 策略只通知 / 策略不属于允许集合 / 没有解析出 `pi` 可执行文件 / 包名不符合 npm 规范 / 包名不在本次检测结果里 / 来源不是已验证的 npm 全局 / 本机版本未知 / 没有目标版本 / 目标版本未经上游验证 / 目标版本不是本次网络结果（缓存回退，GitHub #59）/ 目标版本无法解析 / 目标版本不更高 / 参数数组未通过安全校验 / 有运行中的 Pi 进程 / 进程状态不确定 / 用户取消 / 执行器上还有一次命令没结束 / 上一次命令已放弃等待、退出未确认（这种窗口写明“重启应用即可恢复”）——每条都带固定文案，写入日志与诊断（诊断里只有包名、固定原因文案与脱敏后的进程摘要，没有环境变量值或凭据）。执行后必须用 #16 的识别器重新检测版本：非零退出、超时、启动失败、用户放弃等待、版本没变化或无法解析都算失败，写一条持久告警（`updateChecks.piPackages.lastUpdateWarning.*`，只存类别、包名、旧/新/目标版本、固定原因文案与时间戳），菜单里的“Pi 扩展包更新告警…”条目可展开并清除；一次确认只尝试一次，不自动重试、不声称回滚，失败不阻塞应用启动也不阻止手动启动服务。安装失败（非零退出、超时、启动失败、放弃等待）与验证失败走同一条降级应用路径（GitHub #107 / W2B B-13）：两者都产出降级结论并调用注入的 `applyDegradation`；扩展包没有可重新指向的可执行文件，生产实现对该 kind 只把结论写进日志与历史（no-op），但调用点与 Pi Web / Pi CLI 保持一致，成功路径只记「无需降级」、绝不调用。
- 更新事务与统一阶段结果（GitHub #23）：#20 / #21 / #22 三条路径共用 `UpdateTransactionJournal`、`UpdateVerifier` 与 `UpdateDegradationPlanner`，阶段固定为 准备(preflight) → 执行(install) → 验证(verify) → 启用/提交(commit) → 失败降级(degrade)，每个阶段的结果都在固定集合里：四个进度阶段是 成功 / 失败 / 跳过 / 未执行，降级阶段另有三种（GitHub #106：不再把「无法回滚」与「安装失败」记成成功）——`applied`（已执行：真的把调用方指回更新前记录的路径）/ `recordedOnly`（仅记录：安装失败，或核对后确认文件仍是更新前那份，未执行任何回滚动作）/ `notPossible`（无法执行：只报告并给手动提示）并带固定原因文案与时间。`completedPhase` 只统计前四个“进度阶段”：降级是失败后的恢复动作，不算完成阶段。真正尝试更新的路径才写历史（跳过与推迟不写），每次一条，见下面的统一历史。
- 验证能力边界（GitHub #23）：验证只回答能验证到的事实——可执行文件存在且带可执行位、解析后的真实路径可读、版本能被 #16 识别器重新检测并达到目标（手动路径要求相对更新前发生变化）、`package.json` 的 `name` 与期望包名一致（防替换）、服务启动后的健康检查结果（复用既有探测路径，由调用方传入）。每条检查只有“通过 / 失败 / 未验证”三态：没有注入文件系统探针、缺少路径或缺少包名证据时记为“未验证”，不伪装成通过。明确不做的验证单列在 `UpdateVerificationCheck.notVerifiedCapabilities`：不做代码签名验证、不声称能验证官方签名或发布来源、不做安装包内容哈希或上游文件比对（更新前指纹对本地可执行文件记录内容哈希，仅用于判断旧文件是否仍是同一份，不证明来源）。成功的检查记录只写具体事实（例如“与目标版本一致”“身份名称一致”），不使用可能被读成“来源可信”或“安全检查已通过”的结论性措辞。
- 更新前指纹（GitHub #23；GitHub #63 加强证据）：preflight 记录可执行文件路径、解析后真实路径、版本、`package.json` 名称、文件大小与 mtime，并额外记录 `st_ino`、可执行文件内容哈希（SHA-256，流式读取，上限 16 MiB）与 npm 记录的 `integrity`（从本机锁文件有界读取，取值经过形状校验）。取不到哈希（超限、不可读、无探针）时 `contentHash` 为空并带固定的“未做内容哈希（原因）”；取不到 npm `integrity` 时如实写“npm 完整性未获取”，绝不伪造。指纹的证据等级固定为 `pathOnly`（仅路径与元数据）、`inode`、`contentHash` 之一，并写进历史（`evidenceLevel` / `evidenceNote`）。不读取凭据、不做签名验证；内容哈希只用于判断旧文件是否仍是同一份，不证明发布时间、发布者或来源。扩展包没有独立的可执行文件路径，指纹只含包名与版本，因此证据不足时降级判定会如实给出“无法自动回滚”。本机文件的有界读取只在**已打开的句柄**上复核常规文件类型（对句柄跑 `fstat` 复核 `S_IFREG`，不满足就关闭并放弃），因此路径解析与打开之间的窗口不影响判定（alpha.8 安全评审 `L-3`）。
- 失败语义与有限回滚（GitHub #23；GitHub #63 加固判定）：install 失败 → 不执行任何回滚动作，也不断言系统状态未改变（命令失败不证明旧文件未被改动），不报告成功；verify 失败 → `UpdateDegradationPlanner` 产出四类之一：`installFailedKeepingPreviousVersion`（安装失败，没有执行任何回滚动作）、`stillUsingPreviousArtifact`（版本未变，文件仍是旧的）、`degradedToPreviousArtifact`（已把服务/重检测指回更新前仍然可用的可执行文件）、`cannotAutomaticallyRollback`（无法自动回滚：进入诊断并写持久警告，给出来自静态清单的手动命令或指引）。自动降级的真实边界（全部满足才算“已降级”）：来源必须是已验证的 npm 全局安装；应用保留了更新前的可执行文件路径与版本证据；旧路径仍然存在且带可执行位；旧路径所在包的 `package.json` 名称与更新前记录/期望包名一致；指纹记录了 inode 时必须一致；指纹记录了内容哈希时必须重新计算并一致。任一读不到或不一致 → `cannotAutomaticallyRollback`，绝不写“已降级”。无法自动回滚时展示的资格说明取自固定集合 `UpdateRollbackEligibility`：`sourceDoesNotSupportRollback` / `missingEvidence` / `evidenceChangedOrMissing` / `probeUnavailable`（本次运行没有文件系统探针：如实写“无法核对”，不断言证据被覆盖、删除或不可执行）/ `alreadyOnPreviousArtifact` / `stateNotVerified`。没有内容哈希（超限/不可读/无探针）时降级仍可进行，但只能退回 size/mtime 元数据比对，并在文案与历史里写明“不校验旧文件内容”与“未做内容哈希”；内容哈希一致时不再要求 size/mtime 相同（明示的等价规则：哈希是比元数据更强的证据）。pnpm / Homebrew / nvm / mise / git checkout / 本地路径 / 未知来源一律不回滚，只报告并给出手动提示。commit 成功后不做自动卸载；整个框架不移动、不复制、不删除任何文件，也不向任何 Pi 进程发送信号（唯一的信号调用是 Pi Web 安装器的独立 npm 子进程组，见上文 #20/#62 两条）。
- 统一更新历史与展示（GitHub #23；GitHub #63 证据等级）：历史存在 UserDefaults 单键 `updateChecks.updateHistory`（JSON，最多 20 条，最新在前），每条含时间、组件、来源、从/到版本、各阶段结果、失败原因、降级结论，以及本次使用的证据等级（`evidenceLevel`: `pathOnly` / `inode` / `contentHash`）与证据说明（是否做了内容哈希、npm 完整性是“已记录”还是“未获取”）。写入前逐条校验并截断（非法版本号、非法包名与未知枚举丢弃），不含绝对路径、环境变量值、凭据或子进程输出。诊断页展示最近一次更新的完成阶段、阶段结果、证据等级与建议动作（手动命令文本只显示、应用绝不执行）；持久警告文案区分“更新失败，没有执行任何回滚动作”与“更新后验证失败，已降级 / 无法自动回滚”，“已降级”明确写这只是把调用方指回更新前记录的路径，证据等级不是 `contentHash` 时写明不校验旧文件内容。没有版本证据时的措辞不声称旧文件仍在原位（改由 `UpdateWarningText.oldVersionClaimText` 一处给出，见 alpha.8 安全评审 `L-1`）；应用退出时“已放弃等待”的日志同样不断言文件位置（`L-5`；见 [alpha.9 安全评审](security-review-alpha.9.md)）。
- 超时/放弃等待的「已放弃」记录与重叠防护（GitHub #62；alpha.3 安全审查 A-6、A-7）：三个适配器（Pi Web / Pi CLI / 扩展包）共用同一个记录类型 `UpdateAbandonedAttempt` 与同一份存储（UserDefaults 单键 JSON：`updateChecks.piWeb.abandonedAttempt`、`updateChecks.pi.abandonedAttempt`、`updateChecks.piPackages.abandonedAttempts`），字段固定为组件（扩展包带已校验包名）、已脱敏命令摘要（有长度上限、剔除控制字符）、开始时间、超时上限、放弃原因（`timedOut` / `abandonedWaiting`）、来源、本次对子进程实际做了什么（`waitedWithoutSignals` / `terminatedOwnProcessGroup` / `processGroupUnavailable`）与记录时间；**`finishedAt` 恒为 `nil`**（语义就是“结束时间未知”），派生进程是否结束同样恒为 `nil`（应用没有证据），写入前逐字段校验，任何不可信字段直接丢弃整条记录。三个适配器的自动判定都先过 `UpdateAbandonedAttemptGate`：同一组件有未清除记录 → 不允许自动执行（Pi Web 返回 `.manualOnly(.abandonedAttemptPending)`，Pi CLI 返回 `.deferred(.abandonedAttemptPending(plan:))`，扩展包返回 `.awaitingAbandonedConfirmation`），只保留手动入口，且确认框先展示记录，确认后才执行一次；三个组件互相独立。记录在退出与重新启动后保留，只在用户显式清除（菜单“服务 → 更新检查设置 → 已放弃的更新记录…”）或该组件后来成功完成一次更新时清除（失败不清除）。展示统一走 `UpdateAbandonedAttemptPresenter`（诊断页、更新检查偏好设置窗口、手动确认框共用），只含固定文案与已校验字段；诊断状态块与设置窗口显示同一份文本，绝不自动结束任何进程或改动任何文件。三个适配器在既有退出回调已经确认进程退出、只是在等管道读到 EOF 的宽限窗口里都不写「已放弃」记录，结果照常按真实退出码投递；Pi Web 在退出回调尚未送达时没有可靠的非阻塞退出观测，因此仍按“结束未确认”处理，不另起 `waitpid` 与既有阻塞式回收竞争。扩展包适配器同时把执行结果经一条专用投递队列（`Sources/PiPackageUpdateAdapter.swift`）交给调用方，`stateQueue` 不再被调用方的回调阻塞；读状态接口（`isRunning`、`abandonedChildrenUnconfirmed`）仍走 `stateQueue.sync`。同一个适配器的 stdout/stderr 用增量 UTF-8 解码器，进程退出时以及排水宽限到期结束时都以空块冲刷暂存字节（alpha.8 安全评审 `L-4`：此前只有 EOF 路径冲刷，宽限到期结束可能静默丢掉尾部的不完整字符）；Pi Web 的取消请求落在“进程已退出、仍在等管道 EOF”窗口时会被记入日志而不改变结果（alpha.7 安全评审 `F1` / `F2` / `F5`，见 [alpha.8 安全评审](security-review-alpha.8.md)）。
- 请求边界：只发 GET；URL 只由 `UpdateEndpoint` 的两个工厂方法生成——`https://api.github.com/repos/Su-luoya/pi-web-desktop/releases?per_page=20` 与 `https://registry.npmjs.org/<包名>/latest`（作用域包的 `/` 编码为 `%2F`；包名复用 #16 的 `isPackageName` 校验，不合法就不发请求）。请求头只允许 `Accept: application/json`、固定 `User-Agent`（应用名 + 版本 + bundle identifier，来自 `UpdateCheckIdentity.current`）与 `If-None-Match` / `If-Modified-Since`；`UpdateHTTPRequest.sanitized()` 丢弃白名单外的头，生产客户端再用 `URLSessionConfiguration.ephemeral` + `httpShouldSetCookies = false` + `httpCookieStorage = nil` + `urlCredentialStorage = nil` 保证不发 cookie、不读写凭据，并通过 `willPerformHTTPRedirection` 拒绝所有重定向（跨主机请求因此不可能发生）。响应头只保留 `etag` / `last-modified` / `content-type`。
- 结果来源与自动安装前置条件（GitHub #59 / alpha.3 安全审查 A-1）：每个 `UpdateCheckResult` 带 `origin`（`network` / `cachedFallback` / `unavailable`）与 `cacheWrittenAt`（缓存回退时的缓存写入时间）。**只有 `origin == .network` 可以作为自动安装/自动更新的判定依据**：Pi Web、Pi CLI 与 Pi 扩展包的“是否允许执行”判定都新增这条硬前置，缓存回退或没有结果一律拒绝并给出可读原因（包含“本机缓存”与缓存写入时间，写入日志与诊断），手动入口（命令文本，仅展示不执行）不变。条件请求命中 304 时 `freshness` 仍是 `.fresh`（网络往返成功），但版本值来自缓存文件，因此 `origin` 是 `.cachedFallback`，不驱动自动安装。
- 可信度与比较：`SemanticVersion` 按 SemVer 2.0.0 §11 比较预发布标识符（数字标识符按数值，`alpha.2 < alpha.10 < beta.1 < 1.0.0`）。只有响应来自预期主机且结构可解析时才把上游版本记为 `verified`；网络失败、超时、取消、429 与 5xx 沿用 TTL 内的上次成功结果（`freshness = cached`），但**结论一律按当前本机版本现算**（GitHub #74：用当前本机版本与缓存里的上游版本走与 304 相同的比较路径，绝不沿用缓存里写下的 `status`；旧 schema 条目缺 `installedVersion` 或本机版本不可解析时降级为 `unknown`），超过 TTL 或从未成功则 `unknown`；解析失败、结构异常、重定向或最终主机不在白名单内一律 `unknown`，但保留上一次成功结果（含 etag）供下次条件请求；本机版本未知或包名不合法时不发请求，结果为 `unknown` 并给出原因。
- 缓存：`UpdateCheckCacheFileStore` 把结果写到 `AppPaths.updateCheckCacheURL`（`~/Library/Application Support/Pi Web Desktop/update-check-cache.json`，独立文件，`schemaVersion = 2`，最多 200 条；读取时兼容旧版本 1 并按当前结构处理，写回时自动升级）。结构只有目标 id、分类、包名、`lastAttemptAt` / `lastSuccessAt`、`etag` / `lastModified`、`latestVersion`、写下结论时的本机版本 `installedVersion`、`status` / `confidence` / `failure` / `httpStatusCode`：不含凭据、cookies、会话、URL、响应体或诊断内容。读取时先按文件大小上限（1 MiB）判断，再逐项校验结构与形状：JSON/字段类型可解码、`schemaVersion` 在受支持集合内、条目数不超上限、分类/包名/目标 id 互相一致、枚举值已知、版本字符串是规范化的语义化版本、时间戳不落在未来（允许小幅时钟偏移）、条件请求字段长度受限；任何一项不合法就丢弃**整份**缓存（不部分采用、不崩溃），记一条固定原因的日志（不回显缓存内容），并按“没有可用缓存”（`unavailable`）处理。缓存里的 `status` 只作为历史记录写入，不作为结论复用：缓存回退时用当前本机版本与缓存里的上游版本现算（缺 `installedVersion` 的旧条目降级为 `unknown`）。缓存文件不是可信输入（同一用户可改写），因此它不参与自动安装判定，只用于提示；写失败静默，不影响检查结果、服务与退出路径。
- 失败隔离：`UpdateChecker` 不持有 `ServiceManager` 或任何服务状态引用，也没有安装、下载或执行路径；失败只更新 `UpdateCheckSummary`、状态行与（手动检查时）提示框。日志只写一条计数行（可用更新 / 无法确定 / 检查总数），不含 URL、包名列表或响应内容。

## 数据位置

- 普通设置：UserDefaults（读写都经 `AppConfiguration`）。
- 远程访问密码：macOS Keychain（service = bundle identifier，account = `remote-access-password`，仅本文一处存储）。
- 运行状态和 PID：`~/Library/Application Support/Pi Web Desktop/`。
- 日志：`~/Library/Logs/Pi Web Desktop/`（`Pi Web Desktop.log` 与 `.1.log` … `.5.log`），应用执行按大小轮转，详见 [日志与诊断导出](logging-and-diagnostics.md)。
- 更新检查缓存（GitHub #17）：`~/Library/Application Support/Pi Web Desktop/update-check-cache.json`（只含版本、时间戳与条件请求字段，不含凭据、会话或诊断内容）；更新检查的策略、忽略版本、启动前自动更新开关、最近的更新失败警告、统一更新历史（GitHub #23，`updateChecks.updateHistory`，单键 JSON，只含固定枚举、已校验版本/包名与固定原因文案）与超时/放弃等待的「已放弃」记录（GitHub #62，`updateChecks.piWeb.abandonedAttempt` / `updateChecks.pi.abandonedAttempt` / `updateChecks.piPackages.abandonedAttempts`，只含固定枚举、已校验组件/包名、已脱敏命令摘要与时间）在 UserDefaults（`updateChecks.*`，见 [设置、工作目录与退出行为](settings-and-workspace.md)）。

设置分层、默认工作目录、退出行为与不可写目录的处理见 [docs/settings-and-workspace.md](settings-and-workspace.md)。

应用不读取、复制或修改 Pi 的认证文件。
