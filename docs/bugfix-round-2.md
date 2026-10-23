# 第二阶段审计修复汇总（alpha.16 之后）

本文档记录 `v0.1.0-alpha.16`（发布提交 `761f783`）之后的一轮审计修复。
范围是六份只读审计报告列出的 `outA`–`outE` 条目中判定为真实缺陷的部分。

**这份改动已随 `v0.1.0-alpha.17` 发布**（发布说明见
[release-notes-v0.1.0-alpha.17.md](release-notes-v0.1.0-alpha.17.md)，安全评审见
[security-review-alpha.17.md](security-review-alpha.17.md)）。
`docs/release-notes-v0.1.0-alpha.16.md` 与 `docs/alpha-release-checklist.md`
里的 alpha.16 执行记录仍是发布当时的快照，描述的是 `761f783` 上的状态，本轮的改动不属于那一版，
因此**没有回改**它们（包括其中的「859 个测试」——那是发布提交上的准确计数）。

## 变更边界

- 没有新增第三方 Swift 包、npm 运行时依赖或 UserDefaults 键（本轮新增的两个 UserDefaults 相关
  结构复用既有键：`PreferencesRefreshPolicy` 是纯值判定，`SingleInstanceLock` 只读写既有的
  support 目录文件）。
- 没有新增服务控制路径；停止服务仍只对经过 `ServiceOwnershipVerifier` 校验的进程组发送信号。
- 没有改变网络边界：非 loopback 访问仍是明文 HTTP，更新检查仍只访问 `api.github.com` /
  `registry.npmjs.org`，桌面自更新仍用同源 SHA-256 校验（不含签名链）。
- 桌面自更新仍只在 `/Applications` 可用、仍需用户确认、仍不做无人值守安装、新版本启动失败仍不自动回滚。

## 更新链路

| 编号 | 问题 | 修复 |
| --- | --- | --- |
| H1 | `UpdateRollback` 的版本证据校验可被绕过 | 版本证据必须与实际可执行文件一致 |
| M1 | 退出时 `abandon()` 的落盘是异步的，崩溃会丢 | 退出路径改为同步落盘 |
| M2 | 执行器回调在非投递队列上触发 | 回调收敛到投递队列 |
| M3 | `UpdateTransactionJournal` 崩溃点不一致 | 写入顺序与 `fsync` 语义修正 |
| M4 | `UpdateAbandonedAttempt` 存储无锁、整块 `decode` 失败丢全部记录 | 加锁保护，改为逐条 `decode` 并返回丢弃条数 |
| M5 | 未来时间戳的 abandon 记录可长期残留 | 拦截未来时间戳 |
| M6 | `UpdateVerifier` 在证据缺失时直接判失败 | 增加 fallback 证据路径 |
| M7 | `UpdateHistory` 单条损坏导致整段历史丢失 | 容错 `decode` |
| M8 | `healthCheckFailed` 的提交语义与文案不符 | 修正提交时机 |
| M9 | 通知重复投递 | 去重 |
| M10 | 包名校验过宽 | 收紧包名规则 |
| L6 | `ComponentInstallationDetector` 的 `command -v` 名单可被外部输入影响 | 加 `^[A-Za-z0-9._-]+$` shell 白名单 |
| L7 | `parsePiList` 会把「版本在前」的行产成假条目 | 行首 token 必须是合法包名 |
| L8 | 符号链接链过长与悬空在证据里混为一谈 | 两者分别表述 |
| — | `userAgent` 拼接前未过滤控制字符（含 CR/LF），请求头可被拆行 | 过滤控制字符 |
| — | `interval(for:)` 有未使用的 `category` 参数 | 去掉并更新三处调用点 |

### 桌面 App 自更新（outD-2）

下载窗口期内菜单项与入口都看不到「下载中」，用户在下载过程中能重复触发自更新。
新增 `DesktopAppUpdateInstallState`：下载一开始即进入 `installing`，菜单置灰与入口 guard
共用这一个可见状态。

### Pi CLI 自动更新额度（outD-4）

`PiCLIUpdatePlanner.decide` 的输入原先没有「更新进行中」这个维度，手动入口
`performPiCLIManualUpdate` 也不置位 `piCLIUpdateInProgress`，于是手动更新进行期间自动检查
仍会消耗一次更新额度。决策输入新增 `updateInProgress`，手动路径据此返回 `.deferred`
而不是烧额度。

