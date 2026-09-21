# Pi Web Desktop `0.1.0-alpha.12` 安全评审（delta）

评审对象：`main` 上的 `f938773`（#147 / #148 / #149 / #150 四个 Issue 的修复，PR #152 / #151 / #154 /
#153 合并后的 main；main CI run `35596701327`）。基线：`main` = `895f6a7`（alpha.11 发布值回填提交）。
本报告是**只读评审**：没有修改任何代码、工程文件或脚本，只读取源码、脚本、工程文件与文档。

本版是行为修复版本（健康检查去抖、导航失败分类、WebView 放行面、复制手机访问链接），因此 delta 评审的
重点是三件事：**放行面是否被放宽、切换监听是否引入了未确认/无门槛的路径、新增的日志与剪贴板是否碰到
凭据**。基线 alpha.1 审查（[security-review-alpha.1.md](security-review-alpha.1.md)）的 S1–S8 结论仍然
是权威范围；本报告逐项给出本版 delta 对这些结论的影响。

## 0. 方法与证据基线

### 0.1 评审范围与命令

| 命令 | 用途 |
| --- | --- |
| `git diff --stat 895f6a7..f938773` | 本版 delta 的文件清单（16 个文件，`+1082` / `-57`） |
| `git grep -c -F <pattern> <rev> -- Sources` | 安全相关模式的基线 / 本版计数对比（下表） |
| `git grep -n -E 'kill\(|sendGroupSignal|SIGTERM|SIGKILL' -- Sources` | 信号面调用点清点（S1） |
| `git grep -n 'RemoteAccessPassword.load\|keychain.save(' -- Sources` | 凭据读写入口清点（S2） |
| `./Scripts/build.sh`、`./Scripts/check-identity.sh`、`./Scripts/scan-secrets.sh`、`./Scripts/smoke.sh` | 本版门槛实测（结果见 §5、§8 与 [alpha-release-checklist.md](alpha-release-checklist.md#release-v010-alpha12-执行记录)） |
| 逐行阅读 | `Sources/App/WebViewNavigationPolicy.swift`、`Sources/App/WebViewController.swift`、`Sources/App/ServiceAddresses.swift`、`Sources/App/AppDelegate+Menus.swift`、`Sources/Services/ServiceManager.swift` 的本版改动与上下文 |

本版 delta 的代码面（`Sources/`）共 8 个文件、`+507` / `-36`：`Sources/App/{AppDelegate,AppDelegate+Menus,
AppDelegate+Service,AppDelegate+Window,ServiceAddresses,WebViewController,WebViewNavigationPolicy}.swift`
与 `Sources/Services/ServiceManager.swift`。`Sources/Diagnostics/`、`Sources/Updates/`、
`Sources/Support/` 未改动；`Scripts/` 未改动；`PiWebDesktop.xcodeproj/project.pbxproj` 有 `+13` 行，
内容是 #150 登记新增的 `Sources/App/ServiceAddresses.swift` 与
`PiWebDesktopTests/ServiceAddressesTests.swift`（工程文件本身不属于安全边界，见 §5）。

### 0.2 证据强度分级

- **[A]** 命令输出可复现（计数、脚本退出码、脚本断言）。
- **[B]** 源码逐行阅读 + 机械计数支持的结论。
- **[C]** 只能推断、本次没有运行证据的结论（一律不当作已核实，见 §11）。

## 1. S1 服务所有权与外部服务只读

**结论：通过，本版无变化 [B]。**

- 本版没有新增进程启动点，也没有新增信号发送点。计数对比：`let process = Process()` 基线 4 / 本版 4；
  `executableURL` 4 / 4；`.arguments =` 6 / 6；`NSTask` 0 / 0；`sh -c` 0 / 0；`chmod`、`setenv` 0 / 0
  [A]。
- `kill(` 与 `sendGroupSignal` 的调用点与基线相同：`Sources/Services/ProcessInspector.swift:37`
  （`kill(pid, 0)` 存活探测，PID 0/1 不算应用所有）、`Sources/Services/CommandRunning.swift:171`
  （本次启动的子进程）、`Sources/Services/ServiceOwnership.swift:283`（`kill(-pgid, signal)`）、
  `Sources/Services/ServiceOwnership.swift:288`（`kill(-pgid, 0)`），以及
  `Sources/Services/ServiceManager.swift:873` / `:879`（只对通过所有权校验的进程组发 SIGTERM 再
  SIGKILL）[A/B]。
- #147 改的是健康检查的**判定阈值**，不改变“对谁发信号”：重启仍走 `startManagedService()` 这条既有
  受托管路径，仍要求 `didLaunchService == true`，即只重启应用自己启动的服务；外部服务仍不会被重启
  [B]。
- #148 删除了 `onNavigationFailure` 中的 `setState(.stopped)`，这是**减少**状态写入，不涉及进程面 [B]。

## 2. S2 凭据边界

**结论：通过 [B]。**

- 本版新增的密码接触点只有一处：`Sources/App/AppDelegate+Menus.swift:354` 的
  `RemoteAccessPassword.load(from: keychain) != nil`——只取“是否已设置密码”的布尔值，不读取、不比较、
  不持有密码文本 [B]。
- 本版没有新增 Keychain 写入点：`keychain.save(` 仍然只出现在
  `Sources/Services/KeychainStore.swift:472`（`RemoteAccessSetup.apply` 的“用户提供新密码”分支）[A]。
  「复制手机访问链接」以 `newPassword: nil` 调用 `RemoteAccessSetup.apply`，因此它**只读**Keychain 里
  已有的密码，不会新建、修改或删除凭据 [B]。
- 密码不会进入剪贴板：「复制手机访问链接」写入剪贴板的内容是
  `ServiceAddressLink.url(forIPv4:port:)` 构造出的 `http://<地址>:<端口>/`，不含凭据 [B]。
- 密码不会进入菜单标题、确认文案或错误文案：候选菜单项标题只有种类与地址（`Tailscale · <地址>` /
  `局域网 · <地址>`），确认框说明“把监听地址从当前值切换到该地址并重启”，失败提示使用
  `RemoteAccessSetup` 返回的校验文案或固定文案 [B]。
- 密码不会进入 WebView 导航允许判定：`WebViewNavigationPolicy` 只比较 scheme / host / port，不读
  URL 的 userinfo，也不会把 userinfo 拼进任何输出 [B]。
- `UserDefaults` 计数 77 / 77 未变，本版没有新增持久化键，也没有把地址或密码写进 UserDefaults [A]。

## 3. S3 日志与诊断脱敏

**结论：通过；本版**新增**日志事件，但都经过统一脱敏实例，且不记录凭据 [A/B]。**

- 统一脱敏链路未变：`LogWriter.record(_:)` → `append(_:)` →
  `Sources/Diagnostics/LogWriter.swift:202` 的 `let payload = Data(redactor.redact(text).utf8)`。也就是
  说 `record` 的调用方即使不显式脱敏，文本也会经过 `LogRedactor` [B]。
- #147 新增四类日志行（`Sources/Services/ServiceManager.swift`）：`健康检查探测失败：连续失败 N 次`、
  `健康检查判定服务已断开（连续失败 N 次）`、`健康检查触发受托管重启（连续失败 N 次）`、以及恢复时的
  `健康检查探测已恢复：连续失败计数归零（此前连续失败 N 次）`。四行都只记计数，**不打印探测 URL**
  （源码注释明确写“可能含凭据”），因此即使探测 URL 里带凭据也不会落盘 [B]。
- #148 新增一处日志：`Sources/App/AppDelegate+Window.swift` 的
  `_ = self.logWriter.append(self.logRedactor.redact(message))`——显式脱敏 + `append` 内部二次脱敏，
  记录的是错误页文案（`localizedDescription`），不含 URL 查询串或凭据 [B]。
- 诊断导出面未改：`Sources/Diagnostics/DiagnosticsCollector.swift` 不在本版 delta 内，诊断项集合
  （`items=6 blockers=3`）与 alpha.11 一致 [A]。
- 行为变化的如实说明：本版**第一次**把“探测失败 / 判定断开 / 触发重启 / 恢复”写进日志（此前不记录）。
  这是有意的可诊断性改动，代价是日志里出现服务断开与重启的时间线；该信息不含私密地址之外的内容，
  且本机地址本身属于用户自己的配置，不视为秘密 [B]。

## 4. S4 网络边界（本版 delta 的重点）

### 4.1 #149：WebView 放行面 = 当前配置服务地址 + loopback + inline scheme

**结论：通过；放行面从“仅 loopback”扩到“精确 origin + loopback”，没有网段/后缀/通配白名单 [B]。**

`Sources/App/WebViewNavigationPolicy.swift` 的判定链（`decision(for:serviceURL:)` → `allow` /
`openExternally`）：

| 项 | 实现 | 说明 |
| --- | --- | --- |
| 配置服务地址 | `isServiceURL(_:serviceURL:)`：scheme 小写后相等、host 经 `RemoteAccessPolicy.normalizedHostname` 去括号 + `lowercased()` 后相等、`url.port == serviceURL.port` 精确相等 | 唯一非 loopback 入口；path 与 query 不参与判定，host 比较大小写不敏感 |
| loopback | `isLocalURL(_:port:)`：host ∈ {`127.0.0.1`, `localhost`, `::1`}，且 `url.port ?? port == port` | 与基线一致；配置没有端口时该项不存在 |
| inline | `about` / `blob` / `data` | 不发起网络请求 |
| 其他协议 | `isWebScheme` 只接受 `http` / `https`；`file:`、`mailto:` 等一律外开 | 与基线一致 |

- **没有** `100.x.y.z` 之类的网段白名单，**没有**后缀白名单（例如 tailnet 的 MagicDNS 后缀），**没有**通配符，
  也没有“私网地址一律允许”的规则：非 loopback 只允许与配置值**完全一致**的那一个 origin [A/B]。
- `isLocalURL` 仍然要求 host 是 loopback，因此把监听地址配置成某个私网地址并不会让该网段的其他主机
  进入放行面 [B]。
- 弹出窗口（`createWebViewWith`）改用同一套 `isAllowedURL`：目标是放行面就替换当前页，否则
  `NSWorkspace.shared.open` 交给系统；`NSWorkspace.shared.open` 计数 6 / 6 未变 [A/B]。
- `WebViewController` 删除了独立的 `servicePort` 存储属性，导航判定只读 `serviceURL`（初始化参数与
  `updateService(url:port:)` 的 `port` 只为兼容调用点保留），消除了“同一配置两个来源”的不一致可能
  [B]。
- **风险点（R1）**：一旦用户在设置里把监听地址配置为非 loopback 地址，应用窗口会加载该地址的页面。
  这是 #149 的设计目标（应用自己的窗口不再把服务页丢给系统浏览器），但它意味着配置错误或配置被他人
  修改时，窗口会加载那个主机返回的内容。缓解：只有用户显式保存该地址（且非 loopback 需要非空密码）
  才会生效；放行面仍然只有该精确 origin，不会连带放行同网段其他主机。

### 4.2 #150：接口枚举与「切换监听地址」

**结论：通过；枚举是本机只读，切换监听需要用户确认 + 密码门槛，失败不复制链接 [B]。**

- **枚举面**：`SystemNetworkAddressProvider`（`Sources/App/ServiceAddresses.swift`）用 `getifaddrs`
  只读枚举本机接口，跳过未启用（`IFF_UP` 未置位）与 loopback（`IFF_LOOPBACK` 置位）的接口，只取
  `AF_INET`，用 `getnameinfo(..., NI_NUMERICHOST)` 取数字地址。**不发起任何网络请求**（无 `URLSession`
  新增：计数 14 / 14 未变 [A]），不读取接口之外的系统信息 [B]。
- **分类面**：`ServiceAddressClassifier.kind(forIPv4:)` 是纯函数，只接受严格点分四段十进制；CGNAT 段
  （首段 100、次段在 64…127）记为 Tailscale，`10/8`、`172.16/12`、`192.168/16` 记为局域网；loopback、
  link-local、非法文本返回 `nil` 被丢弃 [B]。
- **写入面**：候选地址只出现在菜单项、确认文案与剪贴板；源码注释与实现都不把它写进日志、诊断或错误
  文案 [B]。
- **确认与门槛**：`ServiceAddressDecision.decide(currentHostname:selected:hasPassword:)` 只有三种结果
  ——已经是当前监听地址 → 直接复制（不改配置、不重启）；没有密码 → 引导去设置（不改配置、不启动
  远程监听、不复制）；否则 → 先弹确认（说明会切换监听并重启服务、当前会话中断）[B]。
- **保存路径复用**：确认后走 `RemoteAccessSetup.apply(requested:newPassword: nil, keychain:)`
  （`Sources/Services/KeychainStore.swift:454`）——先做 `RemoteAccessPolicy.hostnameValidationMessage`
  校验（通配地址 `0.0.0.0` / `::`、空值、空白与非法字符仍不可保存），再做
  `remoteAccessRequirementMessage` 的非 loopback 密码门槛（非 loopback + 空密码 → 拒绝）。校验不通过
  时返回 `configuration: nil`，界面只提示错误，**不保存配置、不复制链接** [B]。
- **门槛脚本佐证**：`./Scripts/check-identity.sh` 的服务默认值检查（默认 hostname 必须是 loopback、
  默认 `noProxy` 只含 loopback 条目）在本版通过（`PASSED (45 checks)`）[A]。
- 文档措辞：发布说明与本节都明写非 loopback 访问是明文 `http`、**密码认证不等于传输加密**，只建议在
  可信网络或隧道内使用 [B]。

### 4.3 未改变的边界

- 默认监听仍是 loopback（`http://127.0.0.1:30141/`），本版没有改默认值 [A]。
- 更新检查的两个主机常量（`api.github.com`、`registry.npmjs.org`）未改，`Sources/Updates/` 不在本版
  delta 内 [B]。
- `https://` 字面量 16 / 16、`http://` 字面量 5 / 6：新增的一处是
  `Sources/App/ServiceAddresses.swift` 的文档注释（`http://<地址>:<端口>/`），实际 scheme 由
  `components.scheme = "http"` 赋值产生，没有新增真实主机 [A/B]。

## 5. S5 构建与发布

**结论：通过 [A]。**

- 本版没有改 `Scripts/`（delta 里没有 `Scripts/` 文件）；`PiWebDesktop.xcodeproj/project.pbxproj` 的
  `+13` 行只为登记 #150 新增的源文件与测试文件，未改构建阶段语义、未改签名配置、未改 target 依赖 [B]。
- `.github/workflows/` 未改：Actions 固定完整 SHA、workflow 权限最小化等 alpha.1 §5.1 / §5.2 的结论
  继续成立（本版没有新增 Action、没有放宽权限）[B]。
- 本机门槛实测（在本工作区、四个改动文件已 `git add` 后执行）：`./Scripts/build.sh` 退出 0；
  `./Scripts/check-identity.sh` → `PASSED (45 checks)`；`./Scripts/scan-secrets.sh` → `suppressed 15 lines`
  与 `PASS`；`./Scripts/smoke.sh` → 两种模式 `smoke: ready` / `smoke: diagnostics ready`，整体
  `smoke: OK` [A]。完整执行记录见
  [alpha-release-checklist.md](alpha-release-checklist.md#release-v010-alpha12-执行记录)。
- ZIP 打包与 checksum 路径：`Scripts/package-release.sh` 未改，白名单与“拒绝路径”逻辑沿用 alpha.11 的
  结论；本版发布产物的 checksum 由 `release.yml` 在 tag 上生成，发布后回填 [B]（本机未打包）。

## 6. S6 签名与 Gatekeeper 表述

**结论：通过（表述未放宽）[B]。**

- 本版不引入 Developer ID、不做公证；产物仍是 ad-hoc 签名，`spctl` 预期拒绝。
- 新增/改写的文档措辞只写“ad-hoc 签名、未公证、需要手动放行”，没有出现“已签名”“已公证”“可从任意
  来源安全安装”这类夸大表述；安装章节仍指向 README 的手动放行步骤 [B]。
- 签名验证命令与结果在 [alpha-release-checklist.md](alpha-release-checklist.md) 的 alpha.11 记录中保留；
  本版本机未执行 `codesign -dv` / `spctl`（本版门槛清单不要求，见 §11）。

## 7. S7 依赖与供应链

**结论：通过 [A/B]。**

- **没有新增第三方依赖**：本版唯一新增的 API 面是 `getifaddrs` / `getnameinfo`（`import Darwin`，
  系统库）与 `NSAlert` / `NSPasteboard`（Cocoa）；没有 `Package.swift`，没有 npm 依赖变更，没有新增
  Action [A/B]。
- 没有新增 shell 调用：`sh -c` 0 / 0，`setenv` / `chmod` 0 / 0，`Process()` 4 / 4 [A]。
- 没有新增 `try!` / `as!`（0 / 0），`fatalError` 3 / 3 未变 [A]。

## 8. S8 个人数据与 secret

**结论：通过 [A]。**

- `./Scripts/scan-secrets.sh`（四个改动文件已 `git add`）→ `scan-secrets: suppressed 15 lines`、
  `scan-secrets: PASS (no matches in tracked files; no untracked files)`，退出 0；抑制标记数 N=15 与
  alpha.5 … alpha.11 的记录一致（本版没有新增抑制标记）[A]。
- 仓库文本扫描（`./Scripts/check-identity.sh` 第 6 节）对 tailnet 主机名、tailnet DNS 后缀、CGNAT 段
  地址、绝对 home 路径、固定本地代理端点五类模式全部为 `ok`（`PASSED (45 checks)`）[A]。
- 本报告与发布说明只使用占位形式描述地址（`100.x.y.z`、`10/8`、`172.16/12`、`192.168/16`、
  `192.168.x.y`、`~/…`），没有写入真实私网地址、真实主机名或绝对 home 路径 [B]。
- 代码里的私网分类是数值比较（首段 / 次段范围判断），不是地址字面量，因此不会命中扫描器的 CGNAT
  模式；这一点由上面两条扫描通过佐证 [A/B]。

## 9. 发现

### 阻断项

无。

### 非阻断项

- **`R1`（本版引入，已登记）**：配置为非 loopback 监听后，**应用窗口会加载该地址的页面**（#149 的
  设计目标）。残余风险：如果该地址被误配，或配置被本机其他进程/他人修改，窗口会加载那个主机返回的
  内容；应用不会校验该主机的身份（ad-hoc、自签、明文 `http` 都可能）。缓解：只有用户显式保存该地址
  才生效；非 loopback 必须有非空密码；放行面仍只有该**精确 origin**，不连带放行同网段或同后缀主机。
  处置建议：后续版本可在窗口标题或状态栏显示当前监听地址，让“窗口加载的是哪个主机”可见。
- **`R2`（本版引入，已登记，非安全放宽）**：`WebViewNavigationPolicy.normalizedHost` 只做去方括号 +
  小写，不处理 host 的**尾部点**（FQDN 写法，例如 `host.` 与配置里的 `host` 不相等）。影响方向是
  该 URL 被判为外部链接并交给系统浏览器打开，**不会放宽放行面**（不会让未配置的主机进入窗口）；仅在
  用户用尾部点写法访问时才表现为“本应留在窗口却外开”。处置建议：在 host 比较前统一去掉单个尾部点。
- **`R3`（本版引入，已登记）**：切换监听地址的“成功”语义是**配置已落盘且停止路径走完**，不是“服务
  已在新地址上就绪”。`applyPreferencesConfiguration(_:credentialsChanged:completion:)`
  （`Sources/App/AppDelegate+Service.swift`）先 `appConfiguration.save(newConfiguration)`，再在
  `stopService` 的回调里 `updateConfiguration` + `reloadAfterConfigurationChange()` + `completion?()`；
  也就是保存发生在重启之前，completion 不是重启成功的证明。若新地址绑定失败（例如地址在本机不可用），
  配置已经持久化为新地址且**没有自动回滚**，而链接仍可能被复制——用户会拿到一个指向未启动服务的链接。
  缓解：切换前的确认文案已明确说明会重启服务、当前会话中断；候选地址来自本机在用接口，误配概率低。
  处置建议：后续版本把复制动作与一次成功的健康探测绑定，或在失败时提示并给出“改回 loopback”的一键路径。

### 既往观察（非本次 delta）

- `#135` 的 `F1`–`F4`（重叠切换竞态、外部服务文案、`application(_:open:)` 未检查 `isFileURL`、路径
  接受面未收紧）与 `O-1` 仍未修；本版只在 `Sources/App/AppDelegate+Window.swift` 改了导航失败上报
  路径，`application(_:open:)` 本身未变。
- alpha.9 审查的措辞观察、alpha.10 的最近工作目录结论、alpha.11 的 `R1`（`ServiceManager.currentState`
  setter 可见性）与 `R2`（测试文件名沿用旧名）都不因本版改变：本版没有新增 `currentState` 写入点，
  也没有重命名测试文件。

## 10. 已核实无问题

- 进程启动点、参数构造、环境白名单与信号策略未变（§1）。
- 没有新增 Keychain 写入点，新增的密码接触点只取布尔值（§2）。
- 新增日志全部经过统一脱敏实例，且只记计数、不记探测 URL（§3）。
- 放行面没有网段 / 后缀 / 通配白名单；非 loopback 只有与配置完全一致的精确 origin（§4.1）。
- 接口枚举只读本机、无网络请求；切换监听有确认与密码门槛，校验失败不保存、不复制（§4.2）。
- 更新检查域名、Actions 权限与 SHA 固定、打包脚本白名单未变（§4.3、§5、§7）。
- 文档措辞没有夸大签名/公证/加密能力（§6）。
- 私网地址、主机名、绝对 home 路径的两条扫描都通过（§8）。

## 11. 证据不足 / 无法确认（不作猜测）

- 本机只有 Command Line Tools、没有完整 Xcode：**没有执行** `xcodebuild build` / `xcodebuild test`，
  也没有执行本机 XCTest shim 全量（本版门槛清单只要求上述脚本链）。#149 的判定规则与 #150 的分类/决策
  逻辑有单元测试覆盖（`PiWebDesktopTests/WebViewNavigationPolicyTests.swift`、
  `ServiceAddressesTests.swift`、`ServiceManagerTests.swift` 在本版扩写），但**本次评审没有运行它们**，
  断言内容只做阅读 [B]，运行结论由 CI 承担。
- **没有做真机 GUI 验收**：窗口切换后的实际加载、菜单项点击、确认弹窗、剪贴板内容、真实 Tailscale /
  局域网可达性都未在真机验证（发布说明与 checklist 的真机表保持「待真机验证」/「待填」）。
- 没有验证 `getifaddrs` 在隧道接口（utun）、多网卡、睡眠唤醒后的输出形态；分类与排序逻辑有注入替身的
  测试断言，但没有真实网络环境证据。
- 没有做更新检查与自动更新的端到端演练（本版不涉及这些路径）。
- 没有检查 `.github/workflows/` 之外的基础设施（分支保护、仓库 secret 设置）。

## 12. 发布决定

- **阻断项 0 条。** 非阻断项 3 条（`R1` 非 loopback 时窗口加载该地址、`R2` host 尾部点不归一、
  `R3` 切换监听的完成语义不等于服务就绪），均不构成未确认的执行路径或凭据泄漏，**不阻塞**
  `0.1.0-alpha.12` 的发布；三条都已在上面给出处置建议。
- 发布门槛：`./Scripts/check-release-version.sh --print-tag`（`v0.1.0-alpha.12`）、
  `./Scripts/check-release-version.sh`、`./Scripts/build.sh`、`./Scripts/check-identity.sh`
  （`PASSED (45 checks)`）、`./Scripts/scan-secrets.sh`（`suppressed 15 lines` + `PASS`）、
  `./Scripts/smoke.sh`（两种模式退出 0）全部通过；main CI run `35596701327` 为绿。完整输出见
  [alpha-release-checklist.md](alpha-release-checklist.md#release-v010-alpha12-执行记录)。
- 发布后仍需回填：真机 smoke 表五项、发布资产大小与 SHA-256、prerelease 正文的未公证说明、回退路径
  可用性（`v0.1.0-alpha.11` 资产仍在 Releases）。
