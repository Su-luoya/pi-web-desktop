# Pi Web Desktop `0.1.0-alpha.17` 安全评审（delta）

评审对象：`main` 上的 `10f9244`（`v0.1.0-alpha.16` 之后两个提交：`24a07e2` 第二阶段审计修复、
`10f9244` 更新链路稳定化）加上本版发布提交（版本 bump、发布说明、本报告、门槛执行记录）。
基线：`main` = `761f783`（`v0.1.0-alpha.16` 的发布提交）。
本报告是**只读评审**：没有修改任何代码、工程文件或脚本，只读取源码、脚本、工程文件与文档。

**定位**：本版是 alpha.16 之后第一次发版，因此同时覆盖两段 delta：一是第二阶段六份只读审计报告的
40+ 项修复（`761f783..24a07e2`，PR #189），二是四条更新链路的稳定化（`24a07e2..10f9244`）。
前者的完整评审已单独记录在
[security-review-2026-10-post-alpha.16.md](security-review-2026-10-post-alpha.16.md)（评审对象 `c430c0f`，
即 PR #189 合并前）；本报告**不重复**该文件的逐项结论，而是在 §2 复述其信任边界结论并补上
`c430c0f..10f9244` 这一段，然后把两份合起来当作本版的审查结论。

## 0. 方法与证据基线

### 0.1 评审范围与命令

| 命令 | 用途 |
| --- | --- |
| `git diff --shortstat 761f783..10f9244` | 本版 delta 规模：85 个文件，`+4428` / `-480` |
| `git diff --shortstat 761f783..10f9244 -- Sources PiWebDesktopTests` | 源码与测试面规模 |
| `git diff --numstat 761f783..10f9244 -- Sources` | 逐文件增删行（下表） |
| `git diff 761f783..10f9244 -- Sources PiWebDesktopTests \| grep -E '^[+-]import'` | 依赖 / 框架面变化 |
| `git grep -c -F <pattern> HEAD -- Sources` 对齐 `761f783` | 安全相关模式计数对比（§1） |
| `git grep -n -F sendGroupSignal HEAD -- Sources` | 信号面调用点清点（S1） |
| `git grep -n -F URLSession HEAD -- Sources` / `git diff` 逐条核对 | 新增网络面（S4） |
| `git diff 761f783..10f9244 -- Sources \| grep '^+.*UserDefaults'` | 新增持久化键（S8） |
| 逐行阅读 `Sources/App/SingleInstanceLock.swift`、`Sources/App/WebViewNavigationPolicy.swift`、`Sources/App/WebViewController.swift`、`Sources/Services/ServiceManager.swift`、`Sources/Services/ServiceOwnership.swift`、`Sources/Services/KeychainStore.swift`、`Sources/Services/ToolPath.swift`、`Sources/Updates/DesktopAppUpdate.swift`、`Sources/Updates/PiCLIUpdatePlanner.swift`、`Sources/Updates/UpdateCheckScheduling.swift`、`Sources/App/AppDelegate+UpdateChecks.swift` | 信任边界与更新链路 |
| `./Scripts/build.sh`、`check-identity.sh`、`scan-secrets.sh --self-test`、`scan-secrets.sh`、`check-release-version.sh`、`smoke.sh`、`xcodebuild test` | 本版门槛实测（结果见 [alpha-release-checklist.md](alpha-release-checklist.md) 的执行记录） |

源码面（`Sources/`）55 个文件有改动，`+1747` / `-408`；测试面 21 个文件（新增 4 个：
`AppMenuHygieneTests.swift`、`PreferencesRefreshPolicyTests.swift`、`SingleInstanceLockTests.swift`、
`UpdateCheckTimerModeTests.swift`），`+2262` / `-45`。逐文件前 12 位（按 `+` 行数）：

