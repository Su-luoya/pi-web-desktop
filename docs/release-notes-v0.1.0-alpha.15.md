# Pi Web Desktop 0.1.0-alpha.15（build 15）— Apple Silicon alpha（未公证）

## 摘要 / Summary

Pi Web Desktop `0.1.0-alpha.15` 是面向 **Apple Silicon（arm64）、macOS 14 或更高版本** 的第十五个
alpha 预览。它启动、监控并显示本机已安装的 Pi Web 服务，默认只监听 loopback。

Pi Web Desktop 0.1.0-alpha.15 is an early alpha for Apple Silicon (arm64) Macs running macOS 14 or
later. The app in the ZIP is **ad-hoc signed and not notarized**: there is no Developer ID
certificate and no Apple notarization, so Gatekeeper blocks a plain double-click and the user has to
approve this app explicitly.

相对上一版**已发布**的 `0.1.0-alpha.14`，本版包含两个改动组：

- **桌面 App 自更新**（[#175](https://github.com/Su-luoya/pi-web-desktop/issues/175)，PR #174，
  main `c0397e3`）：更新检查发现新版本后，菜单里出现「下载并安装桌面应用更新…」；确认后应用按 GitHub
  发布的 `.sha256` 校验 ZIP、核对 bundle id 与版本，替换 `/Applications` 里的应用并重启。
- **人工安装路径的两处修复**（[#176](https://github.com/Su-luoya/pi-web-desktop/issues/176) /
  [#177](https://github.com/Su-luoya/pi-web-desktop/issues/177)，PR #178，main `d1f8ea7`）：条件请求
  命中 304 的复验结论不再被误判成「没有可用的桌面应用发布包」；重定向校验改为同时支持 GitHub 的签名
  直链（文件名在查询串里）。两处都是真机端到端验证时发现的。

随后是发布提交本身（版本 bump、本文件、安全评审、门槛执行记录）。

## 发布信息

| 项目 | 值 |
| --- | --- |
| 版本（tag） | `v0.1.0-alpha.15` |
| `CFBundleShortVersionString` | `0.1.0-alpha.15` |
| `CFBundleVersion` | `15` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 应用包 | `Pi-Web-Desktop.app` |
| 架构 | arm64（Apple Silicon）；**不支持 Intel（x86_64）** |
| 最低系统 | macOS 14.0 |
| 签名 | ad-hoc（`codesign --sign -`），没有证书，`TeamIdentifier=not set` |
| 公证 | 无。Gatekeeper 默认拒绝，需要用户手动放行这一个应用 |
| 发布类型 | GitHub **prerelease**（alpha 预览） |
| 上一版 | `v0.1.0-alpha.14`（build `14`），资产仍在 Releases 中可下载 |
| 已被取代、不发布的构建 | 无：`v0.1.0-alpha.14` 之后合入 main 的改动全部包含在本版 |
| 发布提交 | `d1f8ea7`（合并 #175 / #176 / #177 三个 PR 后的 main；main CI run [35822177506](https://github.com/Su-luoya/pi-web-desktop/actions/runs/35822177506)，`success`）加上本版发布提交（版本 bump、本文件、安全评审、门槛执行记录） |
| 本地数据位置 | UserDefaults（含 `workspace.recentPaths`）、`~/Library/Application Support/Pi Web Desktop/`（`dependency-gate-cache.json`、更新检查缓存）、`~/Library/Logs/Pi Web Desktop/`、Keychain、WebKit 网站数据，见[隐私说明](privacy.md) |

版本与 build 的唯一来源是 `Configuration/AppIdentity.xcconfig`；本文件只是引用，不是来源。

## 目标平台

| 维度 | 支持范围 |
| --- | --- |
| CPU | Apple Silicon（arm64） |
| 系统 | macOS 14.0 或更高 |
| Intel Mac | 不支持，也没有 x86_64 产物 |
| 依赖 | Node.js `>=22.19.0`、Pi CLI、`@agegr/pi-web`（需用户自行安装，应用不打包也不自动安装） |
| 默认服务地址 | `http://127.0.0.1:30141/`（只监听 loopback） |

## `0.1.0-alpha.15` 相对 `0.1.0-alpha.14` 的新增与变更

### 1. #175 / PR #174：桌面 App 自更新（本版新增）

更新检查在 alpha.5 就已经能发现「桌面应用有新版」，但当时没有任何安装动作；本版把它接成了一个**由
用户确认**的安装流程。

| 环节 | 改动前 | 改动后 |
| --- | --- | --- |
| 菜单入口 | 只有状态行与「检查更新…」 | 「服务 → 更新检查设置」里多一项「下载并安装桌面应用更新…」：默认隐藏，只有该分类的检查结论是「有可用更新」时才显示；安装流程进行中置灰 |
| 准入判定 | 无 | `DesktopAppUpdateInstallPolicy` 要求四条同时成立：结论是「有可用更新」、本轮网络往返成功（`freshness == .fresh`）、上游结构已核实（`confidence == .verified`）、目标版本比正在运行的 `CFBundleShortVersionString` 新（语义化版本比较）；任一不成立就报「本次检查结果不是本轮从上游确认的可用更新，或目标版本不比当前版本新」 |
| 确认框 | 无 | 一个 `.warning` 风格的确认框：写明目标版本、说明下载安装后应用会退出并重启，并**明写当前版本没有 Apple Developer 签名与 notarization、请确认 GitHub 发布来源**；默认按钮是「更新」，另一个是「取消」 |
| 资产获取 | 无 | 按结论里的 tag 重新联网请求 `api.github.com/repos/Su-luoya/pi-web-desktop/releases/tags/<tag>`（scheme / host / path 精确匹配，不允许 query 与 fragment），要求 `tag_name` 与请求的 tag 一致；从 `assets` 里选 `Pi-Web-Desktop-<version>[-+build.N].zip` 与同名 `.zip.sha256` |
| 地址锁定 | 无 | 两个资产的 `browser_download_url` 必须**精确等于** `https://github.com/Su-luoya/pi-web-desktop/releases/download/<tag>/<assetName>`（`github.com`、https、无 query / fragment、无 userinfo）；不匹配就报「更新包地址不在允许的 GitHub 主机上」 |
| 校验值 | 无 | 读取 GitHub 公布的 `.zip.sha256`，取第一个 64 位十六进制串；缺失、长度不对或含非十六进制字符就报「更新包缺少 SHA-256 校验值，已停止安装」 |
| 下载与校验 | 无 | 独立的 ephemeral `URLSession`（不写 cookie、不存凭据、忽略本地缓存、固定超时）下载 ZIP；下载完成后用 CryptoKit 流式（1 MB 分块）算 SHA-256 与公布值比对，不一致报「更新包校验失败，已停止安装」 |
| 解压与自检 | 无 | 用 `/usr/bin/ditto -x -k` 解压到系统临时目录下的一次性 staging 目录；只接受 staging 内名为 `Pi-Web-Desktop.app` 且解析符号链接后仍在 staging 内的 `.app`；再核对 bundle id 是 `io.github.su-luoya.pi-web-desktop`、`CFBundleShortVersionString` 与目标版本（语义化版本）一致、可执行文件存在，否则报「更新包中的应用无法验证，已停止安装」 |
| 替换与重启 | 无 | 写一个一次性 `/bin/sh` 脚本（权限 `0700`）到临时目录；脚本等待当前进程退出（`kill -0` 轮询，最长 60 秒，超时就清理 staging 并退出 1），把 `/Applications/Pi-Web-Desktop.app` 移到同目录的隐藏备份名，再把新 bundle 移到原位；第二步失败就把备份移回；成功后删掉备份 / staging / 脚本并 `open -n` 打开新应用。应用侧在启动脚本后调用 `NSApp.terminate(nil)` 退出自己 |

边界说明：

- **安装位置**：只有解析符号链接后正好是 `/Applications/Pi-Web-Desktop.app` 时才允许更新；其它位置
  （例如 `~/Applications`、`/tmp`）直接报「当前应用不是从 /Applications 安装，无法自动更新」。目录
  是否可写用一个临时探针文件实测，不可写就报「当前应用目录不可写，无法自动更新」。
- **信任模型**：信任来自「GitHub 发布的资产 + 仓库公布的 SHA-256 + bundle 身份与版本自检」，
  **不是** Developer ID / Apple 公证的签名链，也不证明发布者身份。更新包只由 SHA-256 保证与公布值
  一致；`.sha256` 本身也从同一个 Release 下载，因此它保护的是「传输与归档损坏 / 被第三方替换资产」
  这类问题，而不是「上游仓库被攻破」。确认框里明写了未公证这一点。
- **失败不破坏现有安装**：所有校验都在替换之前完成；替换脚本只有「备份还在原地」或「已经换成新
  bundle」两种结束状态，第二步失败会把备份移回。脚本在退出前都会清理 staging 与自身。
- **不做无人值守安装**：桌面 App 分类不参与启动前自动更新；每次安装都由用户在菜单里点击并在确认框
  里确认。自动安装路径（Pi Web / Pi CLI / 扩展包）本版未改，仍然要求结论来自本轮网络请求。
- **并发**：安装器由 `AppDelegate` 持有，同一时刻只允许一个安装流程；流程进行中菜单项置灰，再次触发
  直接拒绝。应用退出时清空引用。
- **网络面**：只访问 `github.com`（API 与资产），以及 GitHub 的重定向目标
  `objects.githubusercontent.com` / `release-assets.githubusercontent.com`；请求用既有的固定
  `User-Agent` 标识，不含主机名、用户名或任何本机信息。
- **本机数据**：本版**没有新增 UserDefaults 键**（按既有口径 `git grep -c -F UserDefaults -- Sources`
  合计 79 → 79）。新增的持久化内容只有更新检查缓存里的 `upstreamTag` 字段（GitHub Release 的原始
  tag 字符串，读取时校验长度与控制字符），它只用于按 tag 重新联网取资产。
- **测试**：`PiWebDesktopTests/DesktopAppUpdateTests.swift`（本版新增，172 行，5 个用例）覆盖
  资产选择与地址锁定、校验值形态、`/Applications` 位置判定、304 复验的准入判定、签名直链的重定向
  判定。本机只有 Command Line Tools、没有 Xcode，本文件记录的门槛不包含 XCTest；这些用例由 CI 的
  `xcodebuild test` 运行。

### 2. #176 / #177 / PR #178：人工安装路径的两处修复（本版新增）

两处缺陷都是本版自更新功能在**真机端到端验证**时发现的，都在 `v0.1.0-alpha.14` 发布时间之后才修好，
因此**不包含在 alpha.14 里**。

| 缺陷 | 现象 | 根因 | 修复 |
| --- | --- | --- | --- |
| 304 复验被误判（#176） | 点菜单项每次都报「该版本没有可用的桌面应用 ZIP 发布包」，但更新确实存在 | 条件请求命中 304 时结论是 `freshness == .fresh` 但 `origin == .cachedFallback`，而菜单入口的准入沿用了自动安装的「必须 `origin == .network`」条件 | 新增 `DesktopAppUpdateInstallPolicy`：准入改为「本轮网络往返成功 + 上游结构已核实 + 目标版本比正在运行的新」；下载前仍会按 tag 重新联网、钉死资产路径、用公布校验值核对、核对 bundle 身份与版本 |
| 签名直链被当成非法重定向（#177） | 下载与校验值读取都失败，报「更新包缺少 SHA-256 校验值」 | GitHub 的签名直链把文件名放在查询串里（`response-content-disposition=attachment; filename=….zip`，`rscd` 同义），路径却是 `github-production-release-asset/<id>/<uuid>` 这样的不透明 id；只看 `url.pathExtension` 会把真实的重定向判成非法 | 抽出共享的 `allowsRedirect(_:requiringExtension:)` 与 `signedFileName(in:)`：zip 与 sha256 各自只接受对应扩展名，文件名可以从查询串里取回；允许的重定向主机仍是 `github.com` / `objects.githubusercontent.com` / `release-assets.githubusercontent.com`，https 与「无 userinfo」条件不变 |

边界说明：

- **304 修复的代价与护栏**：允许 304 复验进入安装流程，意味着待安装的版本字符串可能来自本机缓存
  文件（与用户同权限的进程可以改写）。因此保留三道硬条件——本轮网络往返成功、上游结构已核实、
  目标版本严格大于正在运行的版本；缓存的 tag 只用于定位资产，真正的资产 URL、校验值与 bundle 身份
  都在下载前重新从网络取得并核对。缓存的版本字符串决定下载哪个资产名，没有「严格大于」这道比较，
  改写缓存就能让人工流程装回旧版本，所以它不会被去掉。
- **自动安装没有放宽**：`origin == .network` 的要求仍然写在自动安装路径上，本版只调整了人工流程。
- **重定向允许面没有扩大**：主机白名单与后缀要求都是既有集合，只是「文件名」的取法多了一条查询串
  路径。

### 3. 本版的安全审查（delta）

- 完整的 delta 安全评审见[安全评审（alpha.15）](security-review-alpha.15.md)，按 S1–S8 覆盖本版
  delta（`e0afaf1..d1f8ea7`：`Sources/` 9 个文件 `+622/-4`、测试 1 个文件 `+172/-0`、
  `PiWebDesktop.xcodeproj/project.pbxproj`、`Scripts/build.sh`、`docs/` 与本版发布提交）。
- 结论：**阻断项 0 条**；非阻断项在 alpha.14 的 9 条（`R1`–`R9`）基础上新增本版引入的条目，逐条登记
  在报告的「发现」一节，处置建议同样写在报告里。九条继承项的相关代码本版未改，仍然有效。

## 更新检查与自动更新的边界（本版有变化）

alpha.5 之后的版本都写明「更新检查只检查、不安装」。本版对**桌面应用**这一分类改变了这一点，其余
分类不变：

| 项 | 本版行为 |
| --- | --- |
| 检查的域名与频率 | 未变：仍是 `api.github.com` 与 `registry.npmjs.org`，按分类各自的策略与 TTL |
| 桌面 App 分类 | 检查仍然只读元数据；发现新版本时菜单出现入口，**要不要装由用户决定** |
| 安装动作 | 只在用户点击菜单项并在确认框点「更新」后发生；只在 `/Applications` 下可用；只接受带 `.zip.sha256` 的 GitHub 发布资产 |
| Pi Web / Pi CLI / 扩展包 | 未变：三条既有路径与其前置条件、命令、超时行为都以 [alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md) 的「自动更新的准确边界」一节为准 |
| 无人值守 | 桌面 App **没有**启动前自动安装；两条「启动前自动更新」开关仍然只影响 Pi Web 与 Pi CLI，且默认关闭 |
| 回滚 | 桌面 App 更新**没有**自动回滚：替换失败时脚本会把备份移回原位，但「新版本装上后启动失败」不会自动换回旧版本，需要用户手动替换上一版 ZIP |
| 未公证的影响 | 应用内更新不是 Developer ID 的签名更新通道（没有 Sparkle、没有代码签名校验）；见上文第 1 节的信任模型 |

## 本机实测环境与版本（可追溯）

| 项 | 值 |
| --- | --- |
| 硬件 | Apple M4（`sysctl -n machdep.cpu.brand_string`） |
| 架构 | `arm64` |
| macOS | `27.0`（`sw_vers -buildVersion` = `26A428`） |
| Swift | `6.4`（`swift --version`，swift-driver `1.168.6`，Command Line Tools） |
| Node.js | `v24.21.0`（`/opt/homebrew/opt/node@24/bin/node`） |
| npm | `11.19.0` |
| `pi` | `0.87.1`（`@earendil-works/pi-coding-agent`） |
| `@agegr/pi-web` | `0.9.2`（全局 npm 包） |
| 诊断摘要 | 见下节与本版门槛执行记录（`Scripts/smoke.sh` 的诊断模式） |

与 alpha.14 的记录相比，硬件、架构、macOS、Swift、Node.js、npm 逐项相同，`pi` 由 `0.87.0` 变为
`0.87.1`、`@agegr/pi-web` 由 `0.9.1` 变为 `0.9.2`——这是本机环境的变化，不是本版代码引入的依赖。

真机端到端验证（自更新）：

- 用 `MARKETING_VERSION` 临时降为 `0.1.0-alpha.14`（代码是 PR #178 的候选提交）的本地构建装进
  `/Applications`，菜单出现「下载并安装桌面应用更新…」。
- 点击后确认框写明目标版本；确认后下载 `v0.1.0-alpha.14` 的**真实发布资产**、校验 SHA-256、替换
  `/Applications` 里的应用并重启成功。
- 替换后 `/Applications/Pi-Web-Desktop.app` 的 `CFBundleShortVersionString` 为 `0.1.0-alpha.14`，
  可执行文件 SHA-256 与 Release 的 ZIP 内容逐字节一致（`codesign --verify --deep --strict` 退出 0）。
- 更新后的应用能直接启动，不需要再手动放行一次 Gatekeeper（手动下载的 ZIP 仍然需要按「安装」一节
  手动放行）。
- 本版自身资产（`v0.1.0-alpha.15`）发布后会用同一流程再验证一次，结果回填到
  [Release Issue #179](https://github.com/Su-luoya/pi-web-desktop/issues/179) 的「本版真机验证项」表。

## 安装

安装步骤、首次启动会看到什么、依赖怎么装、以及常见问题（Gatekeeper 放行、诊断导出、卸载与清理）都在
[README](../README.md) 里，本节不再重复。与上一版相同：ZIP 解压后把 `Pi-Web-Desktop.app` 放进
`~/Applications` 或 `/Applications`；**自更新只在 `/Applications` 下可用**。应用不打包也不需要
Node.js / Pi CLI / `@agegr/pi-web` 之外的任何运行时。

## 依赖前置与首次启动诊断

依赖（Node.js `>=22.19.0`、Pi CLI、`@agegr/pi-web`）需要用户自己安装，应用只做探测、显示与诊断，
不会自动安装（除非用户显式打开两条「启动前自动更新」开关，且所有前置条件满足）。首次启动的诊断页会
列出每一项的状态与缺失项的安装命令，细节见
[alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md) 的「依赖前置与首次启动诊断」一节与
[README](../README.md)。本版没有改动依赖门控与它的缓存快路径（#169 的行为与边界以
[alpha.14 Release 说明](release-notes-v0.1.0-alpha.14.md) 第 2 节为准）。

## 未公证、ad-hoc 与 Gatekeeper

本产物用 ad-hoc 签名（`codesign --sign -`），没有 Developer ID 证书，也没有经过 Apple 公证。
`spctl -a -vv` 会拒绝它（退出码 3），**这是未公证 ad-hoc 产物的预期结果，不是损坏**。首次打开需要
用户手动放行：

1. 在 Finder 里右键 `Pi-Web-Desktop.app` → 「打开」，在弹窗里再确认一次「打开」。
2. 或在「系统设置 → 隐私与安全性」里对该应用选择「仍要打开」。

请只放行本仓库 Releases 页面下载、并用下文「校验值」核对过 SHA-256 的那一份 ZIP。应用内更新换上的
bundle 由应用自己下载，不带手动下载时的 quarantine 标记，因此更新后不需要再放行一次。

## 校验值

发布资产由 `.github/workflows/release.yml` 在 tag `v0.1.0-alpha.15` 上生成；**本节的大小与 SHA-256
在发布后从 Release 页面回填**，回填前保持占位，不用本机演练值冒充发布值。

| 项 | 值 |
| --- | --- |
| 发布资产 | `Pi-Web-Desktop-0.1.0-alpha.15+build.15.zip` |
| 大小 | 发布后回填 |
| SHA-256 | 发布后回填 |
| 发布提交 | `d1f8ea7` + 本版发布提交；tag `v0.1.0-alpha.15` 指向包含本节内容的发布提交 |

校验方式：从 Release 下载 ZIP 与配套的 `.zip.sha256`，在同一个目录里执行

```sh
shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.15+build.15.zip.sha256
```

预期输出 `<file>: OK`。随后可复核包内版本与签名（解压到临时目录后执行）：

```sh
plutil -p Pi-Web-Desktop.app/Contents/Info.plist | grep -E 'CFBundleShortVersionString|CFBundleVersion'
codesign --verify --deep --strict Pi-Web-Desktop.app
```

预期 `CFBundleShortVersionString=0.1.0-alpha.15`、`CFBundleVersion=15`，`codesign --verify` 退出 0
（ad-hoc 产物仍会被 `spctl` 拒绝，这是预期结果）。本机门槛与演练记录见
[alpha-release-checklist.md](alpha-release-checklist.md) 的「Release v0.1.0-alpha.15 执行记录」。
## 已知问题

### 1. 本版仍然存在的问题

- **未公证、ad-hoc 签名**：Gatekeeper 默认阻止直接双击打开，需要用户针对这一个应用手动放行（见
  「未公证、ad-hoc 与 Gatekeeper」）。本版不引入 Developer ID，也不做公证。
- **自更新只在 `/Applications` 下可用（本版新增）**：应用放在 `~/Applications` 或其它位置时，菜单
  里仍可能出现入口，但点下去会明确拒绝：「当前应用不是从 /Applications 安装，无法自动更新」。
- **自更新要求资产带 `.sha256`（本版新增）**：Release 里没有同名 `.zip.sha256` 时不下载、不安装，
  报「更新包缺少 SHA-256 校验值」。这是设计如此：没有校验值就不安装。
- **没有自动回滚（本版新增）**：替换失败会把备份移回原位，但新版本装上后如果启动失败，应用不会自动
  换回旧版本；回退要按「回退」一节手动替换上一版 ZIP。
- **自更新的信任边界有限（本版新增）**：校验值也从同一个 Release 下载，且不校验代码签名，因此它
  防的是传输 / 归档损坏与资产被替换，不防上游仓库被攻破；确认框里已写明未公证与来源要求。
- **`~/Library/Application Support/Pi Web Desktop/` 里的更新检查缓存多了一个 tag 字段（本版新增）**：
  与用户同权限的进程可以改写它，但改写的后果被限制在「哪一次点击会用哪个版本字符串作为待确认线索」，
  下载前的三道硬条件与网络复核不受影响（见第 1 节的边界说明与安全评审）。
- **非 loopback 监听需要先设置远程访问密码**：见 [alpha.14 Release 说明](release-notes-v0.1.0-alpha.14.md)
  的「已知问题」。本版未改动。
- **非 loopback 访问是明文 `http`**：密码认证**不等于传输加密**，只建议在可信网络或隧道内使用。
- **应用窗口的页面请求仍走系统代理（#157）**、**退出等待预算 ≤1 秒（#158）**、**依赖门控缓存是
  本机状态而不是信任边界（#169）**、**多窗口的可见变化（#168）**、**启动耗时数字的适用范围
  （#169）**：都见 [alpha.14 Release 说明](release-notes-v0.1.0-alpha.14.md) 的「已知问题」，
  本版未改动这些代码路径。
- **真机 GUI 未全部手工验收**：本机只有 Command Line Tools、没有 Xcode，本版门槛是脚本（构建 / 身份 /
  冒烟 / 版本一致性）加上 CI 上的 XCTest。自更新流程已经做过一次真机端到端验证（见「本机实测环境与
  版本」），本版资产发布后会用同一流程再验证一次；其余 GUI 行为（窗口、菜单、诊断页）的运行时行为
  仍以各版的真机验证表为准。

### 2. alpha.14 的评审项与本版状态

| 编号 | alpha.14 的记录 | 本版状态 |
| --- | --- | --- |
| `R1` | 非 loopback 监听后应用窗口会加载该地址 | 代码未改，仍然有效 |
| `R2` | 放行面 host 比较不处理尾部点 | 代码未改，仍然有效 |
| `R3` | 切换监听的「成功」语义不是服务已在新地址就绪 | 代码未改，仍然有效 |
| `R4` | 退出等待预算 ≤1 秒 | 代码未改，仍然有效 |
| `R5` | 占位符硬门禁依赖人工执行 | 代码未改，仍然有效 |
| `R6` | 应用窗口的页面请求仍走系统代理 | 代码未改，仍然有效 |
| `R7` | 依赖门控缓存不是信任边界 | 代码未改，仍然有效 |
| `R8` | 依赖门控缓存指纹不含 pi / pi-web 版本 | 代码未改，仍然有效 |
| `R9` | 缓存不一致收敛与启动所有权记录之间的窄竞态（[C]） | 代码未改，仍然有效 |

本版新增的条目见[安全评审（alpha.15）](security-review-alpha.15.md) 的「发现」一节。

### 3. 需要在真机验证的行为

| 项 | 步骤 | 期望 | 状态 |
| --- | --- | --- | --- |
| 自更新入口出现 | 用低于本版的构建装进 `/Applications`，点「服务 → 更新检查设置 → 检查更新…」 | 菜单出现「下载并安装桌面应用更新…」 | 已在 alpha.14 周期验证（见「本机实测环境与版本」）；本版资产发布后复验 |
| 确认与安装 | 点该菜单项 → 确认框写明目标版本 → 点「更新」 | 下载、校验、替换 `/Applications` 应用，应用退出并重启 | 已在 alpha.14 周期验证；本版资产发布后复验 |
| 安装结果可核对 | 更新后核对 `/Applications/Pi-Web-Desktop.app` | 版本为 `0.1.0-alpha.15`，可执行文件 SHA-256 与 Release 资产一致 | 发布后回填 |
| 校验失败即中止 | 把下载到的 `.sha256` 换成不匹配的值后再触发更新 | 报「更新包校验失败，已停止安装」，`/Applications` 应用不变 | 发布后回填 |
| 非 `/Applications` 拒绝 | 把同一个构建放到 `/tmp` 运行后点该菜单项 | 报「当前应用不是从 /Applications 安装，无法自动更新。」 | 发布后回填 |

## 回退

1. 保留上一版 ZIP 与它的 checksum；回退时解压上一版并替换当前的 `Pi-Web-Desktop.app`。
2. 应用没有系统级常驻组件，删除应用包即可卸载；服务配置保留在用户目录（UserDefaults、Application
   Support 与 Logs），回退时不会自动清理。
3. 桌面 App 自更新**没有自动回滚**：替换失败时脚本会把备份移回原位，但新版本启动失败不会自动换回旧
   版本；按上面第 1 步手动换回，并在 [Release Issue #179](https://github.com/Su-luoya/pi-web-desktop/issues/179)
   中记录问题。
4. Node.js、Pi、Pi Web 的版本回退由用户自行管理；本项目不承诺能恢复第三方包的旧版本。

## 支持边界

- 只支持 Apple Silicon（arm64）与 macOS 14 或更高版本。
- 没有 SLA：这是 alpha 预览，按「现状」提供，不承诺修复时间。
- 桌面 App 的自更新需要用户确认，且只在 `/Applications` 下可用；其余组件没有无人值守安装。
- 没有 Developer ID 签名、没有 Apple 公证，也没有 Apple 支持渠道。
- 不要在公开 issue 或 Release 评论里粘贴密码、token、私有主机名、代理凭据或未脱敏日志。

## 反馈与安全报告

- 功能问题与真机反馈：用 [Release Issue #179](https://github.com/Su-luoya/pi-web-desktop/issues/179)
  或仓库的 issue 模板（本版真机验证项表格可以直接引用）。
- 安全相关：按 [SECURITY.md](https://github.com/Su-luoya/pi-web-desktop/blob/main/SECURITY.md) 的
  渠道私下报告，不要写进公开 issue；自更新的校验值 / 地址 / 重定向相关的疑虑也走这个渠道。
