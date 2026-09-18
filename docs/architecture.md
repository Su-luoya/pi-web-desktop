# 架构说明

## 产品边界

Pi Web Desktop 是独立的 macOS AppKit/WebKit companion app。它启动、管理并显示用户已经安装的 Pi Web 服务；它不 fork、不打包、不维护上游 `agegr/pi-web` 的 Web 服务代码。

## 组件边界

配置、进程检查和诊断文本已经完成拆分（Issue #4 第一段）：`Sources/AppConfiguration.swift`、`Sources/ProcessInspector.swift`、`Sources/DiagnosticsCollector.swift` 从 `Sources/PiWebApp.swift` 移出，默认值与用户可见行为不变。`ServiceManager` 与 `WebViewController` 属于后续 task，本 task 不抽取。

已实现：

- `AppDelegate`：应用生命周期、菜单、窗口协调，以及暂未抽出的服务生命周期编排（启动、停止、重启、健康检查、日志管道）；smoke 启动分支也在这里。
- `AppConfiguration`：support 目录、日志目录、工作目录、PID 与实例锁文件路径、UserDefaults 服务配置读写；支持注入 support/log 根目录，并为 smoke 运行派生 `$TMPDIR` 下的临时目录。
- `ProcessInspector`：`ps`/`lsof` 命令、监听端口 PID、托管 PID 判定和进程描述；命令执行通过 `CommandRunning` 注入，解析规则是不访问进程的纯函数。
- `DiagnosticsCollector`：把调用方已收集的版本、地址、状态、PID、进程描述和路径组装为诊断文本，自身不执行命令、不读磁盘。
- `PreferencesWindowController`：用户设置界面；保存后由 `AppDelegate` 经 `AppConfiguration` 写回 UserDefaults。

后续 task（本 task 不实现）：

- `ServiceManager`：服务生命周期与日志管道（目前仍在 `AppDelegate`）。
- `WebViewController`：WebKit 窗口和页面交互（目前仍在 `AppDelegate`）。
- `DependencyChecker`：Node.js、Pi、Pi Web、版本和安装来源诊断（目前 `resolvePiWebPath` 与版本命令调用仍在 `AppDelegate`）。
- `UpdateCoordinator`：版本检查、更新计划、用户确认和受限安装。
- `KeychainStore`：保存远程访问密码，不把秘密写入普通设置、命令行、日志或诊断。

`DiagnosticsCollector` 只负责文本组装；脱敏由调用方保证——只传入上面列出的字段，不传入密码等秘密。

## 服务所有权

应用启动服务时记录 PID、启动时间、解析后的 executable、参数摘要、监听端口和实例标识。应用重启后必须验证记录和实际进程；任何关键字段不匹配都按外部服务处理。

PID 文件过期时只删除记录，不向对应 PID 发送信号。端口上存在名为 `pi-web` 的进程不足以证明应用拥有它。外部服务只连接和显示，不由应用停止或重启。

## 网络边界

默认监听 `127.0.0.1`。远程访问需要用户显式配置受信任的加密隧道或 HTTPS 反向代理，并设置 Pi Web 密码。桌面应用不把密码写入 UserDefaults、日志或诊断信息。

## 数据位置

- 普通设置：UserDefaults（读写都经 `AppConfiguration`）。
- 远程访问密码：macOS Keychain。
- 运行状态和 PID：`~/Library/Application Support/Pi Web Desktop/`。
- 日志：`~/Library/Logs/Pi Web Desktop.log`，应用执行轮转。

应用不读取、复制或修改 Pi 的认证文件。
