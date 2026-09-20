# Pi Web Desktop 0.1.0-alpha.7（build 7）— Apple Silicon alpha（未公证）

## 摘要 / Summary
Pi Web Desktop `0.1.0-alpha.7` 是面向 **Apple Silicon（arm64）、macOS 14 或更高版本** 的第七个
alpha 预览。它启动、监控并显示本机已安装的 Pi Web 服务，默认只监听 loopback。相对
`0.1.0-alpha.6`，本版本包含 **6 个提交**（4 个修复、1 个文档同步、1 个发布值回填），没有新增功能面：

1. **更新验证器不再“先把整个文件读进内存再判断上限”，取值也不再取决于字典顺序**（#105 / PR #112）：
   超过上限的文件不再被打开；`integrity` 只在唯一命中且版本一致时才被采信；目标版本无法解析时按
   失败处理。
2. **降级阶段的历史不再把“失败”记成“成功”，探针不可用也不再被归因为“证据被覆盖”**（#106 / PR #115）：
   降级阶段新增「已执行 / 仅记录 / 无法执行」三种结果，两套失败文案收敛为一套。
3. **扩展包计划的判定顺序、降级调用与菜单状态与其它两条路径对齐**（#107 / PR #117）：有 Pi 进程
   在运行时先按进程拒绝；只读状态新增 `isRunning` 与“上一次更新未确认退出”后缀，菜单项据此显示
   或置灰。
4. **Web / CLI 执行器的输出解码、`PATH` 解析与“放弃等待”窗口对齐**（#108 / PR #116）：分块切割的
   多字节 UTF-8 不再产生替换字符；`PATH` 里的空项与相对项不再参与 npm 解析；进程退出后等待管道
   关闭有界；成功路径不再丢掉健康检查的最终结论。
5. **文档与版本引用同步**（#109 / PR #114、#113）：`SECURITY.md` 与 issue 模板不再写死某个 alpha
   版本号，`0.1.0-alpha.6` 的发布校验值已回填。

ZIP 里的应用仍然是 **ad-hoc 签名、未公证** 的：没有 Developer ID 证书，也没有 Apple 公证，
因此 Gatekeeper 默认会阻止直接双击打开，需要用户针对这一个应用手动放行。本版本没有 Intel 支持、
没有 SLA，**不承诺所有安装来源都能回滚**，远程访问的密码认证也**不等于传输加密**。更新验证仍然
**不做代码签名确认、不确认官方来源、不做安装包内容比对**。