### 单实例锁（`Sources/App/SingleInstanceLock.swift`）

旧实现有两个生产实证问题：

1. 用 `FileManager.createFile` **重建**锁文件会替换 inode，在运行实例于是持着已删除 inode 的锁，
   后续实例在新 inode 上拿到锁——形成双实例。现在 `open(O_CREAT)` 对已存在路径只打开同一 inode，
   权威互斥改由 `flock` 提供（进程死亡时内核自动释放，含 SIGKILL）。
2. PID 记录被当作身份证据，崩溃残留 + PID 复用会导致应用**永久无法启动**。现在只有记录同时
   通过「进程存活」与「可执行镜像与本应用相同」两项校验才认作已有实例，否则交给 `flock` 判定。

`acquire()` 的失败原因可区分：`alreadyRunning`（正常拒绝）与 `lockUnavailable`
（support 目录只读、锁路径被同名文件占据等环境故障）。旧实现两者都返回 `false`，
AppDelegate 对后者也静默退出——双击无任何提示，用户只能重装。

## 服务生命周期

| 编号 | 问题 | 修复 |
| --- | --- | --- |
| 高危 | 健康检查的「受托管重启」误调 `startManagedService()` | 对存活进程只挂无效轮询链而从不重启；改走 `restartManagedService()` |
| 中危 | 启动就绪轮询按次数而非墙钟时间记账 | 实际可达 480s 而文案写 30s；改为按截止时间计算 |
| 中危 | 主线程同步 spawn `ps` / 登录 shell 探测 | 卡住即整个 UI 冻结；迁出主线程 |
| 中危 | `terminate()` 发完 SIGKILL 即返回 | 不可中断睡眠里的组会让应用对自己启动、仍活着的进程失去全部管理路径。改为返回「是否确认进程组已消失」，SIGKILL 后有界复查（`postKillConfirmationPollAttempts = 10` 轮 ≈100ms） |
| 中危 | 停止时未确认退出也删所有权记录并置 `.stopped` | 保留记录以便重试，收回停止标志并送达完成回调 |
| 中危 | `EPERM` 被判成「进程已死」 | `EPERM` 只代表信号没送达，权威结论来自随后的存活探测 |

**故意不检查 `sendGroupSignal` 返回值**（`ServiceManager.terminate(processGroupID:)`）：`kill` 的
`ESRCH` / `EPERM` 只代表「没送达」，送达与否由随后的存活探测给出权威结论；据此提前判失败
反而会把刚自行退出的服务当成停止失败。两处调用因此写成显式 `_ =` 并注明原因。

## App 与设置窗口

| 编号 | 问题 | 修复 |
| --- | --- | --- |
| outD-3 | 设置窗口可见时不刷新 | 外部写入配置（菜单切监听地址/工作目录）后，打开着的设置窗口仍持旧快照，用户点「保存」会把旧配置写回并重启服务。新增 `PreferencesRefreshPolicy`（纯值判定）与 `refreshIfUnedited(configuration:)`，配置写盘后立即追平；窗口可见时不再整体重置控件 |
| outB-F8 / outA-次要-7 | 空命令行导致永久降级 | 空 `ps` 输出归入 `.processFactsUnavailable`，不再被当成「无进程」 |
| outD-6 | ⌃⌘F 双绑定 | 显示菜单的全屏幕项去掉快捷键，唯一绑定点在窗口菜单 |
| outD-7 | 主线程枚举进程 | 实测 918 进程耗时 1.6–8.1ms，**判定为非 bug**，未改动 |
| — | 菜单缓存引用清理不全 | `installMainMenu` 统一经 `resetCachedMenuReferences` 清空全部菜单缓存引用（此前只清两个数组） |
| — | `NSMenuItemValidation` 未正式声明 | 补声明 |
| — | `PreferencesWindowController` 强解包 `window!` | 改为 `guard` 后跳过面板 |

## 网络安全边界（outD-5）

`WebViewController` 的两条外开路径（`decidePolicyFor navigationAction` 与
`decidePolicyFor navigationResponse`）原先把任何非本地 URL 直接交给 `NSWorkspace`，
等于任意 scheme 都能触发系统协议处理器。

