# Pi Web Desktop 0.1.0-alpha.8（build 8）— Apple Silicon alpha（未公证）

## 摘要 / Summary
Pi Web Desktop `0.1.0-alpha.8` 是面向 **Apple Silicon（arm64）、macOS 14 或更高版本** 的第八个
alpha 预览。它启动、监控并显示本机已安装的 Pi Web 服务，默认只监听 loopback。相对
`0.1.0-alpha.7`，本版本只有 **1 个代码提交**（PR #125：一个修复，关闭 4 个 issue），除此之外只有发布提交本身（版本 bump 与本文档），没有新增功能面：

1. **更新失败的文案族与事实对齐**（#119 / PR #125）：日志尾句从「旧版本保持不变」改成「本次没有执行
   任何回滚动作」，与弹窗、`reason` 同源；重新检测拿不到版本时不再同时写「仍在使用更新前的版本」和
   「重新检测到的版本是 未知」；Pi CLI 的「更新进行中」拒绝在放弃等待未确认时补上「重启应用即可恢复」
   的提示。
2. **Web / 扩展包执行器的收尾边界**（#121 / PR #125）：扩展包执行器的完成回调改由专用投递队列派发，
   不再阻塞状态队列；UTF-8 多字节字符被分块切开时不再产生替换字符（EOF 冲刷）；验证器只在**常规
   文件**上继续读取（到常规文件的符号链接仍可读，FIFO、目录与字符设备不再被打开）；Web 的取消请求
   落在「进程已退出、仍在等管道 EOF」窗口时会被记录而不是静默丢弃；失败结果携带的输出尾部先脱敏
   再跨类型传递（与日志路径一致）；
   `PATH` 即信任边界（不固定可执行文件位置、不校验签名）写入文档。
3. **npm `integrity` 的基准版本固定**（#124 / PR #125）：只有在同一条 `node_modules` 路径、同一个
   包名、且以**更新前已安装的版本**为基准时才采信 `integrity`；`package.json` 里的版本只在包名一致
   时作为回退基准，不再直接进入判定。
4. **测试面补强**（#120 / PR #125）：新增 `PiWebDesktopTests/UpdateVerifierTests.swift`（9 个对抗
   用例：精确 `node_modules` 路径优先、嵌套同名条目歧义 → 不采信、条目基准版本必须一致、
   `dependencies` 回退、五种非法 `integrity` 形状、最近的锁文件优先（含隐藏的
   `node_modules/.package-lock.json`）、上层无关锁文件不参与、FIFO 视为不可读、符号链接到常规文件
   可读），并为「完成回调不在状态队列上」「UTF-8 按字节切开」「事实句必须有证据来源」各补一个用例。

ZIP 里的应用仍然是 **ad-hoc 签名、未公证** 的：没有 Developer ID 证书，也没有 Apple 公证，
因此 Gatekeeper 默认会阻止直接双击打开，需要用户针对这一个应用手动放行。本版本没有 Intel 支持、
没有 SLA，**不承诺所有安装来源都能回滚**，远程访问的密码认证也**不等于传输加密**。更新验证仍然
**不做代码签名确认、不确认官方来源、不做安装包内容比对**。

