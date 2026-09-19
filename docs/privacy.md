# 隐私说明

本政策只覆盖 Pi Web Desktop 应用本体（含仓库内的构建与安装脚本）在本机处理的数据。Pi Web 服务、Pi CLI、Node.js 与 npm 由各自上游提供，它们的数据处理不属于本仓库范围；用户侧说明与上游归属见 [README](../README.md)，支持矩阵见[开发说明](development.md#支持矩阵与非承诺)。

## 无遥测

Pi Web Desktop 不收集或上传遥测、使用统计、会话内容、认证信息或诊断报告。除了下面的只读版本检查，应用不会主动向任何上游发送数据；用户主动复制诊断信息或打开日志时，数据才离开本机，且用户负责在公开提交前脱敏。

## 版本检查、提示与忽略版本

Pi Web Desktop 在应用运行期间做只读的版本查询，只提示、不下载、不安装任何东西。版本查询**不是项目遥测**：请求只用于比较“本机版本”与“上游最新版”，不携带使用数据、会话内容、认证信息或诊断报告。应用退出后不检查（不安装 LaunchAgent，也不在后台常驻）。唯一的例外是下面两个启动前自动更新（**默认关闭**）：它们只对来源为已验证的 npm 全局（Pi CLI 还允许 pnpm 全局）安装的组件执行一次受限更新，不改动桌面应用自身，也不涉及 Pi 扩展包——**Pi 扩展包永远不会在无人值守时更新**（见下面“扩展包更新需要用户确认”）。

- 访问的域名与请求内容：`api.github.com`（`GET /repos/Su-luoya/pi-web-desktop/releases?per_page=20`，桌面应用发布）与 `registry.npmjs.org`（`GET /<包名>/latest`，Pi CLI、Pi Web 与 `pi list` 得到的扩展包）。只有 GET + JSON 解析；`User-Agent` 固定为应用名 + 版本 + bundle identifier（来自应用自身的 Info.plist，不含用户名或主机名）。不发送 cookies、账号凭据、会话内容或诊断字段；`Cookie`、`Authorization` 这类头即使被误加也会在发出前丢弃；应用侧客户端不跟随重定向，因此请求不会落到这两个域名之外。响应只保留 `etag`、`last-modified` 与 `content-type`，`Set-Cookie` 等响应头不读取也不保存。
- 频率与设置：应用启动后立即检查一次。之后四类组件各自按设置复查，默认值与 [发布说明](releasing.md) 的 alpha.2 更新策略一致：桌面应用 / Pi CLI / Pi Web 默认“每日”（24 小时），可选“每周”或“关闭”；Pi 扩展包默认“检查并通知”（7 天，与 GitHub #17 的节奏相同），可选“询问后更新”或“关闭”。“询问后更新”同样只按 7 天复查，发现可用更新时询问用户是否更新（GitHub #22 起，用户在确认框里确认后才会执行一次 `pi update npm:<包名>`；未确认、取消或进程状态不确定时都不执行）；询问与确认本身不下载、不安装，只有下面两个启动前自动更新会（默认关闭，Pi Web 仅限已验证的 npm 全局安装，Pi CLI 仅限已验证的 npm/pnpm 全局安装且当次确认没有运行中的 Pi 进程）。
- 关闭与调度：关闭某一类后应用不再发起该类请求，也不为该类安排复查；四类全部关闭时不发任何请求。设置在“服务 → 更新检查设置 → 更新检查偏好设置…”里修改，键与默认值见下表与 [设置、工作目录与退出行为](settings-and-workspace.md)。
- 提示方式（取舍）：发现可用更新时使用应用内提示框（`NSAlert`），**不使用 `UNUserNotificationCenter`，也不申请系统通知权限**。取舍：应用内提示不需要额外权限、内容不会进入“通知中心”或被系统持久化、文案完全由应用控制且只含组件名与版本；代价是应用不在运行时不提示——应用本来也不在后台运行，因此这一点不降低现有隐私边界。提示内容不含本机路径、包名、安装来源、凭据或诊断内容。手动“检查更新…”显示完整结果；自动检查（启动 / 周期）对同一版本在一次运行里最多提示一次。
- 忽略版本：每类组件可以“忽略当前提示的版本”。忽略只抑制那一个具体版本，上游发布更高版本时会重新提示；忽略与安装来源无关，只保存版本字符串与时间戳（`updateChecks.<组件>.ignoredVersion` 与 `.ignoredVersionAt`），不实现任意版本锁定，也不实现降级。提示框与“更新检查偏好设置”窗口里的“忽略此版本”按钮都只记录忽略，不执行安装。
- 状态显示：诊断窗口与“更新检查偏好设置”窗口显示每类组件的最近检查时间、结果（最新 / 可更新 / 未知 / 失败）、被忽略版本与下次检查时间。
- 启动前自动更新 Pi Web（GitHub #20，默认关闭）：打开后，应用启动时（且只在本机 Pi Web 的来源为**已验证的 npm 全局安装**、目标版本为已验证且高于本机版本、服务未在运行时）执行一次 `npm install -g @agegr/pi-web@<版本>`。命令通过参数数组直接执行，**不使用 shell、不调用 `sudo`**；子进程环境只传白名单键（`PATH` / `HOME` / `TMPDIR` / `LANG` / `LC_ALL` / `LC_CTYPE`），因此 `PI_WEB_PASSWORD`、`NODE_OPTIONS`、`npm_config_*` 与代理变量都不会传递给安装器。安装用的是用户自己的 `npm` 与 `~/.npmrc`（应用不读它），所以这一步产生的网络请求与凭据由 npm 自己按用户的 npm 配置发出，应用不代发；默认 registry 是 `registry.npmjs.org`。安装后应用会重新检测版本并做健康检查，失败时只写持久警告与日志，**不会自动回滚**、不卸载也不重装。其它来源（pnpm、Homebrew、nvm/mise、git checkout、本地路径、未知）仍只显示更新命令，绝不自动安装。手动“立即更新 Pi Web…”同样只在设置打开且来源为已验证的 npm 全局安装时可用，并且必须先在确认框里确认（会展示可执行文件路径、参数与版本）。
- 启动前自动更新 Pi CLI 与运行进程保护（GitHub #21，默认关闭）：打开后，应用在拿到当次版本检查结果后（只在本机 Pi CLI 的来源为**已验证的 npm/pnpm 全局安装**、目标版本已验证且高于本机版本、并且当次进程检查确认**没有运行中的 Pi CLI** 时）执行一次 `pi update --self`。
  - **如何判断“有运行中的 Pi CLI”**：应用只读地枚举本机进程（`proc_listpids` / `proc_pidinfo` / `proc_pidpath`，脚本与进程标题靠 `sysctl KERN_PROCARGS2` 得到的 argv 判定），**不看、不写其它进程的任何内容**；判定只做精确的可执行名比较（`pi-web`、`pip`、`pi-helper` 不会命中）。只要有任何 Pi CLI 在运行、或者枚举/读取失败因而无法确认，应用就**不自动更新**（推迟到下次启动或下一次判定），并把原因写入日志与状态页。
  - **不发信号**：应用从不向 Pi 进程（或任何其它进程）发送 `SIGTERM`/`SIGKILL`，也不结束、暂停或接管任何 Pi 会话；超时和应用退出都只是“不再等这个子进程”，命令按自己的方式结束。
  - **命令与子进程环境**：只执行官方自更新参数数组 `update --self`（参数数组直接执行，**不使用 shell、不调用 `sudo`**，不拼接 npm/pnpm 命令）；子进程环境只保留白名单键（`PATH` / `HOME` / `TMPDIR` / `LANG` / `LC_ALL` / `LC_CTYPE`），因此凭据类变量（例如 `PI_WEB_PASSWORD`）、`NODE_OPTIONS`、`npm_config_*` 与代理变量都不会传递。这一步的网络请求与凭据由用户自己的 `pi` 按它自己的配置发出，应用不代发（也不读取 `~/.pi` 的认证内容）。
  - **只读磁盘的部分**：判断“名为 `pi` 的脚本路径是否真的可执行”只查一个可执行位（读文件元数据），不读文件内容、不写任何文件。
  - **记录的内容**：进程记录（诊断页与手动更新的确认框）只包含 PID、父进程 PID、启动时间、判定依据、**已脱敏**的镜像路径与**已脱敏且有长度上限**的命令摘要；凭据（`token=` / `password=` / `api_key=` 等形状、URL 查询串、`Bearer`）在进入记录前就换成占位符，Home 路径换成 `~`，`KEY=VALUE` 环境片段直接丢弃。执行结果只记录退出码、耗时与**脱敏后**的输出尾部（截断），失败只写持久警告（类别、旧/新/目标版本、原因、时间戳），**不含路径、环境变量值、凭据或完整命令输出**。手动入口需先在确认框里看到这些信息并显式确认；自动路径失败或版本未变时同样只写日志与告警，**不会自动回滚**、不降级，也不做无上限重试（一次运行最多一次）。
- 扩展包更新需要用户确认（GitHub #22）：Pi 扩展包策略只有“关闭 / 检查并通知 / 询问后更新”，**没有“自动更新”选项**。“询问后更新”也只是按 7 天复查、发现更新时弹确认框，用户在确认框里显式确认后才执行一次 `pi update npm:<包名>`；未确认、点“取消”或直接关闭对话框都不执行，也不改任何状态。执行入口只在来源为**已验证的 npm 全局安装**、目标版本已验证且更高、且当次进程检查确认没有运行中的 Pi 进程时出现；其它来源（pnpm、Homebrew、nvm/mise、git checkout、本地路径、未知）只显示官方命令文本 `pi update --extensions`，不提供可点的执行入口。
  - **命令与子进程环境**：只执行官方参数数组 `["update", "npm:<包名>"]`（参数数组直接执行，**不使用 shell、不调用 `sudo`**，不拼接 npm/pnpm 命令）；子进程环境只保留白名单键（`PATH` / `HOME` / `TMPDIR` / `LANG` / `LC_ALL` / `LC_CTYPE`），因此凭据类变量（例如 `PI_WEB_PASSWORD`）、`NODE_OPTIONS`、`npm_config_*` 与代理变量都不会传递。这一步的网络请求与凭据由用户自己的 `pi` 按它自己的配置发出，应用不代发，也不读取 `~/.pi` 的认证内容或 npm 配置。
  - **不发信号、不接管会话**：执行前用同一套只读进程检查再确认一次，有运行中的 Pi 进程或状态不确定就**拒绝执行**；应用从不发送 `SIGTERM`/`SIGKILL`，也不结束、暂停或接管任何 Pi 进程，超时与应用退出只是不再等待子进程。
  - **记录的内容**：确认框与诊断只包含包名、当前/目标版本、来源与可信度、脱敏后的可执行文件路径（Home → `~`）、参数数组与每个进程的**已脱敏且长度受限**的命令摘要；执行结果只记录退出码、耗时与截断后的输出尾部（经 `LogRedactor`），失败只写持久告警（类别、包名、旧/新/目标版本、固定原因文案与时间戳），**不含环境变量值、凭据或完整命令输出**；拒绝原因同样只写入日志与诊断且不含凭据。不自动重试、不声称回滚，也不修改 Pi 自己的配置文件。
- 结果缓存：`~/Library/Application Support/Pi Web Desktop/update-check-cache.json`（见下表），只含版本号、时间戳与 etag/条件请求字段；**不含**凭据、cookies、会话、URL、响应体或诊断内容。删除该文件只会让下一次检查重新发起普通 GET。
- 可信度：只有响应来自预期域名且结构可解析时才将上游版本标为“已验证”；网络失败、超时、限流（HTTP 429）与 5xx 沿用 24 小时/7 天内上一次成功结果并标注为缓存结果；超过有效期、响应无法解析或来自非预期主机时显示“无法确定”。检查失败只影响提示文案，不影响正在运行的服务，也不改变服务状态。

上游服务会看到请求的源 IP、`User-Agent` 与请求时间，并按各自隐私政策处理这些接入日志；这不属于本仓库能控制的范围。本仓库不代理、不中转这些请求，也不使用代理或镜像端点。

## 本地数据

- 普通设置写入 UserDefaults。
- 远程访问密码只写入 macOS Keychain：`kSecClassGenericPassword`，service 为应用 bundle identifier，account 为 `remote-access-password`，可访问性为 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`（设备解锁一次后可读，且不随备份迁移到其他设备）。密码不进入 UserDefaults、命令行参数、日志文件、诊断文本或错误消息；设置界面只显示“已设置/未设置”，已保存的密码不会被读回显示。
- 只有远程模式（监听地址不是 loopback）启动托管服务时，密码才经子进程环境变量 `PI_WEB_PASSWORD` 传给 pi-web；loopback 模式不注入，并会清除继承来的同名变量。
- 删除 Keychain 密码条目会立即关闭远程模式：监听地址回到 `127.0.0.1` 并更新配置；若密码是在服务运行期间被删除或变成不可读，应用会先停止本应用启动且仍可验证所有权的远程进程组（外部服务不发信号），再把配置收回到 `127.0.0.1` 并显示可读提示。
- 运行状态写入 `~/Library/Application Support/Pi Web Desktop/`。
- 日志写入 `~/Library/Logs/Pi Web Desktop/Pi Web Desktop.log`（见 `Sources/AppPaths.swift`），超过 10 MB 轮转为 `.1.log` … `.5.log`。写入日志的每一行、错误消息、环境变量与命令行展示、诊断导出都经过同一个 `LogRedactor` 实例；启动前自动更新的决策、参数数组、退出码与前后版本也走同一实例，环境变量只记键名、不记值，子进程输出只保留截断尾部（Pi CLI 更新的进程记录同样先完成凭据与 Home 脱敏再写入日志）。规则与边界见 [日志与诊断导出](logging-and-diagnostics.md)。
- `WKWebView` 使用系统默认的持久化网站数据存储：`Sources/WebViewController.swift:37` 设置 `configuration.websiteDataStore = .default()`，`Sources/` 里没有任何 `WKWebsiteDataStore` 的删除调用。WebKit 因此会以 bundle identifier 为键，在应用自己的 UserDefaults/Application Support 之外持久化网站数据：`~/Library/WebKit/io.github.su-luoya.pi-web-desktop/WebsiteData/`（本机观察到 `Default/`、`IndexedDB/`、`LocalStorage/`、`SearchHistory/`、`ResourceLoadStatistics/`、`EnhancedSecurity/` 等子目录）和 `~/Library/Caches/io.github.su-luoya.pi-web-desktop/WebKit/`（观察到 `NetworkCache/`、`CacheStorage/`、`ServiceWorkers/`、`HSTS/`、`AlternativeServices/`）。这些文件（WebKit 保存的 cookies、缓存、local storage、IndexedDB、Service Worker 记录等，具体取决于服务页面和 WebKit 版本；本机未在 `~/Library/Cookies/` 或 `~/Library/HTTPStorages/` 下观察到属于本 bundle id 的独立文件）由 WebKit 管理，应用自身不读取也不解析它们。当前构建未启用 App Sandbox，所以路径就在用户的 `~/Library` 下，而不是沙盒容器里。
- 应用不读取、复制或迁移 `~/.pi/agent/auth.json` 等 Pi 认证内容。
- 首次启动诊断只检查 `~/.pi/agent` 是否存在与可读（不列目录、不读取任何文件），报告里只出现脱敏后的路径 `~/.pi/agent`。
- 用户在诊断窗口选择 pi-web 路径时，只对该文件做两件本地只读的事：执行 `--version`、向上查找并读取 package.json 的 `name`（不安装、不联网、不读取其他文件）。
- 组件安装识别（GitHub #16）同样只读：它只执行只读命令（`--version`、`npm root -g`、`pnpm root -g`、`pi list`、登录 shell 的 `command -v`）、只读可执行位/符号链接/真实路径、最多向上 6 层读 `package.json` 与检查 `.git` 是否存在（目录只看存在性；`.git` 是文件时只读它一次，不解析内容）。它不执行安装/升级/卸载命令、不调用 `sudo`、不联网、不读 Keychain、不读 `~/.pi` 认证内容；除了写日志/诊断（仍经同一个 `LogRedactor`）以外不写任何文件，也不修改用户全局目录（`~/.npm-global`、npm prefix、Homebrew 前缀都只读）。临时目录夹具的隔离断言见 [开发说明](development.md) 的测试分层一节。

## 本地数据一览与删除

| 数据 | 位置 | 删除方式 |
| --- | --- | --- |
| 服务配置、首次设置状态、窗口位置、更新检查设置 | UserDefaults（domain 为 bundle identifier `io.github.su-luoya.pi-web-desktop`） | 先 `defaults read io.github.su-luoya.pi-web-desktop` 确认内容，再 `defaults delete io.github.su-luoya.pi-web-desktop`。更新检查设置包括策略键 `updateChecks.<组件>.policy`、启动前自动更新开关 `updateChecks.piWeb.autoUpdateBeforeLaunch` 与 `updateChecks.pi.autoUpdateBeforeLaunch`、忽略版本键 `updateChecks.<组件>.ignoredVersion` / `.ignoredVersionAt`（只含版本字符串与时间戳）与最近一次更新失败警告 `updateChecks.piWeb.lastUpdateWarning.*`、`updateChecks.pi.lastUpdateWarning.*` 和 `updateChecks.piPackages.lastUpdateWarning.*`（只含类别、包名、旧/新/目标版本、固定原因文案与时间戳，不含路径、环境变量值、凭据或子进程输出；进程检查结果不落盘，只在内存与界面/日志里存在） |
| 运行状态与所有权记录 | `~/Library/Application Support/Pi Web Desktop/` | 退出应用后删除该目录 |
| 日志（含轮转文件） | `~/Library/Logs/Pi Web Desktop/`（`Pi Web Desktop.log` 与 `.1.log` … `.5.log`） | 退出应用后删除该目录 |
| 更新检查缓存 | `~/Library/Application Support/Pi Web Desktop/update-check-cache.json` | 退出应用后删除该文件；在“服务 → 更新检查设置”里关闭四类可停止后续请求（已存缓存不会自动删除），忽略版本记录在 UserDefaults 里、不影响缓存 |
| 远程访问密码 | 登录 Keychain；service 为 bundle identifier，account 为 `remote-access-password` | 在应用里点“删除密码”，或 `security delete-generic-password -s io.github.su-luoya.pi-web-desktop -a remote-access-password` |
| WebKit 持久化网站数据 | `~/Library/WebKit/io.github.su-luoya.pi-web-desktop/`、`~/Library/Caches/io.github.su-luoya.pi-web-desktop/` | 应用当前没有“清空网站数据”入口，只能退出应用后手动删除：`rm -rf "$HOME/Library/WebKit/io.github.su-luoya.pi-web-desktop" "$HOME/Library/Caches/io.github.su-luoya.pi-web-desktop"` |

删除以上任何一项都不会影响 Pi Web、Pi CLI 或 Node.js 自身的数据。除上表位置外，应用自身不写其他位置；WebKit 的持久化网站数据由系统框架按 bundle id 写入，不在应用自己的 Application Support 目录或 UserDefaults 里，删除 Keychain 密码或删除应用本身都不会自动清除它。`Scripts/smoke.sh` 只把应用自己的 support 目录和日志放进临时目录，不写 UserDefaults、Application Support 和 Logs，但仍会创建默认的 `WKWebView`，所以不隔离上面那两处 WebKit 数据（实测 smoke 会更新其文件 mtime/size，见 [开发说明](development.md)）。

## 诊断脱敏

公开 Issue 或 PR 不得包含密码、token、API key、代理凭据、查询参数、用户名、Home 路径、私人主机名或完整私有日志。日志行、错误消息、环境变量与命令行展示、诊断导出共用 `Sources/LogRedactor.swift` 里的同一个实例，至少覆盖：URL 查询串整体替换、`Authorization:` 头、`Bearer <token>`、`token=`/`password=`/`secret=`/`api_key=`/`apikey=` 形式的键值（含 JSON 与 `PI_WEB_PASSWORD`）、JWT 形态字符串、代理凭据（`scheme://user:pass@host`）、Home 路径（包含非当前用户的以 `/Users` 开头的路径，替换为 `~`）、私钥头与私钥块；多行输入逐行处理。菜单“复制诊断”与诊断窗口的复制按钮在写入剪贴板前会弹出脱敏提醒，说明文本已按规则脱敏、但公开粘贴前仍需自行检查。完整规则表与诊断导出字段见 [日志与诊断导出](logging-and-diagnostics.md)。

脱敏不替代用户提交前的自查。

## 隐私相关的仓库约束

- 文档、模板与默认配置里不得出现个人主机名、私有网络地址、凭据或以 `/Users` 开头的主目录绝对路径。
- 仓库现有的自动文本检查能覆盖的范围有限：`./Scripts/check-identity.sh` 的仓库文本扫描（`# --- 6. repository text scan ---` 一节）只用它的固定模式集（小写的私有 VPN 主机名、tailnet DNS 后缀、CGNAT 私网地址段、以 `/Users` 开头的路径、固定本地代理端点，以及 xcconfig 之外的 `MARKETING_VERSION` 字面值）；CI 的 `Check for accidental personal data` 步骤（`.github/workflows/build.yml:54-56`）只跑一条 `git grep` 字面量检查。这两者都**不是**通用 secret scanner，任意凭据、token、私钥或未被列入的私网地址都不会被发现。`./Scripts/scan-secrets.sh`（[#11](https://github.com/Su-luoya/pi-web-desktop/issues/11)）补齐了高信号凭据形状的扫描，并由 CI 的 `Self-test the secret scanner` 与 `Scan tracked files for committed secrets` 两步门禁，但它仍是固定规则集、不扫 Git 历史；它默认只扫已跟踪文件，发现未跟踪且未被 `.gitignore` 忽略的文件时拒绝给出结论并退出 3（或在本地排查时用 `--include-untracked` 显式一并扫描）。能力边界与未覆盖类型见[开发说明](development.md#personal-data-与-secret-扫描能力)与 [alpha.1 安全与发布审查](security-review-alpha.1.md)。
- 诊断文本只包含本政策与 [日志与诊断导出](logging-and-diagnostics.md) 列出的字段，且全部经过同一个 `LogRedactor`；脱敏不替代用户提交前的自查。应用不读取、不复制、不上传 Pi 认证文件与日志。
- 新增任何联网行为或新增本地数据位置前，必须先更新本文件，并在同一个 PR 里说明用户可见的开关与删除方式。

## 远程访问

默认服务只监听 loopback（`127.0.0.1`）。非 loopback 监听地址必须在 Keychain 中存在非空密码：缺少密码时配置无法保存、服务也无法启动，运行中的远程托管服务在密码被删除后会立即停止并回到 loopback。监听地址在保存、配置加载与启动决策三处都经同一条规则校验：`0.0.0.0`、`::`、`*` 等“所有网络接口”地址、空地址、前后空白与非法字符一律被拒绝，直接改写 UserDefaults 也不能让服务以这些地址启动（见 [架构说明](architecture.md) 的“监听边界”）。密码认证不等于传输加密；远程访问需要用户配置受信任的加密隧道或 HTTPS 反向代理。项目文档不会把个人主机名或其他私人网络地址写入默认配置。

“生成高强度密码”完全在本地完成（`SecRandomCopyBytes`），长度不低于 24，字符集包含大小写字母、数字和符号，不联网、不引入依赖、不做密码同步。诊断文本里只出现密码状态（已设置/未设置），不出现密码值、密码长度或 Keychain 原始数据。
