# 隐私说明

本政策只覆盖 Pi Web Desktop 应用本体（含仓库内的构建与安装脚本）在本机处理的数据。Pi Web 服务、Pi CLI、Node.js 与 npm 由各自上游提供，它们的数据处理不属于本仓库范围；上游归属与支持矩阵见 [README](../README.md)。

## 无遥测

Pi Web Desktop 不收集或上传遥测、使用统计、会话内容、认证信息或诊断报告。用户主动复制诊断信息或打开日志时，数据才离开本机，且用户负责在公开提交前脱敏。

## 版本检查

计划中的版本检查会访问相应上游服务，例如 GitHub Releases、npm registry 或 Pi 上游。请求会让这些服务看到网络请求的 IP 和 User-Agent。版本检查不是项目遥测，首版实现后会在首次启动说明中披露，并允许用户分别关闭。

## 本地数据

- 普通设置写入 UserDefaults。
- 远程访问密码只写入 macOS Keychain：`kSecClassGenericPassword`，service 为应用 bundle identifier，account 为 `remote-access-password`，可访问性为 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`（设备解锁一次后可读，且不随备份迁移到其他设备）。密码不进入 UserDefaults、命令行参数、日志文件、诊断文本或错误消息；设置界面只显示“已设置/未设置”，已保存的密码不会被读回显示。
- 只有远程模式（监听地址不是 loopback）启动托管服务时，密码才经子进程环境变量 `PI_WEB_PASSWORD` 传给 pi-web；loopback 模式不注入，并会清除继承来的同名变量。
- 删除 Keychain 密码条目会立即关闭远程模式：监听地址回到 `127.0.0.1` 并更新配置；若密码是在服务运行期间被删除或变成不可读，应用会先停止本应用启动且仍可验证所有权的远程进程组（外部服务不发信号），再把配置收回到 `127.0.0.1` 并显示可读提示。
- 运行状态写入 `~/Library/Application Support/Pi Web Desktop/`。
- 日志写入 `~/Library/Logs/Pi Web Desktop/Pi Web Desktop.log`（见 `Sources/AppPaths.swift`），超过 10 MB 轮转为 `.1.log` … `.5.log`。写入日志的每一行、错误消息、环境变量与命令行展示、诊断导出都经过同一个 `LogRedactor` 实例；规则与边界见 [日志与诊断导出](logging-and-diagnostics.md)。
- `WKWebView` 使用系统默认的持久化网站数据存储：`Sources/WebViewController.swift:37` 设置 `configuration.websiteDataStore = .default()`，`Sources/` 里没有任何 `WKWebsiteDataStore` 的删除调用。WebKit 因此会以 bundle identifier 为键，在应用自己的 UserDefaults/Application Support 之外持久化网站数据：`~/Library/WebKit/io.github.su-luoya.pi-web-desktop/WebsiteData/`（本机观察到 `Default/`、`IndexedDB/`、`LocalStorage/`、`SearchHistory/`、`ResourceLoadStatistics/`、`EnhancedSecurity/` 等子目录）和 `~/Library/Caches/io.github.su-luoya.pi-web-desktop/WebKit/`（观察到 `NetworkCache/`、`CacheStorage/`、`ServiceWorkers/`、`HSTS/`、`AlternativeServices/`）。这些文件（WebKit 保存的 cookies、缓存、local storage、IndexedDB、Service Worker 记录等，具体取决于服务页面和 WebKit 版本；本机未在 `~/Library/Cookies/` 或 `~/Library/HTTPStorages/` 下观察到属于本 bundle id 的独立文件）由 WebKit 管理，应用自身不读取也不解析它们。当前构建未启用 App Sandbox，所以路径就在用户的 `~/Library` 下，而不是沙盒容器里。
- 应用不读取、复制或迁移 `~/.pi/agent/auth.json` 等 Pi 认证内容。
- 首次启动诊断只检查 `~/.pi/agent` 是否存在与可读（不列目录、不读取任何文件），报告里只出现脱敏后的路径 `~/.pi/agent`。
- 用户在诊断窗口选择 pi-web 路径时，只对该文件做两件本地只读的事：执行 `--version`、向上查找并读取 package.json 的 `name`（不安装、不联网、不读取其他文件）。

## 本地数据一览与删除

| 数据 | 位置 | 删除方式 |
| --- | --- | --- |
| 服务配置、首次设置状态、窗口位置 | UserDefaults（domain 为 bundle identifier `io.github.su-luoya.pi-web-desktop`） | 先 `defaults read io.github.su-luoya.pi-web-desktop` 确认内容，再 `defaults delete io.github.su-luoya.pi-web-desktop` |
| 运行状态与所有权记录 | `~/Library/Application Support/Pi Web Desktop/` | 退出应用后删除该目录 |
| 日志（含轮转文件） | `~/Library/Logs/Pi Web Desktop/`（`Pi Web Desktop.log` 与 `.1.log` … `.5.log`） | 退出应用后删除该目录 |
| 远程访问密码 | 登录 Keychain；service 为 bundle identifier，account 为 `remote-access-password` | 在应用里点“删除密码”，或 `security delete-generic-password -s io.github.su-luoya.pi-web-desktop -a remote-access-password` |
| WebKit 持久化网站数据 | `~/Library/WebKit/io.github.su-luoya.pi-web-desktop/`、`~/Library/Caches/io.github.su-luoya.pi-web-desktop/` | 应用当前没有“清空网站数据”入口，只能退出应用后手动删除：`rm -rf "$HOME/Library/WebKit/io.github.su-luoya.pi-web-desktop" "$HOME/Library/Caches/io.github.su-luoya.pi-web-desktop"` |

删除以上任何一项都不会影响 Pi Web、Pi CLI 或 Node.js 自身的数据。除上表位置外，应用自身不写其他位置；WebKit 的持久化网站数据由系统框架按 bundle id 写入，不在应用自己的 Application Support 目录或 UserDefaults 里，删除 Keychain 密码或删除应用本身都不会自动清除它。`Scripts/smoke.sh` 只把应用自己的 support 目录和日志放进临时目录，不写 UserDefaults、Application Support 和 Logs，但仍会创建默认的 `WKWebView`，所以不隔离上面那两处 WebKit 数据（实测 smoke 会更新其文件 mtime/size，见 [开发说明](development.md)）。

## 诊断脱敏

公开 Issue 或 PR 不得包含密码、token、API key、代理凭据、查询参数、用户名、Home 路径、私人主机名或完整私有日志。日志行、错误消息、环境变量与命令行展示、诊断导出共用 `Sources/LogRedactor.swift` 里的同一个实例，至少覆盖：URL 查询串整体替换、`Authorization:` 头、`Bearer <token>`、`token=`/`password=`/`secret=`/`api_key=`/`apikey=` 形式的键值（含 JSON 与 `PI_WEB_PASSWORD`）、JWT 形态字符串、代理凭据（`scheme://user:pass@host`）、Home 路径（包含非当前用户的以 `/Users` 开头的路径，替换为 `~`）、私钥头与私钥块；多行输入逐行处理。菜单“复制诊断”与诊断窗口的复制按钮在写入剪贴板前会弹出脱敏提醒，说明文本已按规则脱敏、但公开粘贴前仍需自行检查。完整规则表与诊断导出字段见 [日志与诊断导出](logging-and-diagnostics.md)。

