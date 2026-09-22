# Pi Web Desktop 0.1.0-alpha.14（build 14）— Apple Silicon alpha（未公证）

## 摘要 / Summary

Pi Web Desktop `0.1.0-alpha.14` 是面向 **Apple Silicon（arm64）、macOS 14 或更高版本** 的第十四个
alpha 预览。它启动、监控并显示本机已安装的 Pi Web 服务，默认只监听 loopback。

相对上一版**已发布**的 `0.1.0-alpha.13`，本版包含三个改动组：

- **⌘N 多窗口，以及「启动主窗口」与「最近使用窗口」的关闭语义**
  （[#168](https://github.com/Su-luoya/pi-web-desktop/issues/168)，PR #170，main `aed9774`）：新增窗口
  登记表，区分**启动主窗口（primary）** 与**最近使用窗口（MRU）**；⌘W / 红色关闭按钮对 primary 只做
  `orderOut(nil)` 隐藏（保留窗口对象、WebView 与页面会话，Dock 图标或「显示 Pi Web」恢复），对其它窗口
  （含 ⌘N 新开的）真正关闭；页面加载与页面提示广播到所有窗口；菜单与页面动作作用于 key 窗口，没有 key
  窗口时回落到最近使用窗口。
- **启动性能：依赖门控缓存快路径**（[#169](https://github.com/Su-luoya/pi-web-desktop/issues/169)，
  PR #171，main `e0afaf1`）：新增本机缓存
  `~/Library/Application Support/Pi Web Desktop/dependency-gate-cache.json`（schema `1`、7 天有效期、
  六字段指纹）；命中即立即放行 `serviceManager.isDependencyGateOpen` 并进入主窗口，完整检查转入后台
  复查。本机实测：门控放行 **0.81–0.86s → 0.137–0.139s**，服务就绪 **1.89–1.96s → 0.61–0.64s**
  （后台完整检查 +0.92s，晚于首屏）。首次启动、诊断路由与用户「重新检测」仍然走完整检查。
- **CI 构建产物 action 升级**（#166 / #167，PR #166 / #167）：`actions/upload-artifact` →
  `7.0.1`、`actions/download-artifact` → `8.0.1`；`release.yml` 的 `name` / `path` 输入不变，对用户
  可见行为没有影响。

ZIP 里的应用仍然是 **ad-hoc 签名、未公证** 的：没有 Developer ID 证书，也没有 Apple 公证，
因此 Gatekeeper 默认会阻止直接双击打开，需要用户针对这一个应用手动放行。本版本没有 Intel 支持、
没有 SLA，**不承诺所有安装来源都能回滚**；把监听地址切到非 loopback 后，访问是明文 `http`，
远程访问的密码认证**不等于传输加密**，只建议在可信网络或隧道内使用。更新验证仍然
**不做代码签名确认、不确认官方来源、不做安装包内容比对**。

Pi Web Desktop `0.1.0-alpha.14` is the fourteenth alpha preview for **Apple Silicon (arm64) Macs
running macOS 14 or later**. It starts, monitors and displays a locally installed Pi Web service and
listens on loopback by default. Compared with the previously published `0.1.0-alpha.13`, this release
carries three change groups: **⌘N multi-window support, with separate "launch primary" and "most
recently used" window roles**
([#168](https://github.com/Su-luoya/pi-web-desktop/issues/168), PR #170) — the registry distinguishes
the launch window (primary) from the most recently used window; ⌘W / the red close button only sends
the primary window to `orderOut(nil)` (the window object, web view and page session survive, and the
Dock icon or "Show Pi Web" brings it back), while every other window — including ones opened with ⌘N
— closes for real; page loads and page messages are broadcast to all windows, and menu/page actions
target the key window, falling back to the most recently used one — **a dependency-gate cache fast
path for startup** ([#169](https://github.com/Su-luoya/pi-web-desktop/issues/169), PR #171), which
stores `~/Library/Application Support/Pi Web Desktop/dependency-gate-cache.json` (schema `1`, 7-day
lifetime, six-field fingerprint) and, on a hit, opens the gate and the main window immediately while
the full check runs in the background; measured on this machine, gate release went from
**0.81–0.86s to 0.137–0.139s** and service readiness from **1.89–1.96s to 0.61–0.64s** (the
background full check finishes +0.92s later, after the first screen) — and **CI artifact-action
upgrades** (#166 / #167), where `actions/upload-artifact` moves to `7.0.1` and
`actions/download-artifact` to `8.0.1` with the `release.yml` `name` / `path` inputs unchanged. The
app inside the ZIP is still **ad-hoc signed and not notarised**: without a Developer ID certificate
and Apple notarisation, Gatekeeper blocks a plain double-click by default, so the user has to allow
this one app manually. There is no Intel support and no SLA, **not every install source can be rolled
back**, and after the listener is switched away from loopback the connection is plain `http` —
password authentication for remote access is **not transport encryption** and should only be used on
a trusted network or over a tunnel. Update verification still **does not confirm code signatures,
does not confirm the official source, and does not compare installer contents**.

## 发布信息

| 项目 | 值 |
| --- | --- |
| 版本（tag） | `v0.1.0-alpha.14` |
| `CFBundleShortVersionString` | `0.1.0-alpha.14` |
| `CFBundleVersion` | `14` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 应用包 | `Pi-Web-Desktop.app` |
| 架构 | arm64（Apple Silicon）；**不支持 Intel（x86_64）** |
| 最低系统 | macOS 14.0 |
| 签名 | ad-hoc（`codesign --sign -`），没有证书，`TeamIdentifier=not set` |
| 公证 | 无。Gatekeeper 默认拒绝，需要用户手动放行这一个应用 |
| 发布类型 | GitHub **prerelease**（alpha 预览） |
| 上一版 | `v0.1.0-alpha.13`（build `13`），资产仍在 Releases 中可下载 |
| 已被取代、不发布的构建 | 无：`v0.1.0-alpha.13` 之后合入 main 的改动全部包含在本版 |
| 发布提交 | `e0afaf1`（合并 #168 / #169 / #166 / #167 四个 PR 后的 main；main CI run [35690235011](https://github.com/Su-luoya/pi-web-desktop/actions/runs/35690235011)，`success`）加上本版发布提交（版本 bump、本文件、安全评审、门槛执行记录） |
| 本地数据位置 | UserDefaults（含 `workspace.recentPaths`）、`~/Library/Application Support/Pi Web Desktop/`（本版新增 `dependency-gate-cache.json`）、`~/Library/Logs/Pi Web Desktop/`、Keychain、WebKit 网站数据，见[隐私说明](privacy.md) |

版本与 build 的唯一来源是 `Configuration/AppIdentity.xcconfig`；本文件只是引用，不是来源。

## 目标平台

| 维度 | 支持范围 |
| --- | --- |
| CPU | Apple Silicon（arm64） |
| 系统 | macOS 14.0 或更高 |
| Intel Mac | 不支持，也没有 x86_64 产物 |
| 依赖 | Node.js `>=22.19.0`、Pi CLI、`@agegr/pi-web`（需用户自行安装，应用不打包也不自动安装） |
| 默认服务地址 | `http://127.0.0.1:30141/`（只监听 loopback） |

## `0.1.0-alpha.14` 相对 `0.1.0-alpha.13` 的新增与变更

本版包含三个改动组（#168 / #169 / #166 / #167，PR #170 / #171 / #166 / #167），随后是发布提交本身
（版本 bump、本文件、安全评审、门槛执行记录）。以下逐条说明每个改动做了什么、边界在哪里。

### 1. #168 / PR #170：⌘N 多窗口、primary 与「最近使用」两种角色（本版新增）

| 项 | 改动前 | 改动后 |
| --- | --- | --- |
| 窗口身份 | 只有「主窗口」一个概念：`window` / `webViewController` 指向唯一窗口 | 两种**相互独立**的角色：**启动主窗口（primary）** 是 `createWindow()` 创建的启动窗口，只有真正关闭（`remove(window:)`）才清除；**最近使用窗口（MRU）** 是登记表里最前面的窗口，`mainWindow` / `mainController` 表示它。最近使用顺序的变化**不会**改变 primary |
| ⌘W / 红色关闭按钮 | 关闭唯一窗口 | 判据是「是不是 primary」而不是「是不是最近使用」：primary → `orderOut(nil)` 隐藏并返回 `false`（窗口对象、WebView 与页面会话保留，Dock 图标或「显示 Pi Web」可恢复）；其它窗口（含 ⌘N 新开的）→ 返回 `true` 真正关闭，`windowWillClose` 把它从登记表移除 |
| ⌘N / 「新建窗口」 | 不存在这个命令 | 窗口菜单新增「新建窗口」（⌘N）：从最近使用窗口向右下偏移开一个新窗口；新窗口成为 key 窗口时记为最近使用 |
| 页面加载成功时 | 只更新唯一窗口的地址并重新加载 | `onLoadPage` 遍历登记表里的**所有**控制器：更新服务地址并让每个窗口重新加载服务页 |
| 页面提示（`onPageMessage`） | 只更新唯一窗口 | 广播到所有窗口 |
| 菜单 / 页面动作目标 | 唯一窗口 | key 窗口优先；没有 key 窗口时回落到最近使用窗口（`activeWindow` / `activeWebViewController`） |
| Dock 图标 / 「显示 Pi Web」恢复 | alpha.13 的 `showMainWindow()` 复用唯一窗口 | 仍然复用 **primary**：最小化先 `deminiaturize`、显示前按当前屏幕适配一次、置前后在应用不活跃时激活；primary 缺失（登记表为空或已被真正关闭）时才补建，且只在主菜单已安装（启动流程已走到 `applicationDidFinishLaunching` / smoke 路径）时补建 |

边界说明：

- 登记表（`Sources/App/AppWindowRegistry.swift`）只维护「窗口 ↔ 控制器」的对应关系、primary 标识与
  最近使用顺序：它**不 import AppKit、也不触碰 `ServiceManager`**，因此不会启动、停止或重启任何进程。
  服务生命周期仍然只由共享的 `ServiceManager` 决定；登记表为空只意味着「下次会补建窗口」，
  **不代表服务被停止**。
- 真正关闭一个非 primary 窗口只影响页面动作的目标集合：它对应的控制器被释放，其它窗口与它们的顺序
  不变。
- 窗口与 WebView 的生命周期：`newWindow.isReleasedWhenClosed = false`，由 ARC 持有与释放，避免 AppKit
  在 `isReleasedWhenClosed` 路径下重复释放；登记表持有窗口与控制器的强引用，窗口真正关闭时移除；
  控制器对窗口的 `windowProvider` 与导航失败回调都是**弱引用**捕获，不构成环。primary 被隐藏时窗口、
  WebView 与页面会话都保留（这是设计目标，不是泄漏）。
- 多窗口共享同一个服务进程与同一份 WebKit 数据存储；本版**没有**为每个窗口引入独立的服务、独立的
  配置或独立的会话数据。
- 测试：`PiWebDesktopTests/AppWindowRegistryTests.swift` 从 14 条增加到 22 条，覆盖两种角色的分离、
  `register` / `markPrimary` / `noteUsage` / `remove` 的顺序与幂等、重复登记同一窗口不产生两条记录、
  移除 primary 后的回落等（测试断言由 CI 运行；本机门槛不跑 XCTest）。

### 2. #169 / PR #171：依赖门控缓存快路径（本版新增）

| 指标 | 改动前 | 改动后 |
| --- | --- | --- |
| 门控放行（首屏可进入的时间点） | 0.81–0.86s | **0.137–0.139s** |
| 服务就绪 | 1.89–1.96s | **0.61–0.64s** |
| 完整依赖检查 | 在首屏之前完成 | 后台复查，晚于首屏（+0.92s） |

上表数字来自 #169（PR #171）的本机实测记录，**本机（Apple M4）实测**；首次启动、诊断路由与用户
「重新检测」不走快路径，耗时与上表无关。

缓存与失效规则：

- **路径与格式**：`~/Library/Application Support/Pi Web Desktop/dependency-gate-cache.json`；schema
  `1`；7 天有效期（`DependencyGateCachePolicy.maximumAge = 7 * 24 * 60 * 60`）。
- **六字段指纹**（任一变化即失效）：应用版本、`piWebPath`、`workspacePath`、hostname、
  port、工具 PATH 摘要（PATH + 登录 shell 路径 + home 目录的**摘要**，原文不落盘）。
- **其它失效条件**：文件缺失 / 不可读、schema 不匹配、超过 7 天、时钟回拨（age < 0）、缓存结论本身
  是「不可启动」、缓存里的组件枚举无法重建报告。任一成立都走完整检查。
- **适用条件**：只在**启动路径**、且本次启动本来就会进主窗口时生效；`shouldPresentDiagnostics` 与
  「首次设置未完成」不适用；用户点「重新检测」永远走完整检查。
- **收敛**：命中后完整检查仍在后台执行。结论与缓存不一致（变为不可启动，或路由不再指向主窗口）时，
  应用收敛到诊断页，并按**既有的停止路径**停掉「本应用管理、所有权可验证」的服务（外部 / 不受托管的
  服务不受影响，也不会被误杀）；一致时只刷新状态，不重新路由，避免把已经显示的服务页翻回加载页。
- **写回**：只有本机真实检查的结论才写回缓存；「不可启动」的结论也会写入，但读取端一律拒绝，因此
  「上次不可启动」是一条真实生效的失效规则；快路径自身的报告不写回（否则每次启动都会刷新时间戳，
  让 7 天有效期形同虚设）。写入失败不影响本次结论，只影响下次启动的快路径。
- **日志**：快路径命中 / 未命中（带原因码）、缓存写入结果与有效期，都经统一 `LogRedactor` 输出，只写
  状态与静态文案，不写路径、URL 或凭据。

### 3. #166 / #167：CI 构建产物 action 升级（对用户可见行为无影响）

| 项 | 改动前 | 改动后 |
| --- | --- | --- |
| 上传产物 | `actions/upload-artifact`（`v4.6.2`，固定 SHA） | `actions/upload-artifact`（`v7.0.1`，固定 SHA） |
| 下载产物 | `actions/download-artifact`（`v4.3.0`，固定 SHA） | `actions/download-artifact`（`v8.0.1`，固定 SHA） |
| `release.yml` 的输入 | `name: pi-web-desktop-alpha`、上传 `path: dist/`、下载 `path: dist` | 不变 |
| `actions/checkout` | 已在 alpha.13 周期升到 `v7.0.1` | 本版未再改 |

两个 action 都继续用**固定 SHA** 引用；发布产物的文件名、目录结构与校验方式不变。这是 CI 内部依赖
升级，不改变应用的运行时行为。

### 4. 本版的安全审查（delta）

- 完整的 delta 安全评审见 [安全评审（alpha.14）](security-review-alpha.14.md)，按 S1–S8 覆盖本版
  delta（`aa3ee17..e0afaf1`：`Sources/` 11 个文件 `+874/-98`、测试 2 个文件 `+790/-0`、
  `PiWebDesktop.xcodeproj/project.pbxproj`、`docs/` 四篇、`.github/workflows/release.yml` 两行）。
- 结论：**阻断项 0 条**；非阻断项 9 条——`R1`（非 loopback 监听后应用窗口会加载该地址）、`R2`（放行面
  host 比较不处理尾部点）、`R3`（切换监听的「成功」语义不是服务已在新地址就绪）、`R4`（退出等待预算
  ≤1 秒）、`R5`（占位符硬门禁依赖人工执行）、`R6`（应用窗口的页面请求仍走系统代理）六条继承自
  alpha.12 / alpha.13 评审且相关代码本版未改；本版新增 `R7`（依赖门控缓存是本机状态而非信任边界，
  文件含绝对路径与配置 hostname）、`R8`（指纹不含 pi / pi-web 版本，同路径版本升级不会让缓存失效）、
  `R9`（缓存不一致的收敛与「服务已在启动、所有权记录尚未落盘」之间存在窄竞态，停不下来的可能性无法
  在本机排除）。九条都已在报告里登记，不阻塞发布。

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
| Swift | `6.4`（`swift --version`，swift-driver `1.168.6`，Command Line Tools） |
| Node.js | `v24.21.0`（`/opt/homebrew/opt/node@24/bin/node`） |
| npm | `11.19.0` |
| `pi` | `0.87.0`（`@earendil-works/pi-coding-agent`） |
| `@agegr/pi-web` | `0.9.1`（全局 npm 包） |
| 诊断摘要 | `items=6 / blockers=3`（`Scripts/smoke.sh` 的诊断模式） |

与 alpha.13 记录相比逐项相同，只有 `pi` 由 `0.86.1` 变为 `0.87.0`——这是本机环境的变化，不是本版代码
引入的依赖；因此门槛结果仍可与上一版对照。

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
[README](../README.md)。#169 之后，**非首次**启动在缓存命中时直接进入主窗口，完整检查在后台复查；
首次启动、诊断路由与「重新检测」仍然是完整检查（见上文第 2 节）。

## 未公证、ad-hoc 与 Gatekeeper

本产物用 ad-hoc 签名（`codesign --sign -`），没有 Developer ID 证书，也没有经过 Apple 公证。
`spctl -a -vv` 会拒绝它（退出码 3），**这是未公证 ad-hoc 产物的预期结果，不是损坏**。首次打开需要
用户手动放行：

1. 在 Finder 里右键 `Pi-Web-Desktop.app` → “打开”，在弹窗里再确认一次“打开”。
2. 或在“系统设置 → 隐私与安全性”里对该应用选择“仍要打开”。

请只放行本仓库 Releases 页面下载、并用下文“校验值”核对过 SHA-256 的那一份 ZIP。

## 校验值

发布资产由 `.github/workflows/release.yml` 在 tag `v0.1.0-alpha.14` 上生成；**本节的大小与 SHA-256
在发布后从 Release 页面回填**，回填前保持占位，不用本机演练值冒充发布值。

| 项 | 值 |
| --- | --- |
| 发布资产 | `Pi-Web-Desktop-0.1.0-alpha.14+build.14.zip` |
| 大小 | 发布后回填 |
| SHA-256 | 发布后回填 |
| 发布提交 | `e0afaf1` + 本版发布提交；tag `v0.1.0-alpha.14` 指向包含本节内容的发布提交 |

校验方式：从 Release 下载 ZIP 与配套的 `.zip.sha256`，在同一个目录里执行

```sh
shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.14+build.14.zip.sha256
```

预期输出 `<file>: OK`。随后可复核包内版本与签名（解压到临时目录后执行）：

```sh
plutil -p Pi-Web-Desktop.app/Contents/Info.plist | grep -E 'CFBundleShortVersionString|CFBundleVersion'
codesign --verify --deep --strict Pi-Web-Desktop.app
```

预期 `CFBundleShortVersionString=0.1.0-alpha.14`、`CFBundleVersion=14`，`codesign --verify` 退出 0
（ad-hoc 产物仍会被 `spctl` 拒绝，这是预期结果）。本机门槛与演练记录见
[alpha-release-checklist.md](alpha-release-checklist.md) 的「Release v0.1.0-alpha.14 执行记录」，
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
  点开有网段说明与修复步骤；应用只读取、不修改系统代理设置。
- **退出等待预算 ≤1 秒（#158）**：受托管服务在 SIGTERM 后超过约 1 秒仍未退出时会被 SIGKILL（旧行为
  会等最多 4 秒）。需要长时间收尾的服务可能来不及做完清理；外部 / 不受托管的进程不受影响。
- **依赖门控缓存是本机状态，不是信任边界（#169）**：缓存文件位于
  `~/Library/Application Support/Pi Web Desktop/dependency-gate-cache.json`，内容包含本机的
  `piWebPath` / `workspacePath` / 配置的 hostname，以及依赖组件的绝对路径与版本证据；**不含**密码、
  token 或 PATH 原文（PATH 只存摘要）。默认权限下同机其它用户不可读（`~/Library` 与
  `Application Support` 目录为 `0700`，应用自己的数据目录 `755`、缓存文件 `644`）。与用户**同权限**
  的进程可以改写这个文件，最多让某一次启动在首屏短暂显示服务页，后台复查会在几百毫秒内收敛到真实
  结论；它**不能**绕过远程访问密码与监听地址门槛，也不会让应用执行缓存里记录的路径。
- **多窗口的可见变化（#168）**：⌘W / 红色关闭按钮关闭的是 **key 窗口**；key 是 primary 时只是隐藏
  （用 Dock 图标或「显示 Pi Web」恢复，页面会话保留），⌘N 打开的窗口会被**真正关闭**。多窗口、隐藏与
  恢复行为需要真机验证（见下）。
- **启动耗时数字的适用范围（#169）**：门控放行 0.137–0.139s、服务就绪 0.61–0.64s 是本机（Apple M4）
  实测值；不同机器、首次启动、诊断路由与「重新检测」都会走完整检查，耗时与快路径数字无关。
- **更新验证的边界**：不确认代码签名、不确认官方来源、不做安装包内容比对（见「更新检查与自动更新的
  边界」）。验证只看版本证据与文件身份。
- **回滚能力不均**：只有带版本证据的安装来源才走降级路径；npm 全局更新与 Pi 扩展包更新没有自动回滚，
  失败时只保证不声称成功、不改状态。
- **真机 GUI 未手工验收**：本机只有 Command Line Tools、没有 Xcode，本版的门槛是脚本（构建 / 身份 /
  冒烟 / 版本一致性）加上 CI 上的 XCTest；#168 的多窗口与 #169 的快路径都涉及窗口、菜单与启动时序的
  运行时行为，**真机项见下表明细，状态为「待真机验证」**。

### 2. alpha.13 的评审项与本版状态

| 编号 | alpha.13 的记录 | 本版状态 |
| --- | --- | --- |
| `R1` | 非 loopback 监听后应用窗口会加载该地址（#149 的设计目标） | 未修（设计如此；相关代码本版未改） |
| `R2` | 放行面 host 比较不处理尾部点（`host.`），判为外链外开 | 未修（方向仍是外开，不放宽放行面） |
| `R3` | 切换监听的「成功」语义是配置落盘 + 停止路径走完，不是服务就绪 | 未修（相关代码本版未改） |
| `R4` | 退出等待预算 ≤1 秒，受托管服务可能被提前 SIGKILL | 未改（#169 与本版其他改动都不触碰退出路径） |
| `R5` | 占位符硬门禁在 workflow 内只是 warning，依赖人工执行 | 未改 |
| `R6` | 应用窗口的页面请求仍走系统代理，WebKit 不支持按视图绕行 | 未改 |
| 未公证需手动放行 / 依赖需自装 / 无应用内更新 / 只支持 Apple Silicon | 产品边界 | 本版均无变化 |
| 本版新增 | — | `R7` 缓存的信任边界与隐私足迹、`R8` 指纹不含依赖版本、`R9` 收敛与启动的所有权记录竞态，见[安全评审 §9](security-review-alpha.14.md) |

### 3. 需要在真机验证的行为

**状态：待真机验证**（下表由 [Release Issue #172](https://github.com/Su-luoya/pi-web-desktop/issues/172)
的真机 smoke 表回填；在本机脚本门槛之外，下面各项都需要真机点击/观察，本机不代填结果）。

| 验证项 | 设备 | 步骤 | 期望 | 结果 |
| --- | --- | --- | --- | --- |
| ⌘N 多窗口 | 任意机器 | 启动应用 → ⌘N 打开第二个窗口 → 在两个窗口间切换 | 出现第二个窗口；两个窗口都能显示服务页；窗口位置向右下偏移 | 待真机验证 |
| 主窗口关窗语义（primary 隐藏） | 任意机器 | 点主窗口的红色关闭按钮 / ⌘W | 主窗口隐藏、页面会话保留；点 Dock 图标或「服务 → 显示 Pi Web」恢复同一个窗口（不是新窗口） | 待真机验证 |
| 非 primary 窗口真正关闭 | 任意机器 | 对 ⌘N 打开的窗口点红色关闭按钮 / ⌘W | 该窗口真正关闭；主窗口不受影响；再次 ⌘N 可再开 | 待真机验证 |
| 菜单动作作用于 key 窗口 | 任意机器 | 在第二个窗口为 key 时执行「刷新」「放大/缩小」「在页面中查找」 | 动作只作用于 key 窗口，另一个窗口的缩放/查找状态不变 | 待真机验证 |
| 页面广播不重复开窗 | 任意机器 | 在「设置」里切换监听地址（或触发服务重载） | 所有已打开窗口都更新到新地址；不会额外冒出窗口 | 待真机验证 |
| 启动耗时（#169 快路径） | 任意机器 | 第二次及之后的冷启动，观察首屏与日志里的门控/缓存行 | 首屏快速进入服务页；日志出现「快路径命中」与缓存有效期；后台复查完成 | 待真机验证 |
| 缓存失效与收敛 | 任意机器 | 构造一次「依赖不可用」后重启应用（例如临时改坏依赖路径） | 不走快路径 / 后台复查发现不一致后收敛到环境检查页，并停掉本次启动的受托管服务 | 待真机验证 |
| 服务闪断消失 | 另一台 Mac（此前反复闪现「Pi Web 服务已断开，正在尝试恢复…」） | 冷启动应用，观察 ≥2 分钟，并同时 `tail -f` 日志 | 不再出现周期性「已断开」提示；日志里没有高频重启记录 | 待真机验证 |
| 手机访问（Tailscale） | 手机（已登录同一 tailnet） | 「服务 → 复制手机访问链接 → Tailscale」→ 粘贴到手机浏览器 | 无需额外配置即可打开；首次访问提示输入远程访问密码 | 待真机验证 |
| 手机访问（局域网） | 手机（同一 Wi-Fi） | 同上，选「局域网」 | 可打开 | 待真机验证 |
| 非 loopback 下应用窗口可用 | 本机或另一台 Mac | 切换监听地址到 Tailscale/局域网后，看应用自身窗口 | 窗口显示服务页，不再跳到系统浏览器、不再闪断 | 待真机验证 |
| 代理未排除时的菜单告警 | 任意机器（系统代理已启用且未排除 VPN 网段） | 把监听地址切到 Tailscale 地址，切到应用前台 | 「服务」菜单出现代理告警项、点开有修复步骤；按提示把该网段加入代理例外后告警自动消失 | 待真机验证 |
| 导航失败不再误报 | 任意机器 | 在页面里点一个外部链接 | 外链在系统浏览器打开，应用内不出现服务断开提示 | 待真机验证 |
| 关窗后 Dock 恢复 | 任意机器 | 点红色关闭按钮 → 点 Dock 图标 | 主窗口恢复（含最小化状态下的恢复） | 待真机验证 |
| 退出不卡顿 | 任意机器 | `Cmd+Q`，对照日志里的「退出时间线」 | 从退出请求到进程结束 ≤1s 量级，无残留服务进程 | 待真机验证 |

## 回退

1. 保留上一版的 ZIP 与它的 `.sha256`。回退时解压上一版（`v0.1.0-alpha.13`，
   [资产仍在 Releases 中](https://github.com/Su-luoya/pi-web-desktop/releases/tag/v0.1.0-alpha.13)）
   并替换当前的 `Pi-Web-Desktop.app`，然后用 `codesign --verify --deep --strict` 复核（未公证的
   ad-hoc 产物仍会被 `spctl` 拒绝，这是预期结果）。
2. 删除应用包即可完成卸载：应用没有系统级常驻组件或 LaunchAgent，删除应用包不会残留其他系统文件
   （退出应用后 `rm -rf "$HOME/Applications/Pi-Web-Desktop.app"`，装在 `/Applications` 时替换路径）。
3. 清理用户目录数据、删除「已放弃」记录、以及组件版本回退的具体命令与边界，见
   [alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md) 的“回退”一节与
   [隐私说明](privacy.md#本地数据一览与删除)。
4. 本版**没有新增 UserDefaults 键**（`UserDefaults` 计数 79 → 79），但**新增了一个本机缓存文件**：
   `~/Library/Application Support/Pi Web Desktop/dependency-gate-cache.json`。回退到 `v0.1.0-alpha.13`
   后旧版**不读取**这个文件（它会完整检查），因此可以保留也可以删除，删除只影响那一次启动的速度，
   不影响配置与页面数据。多窗口不引入新的持久化数据；回退后行为回到 alpha.13 的单窗口语义。
5. 已经发布的版本不会静默替换 ZIP 或 checksum；新版本有问题时发布新的 alpha 并在 Release 说明中给出
   回退路径。

## 支持边界

- 只支持 Apple Silicon（arm64）与 macOS 14 或更高版本；没有 Intel 产物。
- 没有 SLA，桌面应用没有自动更新安装，没有 Developer ID 签名、Apple 公证或 Apple 支持渠道。
- 默认只监听 loopback；远程访问必须自备加密传输，并且**密码认证不等于传输加密**。非 loopback 监听
  会拒绝保存空密码（`0.0.0.0` / `::` 也仍然不可保存）。
- 「复制手机访问链接」只枚举本机接口地址，不探测对端是否可达、不校验隧道是否在线：候选列表可能包含
  手机实际连不上的地址（例如不同网段），此时链接会打开失败。
- **多窗口共享同一个服务与同一份 WebKit 数据存储**（#168）：关闭非 primary 窗口或隐藏 primary 都
  **不会**停止服务；服务生命周期只由启动流程、健康检查与退出路径决定。
- **依赖门控快路径的硬边界**（#169）：只在启动路径生效；六字段指纹任一变化、schema 不匹配、超过
  7 天、缓存结论为「不可启动」或缓存不可读时一律走完整检查；后台复查与缓存不一致时收敛到诊断页。
  缓存文件不是配置，也不是信任边界（见「已知问题」）。
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
  更新命令与服务进程；缓存文件里只保存这份输入的**摘要**，不保存原文。
- 不要在公开 Issue、PR 或 Release 评论里粘贴密码、token、私有主机名、代理凭据或未脱敏日志。

## 反馈与安全报告

- 普通问题与功能建议：使用本仓库的
  [Issue 表单](https://github.com/Su-luoya/pi-web-desktop/issues/new/choose)；请附版本、安装与依赖
  信息（脱敏后的诊断导出），以及可复现步骤。上游 Pi Web、Pi CLI 或 Pi packages 的问题请先到对应
  上游仓库确认。
- 安全漏洞：**不要**开公开 Issue、不要粘贴到 PR 或 Release 评论。请使用
  [私密漏洞报告](https://github.com/Su-luoya/pi-web-desktop/security/advisories/new)，
  范围、处理流程与“不承诺 SLA”的说明见 [SECURITY.md](../SECURITY.md)。
