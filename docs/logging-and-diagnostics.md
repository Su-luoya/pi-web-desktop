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
| 敏感键值（`=`、`:`、JSON 引号形式，大小写不敏感） | `token=…`、`password: …`、`secret=…`、`api_key=…`、`apikey=…`、`access_token=…`、`"token": "…"`、`PI_WEB_PASSWORD=…` | 值替换为 `<redacted>` |
| 命令行参数形式 | `--password …`、`--api-key …` | 值替换为 `<redacted>` |
| JWT 形态（`eyJ` 开头的三段 base64url） | `eyJhbGciOi….eyJzdWIi….dozjgNry…` | `<redacted>` |
| 代理凭据（userinfo） | `http://user:pass@proxy.example.invalid:8080` | `http://<redacted>@proxy.example.invalid:8080` |
| Home 路径 | 注入的 Home 前缀，以及 `/Users` 后跟任意用户名的路径 | `~/…`（不残留用户名） |
| 私钥 | `-----BEGIN … PRIVATE KEY-----` 到 `-----END … PRIVATE KEY-----` 的每一行 | `<redacted>` |

实现细节：

- 多行输入逐行处理，行数与换行结构保持不变，不因换行漏判；整段私钥（头与体在同一次输入里）逐行替换。
- 脱敏是幂等的：对已经脱敏的文本再运行一次结果不变。
- 规则只针对“像秘密”的形态：`tokenizer=fast`、`passwordless=true` 这类普通词不会被误伤。
- 同一实例由 `AppDelegate` 创建后注入 `ServiceManager`（经由它的 `LogWriter`），所以“同一实例脱敏”是类型上的同一个对象，而不是两处各自复制规则。
- 脱敏不替代自查：公开粘贴前必须自己检查内容。

### 子进程输出

托管 pi-web 的 stdout/stderr 由 `posix_spawn` 直接重定向到日志文件（与 #9 的“退出应用时保持服务运行”行为一致：应用退出后子进程仍然能继续写日志，不会因为读取端消失而收到 `EPIPE`）。因此：

- 应用自己写入日志的每一行（事件行、错误、诊断）都经过 `LogRedactor`；
- 每次打开子进程日志句柄前（即每次启动/重启托管服务）会先对已有日志做一次就地脱敏，上一轮运行留下的秘密不会继续留在文件里；
- 子进程自己打印的内容按“它自己的输出”处理：应用不解析、不上传、不转发；日志文件属于用户本机，需要公开时请按上面的规则先自查（也可以直接复制诊断文本，它只包含已脱敏字段）。

应用也从不把密码值、代理凭据或 token 交给子进程以外的任何地方：远程密码只通过子进程环境变量 `PI_WEB_PASSWORD` 传递。

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

可信度取值与依赖诊断一致，导出里同时给出英文取值与中文标注：`verified（已验证）`、`inferred（推断）`、`unknown（未知）`；没有报告时按 `unknown` 处理。

复制入口：**服务 → 复制诊断**，以及诊断窗口的“复制诊断”按钮。两者调用同一条导出路径，复制前都会弹出提醒：

> 诊断信息已按规则脱敏——已替换 Home 路径、URL 查询串、Authorization/Bearer、token/password/secret/api_key 等键值、代理凭据、JWT 与私钥。脱敏不能替代自查：公开粘贴前请再确认一次。

## 边界

- 不上传日志或诊断：应用没有遥测、没有远程上报；数据只有在用户主动复制或打开日志时才离开本机（复制到剪贴板、在 Finder/文本编辑器中打开）。
- 不读取、不复制 Pi 认证文件（例如 `~/.pi/agent/auth.json`）；诊断只报告配置目录路径。
- 日志与诊断文本不包含远程访问密码值；远程密码只通过子进程环境变量传给 pi-web。
- 测试与 smoke 只写注入的临时目录，不写真实 `~/Library/Logs`、不启动真实 pi-web、不联网。

## 验证

| 检查 | 命令 |
| --- | --- |
| 轮转、保留份数、失败路径、假时钟 | `PiWebDesktopTests/LogWriterTests.swift` |
| 各条脱敏规则、多行、幂等、精度 | `PiWebDesktopTests/LogRedactorTests.swift` |
| 导出布局、脱敏后上下文保留、可信度映射 | `PiWebDesktopTests/DiagnosticsCollectorTests.swift` |
| 启动失败消息先脱敏再进状态/回调/日志 | `PiWebDesktopTests/ServiceManagerTests.swift` |
| 打包、身份、双模式 smoke | `./Scripts/build.sh`、`./Scripts/check-identity.sh`、`./Scripts/smoke.sh` |

相关文档：[设置、工作目录与退出行为](settings-and-workspace.md)（路径分层）、[隐私说明](privacy.md)（本地数据一览与脱敏边界）、[架构说明](architecture.md)（组件边界）。