| 文件 | +/− | 本版内容 |
| --- | --- | --- |
| `Sources/Services/ServiceManager.swift` | `+154/-46` | 启动就绪改为墙钟截止、主线程阻塞迁出、停止流程的确认退出与有界复查 |
| `Sources/Updates/DesktopAppUpdate.swift` | `+147/-18` | 解压失败清 staging、`NSApp.terminate` 回主线程、解压参数注释 |
| `Sources/Updates/PiPackageUpdateCoordinator.swift` | `+136/-105` | 命令输出脱敏 / 折叠 / 尾部处理统一、退出与超时判定 |
| `Sources/App/SingleInstanceLock.swift` | `+122/-0`（新增） | 内核 `flock` 单实例互斥 |
| `Sources/App/AppDelegate+UpdateChecks.swift` | `+100/-12` | 校验和失败结束本轮、菜单闸控、手动 / 自动额度分离 |
| `Sources/App/PreferencesWindowController.swift` | `+94/-10` | 设置窗口追平（可见时刷新，保存不再写回旧值） |
| `Sources/Updates/UpdateRollback.swift` | `+69/-29` | 回滚的事务一致性 |
| `Sources/Diagnostics/LogWriter.swift` | `+66/-19` | 轮转阈值、打开句柄前就地脱敏 |
| `Sources/Services/ToolPath.swift` | `+52/-2` | 登录 shell 输出只取末行 + `expandingTildeInPath` |
| `Sources/Updates/ComponentInstallationDetector.swift` | `+49/-16` | `command -v` 名单白名单 |
| `Sources/Updates/UpdateChecker.swift` | `+48/-7` | 检查状态串行化、停止语义、`userAgent` 控制字符过滤 |
| `Sources/App/AppDelegate+Menus.swift` | `+48/-5` | ⌃⌘F 唯一绑定、菜单跟随 key 窗口 |

### 0.2 证据强度分级

- **[A]** 命令输出可复现（计数、脚本退出码、脚本断言、实测计时）。
- **[B]** 源码逐行阅读 + 机械计数支持的结论。
- **[C]** 只能推断、本次没有运行证据的结论（一律不当作已核实，见 §5）。

## 1. 模式基线对比

| 模式 | `761f783` | `10f9244` | 结论 |
| --- | --- | --- | --- |
| `kill(` | 7 | 7 | 未变 |
| `sendGroupSignal` | 4 | 5 | **+1**，全部是符号出现次数（`ServiceManager.swift` 两处调用改为带 `_ =` 的结果忽略 + 一处注释提到函数名）；实际信号调用点仍是 SIGTERM / SIGKILL 各一处，见 S1 |
| `Process()` | 7 | 7 | 未变 |
| `.arguments =` | 8 | 8 | 未变 |
| `keychain.save(` | 1 | 1 | 未变 |
| `URLSession` | 28 | 31 | **+3**，两处是 `ServiceScheduling.swift` 的注入式会话持有（不是新网络目标），一处是注释；见 S4 |
| `getifaddrs` | 2 | 2 | 未变 |
| `try!` | 0 | 0 | 未变 |
| `as!` | 0 | 0 | 未变 |
| `fatalError` | 3 | 3 | 未变 |
| `UserDefaults` | 79 | 82 | **+3**，全是注释；`UserDefaults` 键集合未增加（S8） |

## 2. 第二阶段审计修复的信任边界结论（`761f783..24a07e2`）

完整证据与逐项清单见
[security-review-2026-10-post-alpha.16.md](security-review-2026-10-post-alpha.16.md)。结论复述：

- **只收紧，没有放宽**：信号路径（确认退出后才发信号、`EPERM` 仍判存活）、外链从「任意 scheme」
  收紧为 `http` / `https` / `mailto` 三项白名单、单实例互斥从「可重建的锁文件 + 可复用的 PID」
  收紧为内核 `flock`（锁文件 `0600`，位于当前用户 support 目录）。
- **新增攻击面**：只有 `flock` 锁文件本身，以及外链白名单未覆盖的非 WebView 打开路径（该轮不存在）。
- **阻断项 0 条**；需真机验证的项：T5（GUI 菜单与设置窗口观感）、T11（真实 `/Applications` 的
  端到端自更新）。
- **未覆盖**：`Sources/Diagnostics/`（2304 行）未做独立审计；解压器对恶意归档路径（R12）与
  `/Applications` 写权限探针的 TOCTOU（R13）是从 alpha.15 继承、本轮未重新审计的 [C] 项。

## 3. S1 服务所有权与外部服务只读

`761f783..10f9244` 在信号面**没有新增调用点**。`ServiceManager.swift:1027-1046` 的两处
`signaler.sendGroupSignal(SIGTERM/SIGKILL, toProcessGroup:)` 就是 alpha.16 已有的那两个位置，
本版只把返回值显式忽略（`_ =`）并补注释说明「不看返回值：`ESRCH` / `EPERM` 只说明不到，不代表已退出」。
原因见 [bugfix-round-2.md](bugfix-round-2.md) 的服务生命周期一节。