`WebViewNavigationPolicy.swift:74` 现在是白名单：

```swift
static let externalSchemes: Set<String> = ["http", "https", "mailto"]
```

`WebViewNavigationDecision` 新增 `case block`；`file://`、`javascript:`、自定义 scheme
一律不交给 `NSWorkspace`。

## 凭据可读性（`Sources/Services/KeychainStore.swift`）

读取失败与「确实未设置」原先被压成同一个 `false`：登录钥匙串锁定时界面显示「未设置」且删除按钮
禁用，用户会以为密码丢失。现在引入三态 `Status`（`set` / `notSet` / `unreadable`，
`KeychainStore.swift:160-164`），设置窗口消费三态并在 `unreadable` 时提示解锁钥匙串。

## 工具 PATH（`Sources/Services/ToolPath.swift`）

- 登录 shell 的 stdout 混入 `.zshenv` 的 `echo` 时，整段输出被当成路径，`posix_spawn` 得到 `ENOENT`。
  现在只取最后一行并校验可执行。
- 用户配置的 `~` 开头路径未展开，恒判「未找到」。补 `expandingTildeInPath`。

## 质量卫生

- `ServiceManager.terminate(processGroupID:)` 的两处未使用返回值警告已消除（见上文）。
- `PreferencesRefreshPolicyTests` 的示例地址从 CGNAT 段改为普通私网地址（断言语义不变），
  以通过 `check-identity.sh` 的禁止项扫描。
- `WorkspaceDirectory.swift` 注释里的绝对 home 路径示例改成中性示例，同上。
- 删除零引用代码：`AppConfiguration.clearUpdateHistory`、`DesktopAppReleaseAssetSelector.allowedHost`、
  `isRunningFromApplications`、`#if DEBUG DesktopAppUpdateSelfCheck`、
  `UpdateArtifactFingerprint.hasVersionEvidence`、测试夹具 `successResult` / `readLegacyPIDRecord`、
  `onCancel` 死钩子、`URLSessionServiceProbe` 每次新建的 `URLSession`。
- 测试文件改名 `*AdapterTests` → `*FlowTests`，对齐 `Planner` / `Coordinator` / `Command` 命名。
- `CONTRIBUTING.md` 失效锚点、`architecture.md` 过时类型名、`development.md` 过时的
  `PiWebUpdateAdapter` 表述、`security-ownership.md` 三个不存在的测试名，均已修正。

## 验证

在提交 `c430c0f` 的最终树上执行：

| 检查 | 结果 |
| --- | --- |
| `xcodebuild test` | 943 个测试，0 失败（本轮结束时的值；alpha.17 发布时为 951，多出的 8 个来自 `UpdateCheckTimerModeTests.swift` 的 3 个与 `DesktopAppUpdateFailurePathTests.swift` 的 5 个） |
| `./Scripts/build.sh` | 成功，0 warning |
| `./Scripts/check-identity.sh` | `PASSED (45 checks)` |
| `./Scripts/scan-secrets.sh` | PASS |
| `./Scripts/smoke.sh` | 两种模式均 OK |
| `git diff --check` | 通过 |

跨版本对照：alpha.16 发布提交 `761f783` 上 `PiWebDesktopTests/` 有 33 个文件、859 个 `func test`；
本轮结束（`c430c0f`）为 36 个文件、943 个；随后更新链路稳定化提交 `10f9244` 增至 37 个文件、946 个，alpha.17 发布提交补上失败路径守卫后为 38 个文件、951 个。

**未验证项**：以下需要真机或人工操作，本轮没有执行，不能声称已验证——

- T5：GUI 菜单与设置窗口的实际观感（⌃⌘F 唯一绑定、设置窗口追平后的控件状态）。
- T11：真实 `/Applications` 环境下的桌面自更新端到端流程（含下载窗口期重复触发的拦截）。

`Sources/Diagnostics/`（2304 行，`LogWriter.swift`、`LogRedactor.swift`、`DiagnosticsCollector.swift`、
`DiagnosticsClipboard.swift`、`DiagnosticsWindowController.swift`、`FirstLaunchDiagnostics.swift`）
不在本轮审计范围内，建议作为下一轮对象。
