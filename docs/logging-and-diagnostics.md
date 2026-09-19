# 日志与诊断导出

本文说明统一日志写入与轮转（`Sources/LogWriter.swift`）、统一脱敏器（`Sources/LogRedactor.swift`）和“复制诊断”导出内容（`Sources/DiagnosticsCollector.swift`）的位置、规则与边界。实现入口：`Sources/AppPaths.swift`（路径）、`Sources/AppConfiguration.swift`（打开日志/日志文件夹前的准备）、`Sources/ServiceManager.swift`（写入器接线与错误消息脱敏）、`Sources/PiWebApp.swift`（菜单与导出装配）、`Sources/DiagnosticsWindowController.swift`（诊断窗口的复制按钮）。

## 日志位置与文件

| 文件 | 说明 |
| --- | --- |
| `~/Library/Logs/Pi Web Desktop/Pi Web Desktop.log` | 当前日志。托管 pi-web 子进程的 stdout/stderr 直接写到这里；应用侧事件行（例如 `服务已启动：PID …`、`启动失败：…`）也写入这里。 |
| `~/Library/Logs/Pi Web Desktop/Pi Web Desktop.1.log` … `.5.log` | 轮转文件，`.1` 最新，`.5` 最旧。 |
| `$TMPDIR/pi-web-desktop-smoke-<pid>/Logs/` | smoke 启动使用的临时日志目录（`AppPaths.smoke`），不写真实 `~/Library/Logs`。 |

菜单位置：**服务 → 打开日志**（打开当前日志文件）、**服务 → 打开日志文件夹**（打开日志目录）。两个动作都会先确保目录存在；从未启动过服务时目录还不存在，失败会给出可读提示而不是静默失败。日志目录与文件名都来自 `AppPaths`，测试与 smoke 可以注入临时目录。

## 轮转策略

`LogRotationPolicy` 的默认值与文档一致，并且可以注入（`LogWriter(logFileURL:policy:fileManager:redactor:now:)`）：

- `maximumBytes`：默认 `10 * 1024 * 1024`（10 MB）。追加或打开子进程日志句柄前，当前日志达到该字节数就轮转。
- `retainedFileCount`：默认 5。保留 `.1` … `.5`；更旧的轮转文件在轮转时删除，保留份数有硬上限。
- 轮转动作：`.4` → `.5`、`.3` → `.4`、…、当前日志 → `.1`，然后新建空的当前日志。文件名固定为 `<base>.<index>.log`。
- 打开子进程日志句柄前，先对已存在的日志做一次就地脱敏（整段读取、逐行脱敏、原子写回）：上一轮运行留下的秘密不会因为“这一轮没打印”而继续留在文件里。

失败处理：目录创建、轮转、写入、打开句柄的失败都只记录在 `LogWriter.failureDescription`（包含日志位置，已经过脱敏），不会崩溃，也不会中断服务；轮转失败仍然会把这一行写下去。日志目录完全不可用会让托管启动以可读错误失败（`无法创建日志目录：…`），由启动失败提示展示。

阈值/份数可注入是为了用很小的阈值反复演练真实轮转路径：`PiWebDesktopTests/LogWriterTests.swift` 用 40–80 字节的阈值验证轮转文件名、保留份数上限、越新越靠前的顺序，以及“写入失败只记录不崩溃”。10 MB 默认值本身由 `LogRotationPolicy.standard` 的断言覆盖。

## 脱敏规则（`LogRedactor`）

同一个 `LogRedactor` 实例用于四处，不存在第二份规则：

1. 写入日志的每一行（`LogWriter`）；
2. “复制诊断”/诊断窗口的完整导出文本（`DiagnosticsCollector`）；
3. 错误消息（启动失败、日志目录/文件创建失败、所有权提示等）；
4. 环境变量与命令行参数的展示（子进程启动环境、`ps` 进程描述、启动命令）。