Pi Web Desktop `0.1.0-alpha.8` is the eighth alpha preview for **Apple Silicon (arm64) Macs running
macOS 14 or later**. It starts, monitors and displays a locally installed Pi Web service and listens
on loopback by default. Compared with `0.1.0-alpha.7` this release contains **a single code change
commit** (PR #125, one fix that closes four issues) plus the release commit itself (version bump and
this document), and no new features: the failure wording now matches what actually
happened (a failure log no longer claims the old version was kept when nothing was rolled back, a
missing re-detected version no longer contradicts itself in one sentence, and the CLI refusal for an
in-flight update carries the recovery hint when an abandoned child has not been confirmed as exited;
#119); the Web and Pi package executors' finish windows are aligned (the Pi package executor delivers
its completion callback on a dedicated queue instead of the state queue, split UTF-8 reads are flushed
at EOF instead of producing replacement characters, the verifier keeps reading only regular files, a
Web cancel that lands after the process exited is recorded rather than dropped, and the output tail
carried by a failure outcome is redacted before it crosses the type boundary, matching the log path;
#121); npm `integrity` is only trusted on the same `node_modules` path and package name when the
baseline is the pre-update installed version recorded before the install (#124); and the verifier
gained an adversarial test file plus three behavioural tests (#120).

## 发布信息

| 项目 | 值 |
| --- | --- |
| 版本（tag） | `v0.1.0-alpha.8` |
| `CFBundleShortVersionString` | `0.1.0-alpha.8` |
| `CFBundleVersion` | `8` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 应用包 | `Pi-Web-Desktop.app` |
| 架构 | arm64（Apple Silicon）；**不支持 Intel（x86_64）** |
| 最低系统 | macOS 14.0 |
| 签名 | ad-hoc（`codesign --sign -`），没有证书，`TeamIdentifier=not set` |
| 公证 | 无。Gatekeeper 默认拒绝，需要用户手动放行这一个应用 |
| 发布类型 | GitHub **prerelease**（alpha 预览） |
| 上一版 | `v0.1.0-alpha.7`（build `7`），资产仍在 Releases 中可下载 |
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

## alpha.8 相对 alpha.7 的新增与变更

本版本不新增功能面：它清掉 `v0.1.0-alpha.7` 发布说明「已知问题」里剩下的**文案面**与**测试面**清单 ——
alpha.6 delta 评审的 `L-1` / `L-2` / `L-3`（[#119](https://github.com/Su-luoya/pi-web-desktop/issues/119)）、
两份复核的测试面 `T-1` / `T-2` / `T-3`（[#120](https://github.com/Su-luoya/pi-web-desktop/issues/120)）、
alpha.7 delta 评审的 `F1` … `F6`（[#121](https://github.com/Su-luoya/pi-web-desktop/issues/121)）与它的
版本证据来源观察项（[#124](https://github.com/Su-luoya/pi-web-desktop/issues/124)）。唯一的代码提交
（[#125](https://github.com/Su-luoya/pi-web-desktop/pull/125)）只改文案、投递队列、文件读取方式与测试，
**不改变信号语义、文件操作范围与权限语义**。`v0.1.0-alpha.7` 已有的行为与能力边界见
[alpha.7 Release 说明](release-notes-v0.1.0-alpha.7.md)。

### 1. 更新失败与拒绝的文案族（#119 / PR #125）

- **日志尾句**：`Sources/PiCLIUpdateAdapter.swift`、`Sources/PiWebUpdateAdapter.swift`、
  `Sources/PiPackageUpdateAdapter.swift` 里命令失败与放弃等待的日志行从「旧版本保持不变」改为
  「本次没有执行任何回滚动作」，与弹窗和 `reason` 文案同源；
  `PiWebDesktopTests/PiWebUpdateAdapterTests.swift` 里把旧文案写成断言的用例同步更新。
  `.versionUnchanged` 分支（`Sources/PiPackageUpdateAdapter.swift` 的两处与 CLI / Pi Web 的对应行）的
  「旧版本保持不变」**保留不动**：那里的版本状态有重检测探针支撑。
- **`detectedVersion == nil` 的句子**：三条路径的验证失败句改成「更新命令已结束，但重新检测没有给出
  可用的版本结果，因此无法判断是否达到目标版本」，不再在同一句里既写「仍在使用更新前的版本」又写
  「重新检测到的版本是 未知」。`Sources/UpdateTransaction.swift` 的 `displayName`
  （「更新后验证失败，仍在使用更新前的版本」）**保留**：它只在“版本相等”或“路径与证据一致”时成立，
  两种情况都有证据（见 [alpha.7 安全评审](security-review-alpha.7.md) 的证据链）。
- **Pi CLI 的拒绝文案**：`Sources/PiWebApp.swift` 的 `notAttempted` 分支在「更新进行中 + 上一次放弃
  等待未确认退出」时追加「上一次更新命令已放弃等待，但还不能确认它已经退出；如果长时间没有变化，
  重启应用即可恢复（重启后这个未确认窗口不会保留）」。判据是执行器自己的读状态
  （`abandonedChildrenUnconfirmed`），不是轮询。

### 2. Web / 扩展包执行器的收尾边界（#121 / PR #125）

- **完成回调的投递队列**（`F1`）：`Sources/PiPackageUpdateAdapter.swift` 新增专用投递队列，忙拒绝的
  回调与 `completeLocked` 的收尾结果都在该队列上派发，状态队列不再被调用方的回调阻塞；
  `docs/architecture.md` 的投递说明同步（执行结果经专用投递队列交给调用方、管道 EOF 冲刷、取消落在收尾窗口时的记录）。
- **增量解码的 EOF 冲刷**（`F2`）：扩展包执行器用 `IncrementalUTF8Decoder` 解码 stdout/stderr，进程
  退出时以空块冲刷暂存的不完整序列并在下一个进程开始前重置；分块切开的多字节字符不再变成 U+FFFD。
- **只读常规文件**（`F4`）：`Sources/UpdateVerifier.swift` 新增 `fileType(atPath:)` 与
  `openRegularFile(atPath:)`（先 `resolvingSymlinksInPath`，再按 `FileAttributeType` 判定），
  `readBoundedData` 与 `readContentHash` 只在 `.typeRegular` 上继续；FIFO、目录与字符设备返回 nil，
  不再可能阻塞在读管道上。
- **取消落在收尾窗口**（`F5`）：`Sources/PiWebUpdateAdapter.swift` 用 `cancelRequestedDuringFinish`
  记录「进程已经退出、只是还在等管道读到 EOF」这次取消，并在日志里说明没有信号可发、结果按真实
  退出码处理。
- **先脱敏再入库**（`F6`）：失败尾部的文本进入 `installFailed` 之前先过 `Redactor`，与日志路径一致。
- **文档**（`F3`）：`docs/security-ownership.md` 记录「不固定可执行文件位置、不校验签名：`PATH` 即
  信任边界」，与 `Sources/PiCLIUpdateAdapter.swift` / `Sources/PiWebUpdateAdapter.swift` 的解析器
  注释同步。

### 3. `integrity` 的基准版本（#124 / PR #125）

- `UpdateArtifactProbe.npmIntegrity` 的签名变为 `(String, String?, String?) -> String?`
  （`executablePath`、`packageName`、`fingerprintVersion`）：`Sources/UpdateVerifier.swift` 用
  `fingerprintVersion ?? （包名一致时的 package.json 版本）` 作为基准，`Sources/UpdateTransaction.swift`
  在采集时传入**更新前已安装的版本**（采集发生在安装命令之前，与读取时点自洽）。效果：同一个包的不同版本不再互相采信 `integrity`，条目缺失或
  包名不一致时如实显示「未获取」。

### 4. 测试面（#120 / PR #125）

- 新增 `PiWebDesktopTests/UpdateVerifierTests.swift`：9 个对抗用例（精确 `node_modules` 路径优先、
  嵌套同名条目歧义 → 不采信、条目基准版本必须一致、`dependencies` 回退、五种非法 `integrity` 形状 /
  未知算法 / 非 base64 / 空载荷 / 超长 / 缺分隔、最近的锁文件优先（含隐藏项）、上层无关锁文件不参与、
  FIFO 视为不可读、符号链接到常规文件可读）；工程文件已在四处登记
  （`PiWebDesktop.xcodeproj/project.pbxproj`）。
- `PiWebDesktopTests/PiPackageUpdateAdapterTests.swift`：完成回调不阻塞状态队列、UTF-8 按字节切开
  两类用例（`T-1` 的缺口用真实执行器覆盖）。
- `PiWebDesktopTests/UpdateTransactionTests.swift`：`testIdentityWordingFollowsTheEvidenceSource`
  断言事实句必须有证据来源（`T-2`）。

### 5. 本版的安全审查（delta）

本版新增并提交了一份**只读的 delta 安全评审**：[v0.1.0-alpha.8 安全评审](security-review-alpha.8.md)，
范围是 `git diff 3ed1a09..c4f26a1`（本版唯一的提交）。结论：阻断项 **0 条**，非阻断项 **5 条**：
`L-1` 四条「验证失败」日志行仍在 `detectedVersion == nil` 路径断言「旧版本保持不变」（与 #119 同源，
属文案完成度）；`L-2` 本文档曾把 `integrity` 的基准写成「目标版本」——评审指出后本版已按代码实际语义
（基准是**更新前已安装的版本**，采集发生在安装命令之前）改正；`L-3` `openRegularFile` 的类型检查与
打开之间仍有 TOCTOU 窗口；`L-4` 排水宽限到期结束时不清空增量解码器的暂存字节（尾部可能少一个不完整
字符）；`L-5` 既有的「已放弃等待」日志仍写「保持不变」。评审用逐处证据确认 `#121` 的 `F1`–`F6`、`#120`
的 `T-1`–`T-3` 按主张落实、`#124` 的代码语义正确，未发现越权、崩溃、数据损坏或凭据泄漏的新路径，
结论为**不阻断发布**；未在本版处理的四项登记在
[#127](https://github.com/Su-luoya/pi-web-desktop/issues/127)。

## 更新检查与自动更新的边界（本版无变化）

本版**没有改动**更新检查的域名、频率、开关与自动更新的前置条件，也没有新增任何安装路径：
`Sources/UpdateChecker.swift` 的两个主机常量（`api.github.com`、`registry.npmjs.org`）未变，两条
自动更新开关仍然默认关闭。完整边界（会做/不会做、域名与关闭方式、三种更新路径的命令与超时行为）
以 [alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md) 的
“更新检查访问的域名、频率与关闭方式”“自动更新的准确边界”两节为准；本版只改了**失败时的文案**与
**门闩的提示**，两者的用户可见效果见上一节。

## 本机实测环境与版本（可追溯）

下表来自维护者一台 Apple Silicon 真机的实测输出，**不是 CI runner**；每一行的值都能用第三列的
命令复现。CI runner 的版本不会写进本说明。

| 项目 | 实测值 | 实测命令（本机输出摘要） |
| --- | --- | --- |
| 机器与芯片 | Apple M4（`Mac16,10`） | `sysctl -n machdep.cpu.brand_string` → `Apple M4`；`sysctl -n hw.model` → `Mac16,10` |
| macOS | 27.0（BuildVersion `26A428`），满足 `>= 14` | `sw_vers` |
| 架构 | arm64 | `uname -m` → `arm64` |
| Node.js | v24.21.0 | `node --version` → `v24.21.0` |
| npm | 11.19.0；全局前缀 `/opt/homebrew` | `npm --version` → `11.19.0`；`npm prefix -g` → `/opt/homebrew` |
| Pi CLI（`@earendil-works/pi-coding-agent`） | 0.86.0 | `pi --version` → `0.86.0` |
| `@agegr/pi-web` | 0.9.1 | `npm ls -g --depth=0` → `@agegr/pi-web@0.9.1` |
| Swift 编译器 | Apple Swift 6.4（`swiftlang-6.4.0.34.1 clang-2100.3.34.1`，target `arm64-apple-macosx27.0.0`） | `swift --version` |
| Xcode | 无 Xcode，只有 Command Line Tools | `xcode-select -p` → `/Library/Developer/CommandLineTools`（`xcodebuild` 在本机不可用） |
| 应用包身份 | 本机脚本构建产物实测 `CFBundleShortVersionString=0.1.0-alpha.8`、`CFBundleVersion=8`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon`；`./Scripts/check-identity.sh` → `check-identity: PASSED (45 checks)` | `Configuration/AppIdentity.xcconfig`；`./Scripts/build.sh` 后用 `./Scripts/check-identity.sh` 与 `plutil -p` 复核（Xcode 构建产物与 `.xctest` bundle 仍由 CI 覆盖，本机没有 Xcode） |

`pi-web` 当前（0.9.1）没有 `--version` 选项（执行会报 `Unknown option '--version'`），核对版本
请用 `npm ls -g @agegr/pi-web` 或读取该包 `package.json` 的 `version`。

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

发布产物由 `.github/workflows/release.yml` 在 tag 上打包时生成，**发布值以 Release 草稿与 assets
为准**（同一提交反复打包会得到不同的 SHA-256，原因见 [发布流程](releasing.md#可复现性与诚实的边界)）。
本节在 tag 与 Release 草稿建立后，由协调者从 workflow 产物回填**实际值**（与 `v0.1.0-alpha.7` 的
回填流程相同）；本机演练值只用于追溯，**不用于发布核对**。

- 资产：`Pi-Web-Desktop-0.1.0-alpha.8+build.8.zip`（以及同前缀的 `.sha256` 与证据 Markdown）
- 字节数：**1,520,630**
- SHA-256：`74aabbe2447e524ded0a5af03fc3a84d4f87a9f21af217195cecd21641406e19`
- 发布 tag `v0.1.0-alpha.8`（合并提交与 `release.yml` run 在发布后回填）：
  <https://github.com/Su-luoya/pi-web-desktop/releases/tag/v0.1.0-alpha.8>（**待回填**：发布时间与
  `shasum -a 256 -c` 的复核结果）
- 校验命令（下载目录执行）：

  ```bash
  shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.8+build.8.zip.sha256
  ```

- 校验失败时不要安装，请在 Release Issue 或普通 Issue 中报告。
- **不要使用本机演练值当发布值**：发布值由 `release.yml` 在 tag 上运行
  `Scripts/package-release.sh` 生成，写在 `dist/release-metadata.env`（`ZIP_NAME` / `SHA256` /
  `COMMIT`）里；Release 草稿的正文与 checksum 必须从该 workflow 产物复制。

## 构建与签名验证记录（本机演练）

**本版在提交前的同一工作区上跑了一遍本机门槛**：`sh -n`、空白检查、脚本构建、身份检查、tag/版本
比对、`codesign` 验签与 `-dv`、`spctl`、`smoke.sh` 两种模式、秘密扫描（自检 + 仓库扫描）、打包与
ZIP/checksum/解包复验。下表是本次的实际输出。与 alpha.6 相同，本次演练在 `~/Documents`（iCloud 同步
目录）**之外**的 worktree（`~/orca/workspaces/Pi-Web/release-alpha-7`）里执行，因此没有再遇到
iCloud File Provider 贴回 `com.apple.FinderInfo` 的问题。`xcodebuild build` / `xcodebuild test`、
GUI 手工验收、真实更新执行仍不在本机范围内。

| 命令 | 结果 |
| --- | --- |
| `sh -n Scripts/*.sh` | 退出 0（无输出） |
| `git diff --check` | 退出 0（无输出） |
| `sh Scripts/check-release-version.sh v0.1.0-alpha.8` | `check-release-version: PASSED (tag v0.1.0-alpha.8, MARKETING_VERSION 0.1.0-alpha.8, CURRENT_PROJECT_VERSION 8)`。脚本只做字符串比对，**不检查 git tag 是否存在**（本次 tag 尚未创建） |
| `./Scripts/build.sh` | 退出 0：`Built: build/Pi-Web-Desktop.app`、`Contents/MacOS/PiWebDesktop: Mach-O 64-bit executable arm64` |
| `./Scripts/check-identity.sh` | `check-identity: PASSED (45 checks)`；包内 `CFBundleShortVersionString=0.1.0-alpha.8`、`CFBundleVersion=8`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`LSMinimumSystemVersion=14.0`、`CFBundleIconFile=ApplicationIcon`；并断言 `no hardcoded MARKETING_VERSION outside Configuration/AppIdentity.xcconfig` |
| `codesign --verify --deep --strict build/Pi-Web-Desktop.app` | 退出 0（`valid on disk` / `satisfies its Designated Requirement`，无输出） |
| `codesign -dv --verbose=4 build/Pi-Web-Desktop.app` | `Identifier=io.github.su-luoya.pi-web-desktop`、`Format=app bundle with Mach-O thin (arm64)`、`flags=0x2(adhoc)`、`Signature=adhoc`、`TeamIdentifier=not set`、`Sealed Resources version=2 rules=13 files=1` |
| `spctl -a -vv build/Pi-Web-Desktop.app` | 输出 `rejected`（退出 3）：未公证 ad-hoc 产物的预期结果 |
| `./Scripts/smoke.sh` | 退出 0。启动模式：标记 `smoke: ready`（app 退出 0）；诊断模式：标记 `smoke: diagnostics items=6 blockers=3` 与 `smoke: diagnostics ready`（app 退出 0）；脚本收尾写 `smoke: OK (markers … both modes exit 0)` |
| `./Scripts/scan-secrets.sh --self-test` | 退出 0：`self-test: PASS (all rules fired, look-alikes stayed clean, suppression and rejection verified, untracked-file gate verified, samples cleaned up)` |
| `./Scripts/scan-secrets.sh` | 退出 0：`scan-secrets: suppressed 15 lines`、`scan-secrets: PASS (no matches in tracked files; no untracked files)`。suppressed 行数与 alpha.5 记录一致（15 行，均为测试夹具的内联 `allow(reason=…)` 豁免） |
| `./Scripts/package-release.sh --tag v0.1.0-alpha.8` | 退出 0：`package-release: OK`，产出 `Pi-Web-Desktop-0.1.0-alpha.8+build.8.zip` 及 `.zip.sha256` / `.evidence.md` / `release-metadata.env`（`VERSION=0.1.0-alpha.8`、`BUILD=8`、`COMMIT=c4f26a1c28886c2c79d17e85907c6be6c1b6a8a1`）。ZIP 1,520,630 字节、SHA-256 `74aabbe2447e524ded0a5af03fc3a84d4f87a9f21af217195cecd21641406e19`（**演练值**）；脚本同时复验了“包内条目固定修改时间”“归一化时间后签名仍通过”“白名单条目集合一致（无 `__MACOSX/`）” |
| `unzip -l`（演练 ZIP） | 9 项：`Pi-Web-Desktop.app/` 及其 `Contents/{,_CodeSignature,MacOS,Resources}`、`Contents/Info.plist`、`Contents/MacOS/PiWebDesktop`、`Contents/Resources/ApplicationIcon.icns`、`Contents/_CodeSignature/CodeResources`；无 `__MACOSX/`，无源码、测试、日志或个人路径 |
| `shasum -a 256 -c`（演练 ZIP） | `Pi-Web-Desktop-0.1.0-alpha.8+build.8.zip: OK`（退出 0） |
| `ditto -x -k` + `plutil -p` + `codesign --verify --deep --strict` | 解压到 `mktemp -d` 后：`CFBundleShortVersionString=0.1.0-alpha.8`、`CFBundleVersion=8`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon`；解压出的 bundle 签名校验退出 0（临时目录已删除） |
| `xcodebuild build` / `xcodebuild test` / GUI 手工验收 / 真实更新执行 | 本机未执行：`xcode-select -p` → `/Library/Developer/CommandLineTools`，没有 Xcode；GUI 手工验收与真实更新执行本轮未执行。由 CI 的 `macos-14` job 与维护者真机验收覆盖 |
| CI（本版提交） | `build.yml`：`c4f26a1`（#125）run `35501956085` **success**（`xcodebuild build` / `xcodebuild test`、`build.sh`、`check-identity.sh --test-bundle`、`smoke.sh`、秘密扫描与 `sh -n Scripts/*.sh`）；发布提交的 run 待回填 |

**演练值的工作区状态（如实记录）**：这次本机打包发生在“版本 bump 已写入工作区、但发布提交尚未
创建”的状态下，`release-metadata.env` 的 `COMMIT` 记的是打包时的工作区 `HEAD`（`c4f26a1`，即
本说明所在的发布提交之前）。因此演练 ZIP **不等于**发布资产；发布资产由
`release.yml` 在 `v0.1.0-alpha.8` tag（即发布提交）上重新打包，名称、字节数与 SHA-256 一律以
workflow 产物为准。

`./Scripts/smoke.sh`（在 CI 中）只验证窗口、诊断页与退出路径：两种模式都在临时 support 目录里
运行，不写真实 UserDefaults / Application Support / Logs，也不启动真实 pi-web；它不替代
`xcodebuild test`。

## 已知问题

- **`v0.1.0-alpha.7` 那批「已知问题」在本版的状态**：
  - **已修**：alpha.6 delta 评审的 `L-1` / `L-2` / `L-3`（[#119](https://github.com/Su-luoya/pi-web-desktop/issues/119)）、
    两份复核的测试面 `T-1` / `T-2` / `T-3`（[#120](https://github.com/Su-luoya/pi-web-desktop/issues/120)），
    以及 alpha.7 delta 评审的 `F1` … `F6` 与它的版本证据来源观察项（[#121](https://github.com/Su-luoya/pi-web-desktop/issues/121)、
    [#124](https://github.com/Su-luoya/pi-web-desktop/issues/124)）。逐条证据见上面第 1–4 节与
    [alpha.8 安全评审](security-review-alpha.8.md)，以及 [v0.1.0-alpha.8 #125](https://github.com/Su-luoya/pi-web-desktop/pull/125)。
  - **按设计保留（有界窗口，不是本版修复目标）**：`L-4`（超时重试上限 5 × 0.2s = 1.0s 之后仍可能落一条
    「已放弃」记录；记录语义是「结束时间未知」，仍然为真）、`L-5`（扩展包 runner 退出时不 `abandon()`，
    重启后旧的 `npm i -g` 子进程可能与新命令重叠；菜单已按「上一次更新未确认退出」显示后缀并在受阻时
    置灰，但应用仍不会去确认那个进程何时结束）。
- **alpha.8 delta 评审新增的非阻断项（不阻断发布，登记在 [#127](https://github.com/Su-luoya/pi-web-desktop/issues/127)）**：
  - `L-1`：四条「验证失败」日志行仍在 `detectedVersion == nil` 路径写「旧版本保持不变」，与 `#119` / `L-2` 同一形态。
  - `L-3`：`openRegularFile` 的类型检查与打开之间有 TOCTOU 窗口（已有类型闸门，不是权限边界）。
  - `L-4`：排水宽限到期结束时不清空增量解码器的暂存字节，尾部可能少一个不完整字符。
  - `L-5`：既有的「已放弃等待」日志仍写「旧版本保持不变」，与相邻注释不一致（本版未改这一行）。
  - `L-2`（本文档把 `integrity` 的基准写成「目标版本」）已在本版按代码实际语义改正，不算遗留。
- **未公证**：首次打开必须手动放行，见上文“未公证、ad-hoc 与 Gatekeeper”。
- **更新验证有边界**：不确认代码签名、不确认公证、不做安装包内容比对；`package.json` 名称检查只防
  “换成了别的包名”，不等于发布者身份验证；内容哈希与 npm `integrity` 都只证明“本机文件是否仍是
  同一份 / 本机记录了什么”，**不证明来源可信**。`integrity` 的基准版本自本版起固定为本次更新的目标
  版本（同一条 `node_modules` 路径、同一个包名），因此“同一个包、不同版本”的历史不会被互相采信。
- **回滚能力有限**：只有“已验证的 npm 全局安装 + 应用保留的更新前证据仍在原位、身份名称一致、
  inode 与（若记录过）内容哈希一致”这一种情况会做自动降级；其它来源与证据缺失/被覆盖的情况一律
  写“无法自动回滚”，只给手动命令。应用**不恢复文件内容、不卸载新版本**。
- **更新失败不保证子进程结束**：Pi Web 只对本次启动的独立进程组发一次 `SIGTERM`（尽力而为），
  Pi CLI 与扩展包只放弃等待；应用不确认被放弃的进程是否结束、什么时候结束。被放弃的进程若未退出，
  该组件的下一轮更新会被保守拒绝，可靠恢复方式是重启应用。本版补上了「取消落在收尾窗口」的记录，
  但**取消仍然不能保证进程退出**。
- **依赖需要自行安装**：缺失时应用只显示诊断信息，不会自动安装（除非用户打开 Pi Web 或 Pi CLI
  的启动前自动更新开关，且全部前置条件满足）。
- **无 Intel 支持**：只支持 Apple Silicon（arm64），Intel Mac 不在支持范围。
- **无 SLA**：alpha 预览按“现状”提供，不承诺响应时间或修复时限。
- **远程访问**：默认只监听 `127.0.0.1`；远程访问必须自备加密隧道或 HTTPS 反向代理。**密码认证
  只验证访问者，不等于传输加密**，也没有暴力破解防护（上游 pi-web 范围，审查 R-4）。
- **日志轮转只保留 5 份**（每份上限 10 MB），超过上限的旧日志会被删除（见
  [日志与诊断导出](logging-and-diagnostics.md)）。
- **仍未在本机执行 / 验证的项**：`xcodebuild build` / `xcodebuild test`、GUI 手工验收、真实更新执行。

## 回退

1. 保留上一版的 ZIP 与它的 `.sha256`。回退时解压上一版（`v0.1.0-alpha.7`，资产仍在 Releases 中）
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
