# Pi Web Desktop 0.1.0-alpha.13（build 13）— Apple Silicon alpha（未公证）

## 摘要 / Summary

Pi Web Desktop `0.1.0-alpha.13` 是面向 **Apple Silicon（arm64）、macOS 14 或更高版本** 的第十三个
alpha 预览。它启动、监控并显示本机已安装的 Pi Web 服务，默认只监听 loopback。

本版取代 `0.1.0-alpha.12` 的草稿构建：alpha.12 的 tag（`v0.1.0-alpha.12`）与草稿 Release 建立在四个
WebView / 健康检查修复**之前**，从未发布；本版第一次把这些修复发布出去，并在其之上再修四个用户可见
问题。相对上一版**已发布**的 `0.1.0-alpha.11`，本版一共包含九个 Issue 的修复：

- **来自 alpha.12 草稿、本版首次发布**：**健康检查去抖**（单次 1 秒抖动不再翻成「已断开」，也不再第一次
  失败就重启服务，[#147](https://github.com/Su-luoya/pi-web-desktop/issues/147)，PR #152）、
  **被取消的导航不再被判为失败**、页面加载失败不再把服务状态改成「已停止」
  （[#148](https://github.com/Su-luoya/pi-web-desktop/issues/148)，PR #151）、**WebView 放行面跟随当前
  配置的服务地址**（[#149](https://github.com/Su-luoya/pi-web-desktop/issues/149)，PR #154）、新增
  **「复制手机访问链接」**，按需枚举地址、确认后切换监听并复制
  （[#150](https://github.com/Su-luoya/pi-web-desktop/issues/150)，PR #153）；
- **本版新增**：**关闭窗口后点 Dock 图标恢复主窗口，退出等待从固定 4 秒改为 ≤1 秒的两段式等待**
  （[#158](https://github.com/Su-luoya/pi-web-desktop/issues/158)，PR #161）、**配置代次（丢弃过期回调）、
  外部服务切换文案分三态、`open` 只接受文件 URL、最近工作目录路径归一化收紧**
  （[#135](https://github.com/Su-luoya/pi-web-desktop/issues/135)，PR #160）、**CI、PR 模板与发布文档里
  的 shell 语法检查改为逐文件执行**（[#139](https://github.com/Su-luoya/pi-web-desktop/issues/139)，
  PR #159）、**发布说明残留占位符从 `::notice::` 升为 `::warning::`，并在发布文档里补上发布前硬门禁**
  （[#141](https://github.com/Su-luoya/pi-web-desktop/issues/141)，PR #162）、**健康探针改为直连，并在系统
  代理未排除 VPN 网段时于「服务」菜单给出只读告警与修复步骤**
  （[#157](https://github.com/Su-luoya/pi-web-desktop/issues/157)，PR #164）。

ZIP 里的应用仍然是 **ad-hoc 签名、未公证** 的：没有 Developer ID 证书，也没有 Apple 公证，
因此 Gatekeeper 默认会阻止直接双击打开，需要用户针对这一个应用手动放行。本版本没有 Intel 支持、
没有 SLA，**不承诺所有安装来源都能回滚**；把监听地址切到非 loopback 后，访问是明文 `http`，
远程访问的密码认证**不等于传输加密**，只建议在可信网络或隧道内使用。更新验证仍然
**不做代码签名确认、不确认官方来源、不做安装包内容比对**。

Pi Web Desktop `0.1.0-alpha.13` is the thirteenth alpha preview for **Apple Silicon (arm64) Macs
running macOS 14 or later**. It starts, monitors and displays a locally installed Pi Web service and
listens on loopback by default. This release supersedes the never-published `0.1.0-alpha.12` draft:
that draft's tag and assets were built before four WebView / health-check fixes, so those fixes are
published here for the first time, together with five additional user-visible fixes. Compared with
the previously published `0.1.0-alpha.11`, this release carries nine issues: **health-check
debouncing** ([#147](https://github.com/Su-luoya/pi-web-desktop/issues/147), PR #152), **cancelled
navigations are no longer reported as failures** and a page-load failure no longer rewrites the
service state as "stopped"
([#148](https://github.com/Su-luoya/pi-web-desktop/issues/148), PR #151), **the web view's allow
surface now follows the configured service origin**
([#149](https://github.com/Su-luoya/pi-web-desktop/issues/149), PR #154) and the new
**"Copy phone access link"** command
([#150](https://github.com/Su-luoya/pi-web-desktop/issues/150), PR #153) — those four come from the
alpha.12 draft and ship for the first time here — plus **the main window can be restored by clicking
the Dock icon after the red close button, and the quit wait dropped from a fixed 4 seconds to a
≤1-second two-stage budget** ([#158](https://github.com/Su-luoya/pi-web-desktop/issues/158), PR #161),
**configuration generations (late callbacks are dropped), three-way wording for externally started
services, an `open` handler that accepts only file URLs, and stricter recent-workspace path
normalisation** ([#135](https://github.com/Su-luoya/pi-web-desktop/issues/135), PR #160), **a per-file
shell syntax check in CI, the PR template and the release docs**
([#139](https://github.com/Su-luoya/pi-web-desktop/issues/139), PR #159), and **a placeholder warning
in the release workflow plus a hard pre-publish gate in the release docs**
([#141](https://github.com/Su-luoya/pi-web-desktop/issues/141), PR #162), and **the health probe now
connects directly instead of through the system proxy, with a read-only Services-menu warning when
the system proxy does not bypass the VPN subnet**
([#157](https://github.com/Su-luoya/pi-web-desktop/issues/157), PR #164). The app inside the ZIP is
still **ad-hoc signed and not notarised**: without a Developer ID certificate and Apple
notarisation, Gatekeeper blocks a plain double-click by default, so the user has to allow this one
app manually. There is no Intel support and no SLA, **not every install source can be rolled back**,
and after the listener is switched away from loopback the connection is plain `http` — password
authentication for remote access is **not transport encryption** and should only be used on a
trusted network or over a tunnel. Update verification still **does not confirm code signatures, does
not confirm the official source, and does not compare installer contents**.

## 发布信息

| 项目 | 值 |
| --- | --- |
| 版本（tag） | `v0.1.0-alpha.13` |
| `CFBundleShortVersionString` | `0.1.0-alpha.13` |
| `CFBundleVersion` | `13` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 应用包 | `Pi-Web-Desktop.app` |
| 架构 | arm64（Apple Silicon）；**不支持 Intel（x86_64）** |
| 最低系统 | macOS 14.0 |
| 签名 | ad-hoc（`codesign --sign -`），没有证书，`TeamIdentifier=not set` |
| 公证 | 无。Gatekeeper 默认拒绝，需要用户手动放行这一个应用 |
| 发布类型 | GitHub **prerelease**（alpha 预览） |
| 上一版 | `v0.1.0-alpha.11`（build `11`），资产仍在 Releases 中可下载 |
| 已被取代、不发布的构建 | `v0.1.0-alpha.12`（build `12`，tag 指向 `730128d`）：只有 Draft Release，早于 #135 / #139 / #141 / #158 四个修复，其资产不作为发布物 |
| 发布提交 | `506f5d6`（合并 #158 / #135 / #139 / #141 / #157 五个 PR 后的 main；main CI run [35620781999](https://github.com/Su-luoya/pi-web-desktop/actions/runs/35620781999)，`success`）加上本版发布提交（版本 bump、本文件、安全评审、门槛执行记录） |
| 本地数据位置 | UserDefaults（含 `workspace.recentPaths`）、`~/Library/Application Support/Pi Web Desktop/`、`~/Library/Logs/Pi Web Desktop/`、Keychain、WebKit 网站数据，见[隐私说明](privacy.md) |

版本与 build 的唯一来源是 `Configuration/AppIdentity.xcconfig`；本文件只是引用，不是来源。

## 目标平台

| 维度 | 支持范围 |
| --- | --- |
| CPU | Apple Silicon（arm64） |
| 系统 | macOS 14.0 或更高 |
| Intel Mac | 不支持，也没有 x86_64 产物 |
| 依赖 | Node.js `>=22.19.0`、Pi CLI、`@agegr/pi-web`（需用户自行安装，应用不打包也不自动安装） |
| 默认服务地址 | `http://127.0.0.1:30141/`（只监听 loopback） |

## `0.1.0-alpha.13` 相对 `0.1.0-alpha.11` 的新增与变更

本版包含九个 Issue 的代码改动（#147 / #148 / #149 / #150 来自未发布的 alpha.12 草稿，PR #152 /
#151 / #154 / #153；#158 / #135 / #139 / #141 / #157 是本版新增，PR #161 / #160 / #159 / #162 /
#164），随后是发布提交本身（版本 bump、本文件、安全评审、门槛执行记录）。以下逐条说明每个改动做了
什么、边界在哪里。

### 1. #147 / PR #152：健康检查去抖（alpha.12 草稿内容，本版首次发布）

| 项 | 改动前 | 改动后 |
| --- | --- | --- |
| 单次 HTTP 健康探测超时 | 1 秒 | **3 秒**（系统负载波动或休眠唤醒后的慢响应不再被当成断开） |
| 判定「已断开」并提示 | 单次探测失败即判定 | **连续 2 次**失败才判定（`healthDisconnectThreshold = 2`） |
| 受托管重启 | 第一次失败就重启（只要服务是应用启动的） | **连续 3 次**失败才重启（`healthRestartThreshold = 3`）；单次失败绝不重启 |
| 恢复 | — | 探测成功把连续失败计数**清零**，并作废本次断开判定 |
| 日志 | 不记录探测失败与重启 | 每次失败记一行（只记计数），判定断开与触发重启各记一行，恢复且此前有失败时记一行 |
| 状态判定范围 | 仅对「原本显示运行中」的服务下断开结论 | 不变（`if case .running = currentState` 仍然成立） |

这是用户报告的「正在尝试恢复…」反复闪现的直接成因：改版前单次 1 秒抖动就会把服务翻成「已断开」，
而首次失败还会真的重启服务。实现上新增两个私有状态（`consecutiveProbeFailures`、
`disconnectReported`），`startHealthMonitor()` 每次启动新一轮监控时把两者复位，避免上一轮的失败计数
让新会话的第一次失败就直接触发断开或重启。重启仍然只在**断开判定成立之后**发生，所以启动中/失败态
不会被探测波动顺手重启。日志行**不打印探测 URL**（可能含凭据），只记连续失败次数。

### 2. #148 / PR #151：被取消的导航不再被判为失败，页面加载失败不再改服务状态（alpha.12 草稿内容，本版首次发布）

- **取消不是失败**：`NSURLErrorCancelled`（-999）返回 `nil`，不上报导航失败。外链交给系统浏览器
  打开后 WebKit 会取消这次导航，此前它会被当成一次加载失败并连带把服务状态改成「已停止」。
- **沿包装链判定**：WebKit 常把真正的错误包在 `NSError` 的 `NSUnderlyingErrorKey` 里，因此判定会沿
  包装链（上限 8 层，防止异常 `userInfo` 构造出环）收集 `NSURLErrorDomain` 错误码：链上任何一层是
  取消就按取消处理。
- **错误码分类**：连不上主机（`-1004`）与请求超时（`-1001`）归为「无法连接」，其余（`-1003`、
  `-1006` 等）归为「加载失败」。判定按错误码而不是 `localizedDescription` 文本，上报文案保持原错误
  对象的 `localizedDescription`，与修复前一致。
- **服务状态不再被导航失败改写**：`onNavigationFailure` 只写一行日志（经 `LogRedactor` 脱敏）并渲染
  错误页，不再调用 `setState(.stopped)`。服务状态由启动流程与健康检查决定；页面级失败（包括被取消的
  外链导航）不再影响它。

### 3. #149 / PR #154：WebView 放行面跟随当前配置的服务地址（alpha.12 草稿内容，本版首次发布）

放行面（留在应用窗口内的 URL）从「loopback + inline scheme」改为：

1. **当前配置的服务地址**：scheme、host、port 完全一致（大小写不敏感，IPv6 字面量去括号后比较；
   path 与 query 无关）——这是唯一一个非 loopback 入口，它存在的原因是应用只和自己配置并启动的
   地址比较；
2. **loopback**：`127.0.0.1` / `localhost` / `::1`，且端口等于配置端口（配置没有端口时不存在
   这一项）；
3. **inline scheme**：`about`、`blob`、`data`。

**没有**网段白名单、**没有**后缀白名单、**没有**通配符：不是「允许 `100.x.y.z` 那一整段」，
而是「只允许这一个精确的 origin」。`http` / `https` 以外的协议（`file:`、`mailto:` 等）一律交给系统。
修复的可见问题：把监听地址切到 Tailscale 或局域网地址后，应用自己的窗口不再把服务页丢给系统浏览器。
同一套判定也用于弹出窗口（`createWebViewWith`）：目标是放行面就替换当前页，否则交给系统。

### 4. #150 / PR #153：新增「复制手机访问链接」（alpha.12 草稿内容，本版首次发布）

应用菜单与服务菜单各增加一个子菜单（打开时按当前网络地址重建），候选来自本机接口枚举：

- **枚举**：`getifaddrs` 只读枚举启用中的非 loopback 接口的 `AF_INET` 地址（不发起网络请求），
  再按纯函数分类——CGNAT 段（`100.x.y.z`）记为 Tailscale，私网段（`10/8`、`172.16/12`、`192.168/16`）
  记为局域网；loopback、link-local 与非法文本被丢弃，列表去重后按「Tailscale 在前、组内地址升序」排序。
  没有任何可用的候选时，子菜单只留一条禁用的说明项。
- **无第三方依赖**：分类、排序、菜单项构建、下一步动作判定都是纯函数 + `getifaddrs`，不引入任何库。
- **已经是当前监听地址**：直接复制 `http://<地址>:<端口>/`，**不改配置、不重启**。
- **没有设置远程访问密码**：弹提示引导到「设置… → 远程访问」，**不改配置、不启动远程监听**、不复制
  链接。
- **其他情况**：先确认（文案写明会把监听地址从当前值切到该地址并重启服务、当前会话会中断）；确认后
  走与设置窗口同一条保存路径（`RemoteAccessSetup.apply` 校验 hostname 并沿用 Keychain 里已有的密码），
  **配置生效且重启路径结束之后才复制链接**；保存失败只报错，不复制链接。
- 候选地址只出现在菜单项、确认文案与剪贴板里，**不写入日志、诊断导出或错误文案**。

### 5. #158 / PR #161：关窗后 Dock 恢复主窗口，退出等待收紧到 ≤1 秒预算（本版新增）

**Dock 恢复**：新增 `applicationShouldHandleReopen(_:hasVisibleWindows:)`，返回 `true` 表示事件已处理，
AppKit 不再走自带的「新建窗口」路径。AppKit 只在 `hasVisibleWindows == false` 时调它，恰好覆盖三种
情形：红色关闭按钮之后（`windowShouldClose` 只做 `orderOut(nil)`）、窗口被最小化到 Dock、以及窗口还没
创建（启动早期点击 Dock 图标）。`showMainWindow()` **复用同一个窗口**（重建会丢页面状态并留下第二个
窗口）：最小化时先 `deminiaturize(nil)`，显示前按当前屏幕适配一次（隐藏期间可能换过显示器），再
`makeKeyAndOrderFront(nil)`，应用不活跃时 `activate(ignoringOtherApps: true)`。窗口对象还不存在时，只有
主菜单已安装（启动流程已走到 `applicationDidFinishLaunching` / smoke 路径）才补建，避免与正常启动路径
各建一个窗口。

**退出等待（原 `40 × 0.1s = 4 秒` → ≤1 秒预算）**：分两段探测——前 20 次每 10 毫秒（服务已退出时立刻
返回，检测延迟 ≤10ms），之后每 50 毫秒，睡眠总预算 `stopPollBudgetMilliseconds = 1000`；探测次数由预算
推导（`stopPollAttempts` = 36，避免常量与预算对不上）。**先探测再睡眠**，因此「服务已经退出」这条最
常见的路径一次都不睡；只有预算用尽且进程组仍存活时才 **对同一进程组** 发 SIGKILL。这个等待仍然只在
应用自己启动的受托管服务的停止路径上运行，外部服务不受影响。

**退出时间线日志**：一个退出序列只记一次「退出请求」（状态机不在 `.idle` 时说明本次退出已在进行，
`NSApp.terminate(nil)` 会重入 `applicationShouldTerminate`），随后依次记录「请求停止托管服务」、
「已发送 SIGTERM」、子进程退出（带等待毫秒数）、必要时「已发送 SIGKILL」、「应用即将终止」。行内容
只含阶段名、毫秒时钟与相对进程启动的单调偏移，**不含路径、URL 或参数**，且仍经过 `LogWriter` 的
`LogRedactor`。

### 6. #135 / PR #160：配置代次、外部服务切换文案、`open` URL 过滤与路径归一化（本版新增）

- **配置代次（重叠切换不再互相覆盖）**：`ServiceManager` 新增 `configurationGeneration`；
  `beginConfigurationChange()` 在改动任何状态前领取代次，任何直接写入（`updateConfiguration(_:)`）也让
  更早的代次失效。`stopService` 的异步回调改用
  `updateConfiguration(_:ifGenerationMatches:)`——只有仍是最新请求才写配置并重启，过期回调到此为止，
  **不得把捕获的旧配置写回去**。没有这道校验时，重叠切换工作目录的两次 stop 回调会按完成顺序各自
  写回配置，最终配置可能是被取代的那一次，界面勾选、配置与实际服务目录三者会不一致。
- **外部服务切换文案分三态**：确认框的说明文案按情形不同——受托管且正在运行（「确认后将重启服务」）、
  正在运行但**不是本应用启动的**（「本应用不会重启它，新目录要等你自行重启该服务后才会生效」）、
  服务未运行（「新目录会在下次启动服务时生效」）。按钮标题也随受托管与否变化。
- **`application(_:open:)` 只接受文件 URL**：Finder 拖放 / `open -a` 入口先按 `isFileURL` 过滤；非文件
  URL（`http`/`https`、自定义 scheme）显式忽略并记一条只含**数量**的脱敏日志；多个文件 URL 只处理
  第一个并记一条只含数量的日志。移除了 `AppDelegate+PackageUpdates.swift` 里旧的、不检查 `isFileURL`
  的实现。
- **最近工作目录路径归一化收紧**（`RecentWorkspaceStore.normalizedPath`）：去掉首尾空白后为空、或含
  控制字符 → 拒绝；展开 `~`（`~/work`、`~user/work`）；相对路径与根目录 `/`（含 `/..`）→ 拒绝；
  解析符号链接并标准化，使同一目录只有一种存储形式；长度分两道（输入 trim 后与 `~` 展开后各查一次
  输入长度，解析标准化后再查最终长度）超过 `maximumPathLength = 1024` 字节 → 拒绝。长度必须在
  Foundation 改写之前检查：`expandingTildeInPath` 与 `resolvingSymlinksInPath` 会把超过 `PATH_MAX` 的
  输入截断回合法长度，只在解析后比较永远看不到超长输入。这些值只进 UserDefaults、菜单标题与
  `NSWorkspace.open`，不是安全边界；本版没有新增存储结构或持久化键。

### 7. #139 / PR #159：CI、PR 模板与发布文档改为逐文件 shell 语法检查（本版新增）

`sh -n Scripts/*.sh` 只把**第一个**文件作为脚本参数执行，其余文件被当作位置参数忽略，因此门禁此前
只检查了排序最前的那个脚本，属于空转。三处统一改为逐文件执行：

```sh
for f in Scripts/*.sh; do sh -n "$f" || exit 1; done
```

改动位置：`.github/workflows/build.yml` 的 `Check shell scripts` 步骤、
`.github/pull_request_template.md` 的清单项、`docs/releasing.md` 的本地演练命令。本版没有改
`Scripts/` 里的任何脚本。

### 8. #141 / PR #162：发布说明占位符提示升级为警告，并补发布前硬门禁（本版新增）

- `.github/workflows/release.yml`：渲染 Release 说明后统计未填充占位符的计数（`grep -cE '<待填[写]>'`，
  与 workflow 里的字面量写法等价；按 #163 的文档约定，本文件不复现该占位符字面量），提示从
  `::notice::` 升为 **`::warning::`**——草稿仍必须能创建（维护者要从 Release Issue 回填真机记录），
  但计数在发布（undraft）前必须为 0。
- `docs/releasing.md` 与 `docs/alpha-release-checklist.md`：补上发布前的**硬门禁**命令与说明——
  `gh release view v<MARKETING_VERSION> --json body --jq .body | grep -cE '<待填[写]>'` 输出必须为 0
  （`grep -c` 在计数为 0 时退出码是 1，看计数而不是退出码）；要在计数非 0 时立即失败用
  `test "$(… || true)" -eq 0`。这一条是**人工步骤**：workflow 阶段只警告，不阻断草稿创建。

### 9. #157 / PR #164：健康探针直连，系统代理未排除 VPN 网段时给出只读提示

| 项 | 改动前 | 改动后 |
| --- | --- | --- |
| 探测连接路径 | `URLSessionServiceProbe`（`Sources/Services/ServiceScheduling.swift`）用默认的 `ephemeral` 会话，请求会走系统代理 | 会话显式设置 `connectionProxyDictionary = [:]`，探测**始终直连**；代理应答（502 / 407 / 代理缓存页）不再参与就绪判定 |
| 超时与判定 | 3 秒超时、HTTP `200..<500` 视为就绪、`ephemeral` 缓存策略 | 不变 |
| 系统代理感知 | 没有；用户把监听地址切到 Tailscale 地址（CGNAT 段）而代理未排除该网段时，探针经代理拿到错误页，误报「服务已断开」 | 新增 `Sources/Services/SystemProxyWarning.swift`：用 `SCDynamicStoreCopyProxies` **只读**读系统代理配置；只在服务地址落在 CGNAT 段（`100.x.y.z`）、对应 scheme 的代理（HTTP / HTTPS / SOCKS / PAC）确实生效、且例外列表未命中时才提示 |
| 提示形态 | — | 「服务」菜单里出现一条代理告警项（条件成立时显示，条件不成立时隐藏），点开可看网段说明与修复步骤，也可「清除警告」；触发与清除各记一行日志（只写网段，不写用户真实地址） |
| 提示寿命 | — | 一次运行内只提示一次（手动清除后本次运行不再提示）；切回 loopback 或用户加上例外后条件消失，告警自动清除 |
| 构建与文档 | — | `Scripts/build.sh` 新增 `-framework SystemConfiguration`；[设置与工作区](settings-and-workspace.md) 新增「系统代理与 VPN 网段」一节 |

判定边界（与单测一起固定）：循环地址（`127.*`、`localhost`、`::1`）、普通局域网地址（`192.168.*` /
`10.*` / `172.16–31.*`）与主机名（含 tailnet DNS 名）都**不提示**——这些网段一般在代理软件的默认例外
里，逐个提示噪声太大，主机名也无法与网段可靠对应；例外列表里命中该网段的通配 / 精确地址 / CIDR 条目，
以及无法解析的畸形条目都按「已排除」处理（宁可漏报，不误报）。应用**只读**系统代理设置，不替用户修改，
也没有改动 WebView 的放行面。

### 10. 本版的安全审查（delta）

- 完整的 delta 安全评审见 [安全评审（alpha.13）](security-review-alpha.13.md)，按 S1–S8 覆盖本版
  delta（`730128d..506f5d6`：`Sources/` 10 个文件、测试 3 个文件、`Scripts/build.sh`、工程文件、CI
  三处、`docs/` 四处），并明确继承 alpha.12 评审中针对 #147–#150 的结论（alpha.12 从未发布，这些
  改动由本版首次发布）。
- 结论：**阻断项 0 条**；非阻断项 6 条——继承 alpha.12 评审的 `R1`（非 loopback 监听后应用窗口会加载
  该地址）、`R2`（放行面 host 比较不处理尾部点）、`R3`（切换监听的「成功」语义是配置落盘 + 停止路径
  走完，不是服务已在新地址就绪），以及本版新增的 `R4`（退出等待预算从 4 秒收紧到 ≤1 秒：受托管服务
  在 SIGTERM 后超过约 1 秒仍未退出会被 SIGKILL）、`R5`（占位符门禁在 workflow 里只是 `::warning::`，
  真正的硬门禁依赖维护者人工执行文档里的命令），以及本版新增的 `R6`（#157 只改了健康探测的连接路径：
  应用窗口自己的页面请求仍走系统代理，WebKit 不支持按视图绕行，代理未排除该网段时窗口仍可能显示
  代理错误页；缓解手段是「服务」菜单的只读告警与修复步骤）。六条都已在报告里登记，不阻塞发布。
- `R1`–`R3` 涉及的 #149 / #150 代码在本版 delta 里没有改动；`R4`–`R6` 是本版行为变化，处置建议见
  安全评审报告 §9。

## 更新检查与自动更新的边界（本版无变化）

本版**没有改动**更新检查的域名、频率、开关与自动更新的前置条件：两个主机常量（`api.github.com`、
`registry.npmjs.org`）未变，两条自动更新开关仍然默认关闭，扩展包更新仍然必须由用户确认。完整边界
（会做/不会做、域名与关闭方式、三种更新路径的命令与超时行为）以
[alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md) 的“更新检查访问的域名、频率与关闭方式”
“自动更新的准确边界”两节为准。

## 本机实测环境与版本（可追溯）

| 项 | 值 |
| --- | --- |
| 硬件 | Apple M4（`sysctl -n machdep.cpu.brand_string`） |
| 架构 | `arm64` |
| macOS | `27.0`（`sw_vers -buildVersion` = `26A428`） |
| Swift | `6.4`（`swift --version`，Command Line Tools） |
| Node.js | `v24.21.0`（`/opt/homebrew/opt/node@24/bin/node`） |
| npm | `11.19.0` |
| `pi` | `0.86.1`（`@earendil-works/pi-coding-agent`） |
| `@agegr/pi-web` | `0.9.1`（全局 npm 包） |
| 诊断摘要 | `items=6 / blockers=3`（`Scripts/smoke.sh --diagnostics`） |

与 alpha.12 草稿记录的环境相比逐项相同，因此门槛结果可以直接和上一版对照。

## 安装

安装步骤、首次启动会看到什么、依赖怎么装、以及常见问题（Gatekeeper 放行、诊断导出、卸载与清理）都在
[README](../README.md) 里，本节不再重复。与上一版相同：ZIP 解压后把 `Pi-Web-Desktop.app` 放进
`~/Applications` 或 `/Applications`；应用不打包也不需要 Node.js / Pi CLI / `@agegr/pi-web` 之外的
任何运行时。

## 依赖前置与首次启动诊断

依赖（Node.js `>=22.19.0`、Pi CLI、`@agegr/pi-web`）需要用户自己安装，应用只做探测、显示与诊断，
不会自动安装（除非用户显式打开两条“启动前自动更新”开关，且所有前置条件满足）。首次启动的诊断页会
列出每一项的状态与缺失项的安装命令，细节见
[alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md) 的“依赖前置与首次启动诊断”一节与
[README](../README.md)。

## 未公证、ad-hoc 与 Gatekeeper

本产物用 ad-hoc 签名（`codesign --sign -`），没有 Developer ID 证书，也没有经过 Apple 公证。
`spctl -a -vv` 会拒绝它（退出码 3），**这是未公证 ad-hoc 产物的预期结果，不是损坏**。首次打开需要
用户手动放行：

1. 在 Finder 里右键 `Pi-Web-Desktop.app` → “打开”，在弹窗里再确认一次“打开”。
2. 或在“系统设置 → 隐私与安全性”里对该应用选择“仍要打开”。

请只放行本仓库 Releases 页面下载、并用下文“校验值”核对过 SHA-256 的那一份 ZIP。

## 校验值

发布资产由 `.github/workflows/release.yml` 在 tag `v0.1.0-alpha.13` 上生成；**本节的大小与 SHA-256
在发布后从 Release 页面回填**，回填前保持占位，不用本机演练值冒充发布值。

| 项 | 值 |
| --- | --- |
| 发布资产 | `Pi-Web-Desktop-0.1.0-alpha.13+build.13.zip` |
| 大小 | 发布后回填 |
| SHA-256 | 发布后回填 |
| 发布提交 | `506f5d6` + 本版发布提交；tag `v0.1.0-alpha.13` 指向包含本节内容的发布提交 |

校验方式：从 Release 下载 ZIP 与配套的 `.zip.sha256`，在同一个目录里执行

```sh
shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.13+build.13.zip.sha256
```

预期输出 `<file>: OK`。随后可复核包内版本与签名（解压到临时目录后执行）：

```sh
plutil -p Pi-Web-Desktop.app/Contents/Info.plist | grep -E 'CFBundleShortVersionString|CFBundleVersion'
codesign --verify --deep --strict Pi-Web-Desktop.app
```

预期 `CFBundleShortVersionString=0.1.0-alpha.13`、`CFBundleVersion=13`，`codesign --verify` 退出 0
（ad-hoc 产物仍会被 `spctl` 拒绝，这是预期结果）。本机门槛与演练记录见
[alpha-release-checklist.md](alpha-release-checklist.md) 的「Release v0.1.0-alpha.13 执行记录」，
那里同时给出本机演练值与「发布后回填」的区分。

## 已知问题

### 1. 本版仍然存在的问题

- **未公证、ad-hoc 签名**：Gatekeeper 默认阻止直接双击打开，需要用户针对这一个应用手动放行（见
  「未公证、ad-hoc 与 Gatekeeper」）。本版不引入 Developer ID，也不做公证。
- **非 loopback 监听需要先设置远程访问密码**：「复制手机访问链接」在密码缺失时**不**改配置、
  **不**启动远程监听，只引导去设置密码。这是设计如此，不是缺陷。
- **非 loopback 访问是明文 `http`**：密码认证**不等于传输加密**，只建议在可信网络或隧道内使用。
- **应用窗口的页面请求仍走系统代理（#157）**：健康探测已改为直连，代理应答不再被当成「服务已断开」的
  证据；但 WebKit **不支持按视图绕过系统代理**，应用窗口自己的页面请求仍可能经过系统代理。如果代理的
  「绕过这些主机与域名」没有排除服务所在的 VPN 网段（`100.x.y.z`），窗口里仍可能显示代理返回的错误页
  （例如 502 Bad Gateway），看起来像服务断开——此时服务本身正常，应用会在「服务」菜单里给出代理告警项，
  点开有网段说明与修复步骤（「系统设置 → 网络 → 详细信息 → 代理 → 绕过这些主机与域名」加入该网段，
  或在代理软件里把该网段设为直连）；应用只读取、不修改系统代理设置。
- **退出等待预算 ≤1 秒（#158）**：受托管服务在 SIGTERM 后超过约 1 秒仍未退出时会被 SIGKILL（旧行为
  会等最多 4 秒）。需要长时间收尾的服务可能来不及做完清理；外部 / 不受托管的进程不受影响。
- **更新验证的边界**：不确认代码签名、不确认官方来源、不做安装包内容比对（见「更新检查与自动更新的
  边界」）。验证只看版本证据与文件身份。
- **回滚能力不均**：只有带版本证据的安装来源才走降级路径；npm 全局更新与 Pi 扩展包更新没有自动回滚，
  失败时只保证不声称成功、不改状态。
- **真机 GUI 未手工验收**：本机只有 Command Line Tools、没有 Xcode，本版的门槛是脚本（构建 / 身份 /
  冒烟 / 打包 / 签名）加上 shim 上的单文件 XCTest；完整的 `xcodebuild test` 由 CI 承担。本版九条修复里
  #147–#150、#135、#158、#157 都涉及窗口、菜单、退出与健康检查的运行时行为，**真机项见下表明细，状态为
  「待真机验证」**。

### 2. alpha.11「已知问题」在本版的状态

| 编号 | alpha.11 的发现 | 本版状态 |
| --- | --- | --- |
| `F1` | 重叠切换竞态：迟到的 stop 回调把旧配置写回 | **已修**（#135：配置代次 + `ifGenerationMatches:` 校验） |
| `F2` | 外部服务的切换文案与实际生效时机不符 | **已修**（#135：确认文案分三态） |
| `F3` | `application(_:open:)` 未检查 `url.isFileURL`，多 URL 静默丢弃 | **已修**（#135：只接受文件 URL，多 URL 记数量日志） |
| `F4` | 最近工作目录的路径接受面未收紧 | **已修**（#135：拒绝空/控制字符/相对路径/根目录，`~` 展开、解析符号链接并标准化，长度上限 1024 字节两道检查） |
| `O-1` | 两行持久警告的既往措辞 | 未改 |
| alpha.12 评审 `R1` | 非 loopback 监听后应用窗口会加载该地址（#149 的设计目标） | 未修（设计如此；只有用户显式保存该地址才生效） |
| alpha.12 评审 `R2` | 放行面 host 比较不处理尾部点（`host.`），判为外链外开 | 未修（方向仍是外开，不放宽放行面） |
| alpha.12 评审 `R3` | 切换监听的「成功」语义是配置落盘 + 停止路径走完，不是服务就绪 | 未修 |
| 未公证需手动放行 / 依赖需自装 / 无应用内更新 / 只支持 Apple Silicon | 产品边界 | 本版均无变化 |

### 3. 需要在真机验证的行为

**状态：待真机验证**（下表由 [Release Issue #163](https://github.com/Su-luoya/pi-web-desktop/issues/163)
的真机 smoke 表回填；在本机脚本门槛之外，下面八项都需要真机点击/观察，本机不代填结果）。

| 验证项 | 设备 | 步骤 | 期望 | 结果 |
| --- | --- | --- | --- | --- |
| 服务闪断消失 | 另一台 Mac（此前反复闪现「Pi Web 服务已断开，正在尝试恢复…」） | 冷启动应用，观察 ≥2 分钟，并同时 `tail -f` 日志 | 不再出现周期性「已断开」提示；日志里没有高频重启记录 | 待真机验证 |
| 手机访问（Tailscale） | 手机（已登录同一 tailnet） | 「服务 → 复制手机访问链接 → Tailscale」→ 粘贴到手机浏览器 | 无需额外配置即可打开；首次访问提示输入远程访问密码 | 待真机验证 |
| 手机访问（局域网） | 手机（同一 Wi-Fi） | 同上，选「局域网」 | 可打开 | 待真机验证 |
| 非 loopback 下应用窗口可用 | 本机或另一台 Mac | 切换监听地址到 Tailscale/局域网后，看应用自身窗口 | 窗口显示服务页，不再跳到系统浏览器、不再闪断 | 待真机验证 |
| 代理未排除时的菜单告警 | 任意机器（系统代理已启用且未排除 VPN 网段） | 把监听地址切到 Tailscale 地址，切到应用前台 | 「服务」菜单出现代理告警项、点开有修复步骤；按提示把该网段加入代理例外后告警自动消失 | 待真机验证 |
| 导航失败不再误报 | 任意机器 | 在页面里点一个外部链接 | 外链在系统浏览器打开，应用内不出现服务断开提示 | 待真机验证 |
| 关窗后 Dock 恢复 | 任意机器 | 点红色关闭按钮 → 点 Dock 图标 | 主窗口恢复（含最小化状态下的恢复） | 待真机验证 |
| 退出不卡顿 | 任意机器 | `Cmd+Q`，对照日志里的「退出时间线」 | 从退出请求到进程结束 ≤1s 量级，无残留服务进程 | 待真机验证 |

## 回退

1. 保留上一版的 ZIP 与它的 `.sha256`。回退时解压上一版（`v0.1.0-alpha.11`，
   [资产仍在 Releases 中](https://github.com/Su-luoya/pi-web-desktop/releases/tag/v0.1.0-alpha.11)）
   并替换当前的 `Pi-Web-Desktop.app`，然后用 `codesign --verify --deep --strict` 复核（未公证的
   ad-hoc 产物仍会被 `spctl` 拒绝，这是预期结果）。`v0.1.0-alpha.12` 只有草稿、没有公开资产，不能
   作为回退来源。
2. 删除应用包即可完成卸载：应用没有系统级常驻组件或 LaunchAgent，删除应用包不会残留其他系统文件
   （退出应用后 `rm -rf "$HOME/Applications/Pi-Web-Desktop.app"`，装在 `/Applications` 时替换路径）。
3. 清理用户目录数据、删除「已放弃」记录、以及组件版本回退的具体命令与边界，见
   [alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md) 的“回退”一节与
   [隐私说明](privacy.md#本地数据一览与删除)。
4. 本版**没有新增本地数据**：没有新的 UserDefaults 键、没有新的目录结构，新增的运行期状态（连续失败
   计数、断开判定标记、配置代次、退出时间线、一次运行内的代理告警状态）都不持久化。但路径归一化规则收紧了（#135）：原先可能进入
   `workspace.recentPaths` 的形式——相对路径、含控制字符、展开后超过 1024 字节的路径——现在会被拒绝，
   读取时归一化失败的历史条目会被丢弃。注意一个配置层面的回退差异：如果用过「复制手机访问链接」并确认
   切换，监听地址会被持久化到设置里；回退到 alpha.11 后该监听地址仍然生效，需要在设置里手动改回
   loopback。
5. 已经发布的版本不会静默替换 ZIP 或 checksum；新版本有问题时发布新的 alpha 并在 Release 说明中给出
   回退路径。

## 支持边界

- 只支持 Apple Silicon（arm64）与 macOS 14 或更高版本；没有 Intel 产物。
- 没有 SLA，桌面应用没有自动更新安装，没有 Developer ID 签名、Apple 公证或 Apple 支持渠道。
- 默认只监听 loopback；远程访问必须自备加密传输，并且**密码认证不等于传输加密**。非 loopback 监听
  会拒绝保存空密码（`0.0.0.0` / `::` 也仍然不可保存）。
- 「复制手机访问链接」只枚举本机接口地址，不探测对端是否可达、不校验隧道是否在线：候选列表可能包含
  手机实际连不上的地址（例如不同网段），此时链接会打开失败。
- **退出等待有预算**（#158）：受托管服务收到 SIGTERM 后最多等约 1 秒（睡眠预算
  `stopPollBudgetMilliseconds = 1000`，探测次数由预算推导），超时才 SIGKILL；外部 / 不受托管的进程
  既不会收到信号也不会被等待。
- **配置与工作目录接受面**（#135）：最近工作目录只保存归一化后长度 ≤1024 字节的绝对目录路径，最多 10
  条；应用**不会**因为条目而创建目录，也不会在目录消失时自动清理条目（切换时会拒绝并提示）；解析符号
  链接后再存，同一目录只有一种形式。为接收文件夹声明了 `CFBundleDocumentTypes`（`public.folder`），
  Finder 的「打开方式」会为任意文件夹列出本应用，但非文件 URL 的打开请求会被忽略（只记数量）。
- 更新路径的硬边界（本版未变）：两条自动更新默认关闭且只对来源可信的 npm/pnpm 全局安装生效，目标
  版本必须来自本次网络检查；扩展包更新必须由用户确认；验证不做代码签名确认；不承诺所有来源都能回滚；
  一次只允许一轮更新事务，放弃等待后“未确认退出”的窗口只能靠重启应用可靠恢复。
- 更新检查只访问 `api.github.com` 与 `registry.npmjs.org`，只读、可逐类关闭；除此之外应用不主动向
  任何上游发送数据（自动更新触发的网络请求由用户自己的 `npm` / `pi` 按其配置发出）。
- 依赖探测会读一次登录 shell 的 `PATH`（本机、只读、有超时），并使用合并后的 `PATH` 启动依赖探测、
  更新命令与服务进程。
- 不要在公开 Issue、PR 或 Release 评论里粘贴密码、token、私有主机名、代理凭据或未脱敏日志。

## 反馈与安全报告

- 普通问题与功能建议：使用本仓库的
  [Issue 表单](https://github.com/Su-luoya/pi-web-desktop/issues/new/choose)；请附版本、安装与依赖
  信息（脱敏后的诊断导出），以及可复现步骤。上游 Pi Web、Pi CLI 或 Pi packages 的问题请先到对应
  上游仓库确认。
- 安全漏洞：**不要**开公开 Issue、不要粘贴到 PR 或 Release 评论。请使用
  [私密漏洞报告](https://github.com/Su-luoya/pi-web-desktop/security/advisories/new)，
  范围、处理流程与“不承诺 SLA”的说明见 [SECURITY.md](../SECURITY.md)。
