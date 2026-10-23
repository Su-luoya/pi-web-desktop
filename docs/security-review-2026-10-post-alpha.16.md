# 第二阶段审计修复的安全评审（alpha.16 之后，delta）

评审对象：`main` 上的 `c430c0f`（`v0.1.0-alpha.16` 发布提交 `761f783` 之后的六个提交）。
基线：`761f783`（alpha.16 发布提交）。
本报告是**只读评审**：没有修改任何代码、工程文件或脚本，只读取源码、脚本、工程文件与文档。

**定位**：这一轮的改动尚未随任何版本发布。它不是 alpha.16 的评审，alpha.16 的评审
缺口应在下一次发版时按发布流程补上。本报告的作用是把本轮的信任边界变化先记录在案，
避免下一位维护者从零重审。

## 0. 方法与证据基线

### 0.1 评审范围与命令

| 命令 | 用途 |
| --- | --- |
| `git diff --shortstat 761f783..c430c0f` | delta 规模：80 个文件，`+3892` / `-473` |
| `git diff --numstat 761f783..c430c0f -- Sources PiWebDesktopTests` | 源码与测试面的逐文件增删行 |
| `git diff 761f783..c430c0f -- Sources PiWebDesktopTests \| grep -E '^[+-]import'` | 依赖 / 框架面变化：只有 `import Darwin` ×2、`import Foundation` ×2、`import XCTest` ×3（全在测试） |
| `git grep -c -F <pattern> <rev> -- Sources` | 安全相关模式的基线 / 本轮计数对比（见 §1） |
| `git grep -n -F NSWorkspace -- Sources` | 本轮全部 `NSWorkspace` 调用点清点（S1） |
| `git grep -n -F EPERM -- Sources` | 信号 / 存活判定的 `EPERM` 语义（S2） |
| 逐行阅读 `Sources/App/SingleInstanceLock.swift`、`Sources/App/WebViewNavigationPolicy.swift`、`Sources/App/WebViewController.swift`、`Sources/Services/ServiceManager.swift`、`Sources/Services/ServiceOwnership.swift`、`Sources/Services/ProcessInspector.swift`、`Sources/Services/KeychainStore.swift`、`Sources/Services/ToolPath.swift`、`Sources/Updates/PiCLIUpdatePlanner.swift`、`Sources/Updates/DesktopAppUpdate.swift` | 本轮改动涉及信任边界的全部位置 |
| `./Scripts/build.sh`、`check-identity.sh`、`scan-secrets.sh`、`smoke.sh`、`xcodebuild test` | 本轮门槛实测（结果见 §6） |

源码面（`Sources/`）约 60 个文件有改动；测试面新增 5 个文件
（`AppMenuHygieneTests.swift`、`PreferencesRefreshPolicyTests.swift`、`SingleInstanceLockTests.swift`
及两个测试文件的改名）并扩充 19 个既有文件。

### 0.2 证据强度分级

- **[A]** 命令输出可复现（计数、脚本退出码、断言、实测耗时）。
- **[B]** 源码逐行阅读 + 机械计数支持的结论。
- **[C]** 只能推断、本次没有运行证据的结论（一律不当作已核实，见 §5）。

## 1. 模式基线对比

| 模式 | `761f783` | `c430c0f` | 结论 |
| --- | --- | --- | --- |
| `kill(` | 7 | 7 | 未变 |
| `sendGroupSignal` | 4 | 5 | **+1**（`isProcessGroupAlive` 的 `EPERM` 语义，§2） |
| `Process()` | 7 | 7 | 未变 |
| `.arguments =` | 8 | 8 | 未变（无新增子进程调用点） |
| `URLSession` | 28 | 30 | **+2**（`URLSessionServiceProbe` 改为复用单个实例，见 §3.4；另一个是测试替身） |
| `NSWorkspace` | 7 | 8 | **+1**（外链白名单判定后仍只有一处 `open`，见 §3.1） |
| `Keychain` | 54 | 58 | **+4**（三态 `Status` 的读写分支，见 §3.2） |
| `try!` | 0 | 0 | 未新增 |
| `as!` | 0 | 0 | 未新增 |
| `fatalError` | 3 | 3 | 未变 |

