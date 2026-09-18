# 架构说明

## 产品边界

Pi Web Desktop 是独立的 macOS AppKit/WebKit companion app。它启动、管理并显示用户已经安装的 Pi Web 服务；它不 fork、不打包、不维护上游 `agegr/pi-web` 的 Web 服务代码。

## 组件边界

配置、进程检查和诊断文本（Issue #4 第一段）以及服务生命周期和 WebKit 交互（Issue #4 第二段）都已经从 `Sources/PiWebApp.swift` 移出；默认值、用户可见行为、菜单和窗口布局不变。

已实现：

- `AppDelegate`（`Sources/PiWebApp.swift`）：应用生命周期、菜单、窗口布局、状态栏菜单项、屏幕变化、退出确认、设置窗口协调和 smoke 启动分支。服务动作转发给 `ServiceManager`，WebKit 动作转发给 `WebViewController`；`AppDelegate` 里不再有 `Process()` 启动点，也不再有 WebKit 代理方法实现。
- `ServiceManager`（`Sources/ServiceManager.swift`）：服务生命周期状态机——启动、停止、重启、启动轮询与重试、4 秒健康检查、日志文件句柄与轮转、可验证的服务所有权记录写入与校验、退出行为（保持运行 / 退出并停止）。对外只暴露 `onStateChange`、`onLoadPage`、`onPageMessage`、`onStartupFailure` 回调和动作方法，不接触 AppKit。停止只对已验证的托管进程组发送信号；外部服务只读。
- `ServiceOwnership`（`Sources/ServiceOwnership.swift`）：所有权记录（JSON 字段、规范化命令文本的 SHA-256 摘要、可执行标识来源）、记录文件存取（`ServiceOwnershipStoring`）、逐项校验的纯逻辑（`ServiceOwnershipVerifier`）和只按进程组发送信号的接口（`ServiceSignaling` / `POSIXServiceSignaler`）。
- `WebViewController`（`Sources/WebViewController.swift`）：`WKWebView` 创建与配置、导航策略、下载、外部链接、查找栏、缩放和加载/错误状态页；通过 `onNavigationFailure`（以及 `onDownloadStarted`）回调把结果交给 `AppDelegate`，窗口由 `windowProvider` 闭包注入。
- `WebViewNavigationPolicy`（`Sources/WebViewNavigationPolicy.swift`）：本地/外链 URL 判定（`127.0.0.1`/`localhost`/`::1` 加配置端口；`about`/`blob`/`data` 视为内联），不依赖 Cocoa/WebKit，可在 unhosted 测试目标里直接测试。
- `AppConfiguration`：support 目录、日志目录、工作目录、`service-owner.json` / 旧 `service.pid` / app PID / 实例锁文件路径、UserDefaults 服务配置读写；支持注入 support/log 根目录，并为 smoke 运行派生 `$TMPDIR` 下的临时目录。
- `ProcessInspector`：`ps`/`lsof` 命令、监听端口 PID、进程存活判断、`pgid`/`lstart`/`comm`/`args` 事实读取和进程描述；命令执行通过 `CommandRunning` 注入，可执行标识读取（`proc_pidpath`）也可注入，解析规则是不访问进程的纯函数。它只报告事实，不做所有权判定。
- `DiagnosticsCollector`：把调用方已收集的版本、地址、状态、PID、进程描述和路径组装为诊断文本，自身不执行命令、不读磁盘。
- `PreferencesWindowController`：用户设置界面；保存后由 `AppDelegate` 经 `AppConfiguration` 写回 UserDefaults。

### 注入点

`ServiceManager` 的每个副作用都经过注入的依赖，测试因此不接触真实进程、定时器或网络：

