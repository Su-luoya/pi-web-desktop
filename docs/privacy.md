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
- 日志写入 `~/Library/Logs/Pi Web Desktop.log` 并轮转。
- 应用不读取、复制或迁移 `~/.pi/agent/auth.json` 等 Pi 认证内容。
- 首次启动诊断只检查 `~/.pi/agent` 是否存在与可读（不列目录、不读取任何文件），报告里只出现脱敏后的路径 `~/.pi/agent`。
- 用户在诊断窗口选择 pi-web 路径时，只对该文件做两件本地只读的事：执行 `--version`、向上查找并读取 package.json 的 `name`（不安装、不联网、不读取其他文件）。

## 本地数据一览与删除

| 数据 | 位置 | 删除方式 |
| --- | --- | --- |
| 服务配置、首次设置状态、窗口位置 | UserDefaults（domain 为 bundle identifier `io.github.su-luoya.pi-web-desktop`） | 先 `defaults read io.github.su-luoya.pi-web-desktop` 确认内容，再 `defaults delete io.github.su-luoya.pi-web-desktop` |
| 运行状态与所有权记录 | `~/Library/Application Support/Pi Web Desktop/` | 退出应用后删除该目录 |
| 日志（含轮转文件） | `~/Library/Logs/Pi Web Desktop.log` | 退出应用后删除日志文件 |
| 远程访问密码 | 登录 Keychain；service 为 bundle identifier，account 为 `remote-access-password` | 在应用里点“删除密码”，或 `security delete-generic-password -s io.github.su-luoya.pi-web-desktop -a remote-access-password` |

删除以上任何一项都不会影响 Pi Web、Pi CLI 或 Node.js 自身的数据；应用运行时不写其他位置。删除 Keychain 密码会立即关闭远程模式并把监听地址回落到 loopback（见“远程访问”）。`Scripts/smoke.sh` 只在临时目录里运行，不会写上面任何一项。

## 诊断脱敏

公开 Issue 或 PR 不得包含密码、token、API key、代理凭据、查询参数、用户名、Home 路径、私人主机名或完整私有日志。诊断功能会尽量隐藏这些信息，但用户提交前仍必须检查复制内容。

## 隐私相关的仓库约束

- 文档、模板与默认配置里不得出现个人主机名、私有网络地址、凭据或以 `/Users` 开头的主目录绝对路径；`./Scripts/check-identity.sh` 与 CI 的 personal-data 扫描都会拒绝这些内容。
- 诊断文本只包含本政策列出的字段，且路径在离开检查器前已做 Home 脱敏；脱敏不替代用户提交前的自查。
- 新增任何联网行为或新增本地数据位置前，必须先更新本文件，并在同一个 PR 里说明用户可见的开关与删除方式。

## 远程访问

默认服务只监听 loopback（`127.0.0.1`）。非 loopback 监听地址必须在 Keychain 中存在非空密码：缺少密码时配置无法保存、服务也无法启动，运行中的远程托管服务在密码被删除后会立即停止并回到 loopback。密码认证不等于传输加密；远程访问需要用户配置受信任的加密隧道或 HTTPS 反向代理。项目文档不会把个人主机名或其他私人网络地址写入默认配置，也不会把“所有网络接口”地址（如 `0.0.0.0`）作为默认值或允许用户在界面里保存。

“生成高强度密码”完全在本地完成（`SecRandomCopyBytes`），长度不低于 24，字符集包含大小写字母、数字和符号，不联网、不引入依赖、不做密码同步。诊断文本里只出现密码状态（已设置/未设置），不出现密码值、密码长度或 Keychain 原始数据。
