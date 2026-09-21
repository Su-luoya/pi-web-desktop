# Pi Web Desktop 0.1.0-alpha.12（build 12）— Apple Silicon alpha（未公证）

## 摘要 / Summary

Pi Web Desktop `0.1.0-alpha.12` 是面向 **Apple Silicon（arm64）、macOS 14 或更高版本** 的第十二个
alpha 预览。它启动、监控并显示本机已安装的 Pi Web 服务，默认只监听 loopback。相对
`0.1.0-alpha.11`，本版本集中修掉四个用户可见问题：**健康检查去抖**（单次 1 秒抖动不再翻成「已断开」，
也不再第一次失败就重启服务，[#147](https://github.com/Su-luoya/pi-web-desktop/issues/147)）、
**被取消的导航不再被判为失败**、页面加载失败不再把服务状态改成「已停止」
（[#148](https://github.com/Su-luoya/pi-web-desktop/issues/148)）、**WebView 放行面跟随当前配置的服务
地址**（[#149](https://github.com/Su-luoya/pi-web-desktop/issues/149)）、以及新增
**「复制手机访问链接」**，按需枚举地址、确认后切换监听并复制
（[#150](https://github.com/Su-luoya/pi-web-desktop/issues/150)）。四个 Issue 的 PR 分别是 #152、
#151、#154、#153。

ZIP 里的应用仍然是 **ad-hoc 签名、未公证** 的：没有 Developer ID 证书，也没有 Apple 公证，
因此 Gatekeeper 默认会阻止直接双击打开，需要用户针对这一个应用手动放行。本版本没有 Intel 支持、
没有 SLA，**不承诺所有安装来源都能回滚**；把监听地址切到非 loopback 后，访问是明文 `http`，
远程访问的密码认证**不等于传输加密**，只建议在可信网络或隧道内使用。更新验证仍然
**不做代码签名确认、不确认官方来源、不做安装包内容比对**。

Pi Web Desktop `0.1.0-alpha.12` is the twelfth alpha preview for **Apple Silicon (arm64) Macs
running macOS 14 or later**. It starts, monitors and displays a locally installed Pi Web service and
listens on loopback by default. Compared with `0.1.0-alpha.11` this release fixes four
user-visible problems: **health-check debouncing** (a single one-second hiccup no longer flips the
service to "disconnected", and the first failure no longer restarts the service,
[#147](https://github.com/Su-luoya/pi-web-desktop/issues/147)), **cancelled navigations are no longer
reported as failures** and a page-load failure no longer rewrites the service state as "stopped"
([#148](https://github.com/Su-luoya/pi-web-desktop/issues/148)), **the web view's allow surface now
follows the configured service origin**
([#149](https://github.com/Su-luoya/pi-web-desktop/issues/149)), and a new
**"Copy phone access link"** command that enumerates addresses, asks for confirmation, switches the
listener and copies the link
([#150](https://github.com/Su-luoya/pi-web-desktop/issues/150)). The four pull requests are #152,
#151, #154 and #153. The app inside the ZIP is still **ad-hoc signed and not notarised**: without a
Developer ID certificate and Apple notarisation, Gatekeeper blocks a plain double-click by default,
so the user has to allow this one app manually. There is no Intel support and no SLA, **not every
install source can be rolled back**, and after the listener is switched away from loopback the
connection is plain `http` — password authentication for remote access is **not transport
encryption** and should only be used on a trusted network or over a tunnel. Update verification
still **does not confirm code signatures, does not confirm the official source, and does not
compare installer contents**.

## 发布信息

| 项目 | 值 |
| --- | --- |
| 版本（tag） | `v0.1.0-alpha.12` |
| `CFBundleShortVersionString` | `0.1.0-alpha.12` |
| `CFBundleVersion` | `12` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 应用包 | `Pi-Web-Desktop.app` |
| 架构 | arm64（Apple Silicon）；**不支持 Intel（x86_64）** |
| 最低系统 | macOS 14.0 |
| 签名 | ad-hoc（`codesign --sign -`），没有证书，`TeamIdentifier=not set` |
| 公证 | 无。Gatekeeper 默认拒绝，需要用户手动放行这一个应用 |
| 发布类型 | GitHub **prerelease**（alpha 预览） |
| 上一版 | `v0.1.0-alpha.11`（build `11`），资产仍在 Releases 中可下载 |
| 发布提交 | `f938773`（合并 #147–#150 四个 PR 后的 main；main CI run [35596701327](https://github.com/Su-luoya/pi-web-desktop/actions/runs/35596701327) 为绿） |
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

## `0.1.0-alpha.12` 相对 `0.1.0-alpha.11` 的新增与变更

本版有四个代码提交（#147 / #148 / #149 / #150，对应 PR #152 / #151 / #154 / #153），随后是发布提交
本身（版本 bump、本文件、安全评审、门槛执行记录）。以下逐条说明每个改动做了什么、边界在哪里。

### 1. #147 / PR #152：健康检查去抖

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

### 2. #148 / PR #151：被取消的导航不再被判为失败，页面加载失败不再改服务状态

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

### 3. #149 / PR #154：WebView 放行面跟随当前配置的服务地址

放行面（留在应用窗口内的 URL）从「loopback + inline scheme」改为：

1. **当前配置的服务地址**：scheme、host、port 完全一致（大小写不敏感，IPv6 字面量去括号后比较；
   path 与 query 无关）——这是唯一一个非 loopback 入口，它存在的原因是应用只和自己配置并启动的
   地址比较；
2. **loopback**：`127.0.0.1` / `localhost` / `::1`，且端口等于配置端口（配置没有端口时不存在
   这一项）；
3. **inline scheme**：`about`、`blob`、`data`。

**没有**网段白名单、**没有**后缀白名单、**没有**通配符：不是「允许 `10/8` 之类的一整段」，而是
「只允许这一个精确的 origin」。`http` / `https` 以外的协议（`file:`、`mailto:` 等）一律交给系统。
修复的可见问题：把监听地址切到 Tailscale 或局域网地址后，应用自己的窗口不再把服务页丢给系统浏览器。
同一套判定也用于弹出窗口（`createWebViewWith`）：目标是放行面就替换当前页，否则交给系统。

### 4. #150 / PR #153：新增「复制手机访问链接」

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

### 5. 本版的安全审查（delta）

- 完整的 delta 安全评审见 [安全评审（alpha.12）](security-review-alpha.12.md)，按 S1–S8 覆盖本版 delta。
- 结论：**阻断项 0 条**，非阻断项 3 条（登记，不阻塞）：非 loopback 监听后应用窗口会加载该地址
  （`R1`）、放行面比较的 host 规范化在 host 含尾部点（FQDN 写法）时不归一（`R2`）、
  「切换监听」失败路径只有一处提示而没有回滚已保存配置（`R3`）。
- 本版新增了网络接口枚举（只读、本机、无网络请求）与一条可切换监听地址的用户确认路径；新日志行都
  经过统一脱敏实例，且只记计数、不记探测 URL。

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

与 alpha.11 记录的环境相比逐项相同，因此门槛结果可以直接和上一版对照。

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

发布资产由 `.github/workflows/release.yml` 在 tag `v0.1.0-alpha.12` 上生成；**本节的大小与 SHA-256
在发布后从 Release 页面回填**，回填前保持占位，不用本机演练值冒充发布值。

| 项 | 值 |
| --- | --- |
| 发布资产 | `Pi-Web-Desktop-0.1.0-alpha.12+build.12.zip` |
| 大小 | 待填（发布后回填） |
| SHA-256 | 待填（发布后回填） |
| 发布提交 | `f938773`（本版发布提交；tag `v0.1.0-alpha.12` 指向该提交之后含本节内容的发布提交） |

校验方式：从 Release 下载 ZIP 与配套的 `.zip.sha256`，在同一个目录里执行

```sh
shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.12+build.12.zip.sha256
```

预期输出 `<file>: OK`。随后可复核包内版本与签名（解压到临时目录后执行）：

```sh
plutil -p Pi-Web-Desktop.app/Contents/Info.plist | grep -E 'CFBundleShortVersionString|CFBundleVersion'
codesign --verify --deep --strict Pi-Web-Desktop.app
```

预期 `CFBundleShortVersionString=0.1.0-alpha.12`、`CFBundleVersion=12`，`codesign --verify` 退出 0
（ad-hoc 产物仍会被 `spctl` 拒绝，这是预期结果）。本机门槛与演练记录见
[alpha-release-checklist.md](alpha-release-checklist.md) 的「Release v0.1.0-alpha.12 执行记录」，
那里同时给出本机演练值与「发布后回填」的区分。

## 已知问题

### 1. 本版仍然存在的问题

- **未公证、ad-hoc 签名**：Gatekeeper 默认阻止直接双击打开，需要用户针对这一个应用手动放行（见
  「未公证、ad-hoc 与 Gatekeeper」）。本版不引入 Developer ID，也不做公证。
- **非 loopback 监听需要先设置远程访问密码**：新增的「复制手机访问链接」在密码缺失时**不**改配置、
  **不**启动远程监听，只引导去设置密码。这是设计如此，不是缺陷。
- **非 loopback 访问是明文 `http`**：密码认证**不等于传输加密**，只建议在可信网络或隧道内使用。
- **更新验证的边界**：不确认代码签名、不确认官方来源、不做安装包内容比对（见「更新检查与自动更新的
  边界」）。验证只看版本证据与文件身份。
- **回滚能力不均**：只有带版本证据的安装来源才走降级路径；npm 全局更新与 Pi 扩展包更新没有自动回滚，
  失败时只保证不声称成功、不改状态。
- **真机 GUI 未手工验收**：本机只有 Command Line Tools、没有 Xcode，本版的门槛是脚本（构建 / 身份 /
  冒烟 / 打包 / 签名）加上 shim 上的单文件 XCTest；完整的 `xcodebuild test` 由 CI 承担。本版四条修复
  都涉及窗口、菜单与健康检查的运行时行为，**真机项见下表明细，状态为「待真机验证」**。

### 2. alpha.11「已知问题」在本版的状态

| 编号 | alpha.11 的发现 | 本版状态 |
| --- | --- | --- |
| `F1` / `F2` / `F4`（[#135](https://github.com/Su-luoya/pi-web-desktop/issues/135)） | 重叠切换竞态、外部服务的文案、路径接受面未收紧 | 未修（本版不涉及这些路径；`F4` 的路径接受面仍未收紧） |
| `F3` | `application(_:open:)` 未检查 `url.isFileURL`，多 URL 静默丢弃 | 未修：`Sources/App/AppDelegate+Window.swift` 本版被 #148 改动，但改的是导航失败的上报路径，`application(_:open:)` 本身未变 |
| `O-1` | 两行持久警告的既往措辞 | 未改 |
| 未公证需手动放行 / 依赖需自装 / 无应用内更新 / 只支持 Apple Silicon | 产品边界 | 本版均无变化 |

### 3. 需要在真机验证的行为

**状态：待真机验证**（下表由 [Release Issue #155](https://github.com/Su-luoya/pi-web-desktop/issues/155)
的真机 smoke 表回填；在本机脚本门槛之外，下面五项都需要真机点击/观察，本机不代填结果）。

| 验证项 | 设备 | 步骤 | 期望 | 结果 |
| --- | --- | --- | --- | --- |
| 服务闪断消失 | 另一台 Mac（此前反复闪现「Pi Web 服务已断开，正在尝试恢复…」） | 冷启动应用，观察 ≥2 分钟，并同时 `tail -f` 日志 | 不再出现周期性「已断开」提示；日志里没有高频重启记录 | 待真机验证 |
| 手机访问（Tailscale） | 手机（已登录同一 tailnet） | 「服务 → 复制手机访问链接 → Tailscale」→ 粘贴到手机浏览器 | 无需额外配置即可打开；首次访问提示输入远程访问密码 | 待真机验证 |
| 手机访问（局域网） | 手机（同一 Wi-Fi） | 同上，选「局域网」 | 可打开 | 待真机验证 |
| 非 loopback 下应用窗口可用 | 本机或另一台 Mac | 切换监听地址到 Tailscale/局域网后，看应用自身窗口 | 窗口显示服务页，不再跳到系统浏览器、不再闪断 | 待真机验证 |
| 导航失败不再误报 | 任意机器 | 在页面里点一个外部链接 | 外链在系统浏览器打开，应用内不出现服务断开提示 | 待真机验证 |

## 回退

1. 保留上一版的 ZIP 与它的 `.sha256`。回退时解压上一版（`v0.1.0-alpha.11`，
   [资产仍在 Releases 中](https://github.com/Su-luoya/pi-web-desktop/releases/tag/v0.1.0-alpha.11)）
   并替换当前的 `Pi-Web-Desktop.app`，然后用 `codesign --verify --deep --strict` 复核（未公证的
   ad-hoc 产物仍会被 `spctl` 拒绝，这是预期结果）。
2. 删除应用包即可完成卸载：应用没有系统级常驻组件或 LaunchAgent，删除应用包不会残留其他系统文件
   （退出应用后 `rm -rf "$HOME/Applications/Pi-Web-Desktop.app"`，装在 `/Applications` 时替换路径）。
3. 清理用户目录数据、删除「已放弃」记录、以及组件版本回退的具体命令与边界，见
   [alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md) 的“回退”一节与
   [隐私说明](privacy.md#本地数据一览与删除)。
4. 本版**没有新增本地数据**：本版只新增两个运行期状态变量（连续失败计数与断开判定标记，都不持久化），
   `workspace.recentPaths` 等 UserDefaults 键、Application Support 与 Logs 的目录结构都没有变化。
   注意一个配置层面的回退差异：如果本版用过「复制手机访问链接」并确认切换，监听地址会被持久化到
   设置里；回退到 alpha.11 后该监听地址仍然生效，需要在设置里手动改回 loopback。
5. 已经发布的版本不会静默替换 ZIP 或 checksum；新版本有问题时发布新的 alpha 并在 Release 说明中给出
   回退路径。

## 支持边界

- 只支持 Apple Silicon（arm64）与 macOS 14 或更高版本；没有 Intel 产物。
- 没有 SLA，桌面应用没有自动更新安装，没有 Developer ID 签名、Apple 公证或 Apple 支持渠道。
- 默认只监听 loopback；远程访问必须自备加密传输，并且**密码认证不等于传输加密**。非 loopback 监听
  会拒绝保存空密码（`0.0.0.0` / `::` 也仍然不可保存）。
- 「复制手机访问链接」只枚举本机接口地址，不探测对端是否可达、不校验隧道是否在线：候选列表可能包含
  手机实际连不上的地址（例如不同网段），此时链接会打开失败。
- 更新路径的硬边界（本版未变）：两条自动更新默认关闭且只对来源可信的 npm/pnpm 全局安装生效，目标
  版本必须来自本次网络检查；扩展包更新必须由用户确认；验证不做代码签名确认；不承诺所有来源都能回滚；
  一次只允许一轮更新事务，放弃等待后“未确认退出”的窗口只能靠重启应用可靠恢复。
- 更新检查只访问 `api.github.com` 与 `registry.npmjs.org`，只读、可逐类关闭；除此之外应用不主动向
  任何上游发送数据（自动更新触发的网络请求由用户自己的 `npm` / `pi` 按其配置发出）。
- 依赖探测会读一次登录 shell 的 `PATH`（本机、只读、有超时），并使用合并后的 `PATH` 启动依赖探测、
  更新命令与服务进程。
- 最近工作目录的边界：只保存用户自己选择或被要求打开的绝对路径，最多 10 条；应用**不会**因为条目而
  创建目录，也不会在目录消失时自动清理条目（切换时会拒绝并提示）。为接收文件夹声明了
  `CFBundleDocumentTypes`（`public.folder`），因此 Finder 的「打开方式」会为任意文件夹列出本应用。
- 不要在公开 Issue、PR 或 Release 评论里粘贴密码、token、私有主机名、代理凭据或未脱敏日志。

## 反馈与安全报告

- 普通问题与功能建议：使用本仓库的
  [Issue 表单](https://github.com/Su-luoya/pi-web-desktop/issues/new/choose)；请附版本、安装与依赖
  信息（脱敏后的诊断导出），以及可复现步骤。上游 Pi Web、Pi CLI 或 Pi packages 的问题请先到对应
  上游仓库确认。
- 安全漏洞：**不要**开公开 Issue、不要粘贴到 PR 或 Release 评论。请使用
  [私密漏洞报告](https://github.com/Su-luoya/pi-web-desktop/security/advisories/new)，
  范围、处理流程与“不承诺 SLA”的说明见 [SECURITY.md](../SECURITY.md)。