| 规则 | 输入示例 | 输出 |
| --- | --- | --- |
| URL 查询串（整段替换） | `https://pi.example.invalid/api?a=b&c=d` | `https://pi.example.invalid/api?<redacted>` |
| `Authorization:` / `Proxy-Authorization:` 头 | `Authorization: Basic dXNlcjpwYXNz` | `Authorization: <redacted>` |
| `Bearer <token>` | `Bearer abc.def.ghi` | `Bearer <redacted>` |
| 敏感键值（`=`、`:`、JSON 引号键，大小写不敏感） | `token=…`、`password: …`、`secret = "…"`、`api_key : '…'`、`apikey=…`、`access_token=…`、`"token": "…"`、`PI_WEB_PASSWORD=…` | 值替换为 `<redacted>`；单/双引号值与含空格的值整段替换，未加引号的值替换到 `,`、`;`、`&` 或行尾 |
| 换行值（`key:` 后没有值） | `password:` 换行后紧跟缩进的一行 | 紧随的续行整体替换为 `<redacted>`（保留缩进与尾随的 `,` 等字符）；再往后的行不处理，见下表 |
| 命令行参数形式 | `--password …`、`--api-key "… …"` | 值（单个词或带引号字符串）替换为 `<redacted>`，后续参数保留 |
| JWT 形态（`eyJ` 开头的三段 base64url） | `eyJhbGciOi….eyJzdWIi….dozjgNry…` | `<redacted>` |
| 代理凭据（userinfo） | `http://user:pass@proxy.example.invalid:8080` | `http://<redacted>@proxy.example.invalid:8080` |
| Home 路径 | 注入的 Home 前缀，以及 `/Users` 后跟任意用户名的路径 | `~/…`（不残留用户名） |
| 私钥 | `-----BEGIN … PRIVATE KEY-----` 到 `-----END … PRIVATE KEY-----` 的每一行 | `<redacted>` |

实现细节：

- 多行输入逐行处理，行数与换行结构保持不变，不因换行漏判；`key:` 后没有值时紧随的续行按值处理；整段私钥（头与体在同一次输入里）逐行替换。
- 键值匹配覆盖：键可带引号（JSON）或不带引号；`=` / `:` 两侧允许空白；值是双引号、单引号（都允许空格）或到 `,`、`;`、`&` 之前的未加引号文本。未加引号的值末尾的 `}`、`]`、`)`、`,`、`;` 与空白先拆出、替换后原样回填，所以 JSON 的 `}` 不会被吞掉。
- **幂等（实测，GitHub #38）**：同一段文本连续两次 `redact` 逐字节一致；已覆盖的每种形态（URL 查询串、`Authorization`/`Bearer`、敏感键值的引号形式与含空格值、`key:` 续行、CLI 引号值、代理凭据、JWT、私钥块、Home 路径）都用“第一遍结果再跑一遍等于自身”的用例断言。值里已经含 `<redacted>` 的匹配整段跳过，所以已经脱敏过的文本（包括手工拼出的 `token=prefix-<redacted>`）保持原样；`{"token": "…"}` 第一次脱敏后紧跟占位符的 `}` 在第二遍也保持原样。此前 [alpha.1 安全与发布审查](security-review-alpha.1.md)（风险 R-1）实测的“JSON 引号键第二遍吞字符”已修复，`LogWriter` 的就地脱敏（`scrubExistingLogLocked`）重复执行不再截断该行（回归用例 `PiWebDesktopTests/LogWriterTests.swift` 的 `testScrubbingAnAlreadyRedactedLogIsByteStable`）。
- 规则只针对“像秘密”的形态：`tokenizer=fast`、`passwordless=true` 这类普通词不会被误伤。
- 同一实例由 `AppDelegate` 创建后注入 `ServiceManager`（经由它的 `LogWriter`），所以“同一实例脱敏”是类型上的同一个对象，而不是两处各自复制规则。
- 脱敏不替代自查：公开粘贴前必须自己检查内容。

**不覆盖的形态**（GitHub #38 实测确认：下表记录本轮实测仍未覆盖或只部分覆盖的形态，其余已由上面的规则覆盖；逐条断言见 `PiWebDesktopTests/LogRedactorTests.swift`）：

| 形态 | 示例 | 实测结果 |
| --- | --- | --- |
| `key:` 之后的第 2 行及更后（块标量正文） | `password: \|` 换行后多行缩进文本 | 指示符行的值（`\|`）替换为 `<redacted>`，后续正文行原样保留 |
| 无引号值中含 `,` `;` `&` | `password=a,b c` | `password=<redacted>,b c`（分隔符之后保留） |
| 同缩进且像下一条 `label:` 的续行 | `password:` 换行 `other: value` | 不当作值，原样保留（避免吞掉后续字段） |
| 值里已经含占位符 | `token=prefix-<redacted>` | 整段跳过、原样保留（保证幂等）；`prefix-` 不会消失 |
| URL 查询串值含未编码空格 | `?password=a b` | 替换到空格：`?<redacted> b`（URL 里的空格本应编码为 `%20`） |
| CLI 无引号多词值 | `--password a b` | 只替换第一个词：`--password <redacted> b`（多词请用引号） |

