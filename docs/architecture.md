# 架构说明

## 产品边界

Pi Web Desktop 是独立的 macOS AppKit/WebKit companion app。它启动、管理并显示用户已经安装的 Pi Web 服务；它不 fork、不打包、不维护上游 `agegr/pi-web` 的 Web 服务代码。

本仓库是社区维护的**非官方**项目，与上游 Pi Web 维护者没有隶属关系。支持平台、签名与公证限制、无 SLA 等边界见 [README 支持矩阵](../README.md#支持矩阵)；身份与版本的单一来源、构建与验证入口见 [开发说明](development.md)。

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
- `QuitPlan`（`Sources/QuitPolicy.swift`）：退出行为的纯决策（询问 / 保持运行 / 停止服务），可 unhosted 测试；外部服务在任何退出行为下都不会被停止。
- `ProcessInspector`：`ps`/`lsof` 命令、监听端口 PID、进程存活判断、`pgid`/`lstart`/`comm`/`args` 事实读取和进程描述；命令执行通过 `CommandRunning` 注入，可执行标识读取（`proc_pidpath`）也可注入，解析规则是不访问进程的纯函数。它只报告事实，不做所有权判定。
- `LogWriter`（`Sources/LogWriter.swift`）与 `LogRedactor`（`Sources/LogRedactor.swift`）：统一日志写入与统一脱敏（GitHub #10）。`LogWriter` 按大小轮转（`LogRotationPolicy`，默认 10 MB / 保留 5 份；阈值、份数、`FileManager`、时间源都可注入），打开子进程日志句柄前先就地脱敏历史日志，任何写入/轮转失败只记录在 `failureDescription`（诊断导出的“日志写入”一行）而不抛出也不崩溃。`LogRedactor` 的同一个实例用于日志行、诊断导出、错误消息、环境变量与命令行展示；规则覆盖 URL 查询串、`Authorization`/`Bearer`、敏感键值（含 `PI_WEB_PASSWORD`）、JWT、代理凭据、Home 路径、私钥块，多行输入逐行处理且幂等。
- `DiagnosticsCollector`（`Sources/DiagnosticsCollector.swift`）与 `DiagnosticsClipboard`（`Sources/DiagnosticsClipboard.swift`）：把调用方已收集的版本/构建号、Node/pi/pi-web 版本与路径可信度、服务地址与端口、状态、托管关系、监听/托管 PID、有效工作目录、配置目录、启动命令与启动环境、日志位置与写入状态、密码状态组装为诊断文本，自身不执行命令、不读磁盘；整段文本在导出前交给注入的 `LogRedactor`。菜单“复制诊断”与诊断窗口的复制按钮共用同一导出文本与同一条提醒/写剪贴板路径。字段与规则见 [日志与诊断导出](logging-and-diagnostics.md)。
- `DependencyChecker`（`Sources/DependencyChecker.swift`）：启动前的只读依赖诊断。检查系统（`uname` 架构与 macOS 版本）、Node.js（必须 `>= 22.19.0`，自实现语义化版本比较）、Pi CLI、Pi Web（可执行文件、版本、真实路径、符号链接目标，以及 pi-web 的 package.json `name`/`version`）、默认服务端口（本机 `bind(2)` 判定可用/被占用）和 Pi 配置目录（`~/.pi/agent`，只问“存在吗/可读吗”）。命令经 `CommandRunning` 注入，磁盘经 `DependencyFileSystemProbing` 注入，架构与系统版本经 `DependencySystemProbe` 注入，端口经 `DependencyPortProbing` 注入。它不安装、不升级、不联网、不调用 `sudo`，也不读取认证内容；路径在离开 checker 前已经完成 Home 脱敏（`~`）。除诊断项外，报告还带 `components`（GitHub #16 的组件安装模型，见下条），复用同一批探针结果（包括已知的 Node/pi/pi-web 版本），不重复执行 `--version`。
- `ComponentInstallation`（`Sources/ComponentInstallation.swift`）：组件版本与安装来源模型（GitHub #16）——`ComponentKind`（`desktopApp`/`piCLI`/`piWeb`/`piPackage`）、`InstallSource`（`npmGlobal`/`pnpmGlobal`/`homebrew`/`nvm`/`mise`/`officialInstaller`/`gitCheckout`/`localPath`/`unknown`）、`DetectionConfidence`（`verified`/`inferred`/`unknown`）与 `ComponentInstallation`（包名、版本、可执行文件路径、真实路径、完整符号链接链、package.json 路径、来源、可信度、证据行、建议命令）。`ComponentSourceResolver` 是证据组合的纯函数；`ComponentInstallationDetector` 通过注入的 `CommandRunning` / `DependencyFileSystemProbing` / `environment` / `homeDirectory` 收集证据：可执行位、完整符号链接链（含悬空链）、最近一层 package.json（`name`/`version`/`bin`，最多向上 6 层）、包目录内 `.git`、`npm root -g`、`pnpm root -g` 和 `pi list`（失败或无法解析时降级为 unknown，不崩溃）。它只执行只读命令（`--version`、`npm root -g`、`pnpm root -g`、`pi list`、`command -v`；`DependencyChecker` 已经解析过可执行文件，会关掉重复的 `command -v`），不执行安装/升级、不联网、不调用 `sudo`、不读认证文件、不写任何文件；建议命令只来自静态清单 `InstallCommandManifest`，且只有 npm/pnpm 全局来源且 `verified` 时才给出，其它来源只给指引文字。
- `UpdateChecker`（`Sources/UpdateChecker.swift`）：运行期只读版本检查（GitHub #17；策略、忽略版本与调度见 GitHub #18，详见“更新检查与缓存”）。四类检查（桌面应用 GitHub Releases、Pi CLI 与 Pi Web 的 npm registry、`pi list` 得到的扩展包逐个查询）各自按策略控制（关闭 / 每日 / 每周；扩展包为关闭 / 检查并通知 / 询问后更新），关闭后既不调度也不请求；只发 GET，端点由 `UpdateEndpoint` 白名单固定为 `api.github.com` 与 `registry.npmjs.org`，请求头只允许 `Accept` / `User-Agent` / `If-None-Match` / `If-Modified-Since`（`UpdateHTTPRequest.sanitized()` 丢弃其它头；生产客户端 `URLSessionUpdateHTTPClient` 用 ephemeral 配置且不跟随重定向）；`UpdateResponseParser` 是纯解析函数，`SemanticVersion` 负责含预发布标识符的语义化比较；只有“预期端点 + 结构可解析”才把上游版本标为 `verified`，解析失败、非预期主机或重定向一律 `unknown` 并保留上一次成功结果；失败只更新检查状态与提示文案，不抛出、不影响服务；没有任何安装/下载/执行路径。时钟（`UpdateClock`）、调度（`UpdateCheckScheduling`）、HTTP（`UpdateHTTPClient`）与缓存（`UpdateCacheStoring`）全部可注入，请求超时固定 15 秒。
- `InstallCommandManifest`（`Sources/InstallCommandManifest.swift`）：修复建议的静态清单（Node.js 最低版本、Pi CLI 与 Pi Web 的 npm 安装命令、官方文档 URL，以及 GitHub #16 的按来源更新的指引与 npm/pnpm 更新命令）。纯编译期常量，不联网、不动态拼接包名、不执行；应用只展示和复制，绝不执行。
- `FirstLaunchDiagnostics`（`Sources/FirstLaunchDiagnostics.swift`）：首次启动路由、门控控件映射、pi-web 路径选择和诊断 smoke 夹具的纯逻辑——`DiagnosticsGate`（`checking`/`ready`/`blocked`）、`ServiceControlState`（门控 → start/stop/restart 可用性）、`DiagnosticsRouting`（报告 + 首次设置状态 → `mainWindow`/`diagnostics(reasons)`）、`ServiceLaunchIntent`（首次设置刚完成 → 显式启动，否则尊重 `autoStart`）、`PiWebPathSelection` 与 `PiWebIdentityEvidence`（选中的路径 + 只读身份证据 → 新配置或可读错误）和 `DiagnosticsSmokeFixture`。不依赖 AppKit，可在 unhosted 测试目标里直接断言。
- `DiagnosticsWindowController`（`Sources/DiagnosticsWindowController.swift`）：首次启动诊断状态页（诊断项表格 + 可复制的安装命令 + 组件安装区块 + “选择 pi-web 路径…”“重新检测”“开始使用 Pi Web”）。它只渲染 `DependencyReport` 和收集用户选择：选择结果经 `onSelectPiWebPath` 交给 `AppDelegate` 校验并写入配置，重新检测经 `onRecheck` 回调；窗口不执行安装命令、不执行更新命令、不写配置。
- `PreferencesWindowController`：用户设置界面；保存后由 `AppDelegate` 经 `AppConfiguration` 写回 UserDefaults。“远程访问”分区显示密码已设置/未设置，提供设置/生成/删除密码按钮，并说明密码认证不等于传输加密；删除密码会关闭远程模式并恢复默认 loopback。
- `KeychainStore`（`Sources/KeychainStore.swift`）：远程访问密码的存储与门控纯逻辑。`KeychainStoring` 协议只提供 save/load/delete/exists，生产实现是 macOS Security 的 `kSecClassGenericPassword`（service = bundle identifier，account = `remote-access-password`，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）；`RemoteAccessPassword` 给出读取与“已设置/未设置”状态文本，`RemoteAccessPolicy` 给出唯一的监听地址判定 `addressVerdict(hostname:)`（结果类型 `ServiceAddressVerdict`，保存/加载/启动共用）、loopback 判定、远程监听前置条件与“删除密码后回到 loopback”，`RemoteAccessSetup` 是设置界面的保存流程（密码只进 Keychain，配置只进 UserDefaults），`PasswordGenerator` 用 `SecRandomCopyBytes` 在本地生成不低于 24 位、含大小写字母数字符号的密码，`SecretScrubbing` 在展示前移除已知秘密。

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
- `ComponentInstallationDetector`：组件安装识别的命令执行（`CommandRunning`）、磁盘访问（`DependencyFileSystemProbing`）、`environment` 与 `homeDirectory` 都可注入；测试用临时目录夹具 + 假命令回答覆盖多跳/悬空符号链接、nvm 与 npm 全局共存、Homebrew、git checkout 与降级路径，不执行真实 npm/pi/pi-web。
- 更新检查（GitHub #17 / #18）：`UpdateHTTPClient`（生产 `URLSessionUpdateHTTPClient`；测试用记录请求并返回构造响应的替身）、`UpdateClock`（假时钟推进时间）、`UpdateCheckScheduling`（测试立即执行检查主体与回调，并记录/手动触发周期计时器，不使用真实 sleep）、`UpdateCacheStoring`（内存替身或临时目录文件存储）、`UpdateCheckPreferences`（策略 + alpha.3 预留位）与 `UpdateIgnoredVersions`（忽略版本）都可注入；因此测试不联网、不写真实 Application Support/UserDefaults。

`WebViewController` 通过构造参数接收 service URL、端口和 `windowProvider` 闭包（保存面板、打开面板和查找栏需要窗口），所以 `AppDelegate` 不持有 WebKit 状态。

尚未实现（后续 issue 范围）：

- 更新计划与受限安装（GitHub #20–#23）。版本检查与设置（#17、#18）已经实现，见下文“更新检查与缓存”；当前应用只提示版本，不下载、不安装，也没有任何更新执行路径（alpha.3 预留设置位同样不会触发安装）。

`DiagnosticsCollector` 只负责文本组装（调用方仍然只传入可公开的字段，密码等秘密不会进入输入）；脱敏由注入的 `LogRedactor` 在导出时统一完成，见 [日志与诊断导出](logging-and-diagnostics.md)。

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

`DependencyFinding.status` 取值：`ok`、`missing`、`outdated`（Node.js 低于最低版本，或 macOS 低于 14）、`unknown`（版本无法解析）。`confidence` 取整条结论各项证据里最弱的一项：探针直接确认是 `verified`，只能由候选路径或路径前缀推断是 `inferred`（pi-web 的 package.json `name` 与预期不符也计为 `inferred`），没有可用证据是 `unknown`。诊断项的安装来源按固定优先级推断：Homebrew Cellar（verified）→ npm 前缀 `lib/node_modules`（verified）→ npm 前缀 `bin`（inferred）→ `~/.npm-global`（inferred）→ Homebrew 前缀（inferred）→ 用户目录（inferred）→ unknown。`remediationID` 只指向 `InstallCommandManifest` 的静态条目。

报告里的组件安装模型（`ComponentInstallation`，GitHub #16）单独用一套更严格的证据组合规则（`ComponentSourceResolver`），诊断项的来源优先级保持不变：只在真实路径命中 `/opt/homebrew`/`/usr/local` 的 `Cellar` 或 `opt` 结构时才是 `homebrew`；`nvm`/`mise` 需要路径段（如 `versions/node/<版本>`）与环境标记（`NVM_DIR`/`MISE_DATA_DIR` 或对应的安装目录段）同时成立；`gitCheckout` 需要在包目录里找到 `.git`（文件或目录）；`npmGlobal`/`pnpmGlobal` 只认 `npm root -g` / `pnpm root -g` 的输出前缀；没有任何组合命中时来源为 `unknown`，并总是带一条“未验证原因：…”证据行。仅凭 `/opt/homebrew/bin`、`~/.npm-global`、`/lib/node_modules` 这类前缀或弱证据最多只能给出 `inferred`，`verified` 必须来自直接证据；`suggestedCommand` 只在来源为 npm/pnpm 全局且可信度为 `verified` 时从静态清单取值，其它来源一律只给指引文字。

版本证据必须与报告的路径同源：Node.js 候选路径（含登录 shell 的 `command -v`）存在时只采信它自己的 `--version`，即使它不可运行也不会用 PATH 上另一个 node 的版本来放行；只有候选路径完全不存在时才按进程 PATH 重新解析（`/usr/bin/env node -p process.execPath`），并把真正产出该版本的可执行路径记入报告，解析不出可执行路径就只报 `unknown`。系统项在 `uname` 失败（`machineArchitecture()` 为 `"unknown"`）时 `confidence` 降为 `unknown`，不再声称已验证；系统项本就不阻塞启动。

门控与路由结果：

- 路由 `mainWindow`：与拆分前一致——显示“正在检查 Pi Web 服务…”，调用 `serviceManager.startAtLaunch()`；诊断窗口只在用户主动打开时显示。
- 路由 `diagnostics`：服务控件按 `ServiceControlState` 禁用（`.blocked` 时 start/stop/restart 全不可用），不调用 `startAtLaunch()`，WebView 显示诊断状态页（六个诊断项，每项都有状态、路径、版本、安装来源、可信度五个字段，缺失值用“未找到/未知”占位而不是省略整行）而不是服务地址，并打开/刷新诊断窗口。`.blocked` 时还会 `stopHealthMonitor()` 并把状态置为 stopped，避免健康检查把状态改回 running。
- “重新检测”只是重新运行一次 `DependencyChecker`（使用当前 `ServiceConfiguration.piWebPath`）；前置满足后立即打开门控、撤销控件禁用并进入主窗口，无需重启应用。“选择 pi-web 路径…”经 `NSOpenPanel` 选择文件，`PiWebPathSelection` 要求绝对路径、可执行，并且身份可核对（`--version` 能解析出版本，或沿真实路径向上找到的 package.json `name` 就是 `@agegr/pi-web`）：`/bin/echo` 这类可执行但不是 pi-web 的文件会被拒绝，失败时返回可读错误、配置不变；成功时经 `AppConfiguration` 写回 `ServiceConfiguration.piWebPath`，随后立即重新检测。身份证据由 `DependencyChecker.piWebIdentityEvidence(atPath:)` 收集，只执行 `--version` 并读 package.json 的 `name`，不安装、不联网。

`PI_WEB_DESKTOP_SMOKE=1` 在 `applicationDidFinishLaunching` 的第一个分支返回，因此启动 smoke 完全跳过依赖门控（不运行 checker、不等待后台结果），只验证窗口建立与退出路径。`PI_WEB_DESKTOP_SMOKE=diagnostics` 在另一个分支返回：它使用 `DiagnosticsSmokeFixture` 的确定性报告（固定探针，不执行命令、不读真实磁盘或 `~/.pi`、不绑定真实端口），跑真实的 `DiagnosticsRouting` 决策，渲染诊断状态页并建立诊断窗口，然后打印固定标记并以 0 退出；两者都不写真实 support 目录或 UserDefaults。

门控不只在菜单层生效：`ServiceManager.isDependencyGateOpen`（默认关闭，`AppDelegate` 在诊断期间保持关闭、结果通过后打开）是所有服务启动入口的硬前置。`startAtLaunch()`、`ensureServerIsRunning()`、`startService()`、`startManagedService()`、`reloadAfterConfigurationChange()`、启动轮询（`pollUntilReady()`）和健康检查在入口以及每个异步主队列回调执行前都重新确认门控，因此配置变更重载、启动失败重试、外部服务恢复和健康恢复都不能绕过诊断结果；门控关闭时既不启动子进程、不加载服务页，也不改变状态或报启动失败。诊断判定阻塞时 `AppDelegate` 还会调用 `stopHealthMonitor()`（健康轮询本身也在入口拒绝启动），避免健康检查把状态改回 `running`、把诊断页覆盖回服务页。

诊断文本只包含已脱敏的字段：Home 前缀替换为 `~`，URL 去掉 userinfo、query 和 fragment；不写入用户名、绝对 Home 路径、凭据、token 或查询参数。导出前整段文本经过与日志、错误消息、环境变量/命令行展示共用的 `LogRedactor`（规则见 [日志与诊断导出](logging-and-diagnostics.md)）。Pi 配置目录只报告路径（`~/.pi/agent`）与“存在/可读”状态：既不做目录列表，也不读取目录内任何文件，认证内容永远不会进入报告。

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

GitHub #17 的版本检查在应用运行期间只做只读查询，不下载、不安装、不修改服务配置；应用退出后不再检查（不安装 LaunchAgent）。GitHub #18 在同一模型上加了逐类策略、忽略版本、状态显示与 alpha.3 预留设置位。

- 设置模型：`UpdateCheckPolicy` 只有一份允许集合定义（`allowed(for:)`）——桌面应用 / Pi CLI / Pi Web 允许 `off` / `daily` / `weekly`（默认 `daily`），Pi 扩展包允许 `off` / `checkAndNotify`（默认）/ `askBeforeUpdate`。`UpdateCheckPreferences` 是四类策略（始终包含全部分类，非法组合写入时拒绝）加 alpha.3 预留布尔的纯值类型；`UpdateCheckIntervals` 把策略映射到秒数（每日 24 小时、每周 7 天、扩展包 7 天，`off` → nil），测试注入更短的值即可用假时钟断言周期。
- 调度一致性：`UpdateChecker.restartTimers()` 只为策略非 `off` 的分类创建计时器（相同间隔去重），`appendItem` 在到期判定时再读一次策略，因此关闭 → 不调度、不请求；设置变化时立即重建计时器。`applicationWillTerminate` 调用 `stop()` 取消全部计时器，此后的任何触发（包括 `checkNow`）都被忽略。应用不安装任何随时启动的组件（无 LaunchAgent），关掉应用就没有检查。
- 启动顺序：应用启动后立即检查一次：`AppDelegate.applicationDidFinishLaunching` 先用当时已知的应用版本启动 `UpdateChecker`，依赖诊断结束后 `startUpdateChecking(with:)` 用 `UpdateCheckInventory(components:)`（#16 的识别结果）补齐 Pi / Pi Web / 扩展包版本，并对还没有检查记录（本机版本未知因而不发请求）的对象立即补检。
- 迁移与默认值：`UpdateCheckSettingsMigration.resolve(values:report:)` 是纯函数，读键顺序是“新策略键 → 旧布尔键（GitHub #17 的 `updateChecks.*.enabled`）→ 出厂默认”；值无法识别（未知字符串、非法分类组合、非布尔值）时按默认处理并记录一条只含键名与结论的诊断行（不回显原值），由 `AppConfiguration.updateCheckPreferences(diagnostics:)` 把诊断送进应用日志。`save` 写新键时删除旧布尔键，避免两套值并存。
- 忽略版本：`UpdateIgnoredVersions` 按分类只存版本字符串与时间戳（单独键，不进入缓存文件），不含安装来源或路径；`UpdateChecker` 在判定为可更新时用精确字符串比较标记 `ignoredVersion`，`UpdateNotificationPlanner` 再次用同一份记录过滤，因此忽略只抑制那一个版本，上游发布更高版本时重新进入提示名单，也不存在版本锁定或降级。
- 状态与提示：`UpdateCategoryStatusBuilder` 从注入的缓存、结果与设置算出四类状态（最近检查、结果、忽略版本、下次检查），并随 `UpdateCheckSummary.categoryStatuses` 在主线程发布；诊断窗口与“更新检查偏好设置”窗口只渲染同一份数据（`UpdateStatusPresenter`）。提示走应用内 `NSAlert`（不用 `UNUserNotificationCenter`、不申请通知权限），同一版本在一次运行里最多提示一次，文案只含组件名与版本。
- alpha.3 预留设置位：`autoUpdatePiWebBeforeLaunch` 默认 `false`，`UpdateCheckPreferences.autoUpdateBeforeLaunchIsEffective` 在 alpha.2 恒为 `false`，检查器与调度器都不读它；打开只写入布尔值，请求、结果与调度与关闭时完全一致。界面与文档明确标注“尚未生效”，生效版本是 alpha.3。
- 请求边界：只发 GET；URL 只由 `UpdateEndpoint` 的两个工厂方法生成——`https://api.github.com/repos/Su-luoya/pi-web-desktop/releases?per_page=20` 与 `https://registry.npmjs.org/<包名>/latest`（作用域包的 `/` 编码为 `%2F`；包名复用 #16 的 `isPackageName` 校验，不合法就不发请求）。请求头只允许 `Accept: application/json`、固定 `User-Agent`（应用名 + 版本 + bundle identifier，来自 `UpdateCheckIdentity.current`）与 `If-None-Match` / `If-Modified-Since`；`UpdateHTTPRequest.sanitized()` 丢弃白名单外的头，生产客户端再用 `URLSessionConfiguration.ephemeral` + `httpShouldSetCookies = false` + `httpCookieStorage = nil` + `urlCredentialStorage = nil` 保证不发 cookie、不读写凭据，并通过 `willPerformHTTPRedirection` 拒绝所有重定向（跨主机请求因此不可能发生）。响应头只保留 `etag` / `last-modified` / `content-type`。
- 可信度与比较：`SemanticVersion` 按 SemVer 2.0.0 §11 比较预发布标识符（数字标识符按数值，`alpha.2 < alpha.10 < beta.1 < 1.0.0`）。只有响应来自预期主机且结构可解析时才把上游版本记为 `verified`；网络失败、超时、取消、429 与 5xx 沿用 TTL 内的上次成功结果（`freshness = cached`），超过 TTL 或从未成功则 `unknown`；解析失败、结构异常、重定向或最终主机不在白名单内一律 `unknown`，但保留上一次成功结果（含 etag）供下次条件请求；本机版本未知或包名不合法时不发请求，结果为 `unknown` 并给出原因。
- 缓存：`UpdateCheckCacheFileStore` 把结果写到 `AppPaths.updateCheckCacheURL`（`~/Library/Application Support/Pi Web Desktop/update-check-cache.json`，独立文件，`schemaVersion = 1`，最多 200 条）。结构只有目标 id、分类、包名、`lastAttemptAt` / `lastSuccessAt`、`etag` / `lastModified`、`latestVersion`、`status` / `confidence` / `failure` / `httpStatusCode`：不含凭据、cookies、会话、URL、响应体或诊断内容；读失败或 schema 不匹配按空缓存处理（重新发起普通 GET），写失败静默，不影响检查结果、服务与退出路径。
- 失败隔离：`UpdateChecker` 不持有 `ServiceManager` 或任何服务状态引用，也没有安装、下载或执行路径；失败只更新 `UpdateCheckSummary`、状态行与（手动检查时）提示框。日志只写一条计数行（可用更新 / 无法确定 / 检查总数），不含 URL、包名列表或响应内容。
- 请求边界：只发 GET；URL 只由 `UpdateEndpoint` 的两个工厂方法生成——`https://api.github.com/repos/Su-luoya/pi-web-desktop/releases?per_page=20` 与 `https://registry.npmjs.org/<包名>/latest`（作用域包的 `/` 编码为 `%2F`；包名复用 #16 的 `isPackageName` 校验，不合法就不发请求）。请求头只允许 `Accept: application/json`、固定 `User-Agent`（应用名 + 版本 + bundle identifier，来自 `UpdateCheckIdentity.current`）与 `If-None-Match` / `If-Modified-Since`；`UpdateHTTPRequest.sanitized()` 丢弃白名单外的头，生产客户端再用 `URLSessionConfiguration.ephemeral` + `httpShouldSetCookies = false` + `httpCookieStorage = nil` + `urlCredentialStorage = nil` 保证不发 cookie、不读写凭据，并通过 `willPerformHTTPRedirection` 拒绝所有重定向（跨主机请求因此不可能发生）。响应头只保留 `etag` / `last-modified` / `content-type`。
- 可信度与比较：`SemanticVersion` 按 SemVer 2.0.0 §11 比较预发布标识符（数字标识符按数值，`alpha.2 < alpha.10 < beta.1 < 1.0.0`）。只有响应来自预期主机且结构可解析时才把上游版本记为 `verified`；网络失败、超时、取消、429 与 5xx 沿用 TTL 内的上次成功结果（`freshness = cached`），超过 TTL 或从未成功则 `unknown`；解析失败、结构异常、重定向或最终主机不在白名单内一律 `unknown`，但保留上一次成功结果（含 etag）供下次条件请求；本机版本未知或包名不合法时不发请求，结果为 `unknown` 并给出原因。
- 缓存：`UpdateCheckCacheFileStore` 把结果写到 `AppPaths.updateCheckCacheURL`（`~/Library/Application Support/Pi Web Desktop/update-check-cache.json`，独立文件，`schemaVersion = 1`，最多 200 条）。结构只有目标 id、分类、包名、`lastAttemptAt` / `lastSuccessAt`、`etag` / `lastModified`、`latestVersion`、`status` / `confidence` / `failure` / `httpStatusCode`：不含凭据、cookies、会话、URL、响应体或诊断内容；读失败或 schema 不匹配按空缓存处理（重新发起普通 GET），写失败静默，不影响检查结果、服务与退出路径。
- 失败隔离：`UpdateChecker` 不持有 `ServiceManager` 或任何服务状态引用，也没有安装、下载或执行路径；失败只更新 `UpdateCheckSummary`、状态行与（手动检查时）提示框。日志只写一条计数行（可用更新 / 无法确定 / 检查总数），不含 URL、包名列表或响应内容。

## 数据位置

- 普通设置：UserDefaults（读写都经 `AppConfiguration`）。
- 远程访问密码：macOS Keychain（service = bundle identifier，account = `remote-access-password`，仅本文一处存储）。
- 运行状态和 PID：`~/Library/Application Support/Pi Web Desktop/`。
- 日志：`~/Library/Logs/Pi Web Desktop/`（`Pi Web Desktop.log` 与 `.1.log` … `.5.log`），应用执行按大小轮转，详见 [日志与诊断导出](logging-and-diagnostics.md)。
- 更新检查缓存（GitHub #17）：`~/Library/Application Support/Pi Web Desktop/update-check-cache.json`（只含版本、时间戳与条件请求字段，不含凭据、会话或诊断内容）；更新检查的策略、忽略版本与 alpha.3 预留位在 UserDefaults（`updateChecks.*`，见 [设置、工作目录与退出行为](settings-and-workspace.md)）。

设置分层、默认工作目录、退出行为与不可写目录的处理见 [docs/settings-and-workspace.md](settings-and-workspace.md)。

应用不读取、复制或修改 Pi 的认证文件。
