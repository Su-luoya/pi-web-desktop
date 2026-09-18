# 架构说明

## 产品边界

Pi Web Desktop 是独立的 macOS AppKit/WebKit companion app。它启动、管理并显示用户已经安装的 Pi Web 服务；它不 fork、不打包、不维护上游 `agegr/pi-web` 的 Web 服务代码。

## 组件边界

当前源码仍处于拆分前的 alpha 基线。后续职责边界如下：

- `AppDelegate`：应用生命周期、菜单、窗口协调。
- `ServiceManager`：启动、停止、重启、健康检查和日志管道。
- `ProcessInspector`：进程、监听端口和托管实例所有权判断。
- `DependencyChecker`：Node.js、Pi、Pi Web、版本和安装来源诊断。
- `UpdateCoordinator`：版本检查、更新计划、用户确认和受限安装。
- `DiagnosticsCollector`：收集并脱敏诊断信息。
- `WebViewController`：WebKit 窗口和页面交互。
- `PreferencesWindowController`：用户设置和首次诊断向导。
- `AppConfiguration`：UserDefaults 配置及安全默认值。
- `KeychainStore`：保存远程访问密码，不把秘密写入普通设置、命令行、日志或诊断。

## 服务所有权

应用启动服务时记录 PID、启动时间、解析后的 executable、参数摘要、监听端口和实例标识。应用重启后必须验证记录和实际进程；任何关键字段不匹配都按外部服务处理。

PID 文件过期时只删除记录，不向对应 PID 发送信号。端口上存在名为 `pi-web` 的进程不足以证明应用拥有它。外部服务只连接和显示，不由应用停止或重启。

## 网络边界

默认监听 `127.0.0.1`。远程访问需要用户显式配置受信任的加密隧道或 HTTPS 反向代理，并设置 Pi Web 密码。桌面应用不把密码写入 UserDefaults、日志或诊断信息。

## 数据位置

- 普通设置：UserDefaults。
- 远程访问密码：macOS Keychain。
- 运行状态和 PID：`~/Library/Application Support/Pi Web Desktop/`。
- 日志：`~/Library/Logs/Pi Web Desktop.log`，应用执行轮转。

应用不读取、复制或修改 Pi 的认证文件。