- 服务所有权判定（`ServiceOwnership`）未改语义：仍以「PID + 启动时间 + 命令指纹」为依据，不按进程名匹配。
- `Process()` 与 `.arguments =` 计数不变（7 / 8）：本版没有新增子进程调用点。
- `ProcessInspector` 的 `ps` / `lsof` 调用从主线程迁出（`+14/-2`），参数集合与解析未变。

结论：**通过**。

## 4. S2 凭据与 Keychain

`keychain.save(` 仍为 1 处。`Sources/Services/KeychainStore.swift`（`+42/-1`）的变化是把读取做**三态化**
（存在 / 不存在 / 读取失败），并在凭据缺失时优先收回 loopback 监听；这是 fail closed 方向的收紧，
没有新增凭据字段、没有新增 Keychain 访问点、没有把凭据写入日志或 UserDefaults。

结论：**通过**。

## 5. S3 日志与脱敏

- 脱敏规则集没有减少：`Sources/Diagnostics/LogRedactor.swift`（`+33/-11`）与
  `Sources/Diagnostics/LogWriter.swift`（`+66/-19`）集中在轮转阈值、打开子进程句柄前就地脱敏历史日志、
  写入失败只记录不崩溃。
- 本版新增的日志点都在统一 `LogRedactor` 之后：更新链路的阶段名、计数、毫秒时钟；
  `PiPackageUpdateCoordinator.swift` 的「统一命令输出脱敏 / 折叠 / 尾部处理」是把两处重复逻辑合并到
  既有脱敏路径上，不是新增未脱敏输出。
- `LogRedactorTests.swift` 的幂等与「不误伤 `tokenizer=` / `passwordless=`」断言保持通过。

结论：**通过**。

## 6. S4 网络面与放行面

| 项 | 结论 |
| --- | --- |
| 放行面（`.piwww` / WebView 决策） | 实现未改；`WebViewNavigationPolicy.swift`（`+21/-3`）只新增 `block` 决策与外链协议白名单 |
| 外链 | 从「任意 scheme 交给 `NSWorkspace.open`」收紧为 `http` / `https` / `mailto`；其余返回 `.block`，见 S4-1 |
| 新增 `URLSession` | 两处是 `Sources/Services/ServiceScheduling.swift` 的注入式会话持有（为把 `Timer` 与调度解耦、便于测试），不是新的请求目标；请求集合、主机白名单、超时未变 |
| 桌面自更新下载 | 仍是 `ephemeral` 配置、关闭 cookie / 凭据存储 / 本地缓存；资产 URL 精确匹配、重定向主机白名单未扩大 |
| 检查器 | `UpdateChecker.swift` 的 `userAgent` 拼接前过滤控制字符（含 CR/LF），防止请求头拆行 |

### S4-1 外链协议白名单

`Sources/App/WebViewNavigationPolicy.swift` 新增：

```swift
static let externalSchemes: Set<String> = ["http", "https", "mailto"]
```

两条外开路径（`decidePolicyFor navigationAction` 与 `createWebViewWith`）都先过这层判断，不在白名单内的
返回 `.block`，不再调用 `NSWorkspace.shared.open`。**信任含义**：挡住 `file:` / `ssh:` / 自定义 app
scheme 与 `javascript:` 之类的降级路径，即「网页里的一行链接不能直接让系统去打开任意本地文件或注册
应用」。代价是用户会在少数场景（`ftp:` 等）失去自动打开，需要自行复制链接；这是有意的取舍。

结论：**通过**。

## 7. S5 供应链与 CI

- `.github/workflows/release.yml` 与 `build.yml` **不在本版 delta 内**。
- `Scripts/` 未改动（`git diff --shortstat 761f783..10f9244 -- Scripts` 为空）。
- 没有新增第三方 Swift 包（无 `Package.swift` / `Package.resolved` 变化），没有新增 npm 运行时依赖。
- 版本来源仍唯一（`Configuration/AppIdentity.xcconfig`），`check-release-version.sh --self-test` 通过。

结论：**通过**。

## 8. S6 签名与分发

本版仍是 ad-hoc、未公证：没有 Developer ID、没有公证、没有 `spctl` 放行。`Scripts/build.sh` 未改。
文档（发布说明、模板、README）继续明写「ad-hoc 签名、未公证」，没有把本机校验或同源 SHA-256 说成
开发者身份验证。

