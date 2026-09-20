# Pi Web Desktop 0.1.0-alpha.9（build 9）— Apple Silicon alpha（未公证）

## 摘要 / Summary

Pi Web Desktop `0.1.0-alpha.9` 是面向 **Apple Silicon（arm64）、macOS 14 或更高版本** 的第九个
alpha 预览。它启动、监控并显示本机已安装的 Pi Web 服务，默认只监听 loopback。相对
`0.1.0-alpha.8`，本版本只有 **1 个代码提交**（PR #130：一个修复，关闭 1 个 issue）与 **1 个纯文档
提交**（PR #129：回填 alpha.8 的发布值），除此之外只有发布提交本身（版本 bump 与本文档），
没有新增功能面：

1. **验证失败的日志与警告共用同一套三态措辞**（#127 `L-1` / PR #130）：四处「验证失败」日志行
   （Pi CLI、Pi Web、扩展包的两条路径）不再在重新检测拿不到版本时同时写「重新检测到的版本是
   未知」和「旧版本保持不变」。措辞现在由
   `UpdateWarningText.oldVersionClaimText(detectedVersion:)` 一处给出：有版本证据 → 「仍在使用
   更新前的版本 X」；没有证据 → 「重新检测没有给出可用的版本结果，无法判断更新前的文件是否仍在
   原位」。
2. **已打开句柄的类型复核**（#127 `L-3` / PR #130）：`UpdateVerifier.openRegularFile(atPath:)`
   在打开之后对**句柄本身**再跑一次 `fstat`，只有 `S_IFREG` 才交给调用方。路径解析与打开之间的
   窗口不再影响判定结果；可读文件的范围不变（到常规文件的符号链接仍可读，FIFO / 目录 / 字符设备
   仍被拒绝）。
3. **排水宽限到期也冲刷解码器**（#127 `L-4` / PR #130）：扩展包执行器在结束流程里冲刷 stdout /
   stderr 的增量解码暂存字节，与 Pi CLI、Pi Web 的收尾路径一致。此前只有读到 EOF 的路径冲刷，
   宽限到期结束时尾部可能少一个不完整字符。
4. **放弃等待不再断言旧版本仍在原位**（#127 `L-5` / PR #130）：应用退出时「已放弃等待」的日志
   改成「命令可能仍在后台自己完成；没有确认更新前的版本 X 是否仍在原位，下次启动重新检测」。

ZIP 里的应用仍然是 **ad-hoc 签名、未公证** 的：没有 Developer ID 证书，也没有 Apple 公证，
因此 Gatekeeper 默认会阻止直接双击打开，需要用户针对这一个应用手动放行。本版本没有 Intel 支持、
没有 SLA，**不承诺所有安装来源都能回滚**，远程访问的密码认证也**不等于传输加密**。更新验证仍然
**不做代码签名确认、不确认官方来源、不做安装包内容比对**。

Pi Web Desktop `0.1.0-alpha.9` is the ninth alpha preview for **Apple Silicon (arm64) Macs running
macOS 14 or later**. It starts, monitors and displays a locally installed Pi Web service and listens
on loopback by default. Compared with `0.1.0-alpha.8` this release contains **a single code change
commit** (PR #130, one fix that closes one issue) plus a documentation-only commit (PR #129, which
backfills the published values of alpha.8), and no new features: the four "verification failed" log
lines (Pi CLI, Pi Web and both Pi package paths) no longer claim that the previous version is still
in place while the same sentence reports an unknown re-detected version — the wording now comes from
one place, `UpdateWarningText.oldVersionClaimText(detectedVersion:)`, which distinguishes "still
using the previous version X" (version evidence available) from "cannot tell whether the previous
files are still in place" (no evidence); the verifier re-checks the file type of the **opened**
handle with `fstat` and only accepts `S_IFREG`, so the window between resolving the path and opening
it no longer influences the decision (the set of readable files is unchanged); the Pi package
executor flushes its incremental UTF-8 decoders when the pipe-drain grace expires, matching the Pi
CLI and Pi Web finish paths; and the "abandoned wait" log written at app exit no longer asserts that
the old version is still in place.

