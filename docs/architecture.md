# 架构说明

## 产品边界

Pi Web Desktop 是独立的 macOS AppKit/WebKit companion app。它启动、管理并显示用户已经安装的 Pi Web 服务；它不 fork、不打包、不维护上游 `agegr/pi-web` 的 Web 服务代码。

## 组件边界

配置、进程检查和诊断文本（Issue #4 第一段）以及服务生命周期和 WebKit 交互（Issue #4 第二段）都已经从 `Sources/PiWebApp.swift` 移出；默认值、用户可见行为、菜单和窗口布局不变。

已实现：

- `AppDelegate`（`Sources/PiWebApp.swift`）：应用生命周期、菜单、窗口布局、状态栏菜单项、屏幕变化、退出确认、设置窗口协调和 smoke 启动分支。服务动作转发给 `ServiceManager`，WebKit 动作转发给 `WebViewController`；`AppDelegate` 里不再有 `Process()` 启动点，也不再有 WebKit 代理方法实现。
- `ServiceManager`（`Sources/ServiceManager.swift`）：服务生命周期状态机——启动、停止、重启、启动轮询与重试、4 秒健康检查、日志文件句柄与轮转、`service.pid` 写入与清理、服务所有权判定、退出行为（保持运行 / 退出并停止）。对外只暴露 `onStateChange`、`onLoadPage`、`onPageMessage`、`onStartupFailure` 回调和动作方法，不接触 AppKit。
- `WebViewController`（`Sources/WebViewController.swift`）：`WKWebView` 创建与配置、导航策略、下载、外部链接、查找栏、缩放和加载/错误状态页；通过 `onNavigationFailure`（以及 `onDownloadStarted`）回调把结果交给 `AppDelegate`，窗口由 `windowProvider` 闭包注入。
- `WebViewNavigationPolicy`（`Sources/WebViewNavigationPolicy.swift`）：本地/外链 URL 判定（`127.0.0.1`/`localhost`/`::1` 加配置端口；`about`/`blob`/`data` 视为内联），不依赖 Cocoa/WebKit，可在 unhosted 测试目标里直接测试。
- `AppConfiguration`：support 目录、日志目录、工作目录、PID 与实例锁文件路径、UserDefaults 服务配置读写；支持注入 support/log 根目录，并为 smoke 运行派生 `$TMPDIR` 下的临时目录。
- `ProcessInspector`：`ps`/`lsof` 命令、监听端口 PID、托管 PID 判定和进程描述；命令执行通过 `CommandRunning` 注入，解析规则是不访问进程的纯函数。
- `DiagnosticsCollector`：把调用方已收集的版本、地址、状态、PID、进程描述和路径组装为诊断文本，自身不执行命令、不读磁盘。
- `PreferencesWindowController`：用户设置界面；保存后由 `AppDelegate` 经 `AppConfiguration` 写回 UserDefaults。

### 注入点

`ServiceManager` 的每个副作用都经过注入的依赖，测试因此不接触真实进程、定时器或网络：

- `CommandRunning`：`ps`/`lsof`/`kill` 等命令；`SystemCommandRunner` 是唯一真实实现。
- `ProcessInspector`：监听 PID、进程存活判断、托管 PID 记录校验；其中 `processIsAlive` 闭包可注入，测试里完全不看真实进程。
- `ServiceLaunching`：全项目唯一启动 `Process` 的地方（`SystemServiceLauncher`）；测试用假实现断言完整命令行与环境变量。
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

应用启动服务时只把子进程 PID 写入 `service.pid`；应用重启后必须验证该记录对应的进程仍然存活、且命令行看起来是本项目的 `pi-web`，否则按外部服务处理。任何一项不匹配都只删除记录，不向对应 PID 发送信号。端口上存在名为 `pi-web` 的进程不足以证明应用拥有它。外部服务只连接和显示，不由应用停止或重启。

更完整的进程记录（启动时间、解析后的 executable、参数摘要、实例标识）尚未实现，属于后续 issue 范围。

## 网络边界

默认监听 `127.0.0.1`。远程访问需要用户显式配置受信任的加密隧道或 HTTPS 反向代理，并设置 Pi Web 密码。桌面应用不把密码写入 UserDefaults、日志或诊断信息。

## 数据位置

- 普通设置：UserDefaults（读写都经 `AppConfiguration`）。
- 远程访问密码：macOS Keychain。
- 运行状态和 PID：`~/Library/Application Support/Pi Web Desktop/`。
- 日志：`~/Library/Logs/Pi Web Desktop.log`，应用执行轮转。

应用不读取、复制或修改 Pi 的认证文件。