应用自身从不以上述形态写出密码（密码只进子进程环境，诊断只有“已设置/未设置”）；这些形态主要出现在**子进程 stdout/stderr** 里，而那部分由 `posix_spawn` 直接重定向到日志文件，应用不解析其格式，且只在**下一次启动/重启托管服务时**才做一次就地脱敏（见下节）。因此公开日志前必须自查。

### 子进程输出

托管 pi-web 的 stdout/stderr 由 `posix_spawn` 直接重定向到日志文件（与 #9 的“退出应用时保持服务运行”行为一致：应用退出后子进程仍然能继续写日志，不会因为读取端消失而收到 `EPIPE`）。因此：

- 应用自己写入日志的每一行（事件行、错误、诊断）都经过 `LogRedactor`；
- 每次打开子进程日志句柄前（即每次启动/重启托管服务）会先对已有日志做一次就地脱敏，上一轮运行留下的秘密不会继续留在文件里；
- 子进程自己打印的内容按“它自己的输出”处理：应用不解析、不上传、不转发；日志文件属于用户本机，需要公开时请按上面的规则先自查（也可以直接复制诊断文本，它只包含已脱敏字段）。

应用也从不把密码值、代理凭据或 token 交给子进程以外的任何地方：远程密码只通过子进程环境变量 `PI_WEB_PASSWORD` 传递。

### 启动前自动更新的安装器输出（GitHub #20）

启动前自动更新执行的 `npm install -g` 与托管服务不同：它的 stdout/stderr 由应用通过管道捕获（不写日志文件、不进入诊断导出），内存里只保留截断后的尾部（最多 2000 字符）用于失败原因，写入日志前再经同一个 `LogRedactor`；安装器子进程的环境只含白名单键，日志只记录键名、**绝不记录变量值**。决策行、参数数组、生命周期脚本策略说明（固定文案：按上游包声明的脚本安装、不传 `--ignore-scripts`）、退出码与安装前后版本都会写进应用日志，路径在写入前已把 Home 段替换为 `~`。持久警告（`updateChecks.piWeb.lastUpdateWarning.*`）只含类别、旧/新/目标版本、固定原因文案与时间戳，不含路径、环境变量值、凭据或输出片段。

### 更新历史与诊断行（GitHub #23）

统一的更新历史（`updateChecks.updateHistory`）只存时间、组件、来源、从/到版本、每个阶段的固定结论、固定原因文案与降级结论；写入前逐条校验，非法版本号、非法包名与未知枚举直接丢弃，不写绝对路径、环境值或子进程输出。诊断页的“最近一次更新”行只展示完成阶段、阶段结论与建议动作，手动命令文本来自静态清单，仅展示、不执行。验证阶段的探针结果（文件是否存在、是否可执行、`package.json` 名称、可选的大小/mtime）只在内存中参与判定，不写入历史也不进入诊断导出。

## 诊断导出内容

`DiagnosticsCollector.text(for:redactor:)` 组装以下字段（顺序即导出顺序），最后整段交给 `LogRedactor`：

