# Pi Web Desktop `0.1.0-alpha.14` 安全评审（delta）

评审对象：`main` 上的 `e0afaf1`（#168 / #169 / #166 / #167 的修复，PR #170 / #171 / #166 / #167
合并后的 main；main CI run [35690235011](https://github.com/Su-luoya/pi-web-desktop/actions/runs/35690235011)
为 `success`——本报告的结论不依赖该 run）。
基线：`main` = `aa3ee17`（`v0.1.0-alpha.13` 的 tag 指向的发布提交）。
本报告是**只读评审**：没有修改任何代码、工程文件或脚本，只读取源码、脚本、工程文件与文档。

## 0. 方法与证据基线

### 0.1 评审范围与命令

| 命令 | 用途 |
| --- | --- |
| `git diff --stat aa3ee17..e0afaf1` | 本版 delta 的文件清单（19 个文件，`+1722` / `-105`） |
| `git diff --numstat aa3ee17..e0afaf1 -- Sources PiWebDesktopTests` | 源码与测试面的逐文件增删行（下节） |
| `git grep -c -F <pattern> <rev> -- Sources` | 安全相关模式的基线 / 本版计数对比（各节） |
| `git grep -n -E 'kill\(|sendGroupSignal' e0afaf1 -- Sources` | 信号面调用点清点（S1） |
| `git diff aa3ee17..e0afaf1 -- Sources \| grep -E '^[+-]import'` | 依赖 / 框架面变化（S7：只新增 `+import Foundation`） |
| `ls -ld ~/Library ~/Library/Application\ Support "$HOME/Library/Application Support/Pi Web Desktop"` + 读取一次真实缓存文件的键结构 | 新增本机缓存文件的权限与内容审计（S2 / S8 / `R7`） |
| `./Scripts/build.sh`、`check-identity.sh`、`scan-secrets.sh`、`check-release-version.sh`、`smoke.sh` | 本版门槛实测（结果见 §5、§8、§12 与 [alpha-release-checklist.md](alpha-release-checklist.md)） |
| 逐行阅读 | 本版 delta 的 11 个 `Sources/` 文件改动与上下文 |

本版 delta 的代码面（`Sources/`）11 个文件、`+874` / `-98`：

| 文件 | +/− | 本版内容 |
| --- | --- | --- |
| `Sources/App/AppWindowRegistry.swift` | `+134/-0` | #168（新文件）：窗口登记表（窗口 ↔ 控制器、primary 标识、最近使用顺序）。只 `import Foundation`，不 import AppKit / 不引用 `ServiceManager` |
| `Sources/App/AppDelegate+Window.swift` | `+199/-53` | #168：`makeWindow` 参数化（自动保存名 / 是否从最近使用窗口偏移）、⌘N 的 `newWindow(_:)`、`windowShouldClose` 按 primary 分流、`windowWillClose` 移除登记、`windowDidBecomeKey` 记最近使用、`showMainWindow` 复用 primary |
| `Sources/App/AppDelegate+Service.swift` | `+13/-6` | #168：`onLoadPage` / `onPageMessage` 从「唯一窗口」改为遍历 `windowRegistry.controllers` 广播 |
| `Sources/App/AppDelegate+Menus.swift` | `+30/-8` | #168：窗口菜单新增「新建窗口」（⌘N）；菜单 / 页面动作的目标改为 key 窗口优先、回落到最近使用窗口 |
| `Sources/App/AppDelegate.swift` | `+17/-3` | #168：`windowRegistry` 作为唯一窗口来源；`window` / `webViewController` 分别指向最近使用窗口及其控制器 |
| `Sources/App/WebViewController.swift` | `+5/-1` | #168：`windowProvider` 支持多窗口（查找栏 / 保存面板取当前窗口） |
| `Sources/App/AppConfiguration.swift` | `+6/-0` | #169：`dependencyGateCacheURL`（`supportURL` 下的 `dependency-gate-cache.json`） |
| `Sources/App/AppDelegate+Diagnostics.swift` | `+196/-21` | #169：快路径入口、指纹构造、缓存写回、后台复查与不一致收敛（`convergeAfterCachedFastPath`） |
| `Sources/Services/DependencyModel.swift` | `+202/-5` | #169：`DependencyGateFingerprint` / `DependencyGateCachePolicy` / `DependencyGateCacheInvalidReason` / `DependencyGateCacheVerdict` / `DependencyGateCache` / `DependencyGateFastPath` |
| `Sources/Services/DependencyChecker.swift` | `+69/-0` | #169：`DependencyGateCacheFileIO` 协议 + 系统实现（读 / 原子写）+ `DependencyGateCacheStore` |
| `Sources/App/AppDelegate+PackageUpdates.swift` | `+3/-1` | #168：窗口创建参数化的连带改动（无新增行为） |

`Sources/Services/ServiceManager.swift`、`ServiceOwnership.swift`、`ProcessInspector.swift`、
`CommandRunning.swift`、`KeychainStore.swift`、`WebViewNavigationPolicy`、`RecentWorkspace.swift`、
`Sources/Updates/`、`Sources/Diagnostics/` 都**不在本版 delta 内**。

测试面：`PiWebDesktopTests/AppWindowRegistryTests.swift`（`+435`，新增，登记表 14 → 22 条）、
`PiWebDesktopTests/DependencyCheckerTests.swift`（`+355`，缓存判定 / 失效规则 / 写回）。测试只断言，
不改变运行时行为。

CI 与文档面：`.github/workflows/release.yml`（`+2/-2`，只升级两个 artifact action 的固定 SHA）、
`PiWebDesktop.xcodeproj/project.pbxproj`（登记新源文件与测试文件）、
`docs/architecture.md` / `docs/development.md` / `docs/logging-and-diagnostics.md` /
`docs/settings-and-workspace.md`（#168 / #169 的行为与诊断说明）。

### 0.2 证据强度分级

- **[A]** 命令输出可复现（计数、脚本退出码、脚本断言、真机文件属性与键结构）。
- **[B]** 源码逐行阅读 + 机械计数支持的结论。
- **[C]** 只能推断、本次没有运行证据的结论（一律不当作已核实，见 §11）。

## 1. S1 服务所有权与外部服务只读

**结论：通过；本版没有新增进程启动点、没有新增信号对象、没有改动所有权判定，唯一的服务动作是复用既有停止路径 [A/B]。**

- 计数对比（基线 `aa3ee17` → 本版 `e0afaf1`，范围 `-- Sources`）：`Process()` 5 → 5；
  `.arguments =` 6 → 6；`kill(` 7 → 7；`sendGroupSignal` 4 → 4；`NSWorkspace.shared.open` 6 → 6；
  `getifaddrs` 2 → 2；`try!` 0 → 0；`as!` 0 → 0；`fatalError` 3 → 3 [A]。
- **登记表不碰服务**：`Sources/App/AppWindowRegistry.swift:3` 只有 `import Foundation`；文件头注释明确
  「开窗、关窗与服务生命周期完全无关：服务只由共享的 `ServiceManager` 管理，这里不会启动、停止或重启
  任何东西」。登记表的全部方法是纯数据结构操作（`:88` `register`、`:100` `markPrimary`、
  `:109` `noteUsage`、`:120` `remove`、`:130` `removeAll`），没有 `Process` / `kill` / 信号调用 [A/B]。
- **多窗口的广播不是新的服务控制路径**：`Sources/App/AppDelegate+Service.swift:12` 的
  `onLoadPage` 闭包在 `:18` 遍历 `windowRegistry.controllers`，对每个控制器调 `:19`
  `updateService(url:port:)` 与 `:20` `loadServicePage()`；`:23` 的 `onPageMessage` 在 `:26`-`:27`
  对每个控制器调 `showLoadingPage(message:)`。两者都不触碰启动 / 停止 / 重启，也不写 `isDependencyGateOpen`；
  它们只是把服务层已经决定的结果同步到更多窗口 [B]。
- **所有权判定与停止路径未改**：`Sources/Services/ServiceManager.swift:407`
  `func managedServicePID() -> pid_t?` 返回 `verifiedOwnershipRecord()?.pid`；`:426`
  `verifiedOwnershipRecord()` 仍是既有的所有权校验（校验失败时清除记录并把进程按外部处理）；
  `:909` `stopService(completion:)` 的开头仍然只在「所有权记录可验证」时才动作。本版没有改这三处 [B]。
- **#169 唯一的服务相关动作**：`Sources/App/AppDelegate+Diagnostics.swift:332`-`:334`
  `if serviceManager.managedServicePID() != nil { serviceManager.stopService() }` —— 这是**既有**的
  停止路径：只作用于本应用启动、所有权可验证的服务；外部 / 不受托管的进程既不被等待也不被信号 [B]。
- **门控开关的写入点**：`ServiceManager.swift:95` `var isDependencyGateOpen = false`；`:302`-`:303`
  `isStartPermitted = isBaseStartPermitted && isListeningAddressUsable && hasRequiredRemoteAccessCredentials`。
  本版改变的是**谁在什么时候**把它置为 true：快路径命中时由
  `AppDelegate+Diagnostics.swift:223` `serviceManager.isDependencyGateOpen = report.canStartService`
  放行；完整检查开始时由 `:144` 置回 false（只在非 `refiningCachedGate` 路径）。密码与监听地址门槛
  没有被绕过：`ensureServerIsRunning`（`:558`-`:559`、`:572`）与 `startManagedService`（`:613`）的
  `isStartPermitted` / `isBaseStartPermitted` 守卫计数与位置未变 [A/B]。
- **收敛语义**：快路径之后的完整复查若与缓存不一致，先看 `requiresConvergence`
  （`Sources/Services/DependencyModel.swift:340`，只在「结果不可启动」或「路由不再是主窗口」时为 true），
  然后复用 `stopService` 并把界面收敛到诊断页（`AppDelegate+Diagnostics.swift:321`-`:339`）；
  与缓存一致时只记日志、不重新路由 [B]。`R9` 记录了这条路径上无法在本机排除的一个窄竞态。

## 2. S2 凭据边界

**结论：通过；本版没有新增凭据读写点，新增的缓存文件不含凭据 [A/B]。**

- Keychain 写入点计数 1 → 1（`keychain.save(` 仍只在 `Sources/Services/KeychainStore.swift` 的
  `RemoteAccessSetup.apply` 的“用户提供新密码”分支）；`KeychainStore.swift` 不在本版 delta 内 [A/B]。
- **缓存文件内容审计**（读取一次真机生成的缓存）：顶层键只有 `canStartService`、`components`、
  `findings`、`fingerprint`、`schemaVersion`、`writtenAt`；`fingerprint` 的键是 `appVersion`、
  `hostname`、`piWebPath`、`port`、`toolPathDigest`、`workspacePath`。没有密码、token、cookie 或
  任何 Keychain 数据的镜像；`components` 的证据字符串是本机可执行文件路径、符号链接链、`package.json`
  路径与版本（例如 Homebrew 前缀下的 `pi` 与其 `node_modules` 真实路径）。[A]
- `toolPathDigest`（`Sources/Services/DependencyModel.swift:220`
  `enum DependencyGateCacheDigest`，FNV-1a 64）是**变化检测**用的摘要，不是安全哈希——源码注释也这么
  写。被摘要的输入是 `PATH`、登录 shell 路径与 home 目录（`AppDelegate+Diagnostics.swift:26`
  `currentDependencyGateFingerprint()` 的注释写明「原文不落盘」），这些都不是凭据；但从密码学角度
  不能把它当作不可逆保护，报告按「非敏感输入的弱摘要」对待 [B]。
- 本版新增的输入面（⌘N 的窗口创建、缓存文件的读取）都不接触凭据：`newWindow(_:)` 只创建窗口，
  缓存读取只解析 JSON；两者都不读取、不比较、不写入密码 [B]。
- 本版**没有**改动远程访问密码的保存、读取与关闭路径：`closeRemoteAccessIfCredentialsAreUnavailable()`
  的调用点仍在依赖报告落地路径上（`AppDelegate+Diagnostics.swift:227`），语义未变 [B]。

## 3. S3 日志与诊断脱敏

**结论：通过；本版新增日志都走统一脱敏链路，只写状态与原因码 [A/B]。**

- 统一脱敏链路未变：`LogWriter.record(_:)` → `append(_:)` →
  `Sources/Diagnostics/LogWriter.swift` 的 `redactor.redact(text)`；`LogWriter`、`LogRedactor` 不在
  本版 delta 内 [B]。
- #169 新增的日志集中在 `Sources/App/AppDelegate+Diagnostics.swift:103`
  `logDependencyGate(_:)` → `:105` `logWriter.append(logRedactor.redact(text))`。文案只有「快路径不
  适用 / 未命中：<原因码>」「快路径命中：立即放行服务启动入口，完整检查转入后台复查」「缓存已更新：
  有效期 7 天，任一启动输入变化即失效」「缓存写入失败……」这类状态与静态说明；原因码来自
  `DependencyGateCacheInvalidReason`（`:246`，取值是 `missingOrUnreadable` / `schemaMismatch` /
  `expired` / `fingerprintChanged` / `canStartServiceIsFalse` / `reportUnreadable`），**不含路径、
  URL、hostname 或指纹数值** [B]。
- 多窗口沿用既有的脱敏日志：导航失败时 `Sources/App/AppDelegate+Window.swift:124`
  `_ = self.logWriter.append(self.logRedactor.redact(message))`，`:125` 只把错误页渲染到出错的那个
  窗口；消息文本仍是「页面加载失败：…」/「无法连接 Pi Web：…」的 `localizedDescription`（alpha.13
  的结论未变）[B]。
- 诊断导出面未变：`Sources/Diagnostics/DiagnosticsCollector.swift` 不在 delta 内；诊断项集合实测
  `items=6 blockers=3`，与 alpha.11 … alpha.13 一致 [A]。
- 本版没有新增「记录窗口数量、控制器标识或地址」的日志；登记表本身不写日志 [B]。

## 4. S4 网络边界

### 4.1 #168：多窗口不改变放行面，也不新增网络能力

**结论：通过 [A/B]。**

- 放行判定的实现文件（`WebViewNavigationPolicy`）不在本版 delta 内；`WebViewController` 的改动只有
  `+5/-1`（窗口 provider 相关），`decidePolicyFor`（`Sources/App/WebViewController.swift:171`、
  `:182`）、`didFail`（`:156`、`:160`）、`createWebViewWith`（`:215`）与下载处理（`:191`、`:197`）
  的逻辑没有变化。放行面仍是「当前配置的服务地址（精确 origin）+ loopback + inline scheme」[B]。
- 每个窗口都由 `makeWindow`（`Sources/App/AppDelegate+Window.swift:103`）用**同一个** `startURL`
  初始化（`:108`-`:111`），窗口之间不引入新的放行来源或新的 origin；WebKit 数据存储仍是共享的
  `.default()`（`WebViewController.swift:35`）[B]。
- 菜单与页面动作的目标 `activeWindow`（`Sources/App/AppDelegate+Menus.swift:635`）取 key 窗口，没有
  key 窗口时回落到最近使用窗口；`activeWebViewController`（`:641`）随之确定。没有跨窗口的地址写入或
  配置写入路径 [B]。
- 计数未变：`URLSession` 14 → 14、`getifaddrs` 2 → 2、`NSWorkspace.shared.open` 6 → 6 [A]。

### 4.2 #169：缓存只读本机文件，且被篡改也无法绕过真正的门槛

**结论：通过；缓存不是信任边界，只是加速器 [A/B]。**

- 读取：`Sources/Services/DependencyChecker.swift:859`
  `fileManager.contents(atPath: url.path)`（`SystemDependencyGateCacheFileIO.read(from:)`）；写入：
  `:870` `data.write(to: url, options: .atomic)`，目录用
  `:866`-`:869` `createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)`
  创建；失败一律返回 false（不抛错、不崩溃）[B]。
- 判定顺序（`Sources/Services/DependencyModel.swift:315` `DependencyGateFastPath.decide`）：
  缓存缺失 / 不可读 → 拒绝；`schemaVersion != 1` → 拒绝；`age = now - writtenAt`，`age < 0`（时钟回拨）
  或 `age > maximumAge`（7 天）→ 拒绝；指纹不一致 → 拒绝；缓存结论为「不可启动」→ 拒绝；缓存里的
  components 无法重建报告 → 拒绝。任一条成立都退回完整检查（fail closed）[B]。
- **布尔值伪造无效**：`DependencyGateCache.report()`（`DependencyModel.swift:300`）用缓存的
  `findings` 与 `components` **重新计算** `DependencyReport.canStartService`
  （`DependencyModel.swift:143`），因此只手改 `canStartService` 字段不会放行；要伪造必须同时伪造
  findings / components。
- **即使整份 JSON 被伪造**，影响也是有限的：门控提前放行（首屏进入服务页），服务启动仍要过
  `isStartPermitted`（密码 / 监听地址 / 工作目录），并且每次启动都会跑完整检查
  （`AppDelegate+Diagnostics.swift:48`-`:55`，快路径命中时以 `refiningCachedGate: true` 复查），
  不一致时收敛到诊断页并停掉本次启动的受托管服务（`:321`-`:339`）。缓存里没有可执行路径的“执行
  指令”：启动命令与参数由 `ServiceManager` 按当前配置解析，不从缓存读取 [B]。
- 写回只发生在本机真实检查之后（`:231` `if source != .cachedFastPath` 才写），避免快路径自我刷新
  时间戳；写回失败只影响下次启动的速度 [B]。
- 未改变的边界：默认监听仍是 loopback（`http://127.0.0.1:30141/`），更新检查的两个主机常量未变，
  `Sources/Updates/` 不在 delta 内；`SCDynamicStoreCopyProxies` 3 → 3、`SCDynamicStoreSetValue` 0 → 0
  （#157 的系统代理路径未改）[A/B]。

## 5. S5 构建与发布

**结论：通过；本版的两处 CI 改动只是固定 SHA 的版本升级，构建面只有登记性改动 [A/B]。**

- **#166 / #167（artifact action 升级）**：`.github/workflows/release.yml` 只改了两行 `uses:` 的固定
  SHA 与注释版本（上传 → `7.0.1`、下载 → `8.0.1`）；`name: pi-web-desktop-alpha`、上传
  `path: dist/`、下载 `path: dist` 三个输入未变；`permissions:` 与其它 `uses:` 未变；没有新增
  Action、没有新增 workflow [B]。
- **构建面只有登记性改动**：`PiWebDesktop.xcodeproj/project.pbxproj` 把新增的源文件与两个测试文件
  登记进 target；没有新的 build phase、没有新的链接框架（本版没有新增 `-framework`）；版本唯一来源
  仍是 `Configuration/AppIdentity.xcconfig`（`check-identity.sh` 的
  `no hardcoded MARKETING_VERSION outside Configuration/AppIdentity.xcconfig` 通过）[A]。
- **本机门槛实测**（在本工作区、改动文件与新增文档已 `git add` 后执行；完整输出见
  [alpha-release-checklist.md](alpha-release-checklist.md)）：见下表。

| 命令 | 实测输出 | 退出码 |
| --- | --- | --- |
| `./Scripts/check-release-version.sh --print-tag` | `v0.1.0-alpha.14` | 0 |
| `./Scripts/check-release-version.sh` | `PASSED (MARKETING_VERSION 0.1.0-alpha.14, CURRENT_PROJECT_VERSION 14; tag comparison skipped)` | 0 |
| `./Scripts/build.sh` | `build: release build with -O -wmo`、`Built: …/build/Pi-Web-Desktop.app`（脚本输出工作区绝对路径，此处缩写字面路径）、`…/Contents/MacOS/PiWebDesktop: Mach-O 64-bit executable arm64` | 0 |
| `./Scripts/check-identity.sh` | `PASSED (45 checks)` | 0 |
| `./Scripts/scan-secrets.sh` | `suppressed 15 lines`、`PASS (no matches in tracked files; no untracked files)` | 0 |
| `./Scripts/smoke.sh` | 两种模式 OK：`smoke: ready`、`smoke: diagnostics ready`（`items=6 blockers=3`）；`smoke: OK` | 0 |
| `for f in Scripts/*.sh; do sh -n "$f" \|\| exit 1; done` | 无输出 | 0 |
| `git diff --check` / `git diff --cached --check` | 无输出 | 0 |

- **一个环境发现（不是本版代码缺陷）**：在另一个 checkout（iCloud / Finder 同步目录）上，
  `./Scripts/build.sh` 首次以退出码 1 失败，错误为
  `resource fork, Finder information, or similar detritus not allowed`——bundle 上带有
  `com.apple.FinderInfo` 与 `com.apple.fileprovider.fpfs#P` 扩展属性，ad-hoc 签名（`codesign --force
  --deep --sign -`）因此被拒绝。按脚本提示执行 `xattr -cr <bundle>` 后重跑退出 0。这个问题在
  `docs/development.md` 的「构建」一节与 alpha.1 的门槛记录里已经记载；本版没有新增签名步骤，
  也没有把清理动作写进脚本 [B]。
- **ZIP 打包与 checksum 路径**：`Scripts/` 本版未改，`package-release.sh` 的白名单与“拒绝路径”逻辑
  沿用 alpha.11 … alpha.13 的结论；发布产物的 checksum 仍由 `release.yml` 在 tag 上生成，发布后回填
  [B]（本机未打包）。

## 6. S6 签名与 Gatekeeper 表述

**结论：通过（表述未放宽）[B]。**

- 本版不引入 Developer ID、不做公证；产物仍是 ad-hoc 签名，`spctl` 预期拒绝（退出码 3，这是预期结果）。
- 本版新增/改写的文档（`docs/release-notes-v0.1.0-alpha.14.md`、本报告、checklist 的 alpha.14 记录）
  只写“ad-hoc 签名、未公证、需要手动放行”，没有出现“已签名”“已公证”“可从任意来源安全安装”这类
  夸大表述；校验值章节仍要求 `shasum -a 256 -c`、`plutil -p` 与 `codesign --verify --deep --strict`
  三个动作 [B]。
- 版本表述一致：文档里的 `0.1.0-alpha.14` / build `14` 与 `Configuration/AppIdentity.xcconfig` 一致，
  由 `check-release-version.sh` 与 `check-identity.sh` 佐证（§5）[A]。
- 本版本机未执行 `codesign -dv` / `spctl`（本版门槛清单不要求，见 §11）。

## 7. S7 依赖与供应链

**结论：通过 [A/B]。**

- **没有新增第三方依赖**：`Sources/` 的 delta 里只新增了一个系统框架导入
  （`Sources/App/AppWindowRegistry.swift:3` 的 `import Foundation`）；`Package.swift` 不在 delta 内；
  `project.pbxproj` 只登记新文件；没有 npm 依赖变更；没有新增 Action [A/B]。
- 本版新增的 API 面都是系统框架的既有类型（`FileManager.contents(atPath:)`、`Data.write(to:options:)`、
  `JSONEncoder` / `JSONDecoder`（`.iso8601`、`.prettyPrinted`、`.sortedKeys`）、`NSWindow.orderOut`、
  `NSWindow.deminiaturize`），没有第三方库 [B]。
- 没有新增 shell 调用：`kill(` 7 → 7、`Process()` 5 → 5、`.arguments =` 6 → 6、`sh -c` 0 → 0、
  `NSTask` 0 → 0 [A]。
- 没有新增 `try!` / `as!`（0 → 0），`fatalError` 3 → 3 未变；缓存读写全部走可失败的 `try?` 路径，
  失败时退回完整检查而不是 crash [A/B]。
- CI 的两个 artifact action 仍以固定 SHA 引用，且只升版本、不加权限 [B]。

## 8. S8 个人数据与 secret

**结论：通过 [A]。**

- `./Scripts/scan-secrets.sh`（改动文件与新增文档已 `git add`）→ `scan-secrets: suppressed 15 lines`、
  `scan-secrets: PASS (no matches in tracked files; no untracked files)`，退出 0；抑制标记数 N=15 与
  alpha.5 … alpha.13 的记录一致（本版没有新增抑制标记）[A]。
- 仓库文本扫描（`./Scripts/check-identity.sh` 第 6 节）对 tailnet 主机名、tailnet DNS 后缀、CGNAT 段
  地址、绝对 home 路径、固定本地代理端点五类模式全部为 `ok`（`PASSED (45 checks)`）[A]。
- 本报告与发布说明只使用占位形式描述地址（`100.x.y.z`、`10/8`、`172.16/12`、`192.168/16`、
  `192.168.x.y`、`~/…`），没有写入真实私网地址、真实主机名或绝对 home 路径 [B]。
- 个人信息面：本版**没有新增 UserDefaults 键**——计数 79 → 79 未变 [A]；本版新增的持久化面只有仓库
  之外的一个本机缓存文件（`~/Library/Application Support/Pi Web Desktop/dependency-gate-cache.json`），
  它包含本机绝对路径与配置的 hostname（不包含 PATH / home 原文，只保存摘要），实测权限为
  `~/Library` 与 `Application Support` 目录 `0700`、应用数据目录 `755`、缓存文件 `644`——默认权限下
  同机其它用户不可读。它的内容、失效规则与信任边界见 §4.2 与 `R7` [A]。
- 本版没有新增日志里的个人数据（§3），也没有新增网络请求（§4.2）。

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
  不是“服务已在新地址就绪”；若新地址绑定失败，配置已持久化且没有自动回滚，链接仍可能被复制。处置
  建议：把复制动作与一次成功的健康探测绑定，或失败时给出“改回 loopback”的一键路径。
- **`R4`（继承 alpha.13，代码未改，已登记）**：退出等待预算为 **≤1 秒**（两段式探测 + 睡眠预算
  `stopPollBudgetMilliseconds = 1000`），预算耗尽后对同一进程组发 SIGKILL。影响面：只作用于应用自己
  启动、通过所有权校验的受托管服务进程组。风险形态：需要较长时间收尾的服务可能被强制终止。处置建议：
  观察“退出时间线”日志，若总是走到 SIGKILL 再考虑放宽预算。
- **`R5`（继承 alpha.13，代码未改，已登记）**：占位符门禁在 workflow 里只是 `::warning::`，
  **草稿仍会在含未填充占位符时创建**；真正的硬门禁是发布文档里的人工命令。处置建议：在 publish job
  （`undraft` 之前）增加对草稿 body 的硬校验。
- **`R6`（继承 alpha.13，代码未改，已登记）**：**应用窗口自己的页面请求仍走系统代理**——WebKit 不
  支持按视图绕过系统代理；系统代理未排除服务所在 VPN 网段时，窗口里仍可能显示代理返回的错误页。
  缓解：「服务」菜单的只读告警（#157）给出网段说明与修复步骤。处置建议：后续版本在窗口内区分
  「代理错误页」与「服务未就绪」。
- **`R7`（本版引入 `#169`，已登记）**：依赖门控缓存是本机状态，**不是信任边界**。
  事实（实测）：文件位于 `~/Library/Application Support/Pi Web Desktop/dependency-gate-cache.json`；
  顶层键只有 `canStartService` / `components` / `findings` / `fingerprint` / `schemaVersion` /
  `writtenAt`；内容包含 `piWebPath`、`workspacePath`、配置的 `hostname` 与依赖组件的**绝对路径 /
  符号链接链 / package.json 路径**；不含密码、token 或 PATH 原文（只有 FNV-1a 摘要）。权限实测：
  `~/Library` 与 `Application Support` 为 `0700`、应用数据目录 `755`、缓存文件 `644`，同机其它用户
  默认不可读、也不可写。残余风险：与用户**同权限**的进程可以伪造缓存（必须同时伪造 findings /
  components 才能放行），效果是让某一次启动在首屏提前进入服务页；后台完整检查会在几百毫秒内收敛
  （`AppDelegate+Diagnostics.swift:321`-`:339`）。它**不能**绕过远程访问密码与监听地址门槛，也不会让
  应用执行缓存里记录的路径。次要影响是本地隐私足迹扩大：该文件保存了本机绝对路径与配置 hostname
  （此前这些值只存在于配置与日志目录）。处置建议：写入时显式设 `0600`；或把 hostname 换成
  `hostname + 端口 + 路径摘要`，只保留「是否变化」的信息。
- **`R8`（本版引入 `#169`，已登记）**：六字段指纹（`DependencyModel.swift:210`）**不含 pi / pi-web 的
  版本号**——同一路径上的依赖升级（例如全局包原地更新）不会让缓存失效，缓存仍可能在首屏放行。
  残余风险由两层机制覆盖：7 天有效期与**每次启动都执行**的后台完整复查（不一致即收敛）；因此暴露
  窗口是第一屏的几百毫秒到 1 秒量级，而不是整个有效期。处置建议：把 pi / pi-web 的解析版本纳入指纹
  （缓存里已经保存了组件版本，成本很低）。
- **`R9`（本版引入 `#169`，已登记，证据强度 [C]，未在真机复现）**：缓存不一致的**收敛**与「服务已经
  在启动、所有权记录尚未落盘」之间存在一个窄竞态。`convergeAfterCachedFastPath` 先用
  `serviceManager.managedServicePID() != nil` 做前置判断（`AppDelegate+Diagnostics.swift:332`），而
  `managedServicePID()` 依赖可验证的所有权记录（`ServiceManager.swift:407`、`:426`），记录是在进程
  启动之后才写入磁盘的（`ServiceManager.swift:754` `try ownershipStore.save(record, to:
  appConfiguration.serviceOwnerURL)`）。如果收敛判断恰好落在这个窗口内，`stopService()` 不会被调用，
  而 `presentDependencyDiagnosticsPage` 已经停掉健康轮询并把状态置为 `.stopped`
  （`AppDelegate+Diagnostics.swift:283`-`:285`），于是本次启动的受托管服务可能在**没有界面呈现**的
  情况下继续运行，直到退出应用或下一次走所有权校验的停止路径才被处理。它不会误杀外部服务（方向相反），
  也不会绕过所有权校验；风险形态是“该停的没停在窗口内”的一段过渡状态。处置建议：收敛路径不要只依赖
  `managedServicePID()`（例如直接调用 `stopService()` 让它自己校验，或在启动流程里提供显式取消）。
- **`O-1`（既往观察，未改）**：两行持久警告的既往措辞。

### 既往观察（非本次 delta）

- alpha.13 的 `R4` / `R5` / `R6` 在本版**未处理**（对应代码不在 delta 内），继续作为已登记的非阻断项。
- alpha.11 的 `F1`–`F4` 已在 alpha.13 修复（本版未回退这些修复）。
- alpha.9 审查的措辞观察、alpha.10 的最近工作目录结论、alpha.11 的 `ServiceManager.currentState`
  setter 可见性与“测试文件名沿用旧名”都不因本版改变。

## 10. 已核实无问题

- 没有新增进程启动点、信号对象或所有权判定改动；#169 唯一的服务动作是复用既有停止路径（§1）。
- 多窗口的页面广播只同步地址与提示，不构成新的服务控制路径（§1）。
- 没有新增 Keychain 写入点或凭据接触点；新增缓存文件不含凭据，摘要输入（PATH / shell / home）不是
  凭据（§2）。
- 新增日志全部经过统一脱敏实例，只含状态与原因码，不含路径、URL、hostname 或指纹数值（§3）。
- 放行面实现未改；每个窗口使用同一个配置 URL，不引入新的 origin；窗口之间没有配置写入路径（§4.1）。
- 缓存读取是本机文件读、fail closed；伪造只能影响一次启动的首屏，无法绕过密码 / 地址门槛，也无法让
  应用执行缓存中的路径；写回只发生在本机真实检查之后（§4.2）。
- CI 只升级两个 artifact action 的固定 SHA，输入与权限未变；构建面只有文件登记；版本来源唯一（§5）。
- 文档措辞没有夸大签名 / 公证 / 加密能力（§6）。
- 没有新增第三方依赖或新的 Action；`try!` / `as!` 未新增、`fatalError` 未增加（§7）。
- 两条文本扫描（身份 / secret）都通过；本版没有新增 UserDefaults 键；本报告与发布说明只用占位地址
  形式（§8）。

## 11. 证据不足 / 无法确认（不作猜测）

- 本机只有 Command Line Tools、没有完整 Xcode：**没有执行** `xcodebuild build` / `xcodebuild test`。
  本版新增测试（`PiWebDesktopTests/AppWindowRegistryTests.swift` 14 → 22 条、
  `DependencyCheckerTests.swift`）的断言只做了阅读，没有在本机运行；运行结论由 CI 承担（main CI run
  `35690235011` 为 `success`，但那不是本机执行的证据）。
- **没有做真机 GUI 验收**：⌘N 多窗口、primary 的隐藏 / 恢复（Dock 与「显示 Pi Web」）、非 primary
  窗口的真正关闭、菜单动作跟随 key 窗口、地址变更时所有窗口的广播，以及 #169 的首屏耗时与缓存收敛
  都未在真机验证（发布说明与 checklist 的真机表保持「待真机验证」）。
- **没有在真机上制造 `R9` 的竞态**：该结论来自代码路径推演（[C]），没有运行证据；也没有测量收敛
  路径在服务已启动 / 未启动两种情形下的实际行为差异。
- **没有实际篡改缓存做验证**：§4.2 的结论来自 `decide` / `report` 的代码阅读与判定顺序，没有修改
  本机缓存文件后观察应用行为的实验。
- **没有验证 macOS 各版本下的默认 umask / 目录权限**：§8 与 `R7` 的权限值是本机实测；其它机器上的
  权限取决于系统默认与用户设置。
- 没有做更新检查与自动更新的端到端演练（本版不涉及这些路径）；没有检查 `.github/workflows/` 之外的
  基础设施（分支保护、仓库 secret 设置）。
- 本报告与发布说明里的“门槛实测”值来自本次评审所在工作区的脚本输出；ZIP / `.sha256` / `.evidence.md`
  的发布值由 `release.yml` 在 tag 上生成，**本机未打包、未回填**。

## 12. 发布决定

- **阻断项 0 条。** 非阻断项 9 条：`R1`（非 loopback 时窗口加载该地址）、`R2`（host 尾部点不归一）、
  `R3`（切换监听的完成语义不等于服务就绪）、`R4`（退出等待预算 ≤1 秒）、`R5`（占位符硬门禁依赖人工）、
  `R6`（窗口页面请求仍走系统代理）六条继承自 alpha.12 / alpha.13 评审且相关代码本版未改；`R7`（缓存
  的信任边界与隐私足迹）、`R8`（指纹不含依赖版本）、`R9`（收敛与启动的窄竞态，[C]）是本版 `#169`
  引入。九条都不构成未确认的执行路径、权限放宽或凭据泄漏，**不阻塞** `0.1.0-alpha.14` 的发布；每条
  都给出处置建议。
- 发布门槛（本机实测，全部退出 0）：`./Scripts/check-release-version.sh --print-tag` →
  `v0.1.0-alpha.14`；`./Scripts/check-release-version.sh` →
  `PASSED (MARKETING_VERSION 0.1.0-alpha.14, CURRENT_PROJECT_VERSION 14; tag comparison skipped)`；
  `./Scripts/build.sh`；`./Scripts/check-identity.sh` → `PASSED (45 checks)`；
  `./Scripts/scan-secrets.sh` → `suppressed 15 lines` + `PASS`；`./Scripts/smoke.sh` → 两种模式退出 0。
  main CI run `35690235011`（提交 `e0afaf1`）为 `success`。完整输出见
  [alpha-release-checklist.md](alpha-release-checklist.md)。
- 发布后仍需回填：真机 smoke 表各项、发布资产大小与 SHA-256、prerelease 正文的未公证说明、回退路径
  可用性（`v0.1.0-alpha.13` 资产仍在 Releases）。