[`Sources/App/PreferencesWindowController.swift`](../Sources/App/PreferencesWindowController.swift) 的
`window!` 强解包已改为 `guard` 后跳过面板（本轮唯一一处被移除的强解包）。

## 2. S1 服务所有权与信号路径

本轮的信号相关改动集中在「如何确认进程真的死了」，没有放宽「对谁发信号」。

| 位置 | 改动 | 安全含义 |
| --- | --- | --- |
| `Sources/Services/ServiceManager.swift` | `terminate()` 改为返回「是否确认进程组已消失」；SIGKILL 后有界复查（`postKillConfirmationPollAttempts = 10` 轮 ≈100ms） | 旧实现发完 SIGKILL 即删所有权记录并置 `.stopped`，对不可中断睡眠里的组会**失去全部管理路径**；现在未确认就保留记录以便重试 |
| `Sources/Services/ServiceOwnership.swift` | `isProcessGroupAlive` 把 `EPERM` 也判为存活 | 旧实现只认 `== 0`，把「无权发信号」当成「已退出」，删掉记录后无法再管理自己启动的进程。这是**收紧**，不是放宽 |
| `Sources/Services/ProcessInspector.swift:42-44` | `defaultProcessIsAlive` 同样把 `EPERM` 判为存活 | 同上；避免把其他用户的进程误判为已死 |
| `Sources/Services/ServiceManager.swift:1027` | 两处 `sendGroupSignal` 调用写成显式 `_ =` | **故意不看返回值**：`ESRCH` / `EPERM` 只代表「没送达」，权威结论来自随后的存活探测。据此提前判失败会把刚自行退出的服务当成停止失败 |

**未变的前提**：仍然只对经过 `ServiceOwnershipVerifier` 校验的进程组发信号；`ServiceSignaling`
实现仍然拒绝非正数进程组（`guard processGroupID > 1`）；诱饵进程测试（不在受管进程组里的进程
必须既没被终止也没收到 TERM/INT）保持通过。本轮**没有**新增 `kill(` / `killpg` 调用点。

## 3. S2 信任边界变化

### 3.1 外链协议白名单（收口，最高价值的一项）

`Sources/App/WebViewController.swift` 的两条外开路径（`decidePolicyFor navigationAction` 与
`decidePolicyFor navigationResponse`）原先把**任何**非本地 URL 交给 `NSWorkspace.shared.open`，
等于网页里的任意 scheme（`file:`、`javascript:`、自定义 scheme）都能触发系统协议处理器。

`Sources/App/WebViewNavigationPolicy.swift:74` 现在是白名单：

```swift
static let externalSchemes: Set<String> = ["http", "https", "mailto"]
```

`WebViewNavigationDecision` 新增 `case block`（同文件 :14）；`WebViewController.swift:190-196`
只在白名单命中时调用 `NSWorkspace.shared.open(url)`，否则只上报不打开。

`Sources/App/WebViewNavigationPolicyTests.swift` 新增 56 行覆盖各 scheme 的判定。
其余 `NSWorkspace` 调用点（打开日志目录、工作目录、在浏览器打开）都是应用自身的固定目标，
不接受网页输入。

**残余风险 [C]**：白名单只约束「从 WebView 发起的导航」。若渲染页面通过其他途径（例如未来的
JS bridge）请求打开外部程序，该路径不受本白名单约束。本轮不存在这样的路径。

### 3.2 凭据三态（可观测性，不是权限变化）

`Sources/Services/KeychainStore.swift:160-164` 引入 `Status`（`set` / `notSet` / `unreadable`）。