The app inside the ZIP is still **ad-hoc signed and not notarised**: without a Developer ID
certificate and Apple notarisation, Gatekeeper blocks a plain double-click by default, so the user
has to allow this one app manually. There is no Intel support and no SLA, **not every install source
can be rolled back**, and password authentication for remote access is **not transport encryption**.
Update verification still **does not confirm code signatures, does not confirm the official source,
and does not compare installer contents**.

## 发布信息

| 项目 | 值 |
| --- | --- |
| 版本（tag） | `v0.1.0-alpha.9` |
| `CFBundleShortVersionString` | `0.1.0-alpha.9` |
| `CFBundleVersion` | `9` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 应用包 | `Pi-Web-Desktop.app` |
| 架构 | arm64（Apple Silicon）；**不支持 Intel（x86_64）** |
| 最低系统 | macOS 14.0 |
| 签名 | ad-hoc（`codesign --sign -`），没有证书，`TeamIdentifier=not set` |
| 公证 | 无。Gatekeeper 默认拒绝，需要用户手动放行这一个应用 |
| 发布类型 | GitHub **prerelease**（alpha 预览） |
| 上一版 | `v0.1.0-alpha.8`（build `8`），资产仍在 Releases 中可下载 |
| 本地数据位置 | UserDefaults、`~/Library/Application Support/Pi Web Desktop/`、`~/Library/Logs/Pi Web Desktop/`、Keychain、WebKit 网站数据，见[隐私说明](privacy.md) |

版本与 build 的唯一来源是 `Configuration/AppIdentity.xcconfig`；本文件只是引用，不是来源。
## 目标平台

| 维度 | 支持范围 |
| --- | --- |
| CPU | Apple Silicon（arm64） |
| 系统 | macOS 14.0 或更高 |
| Intel Mac | 不支持，也没有 x86_64 产物 |
| 依赖 | Node.js `>=22.19.0`、Pi CLI、`@agegr/pi-web`（需用户自行安装，应用不打包也不自动安装） |
| 默认服务地址 | `http://127.0.0.1:30141/`（只监听 loopback） |

## `0.1.0-alpha.9` 相对 `0.1.0-alpha.8` 的新增与变更