Pi Web Desktop `0.1.0-alpha.7` is the seventh alpha preview for **Apple Silicon (arm64) Macs running
macOS 14 or later**. It starts, monitors and displays a locally installed Pi Web service and listens
on loopback by default. Compared with `0.1.0-alpha.6` this release contains **six commits** (four
fixes, one documentation sync, one release-value backfill) and no new features: the update verifier no
longer reads whole files into memory before checking the size limit and no longer takes whichever entry
a dictionary happens to return (`integrity` is only trusted on a unique, version-matching hit, and an
unparsable target version counts as failure; #105 / PR #112); degradation records no longer report a
failure as “succeeded” and an unavailable probe is no longer blamed on “evidence changed” (#106 /
PR #115); the Pi package planner checks process protection before the abandoned-record prompt, applies
degradation on install failure too, and exposes a non-blocking read state that drives the menu item
(#107 / PR #117); the Web and CLI executors decode output incrementally, reject empty and relative
`PATH` entries when resolving npm, bound how long they wait for pipes to close after the process has
exited, and keep the health-check verdict on the success path (#108 / PR #116); and the documents no
longer hard-code a specific alpha version (#109 / PR #114, #113).

The app in the ZIP is **ad-hoc signed and not notarized**: there is no Developer ID certificate and no
Apple notarization, so Gatekeeper blocks a plain double-click and the user has to approve this app
explicitly. This release has no Intel support, no SLA, **no promise that every install source can be
rolled back**, and for remote access the password authentication is **not transport encryption**.
Update verification still **does not confirm code signatures, does not confirm an official source and
does not compare package contents**.

## 发布信息

| 项目 | 值 |
| --- | --- |
| 版本（tag） | `v0.1.0-alpha.7` |
| `CFBundleShortVersionString` | `0.1.0-alpha.7` |
| `CFBundleVersion` | `7` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 应用包 | `Pi-Web-Desktop.app` |
| 架构 | arm64（Apple Silicon）；**不支持 Intel（x86_64）** |
| 最低系统 | macOS 14.0 |
| 签名 | ad-hoc（`codesign --sign -`），没有证书，`TeamIdentifier=not set` |
| 公证 | 无。Gatekeeper 默认拒绝，需要用户手动放行这一个应用 |
| 发布类型 | GitHub **prerelease**（alpha 预览） |
| 上一版 | `v0.1.0-alpha.6`（build `6`），资产仍在 Releases 中可下载 |
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

## alpha.7 相对 alpha.6 的新增与变更

本版本不新增功能面：它清掉 `v0.1.0-alpha.6` 发布说明「已知问题」里那张复核清单的绝大部分 ——
W2B 的 `B-1` … `B-13`，W2A 的 `F5` / `F6` / `F7`，以及 alpha.6 delta 安全评审的 `M-1`。
四条修复（#105 / #106 / #107 / #108）都只改判定、记录与文案，**不改变信号语义、文件操作与权限范围**；另外
两个提交是文档同步（#109）与发布值回填（#113）。alpha.6 delta 评审的三条纯文案项 `L-1` / `L-2` / `L-3`
（[#119](https://github.com/Su-luoya/pi-web-desktop/issues/119)）与两份复核的测试面三条 `T-1` / `T-2` / `T-3`
（[#120](https://github.com/Su-luoya/pi-web-desktop/issues/120)）仍留在「已知问题」里。`v0.1.0-alpha.6` 已有的行为与能力边界见
[alpha.6 Release 说明](release-notes-v0.1.0-alpha.6.md)。

### 1. 更新验证器：有界读取与取值确定化（#105 / PR #112）

- **有界读取名实相符**：新增 `readBoundedData(atPath:maximumSize:fileSize:openFile:)` —— 先按文件
  属性判断上限（**超限文件不打开**），再用 `FileHandle` 以 64 KiB 分块读取，累计超过上限返回 nil。
  `readPackageName(atPackageJSONPath:)` 与 `readIntegrityValue(atLockfilePath:packageName:)` 改用它，
  峰值内存不再等于文件大小（`package.json` 512 KiB、锁文件 4 MiB 的上限不变）。
- **`integrity` 取值确定化**：优先精确匹配 `node_modules/<包名>`；其余候选按 key 排序，只允许唯一
  命中；条目 `version` 与非空指纹版本不一致也返回 nil。拿不到就如实显示「未获取」，不再把别的版本
  （或别的项目的）`integrity` 记成本次更新前的证据。
- **目标版本不可解析时按失败处理**：`versionReached` 在目标版本存在但无法解析（例如 `latest`）时返回
  `false`，`versionCheck` 返回 `.failed(detail: "目标版本不可解析")`，不再退化成「版本变了就算达到」。

### 2. 降级阶段的状态与归因（#106 / PR #115）

- **降级不再记成「成功」**：`UpdateTransactionPhaseStatus` 新增降级专用结果 `applied`（已执行）/
  `recordedOnly`（仅记录）/ `notPossible`（无法执行）；安装失败保持旧版本、无法自动回滚分别落到
  「仅记录」「无法执行」。`isSuccessful` 的判据（提交阶段完成且无失败）不变，降级不会再借
  `.succeeded` 让历史看起来像一次成功更新。
- **探针不可用不再被归因成「证据被覆盖」**：新增 `UpdateRollbackEligibility.probeUnavailable`
  （「本次运行没有可用的文件系统探针，无法核对更新前的证据」），不再断言「更新前的证据已被覆盖、
  删除或不可执行」。
- **两套失败文案收敛**：`UpdateDegradationKind.installFailedKeepingPreviousVersion.displayName`
  从「更新失败，仍在使用旧版本」改为「更新失败，没有执行任何回滚动作」，与持久警告、历史说明同源。
- `docs/architecture.md` 的阶段结果集合、失败语义与资格集合三处同步。
- 边界：旧历史里已经写入的 `succeeded` 不做数据迁移，那些行仍显示旧文案。

### 3. 扩展包计划：判定顺序、降级调用与菜单状态（#107 / PR #117）

- **判定顺序**：`PiPackageUpdatePlanner.decide` 把「进程保护」判定移到「已放弃」记录判定之前。有 Pi
  进程在运行时先按进程拒绝（`.executeBlocked(.piRunning)` / `.processStateUnknown`），不再先弹
  「某次放弃未结清」的确认框；进程消失后同一条未结清记录仍然要求确认，**门闩强度不变**。
- **降级调用一致**：安装失败分支补上 `transaction.applyDegradation(degradation)`，与验证失败分支对齐
  （扩展包该 kind 的生产实现是 no-op，只记日志与历史）。
- **读状态接口**：协议 `PiPackageUpdateRunning` 新增非阻塞读属性 `isRunning` 与
  `abandonedChildrenUnconfirmed`；扩展包菜单项据此显示「（正在更新）」/「（上一次更新未确认退出，
  重启应用可恢复）」后缀，并在受阻时置灰。菜单侧不轮询，读的是执行器自己的状态队列。
- `docs/architecture.md`、`docs/settings-and-workspace.md` 同步判定顺序、降级路径与菜单三态。

### 4. Web / CLI 执行器：输出解码、`PATH` 与排水窗口（#108 / PR #116）

- **增量 UTF-8 解码**：新增 `IncrementalUTF8Decoder`，跨块暂存不完整的多字节序列并在 EOF 时冲刷，
  日志与诊断文本里不再出现因分块切断而产生的 U+FFFD 替换字符（仍是 lossy 解码，非法字节不会崩）。
- **`PATH` 解析**：`PiWebUpdateNPMResolver` 拒绝含空项或相对项的 `PATH`，候选目录只保留绝对路径
  （`PiWebUpdateRefusal.unsafeExecutablePath`），不再可能把相对路径解析成其它可执行文件。
- **进程退出后的排水窗口**：`ProcessPiWebUpdateInstaller` 新增可注入的 `pipeDrainGrace`（默认 0.5s）
  与 `pendingFinish` / `drainTimer`：进程退出后先等管道关闭再结算，**成功退出不会再被排水宽限的超时
  污染**；`cancel()` 在已有暂存结论时不再抢跑。CLI 侧补上同类守卫。
- **成功路径保留最终结论**：健康检查后的最终报告写入更新 journal，成功更新的历史里不再出现
  「服务启动后健康检查：未验证（尚未启动服务；健康检查未运行）」。
- `docs/architecture.md` 的排水与放弃等待描述同步（三个适配器在宽限窗口内都不写「已放弃」记录）。

### 5. 文档、版本引用与发布值回填（#109 / PR #114、#113）

- `SECURITY.md` 与 `.github/ISSUE_TEMPLATE/bug_report.yml` 不再写死某个 alpha 版本号，改为指向
  版本唯一来源 `Configuration/AppIdentity.xcconfig`。
- `v0.1.0-alpha.6` 的资产名、字节数与 SHA-256 回填到该版发布说明的「校验值」一节。
- 本次只改文档，不改代码。

### 6. 本版的安全审查（delta）

本版新增并提交了一份**只读的 delta 安全评审**：[v0.1.0-alpha.7 安全评审](security-review-alpha.7.md)，
范围是 `git diff b162544..4e6e332`（本版六个提交）。结论：**阻断项 0；中危 2 项、低危 4 项，全部登记在
[#121](https://github.com/Su-luoya/pi-web-desktop/issues/121)** —— 六项都不改变信号语义、文件操作、
权限范围与凭据处理，因此本版按当前提交发布。评审由发布执行者派发的独立只读评审在单独上下文里完成
（原定的 Orca 只读工人因模型账号额度不足中断、未产出报告，这一过程瑕疵与评审方式、限制都记在该报告里）。
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
| 应用包身份 | 本机脚本构建产物实测 `CFBundleShortVersionString=0.1.0-alpha.7`、`CFBundleVersion=7`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon`；`./Scripts/check-identity.sh` → `check-identity: PASSED (45 checks)` | `Configuration/AppIdentity.xcconfig`；`./Scripts/build.sh` 后用 `./Scripts/check-identity.sh` 与 `plutil -p` 复核（Xcode 构建产物与 `.xctest` bundle 仍由 CI 覆盖，本机没有 Xcode） |

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
本节在 tag 与 Release 草稿建立后，由协调者从 workflow 产物回填**实际值**（与 `v0.1.0-alpha.6` 的
回填流程相同）；本机演练值只用于追溯，**不用于发布核对**。

- 资产：`Pi-Web-Desktop-0.1.0-alpha.7+build.7.zip`（以及同前缀的 `.sha256` 与证据 Markdown）
- 字节数：**待回填**
- SHA-256：**待回填**
- 校验命令（下载目录执行）：

  ```bash
  shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.7+build.7.zip.sha256
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
| `sh Scripts/check-release-version.sh v0.1.0-alpha.7` | `check-release-version: PASSED (tag v0.1.0-alpha.7, MARKETING_VERSION 0.1.0-alpha.7, CURRENT_PROJECT_VERSION 7)`。脚本只做字符串比对，**不检查 git tag 是否存在**（本次 tag 尚未创建） |
| `./Scripts/build.sh` | 退出 0：`Built: build/Pi-Web-Desktop.app`、`Contents/MacOS/PiWebDesktop: Mach-O 64-bit executable arm64` |
| `./Scripts/check-identity.sh` | `check-identity: PASSED (45 checks)`；包内 `CFBundleShortVersionString=0.1.0-alpha.7`、`CFBundleVersion=7`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`LSMinimumSystemVersion=14.0`、`CFBundleIconFile=ApplicationIcon`；并断言 `no hardcoded MARKETING_VERSION outside Configuration/AppIdentity.xcconfig` |
| `codesign --verify --deep --strict build/Pi-Web-Desktop.app` | 退出 0（`valid on disk` / `satisfies its Designated Requirement`，无输出） |
| `codesign -dv --verbose=4 build/Pi-Web-Desktop.app` | `Identifier=io.github.su-luoya.pi-web-desktop`、`Format=app bundle with Mach-O thin (arm64)`、`flags=0x2(adhoc)`、`Signature=adhoc`、`TeamIdentifier=not set`、`Sealed Resources version=2 rules=13 files=1` |
| `spctl -a -vv build/Pi-Web-Desktop.app` | 输出 `rejected`（退出 3）：未公证 ad-hoc 产物的预期结果 |
| `./Scripts/smoke.sh` | 退出 0。启动模式：app exit 0 after 1s、标记 `smoke: ready`；诊断模式：app exit 0 after 0s、标记 `smoke: diagnostics items=6 blockers=3` 与 `smoke: diagnostics ready` |
| `./Scripts/scan-secrets.sh --self-test` | 退出 0：`self-test: PASS (all rules fired, look-alikes stayed clean, suppression and rejection verified, untracked-file gate verified, samples cleaned up)` |
| `./Scripts/scan-secrets.sh` | 退出 0：`scan-secrets: suppressed 15 lines`、`scan-secrets: PASS (no matches in tracked files; no untracked files)`。suppressed 行数与 alpha.5 记录一致（15 行，均为测试夹具的内联 `allow(reason=…)` 豁免） |
| `./Scripts/package-release.sh --tag v0.1.0-alpha.7` | 退出 0：`package-release: OK`，产出 `Pi-Web-Desktop-0.1.0-alpha.7+build.7.zip` 及 `.zip.sha256` / `.evidence.md` / `release-metadata.env`（`VERSION=0.1.0-alpha.7`、`BUILD=7`、`COMMIT=4e6e332e72469d835468a03ebe1e1aace623d6d3`）。ZIP 1,517,551 字节、SHA-256 `5efd8a56c49e76316b2ee4edbe2017b15ccbd647c8330e19ad676f23282f902e`（**演练值**）；脚本同时复验了“包内条目固定修改时间”“归一化时间后签名仍通过”“白名单条目集合一致（无 `__MACOSX/`）” |
| `unzip -l`（演练 ZIP） | 9 项：`Pi-Web-Desktop.app/` 及其 `Contents/{,_CodeSignature,MacOS,Resources}`、`Contents/Info.plist`、`Contents/MacOS/PiWebDesktop`、`Contents/Resources/ApplicationIcon.icns`、`Contents/_CodeSignature/CodeResources`；无 `__MACOSX/`，无源码、测试、日志或个人路径 |
| `shasum -a 256 -c`（演练 ZIP） | `Pi-Web-Desktop-0.1.0-alpha.7+build.7.zip: OK`（退出 0） |
| `ditto -x -k` + `plutil -p` + `codesign --verify --deep --strict` | 解压到 `mktemp -d` 后：`CFBundleShortVersionString=0.1.0-alpha.7`、`CFBundleVersion=7`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon`；解压出的 bundle 签名校验退出 0（临时目录已删除） |
| `xcodebuild build` / `xcodebuild test` / GUI 手工验收 / 真实更新执行 | 本机未执行：`xcode-select -p` → `/Library/Developer/CommandLineTools`，没有 Xcode；GUI 手工验收与真实更新执行本轮未执行。由 CI 的 `macos-14` job 与维护者真机验收覆盖 |
| CI（`main` 上的六个提交） | `build.yml`：`af47866`（#112）run `35496917660`、`9ede020`（#113）run `35497135814`、`be13c88`（#114）run `35497336171`、`0c1610c`（#115）run `35497649990`、`fbae499`（#117）run `35497954810`、`4e6e332`（#116）run `35498186531`，均为 **success**；覆盖 `xcodebuild build` / `xcodebuild test`、`build.sh`、`check-identity.sh --test-bundle`、`smoke.sh`、秘密扫描与 `sh -n Scripts/*.sh` 等 |

**演练值的工作区状态（如实记录）**：这次本机打包发生在“版本 bump 已写入工作区、但发布提交尚未
创建”的状态下，`release-metadata.env` 的 `COMMIT` 记的是打包时的工作区 `HEAD`（`4e6e332`，即
本说明所在的发布提交之前）。因此演练 ZIP **不等于**发布资产；发布资产由
`release.yml` 在 `v0.1.0-alpha.7` tag（即发布提交）上重新打包，名称、字节数与 SHA-256 一律以
workflow 产物为准。

`./Scripts/smoke.sh`（在 CI 中）只验证窗口、诊断页与退出路径：两种模式都在临时 support 目录里
运行，不写真实 UserDefaults / Application Support / Logs，也不启动真实 pi-web；它不替代
`xcodebuild test`。

## 已知问题

- **`v0.1.0-alpha.6` 那批「已知问题」在本版的状态**：
  - **已修**：W2B `B-1` … `B-13`，W2A `F5` / `F6` / `F7`，以及 alpha.6 delta 安全评审的
    `M-1`（同一弹窗两套文案互斥：`Sources/UpdateTransaction.swift:409` 与 `:747` 现在都写
    「没有执行任何回滚动作」）。逐条证据见上面第 1–4 节与
    [alpha.7 安全评审](security-review-alpha.7.md)。
  - **按设计保留（有界窗口，不是本版修复目标）**：`L-4`（超时重试上限 5 × 0.2s = 1.0s 之后仍可能落一条
    「已放弃」记录；记录语义是「结束时间未知」，仍然为真）、`L-5`（扩展包 runner 退出时不 `abandon()`，
    重启后旧的 `npm i -g` 子进程可能与新命令重叠），详见下面两条能力边界。
  - **仍留在本版**：alpha.6 delta 评审的三条**纯文案**项 `L-1` / `L-2` / `L-3`（见下，登记在
    [#119](https://github.com/Su-luoya/pi-web-desktop/issues/119)）与两份复核的**测试面**三条
    `T-1` / `T-2` / `T-3`（见下，登记在 [#120](https://github.com/Su-luoya/pi-web-desktop/issues/120)）。
    这六条都是文案或测试覆盖问题，不影响判定、信号、文件操作与权限语义。
- **命令失败与放弃等待的日志行仍写「旧版本保持不变」**（alpha.6 评审 `L-1`）：
  `Sources/PiCLIUpdateAdapter.swift:1282`、`Sources/PiWebUpdateAdapter.swift:1636`、
  `Sources/PiPackageUpdateAdapter.swift:1558`。弹窗与 `reason` 文案已在 `B-6` 与 #106 里改成
  「没有执行任何回滚动作」，日志与它们不一致；`PiWebDesktopTests/PiWebUpdateAdapterTests.swift:649`
  还把旧文案写成了断言（`XCTAssertTrue(world.log.text.contains("旧版本保持不变"), …)`）。
- **`detectedVersion == nil` 时验证失败句内不自洽**（alpha.6 评审 `L-2`）：
  `Sources/PiCLIUpdateAdapter.swift:1061`、`Sources/PiWebUpdateAdapter.swift:1432`、
  `Sources/PiPackageUpdateAdapter.swift:1543` 同时写「仍在使用更新前的版本」与
  「重新检测到的版本是 未知」；`Sources/UpdateTransaction.swift:410` 的 `displayName` 同族。
- **CLI 的「更新进行中」拒绝文案缺「重启应用即可恢复」**（alpha.6 评审 `L-3`）：
  `Sources/PiCLIUpdateAdapter.swift:83-84` 只写「请稍后再试」，而菜单标题
  （`Sources/PiWebUpdateAdapter.swift:102`）与 Pi Web / 扩展包的拒绝文案都有恢复提示。
- **验证器的对抗用例没有独立测试文件**（W2B `T-3`）：`Sources/UpdateVerifier.swift` 的用例散在
  `PiWebDesktopTests/UpdateTransactionTests.swift`；超大 `package.json` / 锁文件、同名多条目、
  `node_modules/.package-lock.json` 与上层无关锁文件等边界没有对抗测试。
- **协调器测试用假执行器替换了真实执行器**（W2B `T-1`）：
  `PiWebDesktopTests/PiPackageUpdateAdapterTests.swift:176-177` 的 `World.runner = RecordingRunner()`
  让只存在于 `ProcessPiPackageUpdateCommand` 里的缺陷在测试里不可见；真实执行器的用例又每个都新建
  实例，跨批次复用同样测不到。
- **失败与降级的事实性文案缺少对偶断言**（W2B `T-2`）：现有断言主要看状态与文案，很少断言历史里
  的正向事实句确有信息源（`B-3` / `B-6` / `B-8` / `B-9` 都是被旧断言放过的形态）。

以上 `L-1` / `L-2` / `L-3` 三条登记在 [#119](https://github.com/Su-luoya/pi-web-desktop/issues/119)，
`T-1` / `T-2` / `T-3` 三条登记在 [#120](https://github.com/Su-luoya/pi-web-desktop/issues/120)。
- **未公证**：首次打开必须手动放行，见上文“未公证、ad-hoc 与 Gatekeeper”。
- **更新验证有边界**：不确认代码签名、不确认公证、不做安装包内容比对；`package.json` 名称检查只防
  “换成了别的包名”，不等于发布者身份验证；内容哈希与 npm `integrity` 都只证明“本机文件是否仍是
  同一份 / 本机记录了什么”，**不证明来源可信**。
- **回滚能力有限**：只有“已验证的 npm 全局安装 + 应用保留的更新前证据仍在原位、身份名称一致、
  inode 与（若记录过）内容哈希一致”这一种情况会做自动降级；其它来源与证据缺失/被覆盖的情况一律
  写“无法自动回滚”，只给手动命令。应用**不恢复文件内容、不卸载新版本**。
- **更新失败不保证子进程结束**：Pi Web 只对本次启动的独立进程组发一次 `SIGTERM`（尽力而为），
  Pi CLI 与扩展包只放弃等待；应用不确认被放弃的进程是否结束、什么时候结束。被放弃的进程若未退出，
  该组件的下一轮更新会被保守拒绝，可靠恢复方式是重启应用。
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

1. 保留上一版的 ZIP 与它的 `.sha256`。回退时解压上一版（`v0.1.0-alpha.6`，资产仍在 Releases 中）
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