新增的运行时供应链面仍是 alpha.15 登记的 `R10`（从 GitHub Release 取资产并替换自身），本版没有扩大：
自更新的准入条件（`/Applications`、用户确认、bundle 身份自检、同源校验值）都没有放宽——本版改的三处
都在失败路径上（结束后不再卡死、清 staging、回主线程退出），见 §3-3。

结论：**通过**。

## 9. S7 依赖与静态卫生

- `git diff 761f783..10f9244 -- Sources PiWebDesktopTests | grep -E '^[+-]import'` 只出现
  `+import Darwin` ×2、`+import Foundation` ×2、`+import XCTest` ×4，没有任何第三方框架，也没有删除
  任何 `import`。
- `try!` / `as!` 均为 0；`fatalError` 仍为 3 处（与 alpha.16 相同的位置）。

结论：**通过**。

## 10. S8 持久化与隐私足迹

`UserDefaults` 计数从 79 变为 82，但**全部是注释**（`git diff ... | grep '^+.*UserDefaults'` 的三条命中
都在解释既有读-改-写互斥）。本版**没有新增 UserDefaults 键**，没有新增文件持久化位置，没有新增
application support 目录项——`flock` 锁文件复用既有 support 目录（`~Library/Application Support/…`），
权限 `0600`。

结论：**通过**。

## 11. 未覆盖与未验证

以下项**本轮没有运行证据**，一律不当作已核实：

- **本版新增的三处更新链路修复**（计时器 `.common` 模式、校验和失败结束本轮、解压失败清 staging 与
  主线程退出）**没有在真实 `/Applications` 环境做端到端验证**。计时器 `.common` 模式的结论来自真实
  `NSApplication.run()` 事件循环的探针实测（eventTracking 期间默认模式 0 次 vs `.common` 12 次），
  但「每日复查真的会在用户按住菜单时触发」仍是 [B]；另两处只有单元测试与源码断言。
- **真机 GUI 验证未执行**：T5（⌃⌘F 唯一绑定、设置窗口追平后的控件状态）只有
  `PiWebDesktopTests/AppMenuHygieneTests.swift` 的源码级断言；T11（`/Applications` 端到端自更新）
  未执行。
- **`Sources/Diagnostics/` 未做独立审计**：2304 行不在任何一轮评审范围内；§5 的结论只覆盖被改动的行。
- **R12 / R13 继承未重审**：解压器对恶意归档路径、`/Applications` 写权限探针的 TOCTOU，仍为 [C]。
- **`flock` 在网络家目录（NFS / SMB）上的语义**未测试 [C]。
- **`EPERM` 判为存活的副作用**：若进程组确实存在但永久不可信号，停止流程只能依赖有界复查耗尽后
  上报失败 [C]。这是「宁可报失败也不误杀」的取舍，符合既有原则。

## 12. 门槛实测（提交 `10f9244` 的最终树）

| 检查 | 结果 |
| --- | --- |
| `xcodebuild test` | 951 个测试，0 失败 |
| `./Scripts/build.sh` | 成功，0 warning |
| `./Scripts/check-identity.sh` | `PASSED (45 checks)` |
| `./Scripts/scan-secrets.sh` | PASS |
| `./Scripts/check-release-version.sh` | `PASSED (MARKETING_VERSION 0.1.0-alpha.17, CURRENT_PROJECT_VERSION 17; tag comparison skipped)` |
| `./Scripts/smoke.sh` | 两种模式均 OK |
| `git diff --check` | 通过 |

## 13. 结论

本版在两步里都**没有放宽**任何既有信任边界：第二阶段修的是正确性与可用性（其中外链、单实例、
退出信号三项是收紧），更新链路稳定化修的是失败路径（不卡死、不残留、不在子线程动 AppKit）。
新增攻击面只有 `flock` 锁文件（`0600`）。

阻断项：**0 条**。需要真机验证的项：T5、T11，以及本版三处更新链路修复的端到端表现。
建议下一轮对象：`Sources/Diagnostics/`。
R1–R14 的继承与新增登记：R1–R9 继承 [alpha.15 评审](security-review-alpha.15.md)，R10–R14 见同一份
文档 §7；本轮新增两条跟踪项——**R15**（周期检查计时器与退出计时器是否都挂 `.common`，现由
`PiWebDesktopTests/UpdateCheckTimerModeTests.swift` 守护）与 **R16**（更新失败路径必须调用
`finishDesktopAppUpdateRound`，本版只用源码断言与人工核对，没有运行时守护）。