旧行为把「读取失败」与「确实未设置」压成同一个 `false`：登录钥匙串锁定时界面显示「未设置」、
删除按钮禁用，用户会以为密码丢失。新行为区分两者并在 `unreadable` 时提示解锁钥匙串。

**安全含义**：三态只影响 UI 文案与按钮可用性，不改变「密码只存 Keychain、不进 UserDefaults、
不进日志、不进诊断文本」的既有约束；`SecretScrubbing` 仍覆盖注入错误的路径。这是**暴露更少**
（不再把失败伪装成「未设置」导致用户重设密码）而非更多的信息。

### 3.3 单实例锁（新的权威互斥物）

`Sources/App/SingleInstanceLock.swift` 是本轮新增的唯一新安全机制。

| 旧实现 | 问题 |
| --- | --- |
| `FileManager.createFile` 重建锁文件 | **替换 inode**：在运行实例持着已删除 inode 的锁，后续实例在新 inode 上拿到锁 → 双实例 |
| PID 记录被当作权威身份证据 | **崩溃残留 + PID 复用**会让应用永久无法启动（记录里那个 PID 可能已被任意无关进程复用） |
| 所有失败都返回 `false` | 「另一个实例在跑」与「锁文件打不开」不可区分，后者也静默退出 → 双击无提示，用户只能重装 |

新实现：`open(O_RDWR|O_CREAT, 0o600)` 对已存在路径只打开**同一 inode**，权威互斥由
`flock(LOCK_EX|LOCK_NB)` 提供（进程死亡时内核自动释放，含 SIGKILL）；PID 记录退化为提示与
快速路径，只有同时满足「进程存活」+「可执行镜像与本应用相同」才认作已有实例，否则交给 `flock`。
失败原因区分为 `alreadyRunning` 与 `lockUnavailable(detail:)`。

**注意**：`flock` 成功即取得互斥，锁文件权限是 `0600`（仅当前用户）。这把锁防的是同一用户
误启两个实例，**不是**跨用户的沙箱边界；多用户 Mac 上每个用户各自有一份 support 目录。

`PiWebDesktopTests/SingleInstanceLockTests.swift`（247 行，新增）覆盖 inode 保持、PID 复用、
崩溃残留、只读目录、锁路径被占据等分支。

### 3.4 工具 PATH 与子进程环境

| 位置 | 改动 | 安全含义 |
| --- | --- | --- |
| `Sources/Services/ToolPath.swift` | 登录 shell stdout 只取**最后一行**并校验可执行 | 旧实现把 `.zshenv` 的 `echo` 输出整段当路径（`posix_spawn` → `ENOENT`）；只取末行同时避免了把攻击者可控的多行输出整体当作 PATH |
| `Sources/Services/ToolPath.swift` | 补 `expandingTildeInPath` | 修「`~` 开头路径恒判未找到」，不改变候选路径集合 |
| `Sources/Updates/ComponentInstallationDetector.swift` | `command -v` 名单加 `^[A-Za-z0-9._-]+$` 白名单 | 防未来外部输入进入 shell 拼接 |
| `Sources/Updates/UpdateCheckEndpoint.swift` / `UpdateChecker.swift` | `userAgent` 拼接前过滤控制字符（含 CR/LF） | 请求头不可被拆行（header injection） |

子进程环境白名单（`PI_WEB_PASSWORD`、`NODE_OPTIONS`、`npm_config_*` 的处理）本轮未改动。

### 3.5 信号与进程探测之外：主线程阻塞

`Sources/Services/ServiceManager.swift` 的启动就绪轮询从「按次数记账」（实际可达 480s，文案写 30s）
改为按墙钟截止时间计算；主线程同步 spawn `ps` / 登录 shell 探测迁出主线程。

**安全含义**：不是权限变化，但消除了「主线程卡住 → 退出确认框与超时兜底失效」的可用性缺口
（退出状态机的 `decisionTimeout` 依赖主队列排水）。