| 字段 | 来源 |
| --- | --- |
| `Pi Web Desktop 版本` / `构建号` | bundle `Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion`（唯一来源 `Configuration/AppIdentity.xcconfig`；缺失时标注开发构建） |
| `pi-web 版本` / `pi-web 路径` + 可信度 | 依赖诊断报告（`DependencyReport` 的 pi-web 项）；未运行时回退到实时 `--version` 与路径选择结果 |
| `Pi CLI 版本` + 可信度 | 依赖诊断报告的 Pi CLI 项 |
| `Node.js 版本` + 可信度 | 依赖诊断报告的 Node.js 项 |
| `服务地址` / `端口` / `状态` | `ServiceConfiguration.serviceURL`、端口、`ServiceState.statusText(for:managedPID:)` |
| `托管关系` | `managed（本应用托管，所有权校验通过；托管 PID …）` 或 `external（外部服务或未运行，无有效所有权记录）` |
| `监听 PID` / `监听进程` / `托管 PID` | `ProcessInspector` 与所有权记录 |
| `有效工作目录` | `AppConfiguration.workspaceDirectory(for:)`（默认目录或用户自选目录） |
| `配置目录` | 固定为 `~/.pi/agent`（只报告路径） |
| `启动命令` | 应用会为子进程执行的命令行（`--hostname/--port/--no-open`） |
| `启动环境` | 应用显式设置的子进程变量，一行一个 `KEY=value`；远程模式下 `PI_WEB_PASSWORD` 只以 `<redacted>` 占位符进入，真实值不经过诊断代码 |
| `日志文件` / `日志写入` | `AppPaths.logFileURL` 与 `LogWriter.writeStatusDescription`（正常 / 写入失败及时间） |
| `远程访问密码` | 只有“已设置（仅存于 Keychain）”或“未设置”，没有密码值或长度 |
| `组件安装` | `DependencyReport.components`（GitHub #16）：每个组件一行 `summaryLine`，包含组件类型、包名、版本、可执行文件路径、真实路径、安装来源、可信度与建议命令（没有建议命令时写“不给命令”及其原因）。多于一组件时同样使用 `组件安装[2]:` 这样的唯一标签行。路径在进入导出前已由 `DependencyChecker` 完成 Home 脱敏（`~`）；建议命令只可能来自 `InstallCommandManifest` 的静态条目，不包含动态拼接的包名 |

可信度取值与依赖诊断一致，导出里同时给出英文取值与中文标注：`verified（已验证）`、`inferred（推断）`、`unknown（未知）`；没有报告时按 `unknown` 处理。

复制入口：**服务 → 复制诊断**，以及诊断窗口的“复制诊断”按钮。两者调用同一条导出路径，复制前都会弹出提醒：

> 诊断信息已按规则脱敏——已替换 Home 路径、URL 查询串、Authorization/Bearer、token/password/secret/api_key 等键值、代理凭据、JWT 与私钥。脱敏不能替代自查：公开粘贴前请再确认一次。

## 边界

- 不上传日志或诊断：应用没有遥测、没有远程上报；数据只有在用户主动复制或打开日志时才离开本机（复制到剪贴板、在 Finder/文本编辑器中打开）。
- 不读取、不复制 Pi 认证文件（例如 `~/.pi/agent/auth.json`）；诊断只报告配置目录路径。
- 日志与诊断文本不包含远程访问密码值；远程密码只通过子进程环境变量传给 pi-web。
- 启动前自动更新（GitHub #20）不记录环境变量值、不把安装器输出写入日志文件或诊断导出；日志、警告与诊断里的路径、凭据形状统一走 `LogRedactor`。
- 测试与 smoke 只写注入的临时目录，不写真实 `~/Library/Logs`、不启动真实 pi-web、不联网。

## 验证

| 检查 | 命令 |
| --- | --- |
| 轮转、保留份数、失败路径、假时钟 | `PiWebDesktopTests/LogWriterTests.swift` |
| 各条脱敏规则、引号/含空格值、续行、多行、幂等（含 JSON 边界）、不覆盖形态的边界、精度 | `PiWebDesktopTests/LogRedactorTests.swift` |
| 导出布局、脱敏后上下文保留、可信度映射 | `PiWebDesktopTests/DiagnosticsCollectorTests.swift` |
| 组件安装区块的多行标签与逐项渲染（`组件安装[2]:`） | `PiWebDesktopTests/DiagnosticsCollectorTests.swift` |
| 组件安装识别、只读约束与建议命令策略 | `PiWebDesktopTests/ComponentInstallationTests.swift` |
| 启动失败消息先脱敏再进状态/回调/日志 | `PiWebDesktopTests/ServiceManagerTests.swift` |
| 打包、身份、双模式 smoke | `./Scripts/build.sh`、`./Scripts/check-identity.sh`、`./Scripts/smoke.sh` |

相关文档：[设置、工作目录与退出行为](settings-and-workspace.md)（路径分层）、[隐私说明](privacy.md)（本地数据一览与脱敏边界）、[架构说明](architecture.md)（组件边界）。
