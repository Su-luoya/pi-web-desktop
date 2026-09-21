# Pi Web Desktop `0.1.0-alpha.13` 安全评审（delta）

评审对象：`main` 上的 `506f5d6`（#158 / #135 / #139 / #141 / #157 五个 Issue 的修复，PR #161 / #160 /
#159 / #162 / #164 合并后的 main；main CI run [35620781999](https://github.com/Su-luoya/pi-web-desktop/actions/runs/35620781999)
为 `success`——本报告的结论不依赖该 run）。
基线：`main` = `730128d`（`v0.1.0-alpha.12` 的草稿 tag 指向的发布提交）。
本报告是**只读评审**：没有修改任何代码、工程文件或脚本，只读取源码、脚本、工程文件与文档。

发布面的一个前提：`v0.1.0-alpha.12` 只有草稿 Release，**从未发布**（其资产不可下载）。因此本版是
#147 / #148 / #149 / #150 四个修复的**首次发布**：这四组代码在本版 delta 里没有改动，针对它们的结论由
[alpha.12 安全评审](security-review-alpha.12.md) 给出，本报告**继承**该评审的 S1–S8 结论与其非阻断项
`R1`–`R3`，并在 §9 中一并列出；本报告的重点是本版 delta（#158 / #135 / #139 / #141 / #157）。

## 0. 方法与证据基线

### 0.1 评审范围与命令