## 4. S3 日志与脱敏

`Sources/Diagnostics/LogRedactor.swift`（`+33/-11`）与 `LogWriter.swift`（`+66/-19`）有改动，
`LogRedactorTests.swift`（`+59`）与 `LogWriterTests.swift`（`+76`）同步扩充。

本轮**没有**新增日志输出点；改动集中在轮转阈值、打开子进程句柄前就地脱敏历史日志、
写入失败只记录不崩溃。脱敏规则集（URL 查询串、`Authorization`/`Bearer`、敏感键值、
命令行 `--password`、JWT、代理凭据、非当前用户 Home 路径、私钥头与体）未减少。

`PiWebDesktopTests/LogRedactorTests.swift` 的幂等与「不误伤 `tokenizer=` / `passwordless=`」
断言保持通过，说明本轮没有把普通词加入替换集。

## 5. 未覆盖与未验证

**本轮没有运行证据的项（一律不当作已核实）**：

- **真机 / 人工验证未执行**：
  - T5（GUI 菜单与设置窗口的实际观感：⌃⌘F 唯一绑定、设置窗口追平后的控件状态）——只有源码级断言
    （`PiWebDesktopTests/AppMenuHygieneTests.swift`，因 `AppDelegate` 扩展刻意不进测试 target，
    该测试用源码断言代替运行时断言）。
  - T11（真实 `/Applications` 环境下的桌面自更新端到端流程，含下载窗口期重复触发的拦截）。
- **`Sources/Diagnostics/` 未审计**：2304 行（`LogWriter.swift`、`LogRedactor.swift`、
  `DiagnosticsCollector.swift`、`DiagnosticsClipboard.swift`、`DiagnosticsWindowController.swift`、
  `FirstLaunchDiagnostics.swift`）不在本轮六份审计报告范围内。§4 的结论只覆盖被改动的行。
- **R12（解压器对恶意归档路径）与 R13（`/Applications` 写权限探针的 TOCTOU）**：这两项从
  alpha.15 评审继承，本轮**没有**重新审计，仍为 [C]。
- **`flock` 在 NFS / SMB 挂载上的语义**：support 目录默认在本地磁盘，本轮未测试网络家目录场景 [C]。
- **`EPERM` 判为存活的副作用**：若某进程组确实存在但永久不可信号（例如被其他用户的进程复用
  了 pgid），`isProcessGroupAlive` 会一直返回 true，停止流程只能依赖有界复查耗尽后上报失败 [C]。
  这是**宁可报失败也不误杀**的取舍，符合既有原则。

## 6. 门槛实测（提交 `c430c0f` 的最终树）

| 检查 | 结果 |
| --- | --- |
| `xcodebuild test` | 943 个测试，0 失败 |
| `./Scripts/build.sh` | 成功，0 warning |
| `./Scripts/check-identity.sh` | `PASSED (45 checks)` |
| `./Scripts/scan-secrets.sh` | PASS |
| `./Scripts/smoke.sh` | 两种模式均 OK |
| `git diff --check` | 通过 |

`check-identity.sh` 的两条禁止项在本轮被触发并已修正（示例 CGNAT 地址、注释里的绝对 home 路径），
这是这两条扫描规则首次在本仓库抓到真问题，说明它们有效而不是空转。

## 7. 结论

本轮**没有放宽**任何既有信任边界：信号路径只收紧（确认退出、`EPERM` 仍算存活）、
外链从「任意 scheme」收紧为三项白名单、单实例互斥从「可重建的锁文件 + 可复用的 PID」
收紧为「内核 `flock`」。

新增的攻击面只有 `flock` 锁文件本身（`0600`，位于当前用户的 support 目录），以及
外链白名单未覆盖的非 WebView 打开路径（本轮不存在）。

阻断项：**0 条**。需要真机验证的项：T5、T11。建议下一轮对象：`Sources/Diagnostics/`。
