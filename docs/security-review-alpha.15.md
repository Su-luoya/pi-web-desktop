# Pi Web Desktop `0.1.0-alpha.15` 安全评审（delta）

评审对象：`main` 上的 `d1f8ea7`（`v0.1.0-alpha.14` 之后 `#175` / `#176` / `#177` 三个 PR 合并后的
main；main CI run [35822177506](https://github.com/Su-luoya/pi-web-desktop/actions/runs/35822177506) 为
`success`——本报告的结论不依赖该 run），加上本版发布提交（版本 bump、发布说明、本报告、门槛执行记录）。
基线：`main` = `e0afaf1`（`v0.1.0-alpha.14` 的发布提交）。
本报告是**只读评审**：没有修改任何代码、工程文件或脚本，只读取源码、脚本、工程文件与文档。

## 0. 方法与证据基线

### 0.1 评审范围与命令

| 命令 | 用途 |
| --- | --- |
| `git diff --stat e0afaf1..d1f8ea7` | 本版 delta 的文件清单（20 个文件，`+1729` / `-23`） |
| `git diff --numstat e0afaf1..d1f8ea7 -- Sources PiWebDesktopTests` | 源码与测试面的逐文件增删行（下表） |
| `git grep -c -F <pattern> <rev> -- Sources` | 安全相关模式的基线 / 本版计数对比（`kill(`、`sendGroupSignal`、`keychain.save(`、`URLSession`、`getifaddrs`、`try!`、`as!`、`fatalError`、`UserDefaults`、`LogRedactor`） |
| `git grep -n -E 'Process\(\)\|\.arguments =\|\.executableURL =\|\.launch\(\|\.waitUntilExit' d1f8ea7 -- Sources/Updates/DesktopAppUpdate.swift Sources/App/AppDelegate+UpdateChecks.swift` | 新增子进程调用点清点（S1） |
| `git grep -n -E 'LogRedactor\|NSLog\|print\(' d1f8ea7 -- Sources/Updates Sources/App/AppDelegate+UpdateChecks.swift` | 新增日志面（S3；无命中） |
| `git diff e0afaf1..d1f8ea7 -- Sources PiWebDesktopTests \| grep -E '^[+-]import'` | 依赖 / 框架面变化（S7） |
| 逐行阅读 `Sources/Updates/DesktopAppUpdate.swift`、`Sources/App/AppDelegate+UpdateChecks.swift` | 资产选择与地址锁定、下载与校验、解压与身份自检、替换脚本、菜单准入判定 |
| `./Scripts/build.sh`、`check-identity.sh`、`scan-secrets.sh --self-test`、`scan-secrets.sh`、`check-release-version.sh`、`smoke.sh` | 本版门槛实测（结果见 §5、§8、§12 与 [alpha-release-checklist.md](alpha-release-checklist.md) 的执行记录） |

本版 delta 的代码面（`Sources/`）9 个文件、`+622` / `-4`：

| 文件 | +/− | 本版内容 |
| --- | --- | --- |
| `Sources/Updates/DesktopAppUpdate.swift` | `+406/-0` | 本版主体：资产选择与地址锁定（`DesktopAppReleaseAssetSelector`）、下载 / 校验 / 解压 / 身份自检与替换（`DesktopAppUpdateInstaller`）、失败枚举与文案 |
| `Sources/App/AppDelegate+UpdateChecks.swift` | `+164/-0` | 菜单项「下载并安装桌面应用更新…」的建立、显隐与可用性、确认框、安装流程接线与结果提示 |
| `Sources/Updates/UpdateCheckParsing.swift` | `+18/-2` | GitHub Release 解析附带 `upstreamTag` |
| `Sources/Updates/UpdateChecker.swift` | `+16/-0` | 结论携带 tag；复用既有请求超时常量 |
| `Sources/Updates/UpdateCheckCache.swift` | `+10/-0` | 缓存新增 `upstreamTag`（读写时校验长度与控制字符） |
| `Sources/Updates/UpdateCheckResult.swift` | `+2/-0` | `upstreamTag` 字段 |
| `Sources/App/AppDelegate.swift` | `+5/-0` | 安装器持有与菜单项声明（`desktopAppUpdateMenuItem`） |
| `Sources/Updates/UpdateSettingsModel.swift` | `+1/-0` | 分类模型的一处映射 |
| `Sources/Updates/PiCLIUpdateModel.swift` | `-2/-0` | 常量复用（行为无变化） |

测试面：`PiWebDesktopTests/DesktopAppUpdateTests.swift`（`+172`，新增，5 个用例）覆盖资产选择与地址
锁定、校验值形态、`/Applications` 位置判定、304 复验的准入判定、签名直链的重定向判定。测试只断言，
不改变运行时行为。本机只有 Command Line Tools，测试由 CI 的 `xcodebuild test` 运行。

非代码面：`Configuration/AppIdentity.xcconfig`（alpha.14 的版本 bump，本版再 bump）、
`PiWebDesktop.xcodeproj/project.pbxproj`（登记新源文件 / 测试文件 / 测试目标源）、
`Scripts/build.sh`（签名后的属性清理与 iCloud 属性重贴的复验兜底）、`docs/`（alpha.14 与本版的
Release 说明、评审、门槛记录与相关说明）。`.github/workflows/release.yml` **不在本版 delta 内**。

### 0.2 证据强度分级

- **[A]** 命令输出可复现（计数、脚本退出码、脚本断言、真机文件属性与键结构）。
- **[B]** 源码逐行阅读 + 机械计数支持的结论。
- **[C]** 只能推断、本次没有运行证据的结论（一律不当作已核实，见 §11）。

## 1. S1 服务所有权与外部服务只读

| 模式 | `e0afaf1` | `d1f8ea7` | 结论 |
| --- | --- | --- | --- |
| `kill(` | 7 | 7 | 未变 |
| `sendGroupSignal` | 4 | 4 | 未变 |
| `Process()` | 5 | 7 | **+2**（仅本版新增，见下） |
| `.arguments =` | 6 | 8 | **+2**（与上面两处一一对应） |

- 服务所有权与信号面**没有变化**：本版没有触碰 `Sources/Services/ServiceManager.swift`、
  `ServiceOwnership.swift`、`ProcessInspector.swift`，`kill(` / `sendGroupSignal` 的调用点数量与
  基线一致（各 7 / 4），也没有新增任何按命令行子串匹配的停止路径。[A]
- 新增的两处子进程（`Sources/Updates/DesktopAppUpdate.swift:328`、`:341`）**不是服务控制路径**：
  - `:328` 启动 `/bin/sh`，参数数组只有替换脚本自身的路径（`process.arguments = [script.path]`），
    不使用 `-c`、不拼接命令字符串；
  - `:341` 启动 `/usr/bin/ditto`，参数数组为 `["-x", "-k", archive.path, directory.path]`，并在
    `:343` 用 `waitUntilExit()` + `terminationStatus == 0` 判定成功。
  - 两处的可执行路径都是绝对路径常量，参数用数组传值（不经过 shell 解析），被替换与被解压的路径都
    先经 `shellQuote()`（单引号包裹，`'` 转义为 `'\''`）再写进脚本。[B]
- 替换脚本（`:307-325`）对旧进程只做**存在性探测**：`while kill -0 "$pid"`，不发送任何信号；超时
  60 秒即清理 staging 与脚本并以 1 退出，不替换。[B]
- 返回值与并发状态由 `NSLock` 保护的 `installInProgress` / `replacementProcessDidStart` 守卫，同一
  时刻只有一个安装流程，脚本只会被启动一次。[B]

## 2. S2 凭据边界

| 模式 | `e0afaf1` | `d1f8ea7` | 结论 |
| --- | --- | --- | --- |
| `keychain.save(` | 1 | 1 | 未变（无新增凭据写入点） |

- 本版没有新增 Keychain 接触点，自更新流程不读写 Keychain，也不需要用户密码或 token。[A]
- 网络请求使用 `UpdateChecker` 既有的 URL 构造与固定 `User-Agent`；请求里不含主机名、用户名、
  工作区路径或任何本机信息。[B]
- 下载会话的配置显式关闭了凭据与缓存：`URLSessionConfiguration.ephemeral`、
  `httpCookieAcceptPolicy = .never`、`httpShouldSetCookies = false`、`httpCookieStorage = nil`、
  `urlCredentialStorage = nil`、`requestCachePolicy = .reloadIgnoringLocalCacheData`
  （`Sources/Updates/DesktopAppUpdate.swift:226-236`）。[B]
- 唯一新增的持久化字段是更新检查缓存里的 `upstreamTag`（GitHub Release 的原始 tag 字符串），写入
  与读取都校验长度与控制字符；它不是凭据，也用在不了凭据面上。[B]

## 3. S3 日志与诊断脱敏

| 模式 | `e0afaf1` | `d1f8ea7` | 结论 |
| --- | --- | --- | --- |
| `LogRedactor` | 80 | 80 | 未变 |
| 新增代码中的日志调用（`LogRedactor` / `NSLog` / `print(`） | — | 0 处 | **本版新增代码不写日志** |

- `Sources/Updates/DesktopAppUpdate.swift` 与 `Sources/App/AppDelegate+UpdateChecks.swift` 里没有
  任何日志调用（命令无命中）；诊断窗口只调用既有的 `refreshUpdateStatus()`
  （`Sources/App/AppDelegate+UpdateChecks.swift:262`、`:498`），不新增记录内容。[A]
- 用户可见的失败文案集中在 `DesktopAppUpdateFailure` 的固定字符串表
  （`Sources/Updates/DesktopAppUpdate.swift:47-58`），不含 URL、路径、tag 或主机内容；唯一带插值的
  是成功文案 `桌面应用已更新到 \(version)`，其中的版本来自 Release 元数据。[B]
- 结论：本版不扩大日志 / 诊断 / 错误消息的信息面，也不绕过既有 `LogRedactor`。[B]

## 4. S4 网络边界

| 模式 | `e0afaf1` | `d1f8ea7` | 结论 |
| --- | --- | --- | --- |
| `URLSession` | 14 | 28 | **+14**（下载 / 校验两个会话与两个重定向 delegate） |
| `getifaddrs` | 2 | 2 | 未变 |

- **放行面实现未改**：`Sources/App/WebViewNavigationPolicy.swift` 不在本版 delta 内，loopback 默认、
  非 loopback 强制密码、`0.0.0.0` / `::` 不可保存的结论与 alpha.14 一致（见
  [security-review-alpha.14.md](security-review-alpha.14.md) §4）。[B]
- 新增的网络面只有 GitHub 下载路径，且被钉死：
  - 元数据请求与资产请求都只访问 `api.github.com` 与 `github.com`；
  - 资产的 `browser_download_url` 必须**精确等于**
    `https://github.com/Su-luoya/pi-web-desktop/releases/download/<tag>/<assetName>`，不允许 query、
    fragment 与 userinfo（`allowsDownloadURL`）；
  - 下载完成后再校验**最终 URL**（`allowsAssetRedirect`：`github.com`、
    `objects.githubusercontent.com`、`release-assets.githubusercontent.com` 三个主机，https 且无
    userinfo）；重定向到其它主机一律判失败，不落盘、不校验、不替换。[B]
- **304 复验准入的放宽是「结论来源」而不是「网络面」**：菜单入口现在接受
  `freshness == .fresh`（本轮网络往返成功）且 `confidence == .verified` 的结论，即使这一轮命中了
  条件请求的 304（`origin == .cachedFallback`）。下载前仍然重新联网按 tag 取资产清单、钉死资产
  URL、用 GitHub 公布的 `.zip.sha256` 核对下载内容、核对 bundle id 与版本。[B]
- 放宽的最坏后果被三重条件限制：准入要求「本轮网络往返成功 + 上游结构已核实 + 目标版本严格大于正在
  运行的版本」，因此本机缓存被改写最多影响「哪一次点击会用哪个版本字符串作为待确认线索」，不会让
  应用执行缓存里的路径，也不会降低校验强度（见 `R14`）。[B]
- 应用**不做 TLS pinning**，依赖系统根证书，这与 alpha.14 的结论一致，本版没有收紧也没有放宽。[B]
- 非 loopback 访问仍是明文 `http`，密码认证不等于传输加密：既有已知问题，本版未改动。[B]

## 5. S5 构建与发布

- `.github/workflows/release.yml` **不在本版 delta 内**：`uses:`、`permissions:`、`name:`、`path:`
  与固定 SHA 都没有变化，CI 权限面没有放宽。[A]
- 版本来源仍然唯一：`Configuration/AppIdentity.xcconfig`（`MARKETING_VERSION` /
  `CURRENT_PROJECT_VERSION`），本版没有新增第二处版本字面量；`check-release-version.sh` 在候选提交
  上通过。[A]
- `Scripts/build.sh`（`+48/-…`）的变化只涉及**签名之后的属性处理**：
  - 签名前也清理扩展属性，与文档一致；
  - `codesign --verify --deep --strict` 失败且诊断正好是 bundle 根上的
    `com.apple.FinderInfo` / `com.apple.fileprovider.fpfs#P` 时（iCloud「桌面与文稿」同步域会在
    签名后重新贴属性），用 `ditto` 复制到临时目录、清属性后**重新做 strict 校验**，通过则告警放行；
  - 这条兜底路径没有跳过 `codesign` 校验，也没有改变签名方式（仍是 `codesign --sign -`）与产物的
    包内容白名单。[B]
- 本版不新增资产类型：发布资产仍是 `Pi-Web-Desktop-<version>+build.<build>.zip`、
  `.zip.sha256`、`.evidence.md`，包内容白名单与 `unzip -Z1` 双向比对由
  `Scripts/package-release.sh` 负责（本版未改）。[B]
- 发布门槛与演练命令在候选提交上重跑，结果记录在
  [alpha-release-checklist.md](alpha-release-checklist.md)。[A]

## 6. S6 签名与 Gatekeeper 表述

- 应用仍是 ad-hoc 签名、未公证；本版没有引入 Developer ID、没有 notarization、没有 Sparkle 之类的
  签名更新框架。文档（[release-notes-v0.1.0-alpha.15.md](release-notes-v0.1.0-alpha.15.md) 与
  [README](../README.md)）只写 ad-hoc / 未公证，与 `codesign` / `spctl` 的实际行为一致。[A]
- 新增的「应用内自更新」**不校验下载 bundle 的代码签名**，这一点在文档的三个位置写明（本版说明的
  第 1 节信任模型、更新边界表、已知问题），不构成「文档暗示存在签名更新通道」的表述错误。[B]
- 应用自己下载并换上的 bundle 不带手动下载时的 quarantine 标记，因此更新后不会再触发一次 Gatekeeper
  放行；文档明确写了这一点，没有把它描述成「已通过 Gatekeeper 校验」。[B]

## 7. S7 依赖与供应链

- **无新增第三方依赖**：`Sources/` 只新增 `+import AppKit`、`+import CryptoKit`、`+import Foundation`
  三个系统框架导入，测试侧 `+import XCTest`；仓库没有 `Package.swift`，也没有新增 npm / Actions
  依赖。[A]
- 校验使用系统 CryptoKit 的 SHA-256，不引入第三方校验实现；解压使用系统 `/usr/bin/ditto`。[B]
- 本版新增一条**运行时供应链面**：应用会从 GitHub Release 取 ZIP 并替换自己。它由「同源发布的
  SHA-256 + bundle 身份与版本自检」保护，**不**由签名链保护（见 `R10`）。这是本版最重要的新增信任
  边界，已登记为非阻断项并在文档与确认框中明示。[B]
- 构建脚本变化不改变供应链（没有新增下载、没有动态获取外部工具）。[B]

## 8. S8 个人数据与 secret

| 项 | 结果 |
| --- | --- |
| `scan-secrets.sh --self-test` | 通过（退出码 0）[A] |
| `scan-secrets.sh`（先 `git add` 再扫，避免 R-11 的假绿） | 通过（退出码 0）[A] |
| `UserDefaults` 口径（`git grep -c -F UserDefaults <rev> -- Sources` 合计） | `e0afaf1` 79 → `d1f8ea7` 79（**无新键**）[A] |
| 新增持久化字段 | 只有更新检查缓存里的 `upstreamTag`（GitHub tag 字符串；读写校验长度与控制字符）[B] |
| 仓库内容 | 无真实主机名、私网地址、凭据、真实用户路径（两条扫描覆盖）[A] |

- 本版不新增任何个人数据的采集或上传：下载请求只带固定 `User-Agent`，不携带设备标识、工作区路径或
  使用统计。[B]

## 9. 发现

### 阻断项

**无。**

### 非阻断项

- **`R10` 自更新的信任边界不含签名链** [B]：校验值 `.zip.sha256` 与 ZIP 来自同一个 Release，且不校验
  下载 bundle 的代码签名与 notarization，因此它防的是传输 / 归档损坏与资产被替换，**不防上游发布
  渠道或仓库被攻破**。处置：确认框明示「当前版本没有 Apple Developer 签名与 notarization」并要求
  用户确认 GitHub 发布来源；文档写明信任模型。后续可考虑把校验值发布到第二个渠道（如 release 说明与
  cosign 签名）以缩小同源风险——不阻塞本版。
- **`R11` 没有自动回滚** [A]：替换脚本成功路径会 `rm -rf "$backup"` 删除上一版备份，新版本装上后若
  启动失败不会自动换回旧版本（失败路径会把备份移回 `$old`）。处置：文档在「已知问题」与「回退」中
  写明手动回退步骤（重新解压上一版 ZIP 替换应用），并在 Release Issue 中记录。
- **`R12` 解压器对恶意归档路径的处理未审计** [C]：解压用 `/usr/bin/ditto -x -k`，本次没有做 zip-slip
  类路径逃逸的对抗性测试。缓解：归档内容由上游发布的 SHA-256 绑定；解压后只接受 staging 目录内名为
  `Pi-Web-Desktop.app` 且解析符号链接后仍在 staging 内的 bundle，其余一律失败退出。处置：保持只从
  固定 Release 资产下载；若要进一步收紧，可在解压前后增加归档路径白名单校验——不阻塞本版。
- **`R13` `/Applications` 写权限的探针与替换之间存在 TOCTOU** [C]：`canWriteApplicationDirectory`
  写探针成功之后、替换脚本执行之前，目录权限可能变化。缓解：脚本对 `mv` 失败会回滚备份并以 1 退出，
  不会留下半替换状态（错误文案：「替换桌面应用失败，原应用未被删除。」）。处置：评估为低影响，
  不阻塞本版。
- **`R14` 待安装版本字符串可能来自本机缓存** [B]：304 复验准入放宽的直接后果——与用户同权限的进程
  可以改写更新检查缓存里的版本与 tag。缓解与边界：准入要求「本轮网络往返成功 + 上游结构已核实 +
  目标版本严格大于正在运行的版本」，下载前重新联网核对资产 URL、校验值、bundle 身份与版本；缓存只能
  影响「用哪个版本字符串作为线索」，不能注入路径或降低校验强度。处置：已在文档的「已知问题」与第 1
  节边界说明中登记——不阻塞本版。

### 既往观察（非本次 delta）

`R1`–`R9`（见 [security-review-alpha.14.md](security-review-alpha.14.md) §9）相关代码本版未改，仍然
有效：`R1` 非 loopback 时窗口加载该地址、`R2` host 尾部点不归一、`R3` 切换监听的完成语义不等于服务
就绪、`R4` 退出等待预算 ≤1 秒、`R5` 占位符硬门禁依赖人工执行、`R6` 应用窗口的页面请求仍走系统代理、
`R7` 依赖门控缓存不是信任边界、`R8` 指纹不含 pi / pi-web 版本、`R9` 缓存收敛与启动所有权记录之间的
窄竞态（[C]）。

## 10. 已核实无问题

- **信号面与所有权**：`kill(` 7/7、`sendGroupSignal` 4/4，未触碰服务所有权代码（§1）。[A]
- **凭据面**：`keychain.save(` 1/1，自更新不接触 Keychain，下载会话关闭 cookie 与凭据存储（§2）。[A]
- **日志面**：新增代码 0 处日志调用，失败文案是固定字符串表（§3）。[A]
- **网络面**：资产 URL 精确匹配固定路径、重定向主机白名单未扩大、最终 URL 复验后才校验与替换；
  304 准入放宽不改变网络面与校验强度（§4）。[B]
- **供应链**：无新增第三方依赖，无新增 Actions 固定项，workflow 未改（§5、§7）。[A]
- **构建脚本**：`Scripts/build.sh` 的变化不跳过签名校验、不改签名方式（§5）。[B]
- **本机数据**：无新增 `UserDefaults` 键（79/79），新增持久化字段只有 tag（§8）。[A]
- **静态卫生**：`try!` 0/0、`as!` 0/0、`fatalError` 3/3（无新增强制解包或崩溃点）。[A]

## 11. 证据不足 / 无法确认（不作猜测）

- 本机只有 Command Line Tools，**没有运行 XCTest**：5 个新用例的通过性来自 CI 的 `xcodebuild test`
  （run [35818969790](https://github.com/Su-luoya/pi-web-desktop/actions/runs/35818969790) 与后续
  文档提交的 run 均为 `success`），本报告不把「用例覆盖到的分支一定正确」当作已核实结论。
- 「校验失败即中止」「非 `/Applications` 拒绝」两条真机行为在发布后用本版资产回填（此前 alpha.14
  周期的同类验证已完成，但那是对 alpha.14 资产）。
- `R12` 的归档路径逃逸、`R13` 的 TOCTOU 都属于「没有运行证据」的推断，按 [C] 登记，不作为已核实
  结论。
- 上游 GitHub 账户 / Release 被攻破的场景无法在本机验证（`R10`）。
- 下载链路在真实网络抖动 / 代理环境下的行为本次没有专项测试，依赖既有 `UpdateChecker` 超时与内存中
  的 SHA-256 流式校验（不落盘中间态）。

## 12. 发布决定

- **阻断项 0 条**；本版新增非阻断项 5 条（`R10`–`R14`），继承 `R1`–`R9`，全部已在文档中明示或评估为
  低影响。
- 判定：**通过（非阻断项已登记，不阻塞发布）**。发布前门槛的实测记录（构建、身份、冒烟、版本一致性、
  打包演练、文本扫描）在候选提交上重跑，见
  [alpha-release-checklist.md](alpha-release-checklist.md) 的「Release v0.1.0-alpha.15 执行记录」；
  发布资产的 checksum 在发布后回填到
  [Release Issue #179](https://github.com/Su-luoya/pi-web-desktop/issues/179)。