| 命令 | 用途 |
| --- | --- |
| `git diff --stat 730128d..506f5d6` | 本版 delta 的文件清单（22 个文件，`+1291` / `-32`） |
| `git diff --numstat 730128d..506f5d6` | 逐文件增删行（下节） |
| `git grep -c -F <pattern> <rev> -- Sources` | 安全相关模式的基线 / 本版计数对比（各节） |
| `git grep -n -E 'kill\(\|sendGroupSignal' 506f5d6 -- Sources` | 信号面调用点清点（S1） |
| `git diff 730128d..506f5d6 -- Sources \| grep -E '^\+import\|^-import'` | 依赖 / 框架面变化（S7：`SystemProxyWarning.swift` 新增 `Darwin` / `Foundation` / `SystemConfiguration` 三个系统框架导入） |
| `./Scripts/check-release-version.sh`、`./Scripts/build.sh`、`./Scripts/check-identity.sh`、`./Scripts/scan-secrets.sh`、`./Scripts/smoke.sh` | 本版门槛实测（结果见 §5、§8、§12 与 [alpha-release-checklist.md](alpha-release-checklist.md#release-v010-alpha13-执行记录)） |
| 逐行阅读 | 本版 delta 的 10 个 `Sources/` 文件改动与上下文 |

本版 delta 的代码面（`Sources/`）10 个文件、`+746` / `-18`：

| 文件 | +/− | 本版内容 |
| --- | --- | --- |
| `Sources/App/AppDelegate+Menus.swift` | `+25/-3` | #135 F2：工作目录确认文案分三态（受托管运行中 / 外部运行中 / 未运行），按钮标题随受托管与否；#157：「服务」菜单的代理告警项（无告警时隐藏）与菜单构建时的首次刷新 |
| `Sources/App/AppDelegate+PackageUpdates.swift` | `+0/-5` | #135 F3：移除旧的、不检查 `isFileURL` 的 `application(_:open:)` 实现（移到 `AppDelegate+Window.swift`） |
| `Sources/App/AppDelegate+Quit.swift` | `+14/-0` | #158：退出时间线（请求只记一次、停止请求、应用即将终止三个节点） |
| `Sources/App/AppDelegate+Service.swift` | `+60/-1` | #135 F1：领取代次并在 stop 回调里用 `ifGenerationMatches:` 校验；#157：配置保存时立即重算代理告警，新增 `refreshSystemProxyWarning` / `showSystemProxyWarning` / `clearSystemProxyWarning` 与回前台重读 |
| `Sources/App/AppDelegate+Window.swift` | `+63/-0` | #158 Dock 恢复（`applicationShouldHandleReopen` + `showMainWindow`）；#135 F3 文件 URL 过滤 |
| `Sources/App/RecentWorkspace.swift` | `+41/-2` | #135 F4：路径归一化收紧（空/控制字符/相对路径/根目录/超长拒绝，`~` 展开，解析符号链接） |
| `Sources/Services/ServiceManager.swift` | `+155/-7` | #158 两段式停止等待与退出时间线；#135 F1 配置代次 |
| `Sources/App/AppDelegate.swift` | `+16/-0` | #157：`systemProxyWarning` / `systemProxyWarningMenuItem` 状态与只读协调器的装配（日志走 `logWriter.append`） |
| `Sources/Services/ServiceScheduling.swift` | `+6/-0` | #157：`URLSessionServiceProbe` 的会话设 `connectionProxyDictionary = [:]`，探测不再走系统代理 |
| `Sources/Services/SystemProxyWarning.swift` | `+366/-0` | #157（新文件）：`SCDynamicStoreCopyProxies` **只读**读系统代理配置 + 纯函数判定「该不该提示」，日志只写网段 |

`Sources/Diagnostics/`、`Sources/Updates/`、`Sources/Support/` 未改；`Sources/Services/ServiceOwnership.swift`、
`Sources/Services/ProcessInspector.swift`、`Sources/Services/CommandRunning.swift`、`Sources/Services/KeychainStore.swift`
未改；`Package.swift`、`docs/privacy.md` 不在 delta 内。`Scripts/build.sh`（`+4/-1`）只新增
`-framework SystemConfiguration`；`PiWebDesktop.xcodeproj/project.pbxproj`（`+9/-4`）只把新增的源文件与
测试文件登记进 target。测试面新增 `PiWebDesktopTests/SystemProxyWarningTests.swift`（`+247`）、
`ServiceManagerTests.swift`（`+168`）与 `RecentWorkspaceTests.swift`（`+55`），都属于断言，不改变运行时行为。

CI 与文档面：`.github/workflows/build.yml`（`+1/-1`，shell 语法检查逐文件）、
`.github/pull_request_template.md`（`+1/-1`，同一条命令）、`.github/workflows/release.yml`（`+6/-1`，
占位符提示 `::notice::` → `::warning::`）、`docs/releasing.md`（`+15/-3`）、
`docs/development.md`（`+1/-1`）、`docs/settings-and-workspace.md`（`+28/-0`，#157 的「系统代理与
VPN 网段」一节）、`docs/alpha-release-checklist.md`（`+10/-2`）。

### 0.2 证据强度分级

- **[A]** 命令输出可复现（计数、脚本退出码、脚本断言）。
- **[B]** 源码逐行阅读 + 机械计数支持的结论。
- **[C]** 只能推断、本次没有运行证据的结论（一律不当作已核实，见 §11）。

## 1. S1 服务所有权与外部服务只读

**结论：通过；本版没有新增进程启动点或新的信号对象，只缩短了受托管服务的停止等待预算 [A/B]。**

- 计数对比（基线 `730128d` → 本版 `506f5d6`，范围 `-- Sources`）：`let process = Process()` 4 → 4；
  `executableURL` 4 → 4；`.arguments =` 6 → 6；`sendGroupSignal` 4 → 4；`NSWorkspace.shared.open` 6 → 6；
  `NSTask` 0 → 0；`sh -c` 0 → 0；`setenv`、`chmod` 0 → 0 [A]。
- 信号面调用点与基线一致，本版没有新增：
  `Sources/Services/CommandRunning.swift:171`（`kill(pid, SIGKILL)`，本次启动的子进程）、
  `Sources/Services/ProcessInspector.swift:37`（`kill(pid, 0)` 存活探测，PID 0/1 不算应用所有）、
  `Sources/Services/ServiceManager.swift:947`（`sendGroupSignal(SIGTERM, toProcessGroup:)`）、
  `Sources/Services/ServiceManager.swift:959`（预算耗尽后的 `sendGroupSignal(SIGKILL, …)`）、
  `Sources/Services/ServiceOwnership.swift:281` / `:283`（`kill(-processGroupID, signal)`）与 `:288`
  （`kill(-processGroupID, 0)`）[A/B]。
- #135 的配置代次只影响**配置写入顺序**：`beginConfigurationChange()` / `updateConfiguration(_:)` 让更早
  的代次失效，`updateConfiguration(_:ifGenerationMatches:)` 只在仍是最新请求时写入。它不新增进程、不新增
  信号、不改变「对谁发信号」[B]。
- #158 改的是**受托管服务的停止等待**：`stopManagedServiceOnQuit` 仍走既有所有权校验（`processGroupID > 1`、
  只对应用自己启动并验证过的进程组发信号），SIGTERM 之后改为两段式探测（前 20 次每 10 毫秒，之后每
  50 毫秒，睡眠总预算 1000 毫秒；`stopPollAttempts` 由预算推导为 36），预算用尽且进程组仍存活时才
  SIGKILL。**这是 S1 面的行为变化**：宽限期从固定 4 秒收紧到约 1 秒，已登记为非阻断项 `R4`（§9）[B]。
- 外部服务仍不会被重启：本版没有改动所有权判定，也没有给「不是应用启动的服务」增加任何信号路径；
  #135 F2 只是把确认文案按是否受托管分开讲 [B]。

## 2. S2 凭据边界

**结论：通过；本版没有新增凭据读写点 [A/B]。**

- Keychain 写入点计数 1 → 1（`keychain.save(` 仍只在 `Sources/Services/KeychainStore.swift` 的
  `RemoteAccessSetup.apply` 的“用户提供新密码”分支）；`RemoteAccessPassword.load` 计数 3 → 3 未变；
  `KeychainStore.swift` 不在本版 delta 内 [A/B]。
- 本版新增的输入面（`application(_:open:)` 的 URL 数组、`RecentWorkspaceStore.normalizedPath` 的路径
  文本）都不接触凭据：URL 只做 `isFileURL` 过滤与 `requestWorkspaceSwitch`，路径只做归一化与长度检查，
  两者都不读取、不比较、不写入密码 [B]。
- #157 也不接触凭据：新增代码只读系统代理配置（`SCDynamicStoreCopyProxies`），判定输入是服务地址、
  代理字典与例外列表，没有新增 Keychain / 密码路径，也不记录代理字典内容 [B]。
- 本版没有新增剪贴板写入点，也没有改变 #150 的剪贴板内容（`http://<地址>:<端口>/`，不含凭据）；
  `NSPasteboard` 相关调用点不在 delta 内 [B]。
- 密码不会进入新日志：见 §3 的三条新增日志，内容只有计数、阶段名与毫秒时钟 [B]。

## 3. S3 日志与诊断脱敏

**结论：通过；本版新增日志都走统一脱敏链路，且不包含路径、URL 或参数 [A/B]。**

- 统一脱敏链路未变：`LogWriter.record(_:)` → `append(_:)` →
  `Sources/Diagnostics/LogWriter.swift` 的 `let payload = Data(redactor.redact(text).utf8)`；
  `LogWriter.swift` 不在本版 delta 内 [B]。
- #135 F3 新增两处日志（`Sources/App/AppDelegate+Window.swift`）：打开请求含**非文件 URL 的数量**、
  含**多个文件 URL 的数量**。都先经 `logRedactor.redact(...)` 再 `append`（`append` 内部二次脱敏），
  且**不记 URL 或路径**（源码注释明确写“只记数量，不记路径”）[B]。
- #158 新增退出时间线：`ServiceManager.logQuitTimeline(_:detail:)`（`Sources/Services/ServiceManager.swift`）
  把 `QuitTimeline.line(stage, detail:)` 交给 `logWriter.append`；阶段取值为 `退出请求` /
  `请求停止托管服务` / `已发送 SIGTERM` / `已发送 SIGKILL` / `子进程已退出` / `应用即将终止`，`detail`
  只有毫秒数（例如“SIGTERM 之后等待 37ms”“等待超过 1000ms（睡眠上界）”）。源码注释写明日志行
  **只含阶段名、毫秒时钟与相对进程启动的单调偏移，不含路径、URL 或参数** [B]。
- #158 还保证一个退出序列**只记一次**“退出请求”：状态机不在 `.idle` 时不再写第二行（`NSApp.terminate(nil)`
  会重入 `applicationShouldTerminate`），避免时间线出现两个起点 [B]。
- #157 新增三处日志调用（`SystemProxyWarningCoordinator`，`Sources/App/AppDelegate.swift` 把
  `logWriter.append` 作为 `log` 闭包注入）：检测到「代理未排除 VPN 网段」并提示、例外已覆盖时自动清除、
  用户手动清除。三条日志只写网段写法（`vpnSubnetDescription`，即 `100.x.y.z`），不写用户真实地址；
  `append` 内部仍走统一脱敏 [B]。
- 诊断导出面未变：`Sources/Diagnostics/DiagnosticsCollector.swift` 不在 delta 内，诊断项集合
  （`items=6 blockers=3`）与 alpha.11 / alpha.12 一致 [A]。
- 行为变化的如实说明：本版把“退出时间线”第一次写进日志（阶段名 + 毫秒时钟），并把打开请求被忽略的
  数量写进日志。两者都是可诊断性改动，不含私密地址、路径或凭据 [B]。

## 4. S4 网络边界

### 4.1 #135：`open` URL 过滤与最近工作目录路径归一化

**结论：通过；两个方向都是收紧，不涉及任何网络放行面 [B]。**

- `application(_:open:)`（`Sources/App/AppDelegate+Window.swift`）先按 `urls.filter(\.isFileURL)` 过滤：
  非文件 URL（`http`/`https`、自定义 scheme）显式忽略，只记数量。判据是 `isFileURL`（`isFileURL` 计数
  0 → 1 [A]），不解析 URL 内容、不发起请求。多个文件 URL 只处理第一个。
- 旧的、不检查 `isFileURL` 的实现已从 `Sources/App/AppDelegate+PackageUpdates.swift` 删除（`+0/-5`），
  避免两个实现并存 [B]。
- `RecentWorkspaceStore.normalizedPath` 的收紧（`Sources/App/RecentWorkspace.swift`）：空 / 控制字符 /
  相对路径 / 根目录 `/`（含 `/..`）拒绝；`~` 展开；解析符号链接并标准化；长度两道检查
  （trim 后与 `~` 展开后的输入长度、解析标准化后的最终长度）上限 `maximumPathLength = 1024` 字节。
  长度必须在 Foundation 改写之前检查——`expandingTildeInPath` 与 `resolvingSymlinksInPath` 会把超过
  `PATH_MAX` 的输入截断回合法长度，只在解析后比较永远看不到超长输入（`ServiceManagerTests` /
  `RecentWorkspaceTests` 覆盖这些分支，见 §11）[B]。
- 这些值的去向未变：UserDefaults 的 `workspace.recentPaths`、菜单标题与 `NSWorkspace.open`；本版没有
  新增持久化键（§8）[B]。

### 4.2 #149 / #150：放行面与监听切换（继承 alpha.12 评审，代码未改）

**结论：通过（继承）。** 放行面仍是「当前配置的服务地址（scheme / host / port 完全一致）+ loopback
（`127.0.0.1` / `localhost` / `::1`，端口等于配置端口）+ inline scheme（`about` / `blob` / `data`）」，
**没有**网段白名单、后缀白名单或通配符；接口枚举仍是 `getifaddrs` 只读本机（`getifaddrs` 计数 2 → 2
未变 [A]）；切换监听仍要求用户确认 + 非 loopback 的非空密码门槛，校验失败不保存、不复制链接。完整
论证见 [alpha.12 评审 §4](security-review-alpha.12.md)。本版没有改动这两条路径上的任何代码 [B]。

### 4.3 #157：健康探测直连与系统代理只读提示

**结论：通过；只影响应用自身的健康探测路径，且对系统代理只读 [A/B]。**

- 探测侧（`Sources/Services/ServiceScheduling.swift`）：`URLSessionServiceProbe` 的会话设置
  `connectionProxyDictionary = [:]`，探测请求不再继承用户代理配置；代理返回的 502 / 407 / 缓存页不再
  被当成「服务已断开」的证据。超时（3 秒）、就绪判据（HTTP `200..<500`）与缓存策略未变 [B]。
- 检测侧（`Sources/Services/SystemProxyWarning.swift`，新文件）：只用 `SCDynamicStoreCopyProxies`
  **读取**系统代理配置——代码里没有 `SCDynamicStoreSetValue` / `SCPreferencesSetValue` 之类的写入
  调用 [A]；输入是服务地址、各 scheme 的代理开关与例外列表，输出是纯函数布尔值。
- 提示条件（三条件同时成立）：服务地址属于 CGNAT 段、该 scheme 的代理（HTTP / HTTPS / SOCKS / PAC）
  确实生效、例外列表未命中。loopback、普通局域网地址、主机名与畸形例外条目都不提示 [B]。
- 刷新时机：菜单创建、设置保存、应用回到前台（用户可能刚去系统设置加了例外）；一次运行内手动清除后
  不再提示，条件消失则自动清除 [B]。
- 日志只写网段（`vpnSubnetDescription` = `100.x.y.z`），不写用户真实地址 [B]。
- 窗口放行面未改：本版没有触碰 `WebViewNavigationPolicy` 或 `getifaddrs` 相关代码（§4.4）[B]。
- 框架面：只新增 `SystemConfiguration` 系统框架导入（`Scripts/build.sh` 的
  `-framework SystemConfiguration`，`project.pbxproj` 登记新文件），无第三方依赖 [A/B]。
- 残余风险见 `R6`（§9）：应用的窗口页面请求仍走系统代理，WebKit 不支持按视图绕行。

### 4.4 未改变的边界

- 默认监听仍是 loopback（`http://127.0.0.1:30141/`），本版没有改默认值 [A]。
- 更新检查的两个主机常量（`api.github.com`、`registry.npmjs.org`）未改，`Sources/Updates/` 不在本版
  delta 内 [B]。
- 没有新增网络请求：`URLSession` 计数 14 → 14 未变、`getifaddrs` 2 → 2 未变 [A]；`Sources/` 的
  delta 里只有 #157 的三个系统框架导入（`Darwin` / `Foundation` / `SystemConfiguration`），没有第三方
  依赖 [A]。

## 5. S5 构建与发布

**结论：通过；本版的两处 CI 改动都是收紧或提高可见性 [A/B]。**

- **#139（门禁空转修复）**：`sh -n Scripts/*.sh` 只会把**第一个**文件当脚本执行，其余文件被当作位置
  参数忽略。三处统一改为逐文件执行 `for f in Scripts/*.sh; do sh -n "$f" || exit 1; done`——
  `.github/workflows/build.yml` 的 `Check shell scripts` 步骤、`.github/pull_request_template.md` 的
  清单项、`docs/releasing.md` 的本地演练命令。`Scripts/` 本身没有改动 [A/B]。
- **#141（占位符门禁）**：`.github/workflows/release.yml` 对渲染后的 Release 说明统计未填充占位符的
  计数（`grep -cE '<待填[写]>'`，与 workflow 里的字面量写法等价；按 #163 的文档约定，本报告不复现
  该占位符字面量），提示从 `::notice::` 升为 `::warning::`；草稿仍会创建（维护者需要从 Release
  Issue 回填），**发布前的人工硬门禁**写在 `docs/releasing.md` 与 `docs/alpha-release-checklist.md`：
  `gh release view v<MARKETING_VERSION> --json body --jq .body | grep -cE '<待填[写]>'` 输出必须为 0 [A/B]。
- **Actions 面未放宽**：delta 里没有改动任何 `uses:` 或 `permissions:` 行，没有新增 Action；
  `release` workflow 的固定 SHA 与最小权限结论继续成立 [A/B]。
- **构建面只有登记性改动**：`PiWebDesktop.xcodeproj/project.pbxproj`（`+9/-4`）把新增的
  `Sources/Services/SystemProxyWarning.swift` 与 `PiWebDesktopTests/SystemProxyWarningTests.swift`
  登记进 target；`Scripts/build.sh`（`+4/-1`）新增 `-framework SystemConfiguration`；`Package.swift`
  未改；版本仍然只有 `Configuration/AppIdentity.xcconfig` 一个来源（`check-identity.sh` 的
  `no hardcoded MARKETING_VERSION outside Configuration/AppIdentity.xcconfig` 通过）[A]。
- **本机门槛实测**（在本工作区、改动文件已 `git add` 后执行；含本报告与发布说明）：

| 命令 | 实测输出 | 退出码 |
| --- | --- | --- |
| `./Scripts/check-release-version.sh --print-tag` | `v0.1.0-alpha.13` | 0 |
| `./Scripts/check-release-version.sh` | `PASSED (MARKETING_VERSION 0.1.0-alpha.13, CURRENT_PROJECT_VERSION 13; tag comparison skipped)` | 0 |
| `./Scripts/build.sh` | `build: release build with -O -wmo`、`Built: …/build/Pi-Web-Desktop.app`（脚本输出工作区绝对路径，此处缩写字面路径）、`…/Contents/MacOS/PiWebDesktop: Mach-O 64-bit executable arm64` | 0 |
| `./Scripts/check-identity.sh` | `PASSED (45 checks)` | 0 |
| `./Scripts/scan-secrets.sh` | `suppressed 15 lines`、`PASS (no matches in tracked files; no untracked files)` | 0 |
| `./Scripts/smoke.sh` | 两种模式 OK：`smoke: ready`、`smoke: diagnostics ready`；`smoke: OK` | 0 |
| `for f in Scripts/*.sh; do sh -n "$f" \|\| exit 1; done` | 无输出 | 0 |
| `git diff --check` / `git diff --cached --check` | 无输出 | 0 |

  完整执行记录见 [alpha-release-checklist.md](alpha-release-checklist.md#release-v010-alpha13-执行记录) [A]。
- ZIP 打包与 checksum 路径：`Scripts/package-release.sh` 不在 delta 内，白名单与“拒绝路径”逻辑沿用
  alpha.11 / alpha.12 的结论；本版发布产物的 checksum 由 `release.yml` 在 tag 上生成，发布后回填 [B]
  （本机未打包）。

## 6. S6 签名与 Gatekeeper 表述

**结论：通过（表述未放宽）[B]。**

- 本版不引入 Developer ID、不做公证；产物仍是 ad-hoc 签名，`spctl` 预期拒绝（退出码 3，这是预期结果）。
- 本版新增/改写的文档（`docs/release-notes-v0.1.0-alpha.13.md`、本报告、checklist 的 alpha.13 记录）
  只写“ad-hoc 签名、未公证、需要手动放行”，没有出现“已签名”“已公证”“可从任意来源安全安装”这类夸大
  表述；安装章节仍指向 README 的手动放行步骤。
- 版本表述一致：文档里的 `0.1.0-alpha.13` / build `13` 与 `Configuration/AppIdentity.xcconfig` 一致，
  由 `check-release-version.sh` 与 `check-identity.sh` 佐证（§5）[A]。
- 本版本机未执行 `codesign -dv` / `spctl`（本版门槛清单不要求，见 §11）。

## 7. S7 依赖与供应链

**结论：通过 [A/B]。**

- **没有新增第三方依赖**：`Sources/` 的 delta 里只新增了系统框架导入（#157 的 `import Darwin` /
  `import Foundation` / `import SystemConfiguration`）；`Package.swift` 不在 delta 内；`project.pbxproj`
  只登记新文件、`Scripts/build.sh` 只新增 `-framework SystemConfiguration`；没有 npm 依赖变更；没有
  新增 Action [A/B]。
- 本版新增的 API 面都是系统框架的既有类型（`NSString.expandingTildeInPath`、
  `URL.resolvingSymlinksInPath`、`NSApplication.applicationShouldHandleReopen`、
  `NSWindow.deminiaturize`、`SCDynamicStoreCopyProxies`），没有第三方库 [B]。
- 没有新增 shell 调用：`sh -c` 0 → 0、`setenv` 0 → 0、`chmod` 0 → 0、`NSTask` 0 → 0、`Process()` 4 → 4 [A]。
- 没有新增 `try!` / `as!`（0 → 0），`fatalError` 3 → 3 未变 [A]。

## 8. S8 个人数据与 secret

**结论：通过 [A]。**

- `./Scripts/scan-secrets.sh`（改动文件已 `git add`）→ `scan-secrets: suppressed 15 lines`、
  `scan-secrets: PASS (no matches in tracked files; no untracked files)`，退出 0；抑制标记数 N=15 与
  alpha.5 … alpha.12 的记录一致（本版没有新增抑制标记）[A]。
- 仓库文本扫描（`./Scripts/check-identity.sh` 第 6 节）对 tailnet 主机名、tailnet DNS 后缀、CGNAT 段
  地址、绝对 home 路径、固定本地代理端点五类模式全部为 `ok`（`PASSED (45 checks)`）[A]。
- 本报告与发布说明只使用占位形式描述地址（`100.x.y.z`、`10/8`、`172.16/12`、`192.168/16`、
  `192.168.x.y`、`~/…`），没有写入真实私网地址、真实主机名或绝对 home 路径 [B]。第一次扫描曾因发布
  说明里出现**属于 CGNAT 段的真实网段字面量**（具体写法已改写为占位形式，本报告不再复现）失败一次；
  改写后通过。这是本次评审中的一次真实发现：**文档里的网段示例本身也会命中扫描器**（见 §11）[A]。
- 个人信息面：本版没有新增 UserDefaults 键——`UserDefaults` 计数 77 → 79，新增的两处都是文档注释
  （`Sources/App/RecentWorkspace.swift` 说明值的去向；`Sources/Services/SystemProxyWarning.swift`
  明确写「不写 UserDefaults」），不是新的读写点 [A/B]；没有新的目录结构或持久化文件；路径归一化收紧后，旧的
  `workspace.recentPaths` 条目若不再满足规则（相对路径、控制字符、超长），读取时会被丢弃 [B]。

## 9. 发现

### 阻断项

无。

### 非阻断项

- **`R1`（继承 alpha.12，代码未改，已登记）**：配置为非 loopback 监听后，**应用窗口会加载该地址的
  页面**（#149 的设计目标）。残余风险：配置误配或被他人修改时，窗口会加载那个主机返回的内容；应用
  不校验该主机身份（ad-hoc、自签、明文 `http` 都可能）。缓解：只有用户显式保存该地址才生效；非
  loopback 必须有非空密码；放行面仍只有该**精确 origin**。处置建议：后续版本在窗口标题或状态栏显示
  当前监听地址。
- **`R2`（继承 alpha.12，代码未改，已登记，非安全放宽）**：`WebViewNavigationPolicy` 的 host 比较不
  处理**尾部点**（FQDN 写法），`host.` 与配置的 `host` 不相等 → 该 URL 被判为外部链接交给系统浏览器，
  **不会放宽放行面**。处置建议：比较前统一去掉单个尾部点。
- **`R3`（继承 alpha.12，代码未改，已登记）**：切换监听地址的「成功」语义是**配置已落盘且停止路径走完**，
  不是“服务已在新地址就绪”；`applyPreferencesConfiguration` 先 `appConfiguration.save(newConfiguration)`，
  再在 `stopService` 回调里 `updateConfiguration` + `reloadAfterConfigurationChange()` + `completion?()`。
  若新地址绑定失败，配置已持久化且**没有自动回滚**，链接仍可能被复制。处置建议：把复制动作与一次成功
  的健康探测绑定，或失败时给出“改回 loopback”的一键路径。
- **`R4`（本版引入，已登记）**：退出等待预算从固定 `40 × 0.1s = 4 秒` 收紧为 **≤1 秒**（两段式：
  20 × 10ms + 36 次探测、睡眠总预算 1000ms），预算耗尽后对同一进程组发 SIGKILL。影响面：只作用于
  应用自己启动、通过所有权校验的受托管服务进程组；外部进程既不被等待也不被信号。风险形态：需要较长
  时间收尾的服务（flush 状态、写盘）可能在 1 秒后被强制终止，极端情况下丢失服务侧未落盘的数据。
  缓解：先探测再睡眠，服务已退出时立即返回（常见路径不睡）；10ms 起步的探测密度使正常的几十毫秒
  退出路径几乎无感；SIGKILL 仍是最后手段而非默认路径。处置建议：真机 smoke 里观察“退出时间线”日志，
  若出现服务总是走到 SIGKILL，考虑按服务类型放宽预算或做成设置项。
- **`R5`（本版引入，已登记）**：占位符门禁在 workflow 里只是 `::warning::`——**草稿仍会在含未填充
  占位符时创建**，真正的硬门禁是发布文档里的人工命令（计数必须为 0 后才能发布）。残余风险：
  维护者跳过人工步骤、把带占位符的说明发布出去。缓解：#141 把提示升为 warning（在 workflow 摘要里
  可见），`docs/releasing.md` 与 `docs/alpha-release-checklist.md` 都写明“非 0 不要发布”，
  `release.yml` 的注释也写明“publishing with it > 0 is a defect”。处置建议：后续版本在 publish job
  （`undraft` 之前）增加一次对草稿 body 的硬校验，让流程本身再也无法发布未回填的说明。
- **`R6`（本版引入，已登记）**：#157 只把**健康探测**改成直连；**应用窗口自己的页面请求仍走系统
  代理**——WebKit 不支持按视图绕过系统代理。残余风险：系统代理未排除服务所在的 VPN 网段时，窗口里
  仍可能显示代理返回的错误页（实机观察到 502），用户可能继续把它误读为「服务断开」。缓解：「服务」
  菜单的只读告警（只在服务地址属于 CGNAT 段、对应 scheme 的代理生效、且例外未命中时出现）给出网段
  说明与修复步骤，一次运行只提示一次，切回 loopback 或加上例外后告警自动清除；应用只读取、不修改
  系统代理设置。处置建议：后续版本考虑在窗口内区分「代理错误页」与「服务未就绪」（例如给探测响应
  加标记），或引导用户改用 loopback 地址打开。

### 既往观察（非本次 delta）

- alpha.11 审查登记的 `#135` `F1`–`F4` 在本版**已全部修复**：`F1` 配置代次（`ServiceManager.swift`）、
  `F2` 外部服务文案三态（`AppDelegate+Menus.swift`）、`F3` `isFileURL` 过滤（`AppDelegate+Window.swift`）、
  `F4` 路径归一化收紧（`RecentWorkspace.swift`）。这四条从“既往观察”移出，本报告 §1–§4 已按修复后的
  实现复核。
- `O-1`（两行持久警告的既往措辞）未改。
- alpha.9 审查的措辞观察、alpha.10 的最近工作目录结论（本版部分被 #135 收紧）、alpha.11 的
  `ServiceManager.currentState` setter 可见性与“测试文件名沿用旧名”都不因本版改变。

## 10. 已核实无问题

- 进程启动点、参数构造、信号对象与所有权判定未变；只缩短了受托管服务的停止等待预算（§1）。
- 没有新增 Keychain 写入点或凭据接触点（§2）。
- 新增日志全部经过统一脱敏实例，只含计数、阶段名与毫秒时钟，不含路径 / URL / 参数；#157 的代理告警
  日志只写网段（`100.x.y.z`），不写用户真实地址（§3）。
- 放行面与监听切换路径的代码未改，继承 alpha.12 的「精确 origin + loopback + inline、无网段 / 后缀 /
  通配」结论（§4.2）。
- `open` URL 过滤与路径归一化都是收紧；默认监听、更新检查域名未变；没有新增网络请求（§4.1、§4.4）。
- #157 的探测直连只作用于应用自身的健康探测；系统代理配置只读、没有写入 API；只新增一个系统框架
  链接，无第三方依赖；窗口放行面未改（§4.3）。
- shell 检查门禁从空转变为逐文件执行；占位符提示升级为 warning 并补上人工硬门禁；Actions 固定 SHA 与
  权限未放宽（§5）。
- 文档措辞没有夸大签名 / 公证 / 加密能力（§6）。
- 两条文本扫描（身份 / secret）都通过，且本报告与发布说明只用占位地址形式（§8）。

## 11. 证据不足 / 无法确认（不作猜测）

- 本机只有 Command Line Tools、没有完整 Xcode：**没有执行** `xcodebuild build` / `xcodebuild test`，
  也没有执行本机 XCTest shim 全量（本版门槛清单只要求脚本链）。本版新增测试
  （`PiWebDesktopTests/SystemProxyWarningTests.swift`、`ServiceManagerTests.swift`、
  `RecentWorkspaceTests.swift`）的断言只做了阅读，没有运行；运行结论由 CI 承担（main CI run
  `35620781999` 为 `success`，但那不是本机执行的证据）。
- **没有做真机 GUI 验收**：Dock 点击恢复窗口、最小化恢复、`Cmd+Q` 退出时间线的真实耗时、工作目录切换
  三态文案的实际显示、路径被拒绝时的提示、`open` 多 URL 与外部链接的行为、代理未排除网段时「服务」
  菜单告警与修复步骤都未在真机验证（发布说明与 checklist 的真机表保持「待真机验证」）。
- 没有验证 `getifaddrs` 在隧道接口（utun）、多网卡、睡眠唤醒后的输出形态（#150 代码未改，结论继承
  alpha.12，同样没有新的真机证据）。
- 没有做更新检查与自动更新的端到端演练（本版不涉及这些路径）。
- 没有检查 `.github/workflows/` 之外的基础设施（分支保护、仓库 secret 设置）。
- 本报告与发布说明里的“门槛实测”值来自本次评审所在工作区的脚本输出；ZIP / `.sha256` / `.evidence.md`
  的发布值由 `release.yml` 在 tag 上生成，**本机未打包、未回填**。

## 12. 发布决定

- **阻断项 0 条。** 非阻断项 6 条：`R1`（非 loopback 时窗口加载该地址）、`R2`（host 尾部点不归一）、
  `R3`（切换监听的完成语义不等于服务就绪）继承自 alpha.12 评审且代码未改；`R4`（退出等待预算 4s→≤1s，
  可能导致受托管服务被提前 SIGKILL）、`R5`（占位符门禁在 workflow 内只是 warning，硬门禁依赖人工执行）、
  `R6`（#157 只修了探测路径，窗口页面请求仍走系统代理，代理未排除网段时窗口仍可能显示代理错误页）
  是本版新引入。六条都不构成未确认的执行路径、权限放宽或凭据泄漏，**不阻塞** `0.1.0-alpha.13` 的发布；
  每条都给出处置建议。
- 发布门槛（本机实测，全部退出 0）：`./Scripts/check-release-version.sh --print-tag` →
  `v0.1.0-alpha.13`；`./Scripts/check-release-version.sh` →
  `PASSED (MARKETING_VERSION 0.1.0-alpha.13, CURRENT_PROJECT_VERSION 13; tag comparison skipped)`；
  `./Scripts/build.sh`；`./Scripts/check-identity.sh` → `PASSED (45 checks)`；
  `./Scripts/scan-secrets.sh` → `suppressed 15 lines` + `PASS`；`./Scripts/smoke.sh` → 两种模式退出 0。
  main CI run `35620781999`（提交 `506f5d6`）为 `success`。完整输出见
  [alpha-release-checklist.md](alpha-release-checklist.md#release-v010-alpha13-执行记录)。
- 发布后仍需回填：真机 smoke 表八项、发布资产大小与 SHA-256、prerelease 正文的未公证说明、回退路径
  可用性（`v0.1.0-alpha.11` 资产仍在 Releases；`v0.1.0-alpha.12` 只有草稿，不作为回退来源）。
