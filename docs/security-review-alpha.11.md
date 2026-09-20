# Pi Web Desktop `0.1.0-alpha.11` 安全评审（delta）

评审对象：PR #143（已合并为 `main` 上的 `03e06f5`；关闭 [#142](https://github.com/Su-luoya/pi-web-desktop/issues/142)）的实际改动
——`Sources/` 从 36 个扁平文件重排为 5 个领域目录下的 83 个文件，并把大文件按职责拆分。基线
`main` = `5bd520e`。评审日期与工具环境见[发布说明](release-notes-v0.1.0-alpha.11.md#本机实测环境与版本可追溯)。

本版**没有任何功能或行为改动**，因此这份 delta 评审的重点不是“新能力带来了什么边界”，而是
“**重组本身有没有悄悄改变边界**”：进程启动点、网络访问点、秘密读写点、确认流程、工程目标成员
关系、以及构建脚本收集范围。

## 0. 变更面

- 代码改动：`Sources/` 内 36 → 83 个文件（`Sources/App/` 21、`Sources/Services/` 17、
  `Sources/Diagnostics/` 6、`Sources/Updates/` 37、`Sources/Support/` 2），`PiWebDesktopTests/`
  28 → 29 个文件（新增共享测试支持 `SourceScanSupport.swift`）。
- 非代码改动：`PiWebDesktop.xcodeproj/project.pbxproj`（按目录重新登记）、`Scripts/build.sh`
  （按 `Sources/**/*.swift` 收集）、`Scripts/check-identity.sh`（一处路径常量）、`Scripts/pbxproj_gen.py`
  （app-only 清单里的路径）与活文档。
- 两处命名/可见性变化：`private` / `fileprivate` → `internal`（跨文件使用）；三个更新适配器类改名
  `*Adapter` → `*Coordinator`。

## 1. 机械核对：安全相关模式的计数对比

方法：把 `main` 的 `Sources/` 导出到临时目录（`git archive 5bd520e Sources`），对两棵树按固定字符串
统计同一组安全相关模式的**出现行数**，逐项比对。任何一项不等都必须能逐行解释。

| 模式 | `main`（36 文件） | 本版（83 文件） |
| --- | --- | --- |
| `let process = Process()` | 4 | 4 |
| `executableURL` | 4 | 4 |
| `.arguments =` | 6 | 6 |
| `URLSession` | 14 | 14 |
| `https://` / `http://` 字面量 | 16 / 5 | 16 / 5 |
| `SecItem` | 7 | 7 |
| `SecRandomCopyBytes` | 3 | 3 |
| `FileManager.default` | 26 | 26 |
| `createFile(` / `write(to:` | 7 / 3 | 7 / 3 |
| `removeItem(at:` | 10 | 10 |
| `NSAlert` | 27 | 27 |
| `NSWorkspace.shared.open` | 6 | 6 |
| `LogRedactor` / `LogWriter` | 79 / 16 | 79 / 16 |
| `fatalError` | 3 | 3 |
| `try!` / `as!` | 0 / 0 | 0 / 0 |
| `chmod` / `setenv` | 0 / 0 | 0 / 0 |
| `NSApplication` | 14 | 14 |
| `Timer.scheduledTimer` | 2 | 2 |
| `UserDefaults` | 76 | 77 |

唯一一处数量差异是 `UserDefaults` 多 1 行：新增文件的文档注释
`/// Layered user settings and defaults backed by UserDefaults.`（`Sources/Updates/UpdateSettingsModel.swift`）。
把两棵树里所有含 `UserDefaults` 的行做**行多重集合比较**，差异只有这一行新注释；没有任何新增的读写点、
新的 suite、新的键。

## 2. 进程启动面（4 处，集合与参数构造未变）

两棵树的 `let process = Process()` 都是 4 处，只换了文件位置：

| `main` 位置 | 本版位置 | 角色 |
| --- | --- | --- |
| `Sources/ProcessInspector.swift:119` | `Sources/Services/CommandRunning.swift:122` | `ProcessProbeProcess`：依赖探测、版本查询等只读探针的共享执行器 |
| `Sources/DiagnosticsCollector.swift:178` | `Sources/Diagnostics/DiagnosticsCollector.swift:181` | 诊断导出里的 `lsof` / `ps` 只读调用 |
| `Sources/PiCLIUpdateAdapter.swift:684` | `Sources/Updates/PiCLIUpdateCommand.swift:275` | Pi CLI 更新命令（参数数组 `update --self`） |
| `Sources/PiPackageUpdateAdapter.swift:1235` | `Sources/Updates/PiPackageUpdateCommand.swift:251` | 扩展包更新命令（参数数组 `update npm:<包名>`） |

- 参数构造仍是 `executableURL = URL(fileURLWithPath: executable)` + `arguments = Array(arguments.dropFirst())`
  （计数 4 / 6 未变），没有任何新增的 `sh -c`、字符串拼接命令或 shell 路径。
- 子进程环境白名单、stdin `/dev/null`、stdout/stderr 重定向、信号只发本进程 pid 的实现都在
  `ProcessProbeProcess` 内原样保留（`Sources/Services/CommandRunning.swift`）。
- 源码级负向断言（测试里断言生产代码不含 `kill` / `signal` / `SIGTERM` / `sudo` / shell 调用）仍然存在，
  且随 `SourceScanSupport` 适配新目录后继续生效。

## 3. 网络访问面

`URLSession` 14 行、`https://` 16 行、`http://` 5 行，两棵树完全一致。更新检查的两个主机常量
（`api.github.com`、`registry.npmjs.org`）没有新增、没有改写；`Sources/Updates/` 只是把原来一个
文件里的检查器、缓存、设置、通知拆到多个文件，请求构造代码在同一批 `UpdateHTTP*` 类型里。

## 4. 持久化与秘密面

- `SecItem` 7 行、`SecRandomCopyBytes` 3 行两棵树一致，且仍只出现在 `Sources/Services/KeychainStore.swift`：
  Keychain 的读写入口没有被拆分到其他文件，没有新增调用方。
- `UserDefaults` 的读写点未变（见 §1）；`workspace.recentPaths`、更新告警键、更新设置键都在
  `AppConfiguration` / 更新设置模型里，位置变化不影响键名或写入内容。
- 文件写入面：`createFile(` 7、`write(to:` 3、`removeItem(at:` 10，两棵树一致；日志与缓存目录的
  构造仍走 `AppPaths`。
- 脱敏面：`LogRedactor` 79、`LogWriter` 16，两棵树一致；日志与诊断文本的实现没有被拆成“绕过脱敏”的
  新路径。

## 5. 用户确认面

`NSAlert` 27 行两棵树一致：退出确认、目录切换确认、更新确认、危险操作确认都在原处，没有因为拆分而
丢失确认步骤或新增未确认的执行路径。日志文本、确认框文案、菜单标题都是原样搬移（归一化行多重集合
比较里唯一差异是 `ServiceManager.currentState` 的 setter 可见性）。

## 6. 可见性放宽（`private` / `fileprivate` → `internal`）

跨文件使用的声明提升为模块内可见，这是 Pure Swift 的编译器可见性，不改变运行时行为；同模块内没有
新增调用点（模式计数对比佐证）。唯一的 setter 放宽：

- `Sources/Services/ServiceManager.swift` 的 `currentState`：`private(set) var` → `var`（`internal`）。
  写入点仍是原来的几处状态转换（启动/停止/失败），**没有**新增写入方；风险是“以后可能被误写”，
  不是安全边界（`ServiceManager` 的状态本来就是应用内部状态，不跨进程、不持久化）。

## 7. 工程文件与脚本的收集范围

- `PiWebDesktop.xcodeproj/project.pbxproj`：app target 的 Sources 阶段 **83** 条；测试 target 的
  Test Sources 阶段 **96** 条 = 67 个共享生产源文件 + 29 个测试文件。app-only（只在 app target）
  仍是 **16** 个（`main.swift`、`AppDelegate*`、窗口/设置控制器、`DiagnosticsWindowController`、
  `DiagnosticsClipboard` 等），与 `main` 的 app-only 集合**同一类**，没有把测试支持文件或 window-only
  代码塞进 app target，也没有把 app-only 文件拉进测试 target。
- `Scripts/build.sh` 现在按 `Sources/**/*.swift` 收集（新增文件不需要逐文件登记），仍使用同一套
  `-O -wmo` 与 Info.plist 拼装；`Scripts/check-release-version.sh`、`Scripts/smoke.sh`、`Scripts/package-release.sh`
  的白名单与门禁逻辑没有变化。
- `Scripts/check-identity.sh`：`SERVICE_CONFIG_REL` 常量更新为 `Sources/App/ServiceConfiguration.swift`，
  45 项检查全部通过（`PASSED (45 checks)`）。
- `Scripts/scan-secrets.sh`：本版改动触发的文本扫描通过（`suppressed 15 lines`、
  `PASS (no matches in tracked files; no untracked files)`），抑制标记数与 alpha.5…alpha.10 一致。

## 8. 测试面

- 完整 XCTest 套件在本机 shim 上跑过两棵树：`main` 基线 746 passed / 0 failed（另有
  `ServiceConfigurationTests` 单独重跑 12 passed / 0 failed，原因是旧工程文件里该文件的 BuildFile
  注记写成 `in Sources`，本机收集脚本按注记判定而漏收集），本版 **758 passed / 0 failed**。
- 新增的 `PiWebDesktopTests/SourceScanSupport.swift` 只是测试侧支持：按**文件名**在运行时枚举
  `Sources/`，让原先直接读 `Sources/<文件名>.swift` 的结构断言（“代码里没有 `kill` / `sudo` / shell
  调用”“命令只以参数数组启动”等）在目录重组后继续生效。它没有读用户数据、没有启动子进程、没有
  网络访问，并且只在测试 target 里。

## 9. 发现

### 阻断项

无。

### 非阻断项

- **`R1`（本版引入，已登记）**：`ServiceManager.currentState` 的 `private(set)` setter 放宽为
  `internal`，只为跨文件的 `ServiceManager+*.swift` 扩展写入状态。当前没有新增写入点；风险是未来
  可能被误写。跟踪：[#142](https://github.com/Su-luoya/pi-web-desktop/issues/142)（也可以随
  [#135](https://github.com/Su-luoya/pi-web-desktop/issues/135) 一起收紧：把状态转换收进一个
  `private` 方法）。
- **`R2`（本版引入的命名不一致，非安全项）**：生产类型已改名为 `*Coordinator`，但
  `PiWebDesktopTests/PiCLIUpdateAdapterTests.swift`、`PiWebUpdateAdapterTests.swift`、
  `PiPackageUpdateAdapterTests.swift` 三个测试**文件名与类名保持旧名**，多个活文档也仍以旧名引用这些
  测试文件。这是本轮有意保留的（改测试文件名会让 `-only-testing` 过滤器与历史记录里的引用失效）；
  三处源码注释里残留的旧类型名已在本版一并改成新名（`Sources/App/AppDelegate.swift`、
  `Sources/Updates/UpdateChecker.swift`）。

### 既往观察（非本次 delta）

`O-1` 与 `F1`–`F4` 都是 alpha.9 / alpha.10 的遗留，本版没有修也没有扩大，位置随重构更新后记录在
[发布说明的“已知问题”](release-notes-v0.1.0-alpha.11.md#1-本版仍然存在的问题)里
（`F1` 现在位于 `Sources/App/AppDelegate+Service.swift:144-148` 与 `Sources/Services/ServiceManager.swift:172`，
`O-1` 的两行警告现在位于 `Sources/Updates/PiCLIUpdateStatus.swift:113` 与
`Sources/Updates/PiWebUpdateCoordinator.swift:422`）。

## 10. 已核实无问题

- 进程启动点、参数构造、环境白名单与信号策略未变（§2）。
- 网络域名、请求头、关闭开关未变（§3）。
- Keychain 入口唯一性、UserDefaults 键与写入内容、日志脱敏都在原处（§1、§4）。
- 确认流程（`NSAlert` 27 处）未变（§5）。
- 没有新增 `try!` / `as!` / `fatalError`（0 / 0 / 3，与基线一致）。
- 没有新增提权、`chmod`、`setenv`、shell 调用（两棵树均为 0）。
- 工程目标的成员关系没有把 app-only 代码放进测试 target 或反之（§7）。
- 行为不变性有两重机械证据（归一化行多重集合、模式计数）和一重运行证据（758 条用例全过），见
  [发布说明](release-notes-v0.1.0-alpha.11.md#行为不变性的证据)。

## 11. 证据不足 / 无法确认（不作猜测）

- 本机只有 Command Line Tools，没有完整 Xcode：**没有执行** `xcodebuild build` / `xcodebuild test`
  / `xcodebuild -showBuildSettings`。工程文件的正确性由 CI 在 PR #143 上验证；本机的证据是
  `Scripts/build.sh` 用同一份 83 文件的源集合构建成功、shim 测试台跑通 758 条用例、以及
  `plutil`/`PlistBuddy` 对工程文件的解析。
- 没有做真机 GUI 手工验收（本版无行为改动）；alpha.10 功能面的真机项仍由
  [#135](https://github.com/Su-luoya/pi-web-desktop/issues/135) 跟踪。
- 没有做更新检查与自动更新的端到端真机演练（与本版无关，沿袭 alpha.10 的覆盖范围）。

## 12. 发布决定

- 阻断项 0 条，非阻断项 2 条（`R1` 状态 setter 可见性、`R2` 测试文件命名不一致），均不构成安全
  边界变化，**不阻塞** `0.1.0-alpha.11` 的发布。
- 发布门槛：`Scripts/build.sh`、`Scripts/check-identity.sh`（45 项）、`Scripts/scan-secrets.sh`
  （含自检）、`Scripts/smoke.sh`（两种模式，`items=6 blockers=3`）、`Scripts/package-release.sh`
  与其自检、`codesign --verify --deep --strict` 全部通过；758 条用例全过。`xcodebuild` 由 CI 覆盖。
