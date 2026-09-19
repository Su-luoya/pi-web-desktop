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
- `PiWebDesktopTests/ServiceConfigurationTests.swift`：默认退出行为与默认工作目录、既有键名、无法识别的退出行为回落为“询问”、工作目录进入运行时签名。
- `PiWebDesktopTests/WorkspaceDirectoryTests.swift`：默认目录首次使用时创建、自选目录不被静默重建、不存在/不是目录/不可写三种原因的校验与可读修复提示、状态页文本、设置窗口选择（相对路径、缺失、不可写被拒绝且配置不变，留空回到默认目录）。
- `PiWebDesktopTests/QuitPolicyTests.swift`：三种退出行为与三种确认选择的决策表、取消不停止服务、只有显式“退出并停止服务”才请求停止托管服务、任何行为都不停止外部服务。
- `PiWebDesktopTests/ServiceManagerTests.swift`：工作目录不可用时所有启动入口零启动零加载并给出可读提示、恢复后门控重新打开、启动前重新校验（自选目录被删后不重建且阻止启动；存在且可写的自选目录不被创建；默认目录缺失时仍创建；健康监控期间自选目录消失时受托管重启被拒绝）、三种退出行为（保持运行零信号、停止只对已验证进程组、外部服务零信号且状态不变）、关闭期间无后台轮询、校验失败的记录不被认领也不被发信号。
- `PiWebDesktopTests/ServiceOwnershipTests.swift`：重启认领判定表（只有 `.managed` 可认领，`instanceID` 不同、PID 复用、端口变化、`ps` 不可读等都停留在外部服务）。