脱敏不替代用户提交前的自查。

## 隐私相关的仓库约束

- 文档、模板与默认配置里不得出现个人主机名、私有网络地址、凭据或以 `/Users` 开头的主目录绝对路径。
- 仓库现有的自动文本检查能覆盖的范围有限：`./Scripts/check-identity.sh:433-446` 只用它的固定模式集（小写的私有 VPN 主机名、tailnet DNS 后缀、CGNAT 私网地址段、以 `/Users` 开头的路径、固定本地代理端点，以及 xcconfig 之外的 `MARKETING_VERSION` 字面值）；CI 的 `Check for accidental personal data` 步骤（`.github/workflows/build.yml:54-56`）只跑一条 `git grep` 字面量检查。两者都**不是**通用 secret scanner，任意凭据、token、私钥或未被列入的私网地址都不会被发现；通用 secret scan 尚未实现，属 [#11](https://github.com/Su-luoya/pi-web-desktop/issues/11) 的范围。
- 诊断文本只包含本政策与 [日志与诊断导出](logging-and-diagnostics.md) 列出的字段，且全部经过同一个 `LogRedactor`；脱敏不替代用户提交前的自查。应用不读取、不复制、不上传 Pi 认证文件与日志。
- 新增任何联网行为或新增本地数据位置前，必须先更新本文件，并在同一个 PR 里说明用户可见的开关与删除方式。

## 远程访问

默认服务只监听 loopback（`127.0.0.1`）。非 loopback 监听地址必须在 Keychain 中存在非空密码：缺少密码时配置无法保存、服务也无法启动，运行中的远程托管服务在密码被删除后会立即停止并回到 loopback。密码认证不等于传输加密；远程访问需要用户配置受信任的加密隧道或 HTTPS 反向代理。项目文档不会把个人主机名或其他私人网络地址写入默认配置，也不会把“所有网络接口”地址（如 `0.0.0.0`）作为默认值或允许用户在界面里保存。

“生成高强度密码”完全在本地完成（`SecRandomCopyBytes`），长度不低于 24，字符集包含大小写字母、数字和符号，不联网、不引入依赖、不做密码同步。诊断文本里只出现密码状态（已设置/未设置），不出现密码值、密码长度或 Keychain 原始数据。