本版本不新增功能面：它清掉 alpha.8 delta 安全评审留下的四条非阻断发现（[#127](https://github.com/Su-luoya/pi-web-desktop/issues/127) / PR #130），并在对应位置补了回归用例。

### 1. 验证失败时的措辞与证据一致（`L-1`）

- 新增 `UpdateWarningText.oldVersionClaimText(detectedVersion:)`（`Sources/UpdateTransaction.swift`）：重新检测拿到版本 → 「仍在使用更新前的版本 X；」；拿不到 → 「重新检测没有给出可用的版本结果，无法判断更新前的文件是否仍在原位；」。
- 四处日志行改用同一套措辞：`Sources/PiCLIUpdateAdapter.swift:1350`、`Sources/PiWebUpdateAdapter.swift:1726`、`Sources/PiPackageUpdateAdapter.swift:1598`（`.versionUnchanged` 分支）与 `:1860`（`logOutcome` 路径）。此前这些行会在同一条消息里既写「重新检测到的版本是 未知」又断言「旧版本保持不变」。
- 持久警告（`Sources/UpdateTransaction.swift` 的 `verificationFailed`）本来就有三态，这次只把措辞来源统一到一处。
- **不改变任何判定结果**：`status`、验证状态、是否走降级路径、菜单与页面上的其它文案都没有变化。

### 2. 判定基于已打开的句柄（`L-3`）

- `Sources/UpdateVerifier.swift` 的 `openRegularFile(atPath:)` 现在有两道闸门：解析符号链接后先看 `fileType`，打开之后再对**句柄本身**跑一次 `fstat`，只有 `(st_mode & S_IFMT) == S_IFREG` 才交给调用方，否则关闭句柄并返回 `nil`。
- 路径解析/类型判断与打开之间的窗口不再影响判定结果。**可读文件的范围没有变化**：指向常规文件的符号链接仍可读，FIFO、目录、字符设备仍被判为不可读。
- 这是把判定依据从路径搬到句柄，不是新增限制；同一改动同时覆盖 `readBoundedData` 与 `readContentHash` 两条路径。

### 3. 排水宽限到期也冲刷解码器（`L-4`）

- `Sources/PiPackageUpdateAdapter.swift` 的 `completeLocked` 在结束流程里冲刷 `stdoutDecoder` / `stderrDecoder` 的暂存字节，与 Pi CLI 的 `completeLocked`、Pi Web 的 `finishLocked` 一致。
- 此前只有读到 EOF 的路径会冲刷，宽限到期结束时尾部的一个不完整字符会被静默丢弃；现在这条路径产出一个替换字符（`U+FFFD`），不再无声丢字节。
- 新增用例 `testRealExecutorDrainGraceExpiryFlushesPendingDecoderBytes` 走的就是「宽限到期」这条路（后台子进程继续持有 stdout 写端，读不到 EOF）。

### 4. 放弃等待不再断言旧版本仍在原位（`L-5`）

- `Sources/PiWebApp.swift:1684` 在应用退出、上一次更新「已放弃等待」时的日志改成：「命令可能仍在后台自己完成；没有确认更新前的版本 X 是否仍在原位，下次启动重新检测。」
- 放弃等待时命令可能已经改完文件、也可能还在跑，日志不再单方面断言文件仍在原位。

### 5. 本版的安全审查（delta）

- 完整的 delta 安全评审见 [安全评审（alpha.9）](security-review-alpha.9.md)。
- 结论：**阻断项 0 条，非阻断性发现 0 条**。评审范围是 `git diff 5f8f38b..8b7e74d`（alpha.8 发布提交 → 本版候选）的实际改动，逐处对照了修复代码、测试与门槛输出。
- alpha.8 的四条非阻断发现（`L-1` / `L-3` / `L-4` / `L-5`）在本版全部关闭：`L-1` 与 `L-4` 有新增的针对性用例，`L-5` 由退出日志的直接复核覆盖，`L-3` 是窗口收窄而不是新接口，因此没有确定性用例（既有的「符号链接可读 / FIFO 不可读」用例继续覆盖判定结果）。
## 更新检查与自动更新的边界（本版无变化）

本版**没有改动**更新检查的域名、频率、开关与自动更新的前置条件，也没有新增任何安装路径：
`Sources/UpdateChecker.swift` 的两个主机常量（`api.github.com`、`registry.npmjs.org`）未变，两条
自动更新开关仍然默认关闭。完整边界（会做/不会做、域名与关闭方式、三种更新路径的命令与超时行为）
以 [alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md) 的
“更新检查访问的域名、频率与关闭方式”“自动更新的准确边界”两节为准；本版只改了**失败时的文案**与
**门闩的提示**，两者的用户可见效果见上一节。

## 本机实测环境与版本（可追溯）

| 项 | 值 |
| --- | --- |
| 硬件 | Apple M4（`sysctl -n machdep.cpu.brand_string`） |
| 架构 | `arm64` |
| macOS | `27.0`（`sw_vers -buildVersion` = `26A428`） |
| Node.js | `v24.21.0`（`/opt/homebrew/opt/node@24/bin/node`；构建、冒烟与打包脚本都在这条 PATH 上运行） |
| npm | `11.19.0` |
| `pi` | `0.86.0`（`/opt/homebrew/bin/pi` → `@earendil-works/pi-coding-agent`） |
| `@agegr/pi-web` | `0.9.1`（全局 npm 包） |
| 诊断摘要 | `items=6 / blockers=3`（`Scripts/smoke.sh --diagnostics`） |

门槛脚本与冒烟脚本都在这一套版本上运行过；与 alpha.8 记录的环境相同，因此本版的门槛结果可以直接和上一版对照。
## 安装

安装步骤、首次启动会看到什么、依赖怎么装、以及常见问题（Gatekeeper 放行、诊断导出、卸载与清理）
都在 [README](../README.md) 里，本节不再重复。与上一版相同：ZIP 解压后把 `Pi-Web-Desktop.app`
放进 `~/Applications` 或 `/Applications`；应用不打包也不需要 Node.js / Pi CLI / `@agegr/pi-web`
之外的任何运行时。

## 依赖前置与首次启动诊断

依赖（Node.js `>=22.19.0`、Pi CLI、`@agegr/pi-web`）需要用户自己安装，应用只做探测、显示与
诊断，不会自动安装（除非用户显式打开两条“启动前自动更新”开关，且所有前置条件满足）。
首次启动的诊断页会列出每一项的状态与缺失项的安装命令，细节见
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

本节在 tag 与 Release 草稿建立后，由协调者从 workflow 产物回填**实际值**（与 `v0.1.0-alpha.8` 的做法一致）。

| 项 | 值 |
| --- | --- |
| 发布资产 | `Pi-Web-Desktop-0.1.0-alpha.9+build.9.zip` |
| 大小 | 〈待回填〉 |
| SHA-256 | 〈待回填〉 |
| 发布提交 | 〈待回填〉（tag `v0.1.0-alpha.9` 指向该提交） |

**本机演练值（不是发布资产）** —— 在候选工作区 `~/orca/workspaces/Pi-Web/release-alpha-9`（`HEAD = 8b7e74d`，工作区含本版版本 bump 与本文档）用 `Scripts/package-release.sh --tag v0.1.0-alpha.9` 打包，用来验证打包链路与记录产物形态：

| 项 | 值 |
| --- | --- |
| 演练资产 | `Pi-Web-Desktop-0.1.0-alpha.9+build.9.zip` |
| 大小 | `1521314` 字节 |
| SHA-256 | `08728d60c9603fa0ac5f01a1752191e158b6d3a130a1f5a9c172dd3d2fd5d8ed` |
| 演练提交 | `8b7e74dda24eb41e9a2a20a4d56b63683441b686`（`dist/release-metadata.env` 的 `COMMIT`；工作区 dirty，所以这只是演练值） |
| 校验 | `shasum -a 256 -c` 通过 |

发布用的 ZIP 由 `release.yml` 在 tag 上重新打包（同一条 `Scripts/package-release.sh`），大小与校验值以 Release 上的 `.zip.sha256` 与本节的回填值为准。

## 构建与签名验证记录（本机演练）

演练对象：上一节的演练 ZIP（本机构建）。命令与结果：

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 构建 | `Scripts/build.sh` | `Built … (arm64)`；`file` 报 Mach-O 64-bit executable arm64 |
| 版本一致性 | `Scripts/check-release-version.sh v0.1.0-alpha.9` | `PASSED`（`MARKETING_VERSION = 0.1.0-alpha.9`、`CURRENT_PROJECT_VERSION = 9`；唯一来源 `Configuration/AppIdentity.xcconfig`） |
| 身份与文本扫描 | `Scripts/check-identity.sh` | `PASSED (45 checks)`，含 `no hardcoded MARKETING_VERSION` |
| 密钥扫描 | `Scripts/scan-secrets.sh` | `--self-test` PASS；工作区扫描 PASS（15 行已抑制基线） |
| 冒烟 | `Scripts/smoke.sh`（默认与 `--diagnostics`） | 两个模式 exit 0；标记 `smoke: ready` 与 `smoke: diagnostics ready`；诊断报告 `items=6` / `blockers=3` |
| 签名校验 | `codesign --verify --deep --strict <app>` | exit 0 |
| 签名详情 | `codesign -dv <app>` | `Identifier=io.github.su-luoya.pi-web-desktop`；`Format=app bundle with Mach-O thin (arm64)`；`flags=0x2(adhoc)`；`TeamIdentifier=not set`；`Sealed Resources version=2 rules=13 files=1` |
| Gatekeeper | `spctl -a -vv <app>` | `rejected`（预期：ad-hoc 且未公证） |
| 包内容 | `unzip -l`、`ditto -x -k` + `plutil -p` | 9 个条目、无 `__MACOSX`；包内 `CFBundleShortVersionString=0.1.0-alpha.9`、`CFBundleVersion=9`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=AppIcon` |
| 打包 | `Scripts/package-release.sh --tag v0.1.0-alpha.9` | `OK`；白名单 8 个条目、mtime 固定为 `200101010000`、evidence 记录 `macOS 27.0` / arm64 |

XCTest 用例（本机 shim，串行单文件运行）：`UpdateVerifierTests` 9 / 0、`PiPackageUpdateAdapterTests` 57 / 0、`UpdateTransactionTests` 36 / 0、`PiWebUpdateAdapterTests` 44 / 0、`PiCLIUpdateAdapterTests` 44 / 0（合计 190 passed / 0 failed）。完整的 `xcodebuild test` 由 PR #130 上的 CI 承担。

**没有做**：真机 GUI 手工验收（本机只有 Command Line Tools、没有 Xcode）；更新检查与自动更新的端到端真机演练。
## 已知问题

### 1. 本版仍然存在的问题

- **未公证、ad-hoc 签名**：Gatekeeper 默认阻止直接双击打开，需要用户针对这一个应用手动放行（见「未公证、ad-hoc 与 Gatekeeper」）。本版不引入 Developer ID，也不做公证。
- **更新验证的边界**：不确认代码签名、不确认官方来源、不做安装包内容比对（见「更新检查与自动更新的边界」）。验证只看版本证据与文件身份。
- **回滚能力不均**：只有带版本证据的安装来源才走降级路径；npm 全局更新与 Pi 扩展包更新没有自动回滚，失败时只保证不声称成功、不改状态。
- **远程访问默认不加密**：Pi Web 的密码认证不等于传输加密，远程访问应只经隧道或 VPN（见「支持边界」）。
- **真机 GUI 未手工验收**：本机只有 Command Line Tools、没有 Xcode，本版的门槛是脚本（构建 / 身份 / 冒烟 / 打包 / 签名）加上 shim 上的单文件 XCTest；完整的 `xcodebuild test` 由 CI 承担。
- **一处既往文案观察（`O-1`）**：`Sources/PiCLIUpdateAdapter.swift:1528` 与 `Sources/PiWebUpdateAdapter.swift:1883` 的持久警告以「旧版本语义保持不变：应用不会自动回滚已替换的文件，也不声称更新成功」开头。这里说的是**语义**（冒号后即定义），不是文件位置断言；这两行早于本版 delta，本次没有改动（见 [安全评审（alpha.9）](security-review-alpha.9.md) 的观察项）。

### 2. alpha.8「已知问题」在本版的状态

alpha.8 delta 安全评审的四条非阻断发现（[#127](https://github.com/Su-luoya/pi-web-desktop/issues/127)）在本版全部处理：

| 编号 | alpha.8 的发现 | 本版状态 |
| --- | --- | --- |
| `L-1` | 重新检测拿不到版本时，日志行仍写「旧版本保持不变」 | 已修：四处日志行改用 `UpdateWarningText.oldVersionClaimText` 的三态措辞，并有新增用例 |
| `L-3` | `openRegularFile` 在解析路径与打开之间可能读到别的文件 | 已修：判定改为基于已打开的句柄（`fstat` 复核 `S_IFREG`），可读范围不变 |
| `L-4` | 扩展包执行器在排水宽限到期时不冲刷解码器，尾部字符可能丢失 | 已修：`completeLocked` 冲刷两个解码器，并有新增用例覆盖该路径 |
| `L-5` | 应用退出时「已放弃等待」的日志断言旧版本仍在原位 | 已修：改为「没有确认更新前的版本 X 是否仍在原位」 |

alpha.8 说明中列出的其余边界（路径即信任边界、不校验签名、不做内容比对、未公证）在设计上没有变化，仍按「支持边界」与「更新检查与自动更新的边界」执行。

### 3. 需要在真机验证的行为

- 更新失败 / 版本不变时的新措辞在四种安装来源（`brew`、`npm`、`pi` 自更新、Pi 扩展包）下是否都符合实际状态；
- 应用退出时「已放弃等待」的新日志是否与真实文件状态一致（命令可能仍在后台完成）；
- 扩展包更新在宽限到期结束时，日志尾部字符是否完整（本版改动点，本机只有用例覆盖，没有真机演练）。
## 回退

1. 保留上一版的 ZIP 与它的 `.sha256`。回退时解压上一版（`v0.1.0-alpha.8`，资产仍在 Releases 中）
   并替换当前的 `Pi-Web-Desktop.app`，然后用 `codesign --verify --deep --strict` 复核（未公证的
   ad-hoc 产物仍会被 `spctl` 拒绝，这是预期结果）。
2. 删除应用包即可完成卸载：应用没有系统级常驻组件或 LaunchAgent，删除应用包不会残留其他系统文件
   （退出应用后 `rm -rf "$HOME/Applications/Pi-Web-Desktop.app"`，装在 `/Applications` 时替换路径）。
3. 清理用户目录数据、删除「已放弃」记录、以及组件版本回退的具体命令与边界，见
   [alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md) 的“回退”一节与
   [隐私说明](privacy.md#本地数据一览与删除)；本版**没有改变**任何本地数据的位置或格式。
4. 已经发布的版本不会静默替换 ZIP 或 checksum；新版本有问题时发布新的 alpha 并在 Release 说明中
   给出回退路径。

## 支持边界

- 只支持 Apple Silicon（arm64）与 macOS 14 或更高版本；没有 Intel 产物。
- 没有 SLA，桌面应用没有自动更新安装，没有 Developer ID 签名、Apple 公证或 Apple 支持渠道。
- 默认只监听 loopback；远程访问必须自备加密传输，并且**密码认证不等于传输加密**。
- 更新路径的硬边界（本版未变）：两条自动更新默认关闭且只对来源可信的 npm/pnpm 全局安装生效，
  目标版本必须来自本次网络检查；扩展包更新必须由用户确认；验证不做代码签名确认；不承诺所有来源
  都能回滚；一次只允许一轮更新事务，放弃等待后“未确认退出”的窗口只能靠重启应用可靠恢复。
- 更新检查只访问 `api.github.com` 与 `registry.npmjs.org`，只读、可逐类关闭；除此之外应用不主动
  向任何上游发送数据（自动更新触发的网络请求由用户自己的 `npm` / `pi` 按其配置发出）。
- 依赖探测会读一次登录 shell 的 `PATH`（本机、只读、有超时），并使用合并后的 `PATH` 启动
  依赖探测、更新命令与服务进程。
- 不要在公开 Issue、PR 或 Release 评论里粘贴密码、token、私有主机名、代理凭据或未脱敏日志。

## 反馈与安全报告

- 普通问题与功能建议：使用本仓库的
  [Issue 表单](https://github.com/Su-luoya/pi-web-desktop/issues/new/choose)；请附版本、安装与依赖
  信息（脱敏后的诊断导出），以及可复现步骤。上游 Pi Web、Pi CLI 或 Pi packages 的问题请先到对应
  上游仓库确认。
- 安全漏洞：**不要**开公开 Issue、不要粘贴到 PR 或 Release 评论。请使用
  [私密漏洞报告](https://github.com/Su-luoya/pi-web-desktop/security/advisories/new)，
  范围、处理流程与“不承诺 SLA”的说明见 [SECURITY.md](../SECURITY.md)。