- `CommandRunning`：`ps`/`lsof`/`zsh` 等命令；`SystemCommandRunner` 是唯一真实实现。
- `ProcessInspector`：监听 PID、进程存活判断、`pgid`/`lstart`/`comm` 事实读取；其中 `processIsAlive` 闭包可注入，测试里完全不看真实进程。
- `ServiceLaunching`：全项目唯一启动服务进程的地方（`SystemServiceLauncher`）。生产实现用 `posix_spawn` + `POSIX_SPAWN_SETPGROUP` 让子进程成为独立进程组的组长，并保留日志重定向、环境变量、工作目录和 stdin 为 `/dev/null`；测试用假实现断言完整命令行与环境变量。
- `ServiceOwnershipStoring`：`service-owner.json` 的读写（`FileServiceOwnershipStore`）；测试可以注入写入失败的实现来验证“启动后写不进记录就终止刚启动的进程组”。
- `ServiceSignaling`：只提供“向进程组发送信号”和“进程组是否存活”两个方法（`POSIXServiceSignaler` 用 `kill(-pgid, ...)`）；接口里没有单 PID 发送方法，测试用假实现记录收到的组信号。
- `ServiceProbing`：启动轮询与健康检查用的 HTTP 探测（`URLSessionServiceProbe`，超时经参数注入）。
- `ServiceScheduling`：主队列/后台队列、延时、重复定时器和 `sleep` 的调度；测试里即时执行，不等待真实时间。
- `AppConfiguration`、`environment` 闭包与 `FileManager`：路径、子进程环境变量和文件操作。

`WebViewController` 通过构造参数接收 service URL、端口和 `windowProvider` 闭包（保存面板、打开面板和查找栏需要窗口），所以 `AppDelegate` 不持有 WebKit 状态。

尚未实现（后续 issue 范围）：

- `DependencyChecker`：Node.js、Pi、Pi Web、版本和安装来源诊断（目前查找 pi-web 可执行文件在 `ServiceManager.resolvePiWebPath()`，版本命令调用仍在 `AppDelegate` 的诊断动作里）。
- `UpdateCoordinator`：版本检查、更新计划、用户确认和受限安装。
- `KeychainStore`：保存远程访问密码，不把秘密写入普通设置、命令行、日志或诊断。

`DiagnosticsCollector` 只负责文本组装；脱敏由调用方保证——只传入上面列出的字段，不传入密码等秘密。

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

只有验证通过的记录才会收到信号：先向记录的进程组发送 `SIGTERM`，在 `stopPollAttempts`（40 × 0.1 秒）内等待进程组消失，仍存活才对同一进程组发送 `SIGKILL`。`ServiceSignaling` 接口只暴露进程组形式（`kill(-pgid, ...)`），因此不存在向单个 PID 发送信号的路径。外部服务或验证失败时不发送任何信号：`stopService()` 只在验证通过后才会把状态更新为已停止，找不到可验证记录时直接完成回调、保持当前状态（例如仍显示“正在运行（外部服务）”）并删除不匹配的记录；菜单的停止/重启动作仍然先显示原有的“这是外部启动的 Pi Web 服务”警告。`stopAllServices`（“退出并停止服务”）也只停止已验证的托管子进程，不再清理端口上的其他监听进程。

### 过期记录与应用重启

启动时（`startAtLaunch()` → `reconcileOwnershipRecord()`）会重新验证磁盘上的记录：进程已不存在、或记录来自上一次应用运行（`instanceID` 不同）时，只删除记录文件，绝不向对应 PID 发送信号；“退出但保持服务运行”留下的服务在下次启动时因此按外部服务处理。删除规则由 `ServiceOwnershipVerdict.shouldRemoveRecord` 决定：唯一保留记录的情况是 `ps` 事实暂时不可读，此时仍然不会发送信号，留待下次再验证。

## 网络边界

默认监听 `127.0.0.1`。远程访问需要用户显式配置受信任的加密隧道或 HTTPS 反向代理，并设置 Pi Web 密码。桌面应用不把密码写入 UserDefaults、日志或诊断信息。

## 数据位置

- 普通设置：UserDefaults（读写都经 `AppConfiguration`）。
- 远程访问密码：macOS Keychain。
- 运行状态和 PID：`~/Library/Application Support/Pi Web Desktop/`。
- 日志：`~/Library/Logs/Pi Web Desktop.log`，应用执行轮转。

应用不读取、复制或修改 Pi 的认证文件。
