# Pi Web Desktop 0.1.0-alpha.6（build 6）— Apple Silicon alpha（未公证）

## 摘要 / Summary

Pi Web Desktop `0.1.0-alpha.6` 是面向 **Apple Silicon（arm64）、macOS 14 或更高版本** 的第六个
alpha 预览。它启动、监控并显示本机已安装的 Pi Web 服务，默认只监听 loopback。相对
`0.1.0-alpha.5`，本版本包含 **3 个提交**，没有新增功能面：

1. **设置窗口可以自由缩放**（#99 / PR #100）：窗口可拖动边缘调整大小，表单区域滚动，底部按钮
   固定在视口内，说明文字与标签随宽度折行。
2. **更新失败的用户可见语义与真实动作对齐**（#101 / PR #102）：CLI / Web / 扩展包三路都不再断言
   “仍在使用旧版本”；扩展包执行器的忙拒绝能区分“上一次更新已放弃等待、但退出未确认”并给出重启
   恢复提示；包与 CLI 两个执行器在**排水宽限窗口**内不再写不实的“已放弃等待”记录。
3. **README 重写**（#103 / PR #104）：改为面向普通用户的安装与使用说明，技术边界移入 `docs/`。

ZIP 里的应用仍然是 **ad-hoc 签名、未公证** 的：没有 Developer ID 证书，也没有 Apple 公证，
因此 Gatekeeper 默认会阻止直接双击打开，需要用户针对这一个应用手动放行。本版本没有 Intel 支持、
没有 SLA，**不承诺所有安装来源都能回滚**，远程访问的密码认证也**不等于传输加密**。更新验证仍然
**不做代码签名确认、不确认官方来源、不做安装包内容比对**。

Pi Web Desktop `0.1.0-alpha.6` is the sixth alpha preview for **Apple Silicon (arm64) Macs running
macOS 14 or later**. It starts, monitors and displays a locally installed Pi Web service and listens
on loopback by default. Compared with `0.1.0-alpha.5` this release contains **three commits** and no
new features: the **settings window is now resizable** (scrolling form, fixed footer buttons,
wrapping labels; #99 / PR #100); the **user-visible wording of update failures now matches what the
app actually did** (none of the three update paths claims “the old version is still in use”
anymore), the Pi package executor distinguishes “a previous run was abandoned but its exit is still
unconfirmed” and says that restarting the app recovers, and the package and CLI executors no longer
record a false “abandoned” entry when the abandon lands inside the pipe-drain grace window
(#101 / PR #102); and the **README was rewritten for non-technical users** (#103 / PR #104).

The app in the ZIP is **ad-hoc signed and not notarized**: there is no Developer ID certificate and no
Apple notarization, so Gatekeeper blocks a plain double-click and the user has to approve this app
explicitly. This release has no Intel support, no SLA, **no promise that every install source can be
rolled back**, and for remote access the password authentication is **not transport encryption**.
Update verification still **does not confirm code signatures, does not confirm an official source and
does not compare package contents**.

## 发布信息

| 项目 | 值 |
| --- | --- |
| 版本（tag） | `v0.1.0-alpha.6` |
| `CFBundleShortVersionString` | `0.1.0-alpha.6` |
| `CFBundleVersion` | `6` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 应用包 | `Pi-Web-Desktop.app` |
| 架构 | arm64（Apple Silicon）；**不支持 Intel（x86_64）** |
| 最低系统 | macOS 14.0 |
| 签名 | ad-hoc（`codesign --sign -`），没有证书，`TeamIdentifier=not set` |
| 公证 | 无。Gatekeeper 默认拒绝，需要用户手动放行这一个应用 |
| 发布类型 | GitHub **prerelease**（alpha 预览） |
| 上一版 | `v0.1.0-alpha.5`（build `5`），资产仍在 Releases 中可下载 |
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

## alpha.6 相对 alpha.5 的新增与变更

本版本没有新增功能面，只有三处修复/文档改动。三个提交的日期均为 **2026-09-20**，本版本是它们的
第一个对外构建；`v0.1.0-alpha.5` 已有的行为与能力边界见
[alpha.5 Release 说明](release-notes-v0.1.0-alpha.5.md)。

### 1. 设置窗口可以自由缩放，表单滚动而底部按钮固定在视口（#99 / PR #100）

- 窗口现在是可缩放的：风格掩码加入 `.resizable` / `.miniaturizable`
  （`Sources/PreferencesWindowController.swift:229`），设置 `contentMinSize`
  （`:233`）并启用窗口位置的自动保存（`:238`）。
- 表单放进滚动视图，**底部按钮固定在窗口底部**，窗口变小时不会被表单挤出屏幕。
- 说明文字与行内标签随宽度折行；输入框的最小宽度为 200pt
  （`Sources/PreferencesWindowController.swift:10`），因此最小可用宽度由“表单列”决定，而不是由
  某一行最长文本决定。
- 行为说明同步到 [设置与工作区](settings-and-workspace.md)。

本项只改 UI 布局：没有改变任何配置项的取值范围、存储位置或权限语义。

### 2. 更新失败语义、放弃等待门闩与排水宽限窗口（#101 / PR #102）

这是 `v0.1.0-alpha.5` 发布说明里列出的三条遗留（#16；同一批问题也收在 #92 / #93 的复核记录中）。
本版修的是**用户可见语义**，不是新增更新能力：

- **失败文案不再断言“仍在使用旧版本”**：安装命令失败只能证明“这一次没有执行回滚动作”，不能证明
  旧文件没有被改动。三条路径现在写“更新失败，没有执行任何回滚动作：…”，与扩展包一路（本就在
  `v0.1.0-alpha.5` 改过）一致：`Sources/PiCLIUpdateAdapter.swift:1025-1026`、
  `Sources/PiWebUpdateAdapter.swift:1310-1311`、`Sources/PiPackageUpdateAdapter.swift:1507-1508`。
- **扩展包执行器的忙拒绝被拆成两种**：新增
  `PiPackageUpdateRefusal.executorBusyAwaitingAbandonedChildExit`
  （`Sources/PiPackageUpdateAdapter.swift`）与结果字段 `awaitingAbandonedChildExit`。当门闩是
  “上一次更新已放弃等待、但还不能确认它已退出”时，提示会说明这一点，并给出与 CLI / Web 入口同款
  的“重启应用可恢复”恢复路径，而不是笼统地说“执行器忙”。
- **排水宽限窗口内不再写不实的“已放弃等待”记录**：子进程已经退出、只是还有后台子进程持有管道
  写端时，`abandon()` 不再记录一条“已放弃等待”的历史。包侧与 CLI 侧都加了守卫
  （`Sources/PiPackageUpdateAdapter.swift`、`Sources/PiCLIUpdateAdapter.swift`）；CLI 的超时排期补上
  同型守卫与有界让出（超时重试用例有次数上限），`pipeDrainGrace` 改为可注入以便确定性测试。
- **测试**：本版新增 5 个确定性用例（`PiWebDesktopTests/PiPackageUpdateAdapterTests.swift` 94 行、
  `PiWebDesktopTests/PiCLIUpdateAdapterTests.swift` 59 行），覆盖“子进程正常退出胜过排水宽限超时”
  与“abandon 落在排水窗口”两类竞态。
- **没有改变的能力边界**：信号语义不变（Pi Web 只对自己启动的独立进程组发一次 `SIGTERM`；
  Pi CLI 与扩展包不发任何信号）；不确认被放弃的进程是否结束；仍不保证所有来源都能回滚。其余同类
  问题见下文“已知问题”。

### 3. README 重写为面向普通用户的说明（#103 / PR #104）

- `README.md` 从 223 行 / 24,824 字节改为 **128 行 / 10,225 字节**，内容改为“这个应用是什么、怎么装、
  第一次启动会看到什么、依赖怎么装、更新与回退的边界、遇到问题去哪里说”；构建、审查、发布与
  安全边界的细节留在 `docs/` 与 `SECURITY.md`。
- 本次只改文档，不改代码。

### 4. 文档与仓库同步

- 随上述改动同步：`docs/architecture.md`、`docs/releasing.md`、`docs/settings-and-workspace.md`。

### 5. 本版的安全审查（delta）

本版新增并提交了一份**只读的 delta 安全评审**：[v0.1.0-alpha.6 安全评审](security-review-alpha.6.md)，
范围是 `git diff d6fa883..8b591c9`（本版三个提交）。结论：**阻断项 0**；1 条中危、5 条低危、5 条信息级。
中危项（M-1）是同一个失败弹窗里仍会出现互斥的两句话（`Sources/UpdateTransaction.swift:394` 保留
「更新失败，仍在使用旧版本」，而 `:732-734` 已经是「更新失败，没有执行任何回滚动作」），已列入
[#106](https://github.com/Su-luoya/pi-web-desktop/issues/106)。低危项包括：三路**日志**仍写「旧版本保持
不变」；`detectedVersion == nil` 时验证失败句内不自洽；CLI 的「更新进行中」文案独缺恢复提示；超时重试
上限（1 s）之后仍可能落一条有界的失实「已放弃」记录；扩展包 runner 退出时不 `abandon()`，因此重启
恢复可能与仍在运行的旧 `npm` 子进程重叠。报告写明其性质是**自动化只读审查，不是人工审计**：未编译、
未运行测试、未运行 GUI，属于推断的地方都已标注。

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
| 应用包身份 | 本机脚本构建产物实测 `CFBundleShortVersionString=0.1.0-alpha.6`、`CFBundleVersion=6`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon`；`./Scripts/check-identity.sh` → `check-identity: PASSED (45 checks)` | `Configuration/AppIdentity.xcconfig`；`./Scripts/build.sh` 后用 `./Scripts/check-identity.sh` 与 `plutil -p` 复核（Xcode 构建产物与 `.xctest` bundle 仍由 CI 覆盖，本机没有 Xcode） |

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
本节在发布前由协调者填入 workflow 产物的实际值；本机演练值只用于追溯，**不用于发布核对**。

- 资产：`{{ZIP_NAME}}`（按命名规则预期为 `Pi-Web-Desktop-0.1.0-alpha.6+build.6.zip`；以及同前缀的
  `.sha256`、证据 Markdown，名称以 Release assets 为准）
- 字节数：`<发布后由协调者填写>`（本机演练值为 1,510,257 字节，仅供追溯）
- SHA-256：`<发布后由协调者填写>`（本机演练值为 `febf404bfe907b9ea676c782cab0dfedca17938e09c5e163c7f3f6f2880ccb89`，仅供追溯）
- 校验命令（下载目录执行）：

  ```bash
  shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.6+build.6.zip.sha256
  ```

- 校验失败时不要安装，请在 Release Issue 或普通 Issue 中报告。
- **不要使用本机演练值当发布值**：发布值由 `release.yml` 在 tag 上运行
  `Scripts/package-release.sh` 生成，写在 `dist/release-metadata.env`（`ZIP_NAME` / `SHA256` /
  `COMMIT`）里；Release 草稿的正文与 checksum 必须从该 workflow 产物复制。

## 构建与签名验证记录（本机演练）

**本版在提交前的同一工作区上跑了一遍本机门槛**：`sh -n`、空白检查、脚本构建、身份检查、tag/版本
比对、`codesign` 验签与 `-dv`、`spctl`、`smoke.sh` 两种模式、秘密扫描（自检 + 仓库扫描）、打包与
ZIP/checksum/解包复验。下表是本次的实际输出。与 alpha.5 不同，本次演练在 `~/Documents`（iCloud 同步
目录）**之外**的 worktree（`~/orca/workspaces/Pi-Web/release-alpha-6`）里执行，因此没有再遇到
iCloud File Provider 贴回 `com.apple.FinderInfo` 的问题。`xcodebuild build` / `xcodebuild test`、
GUI 手工验收、真实更新执行仍不在本机范围内。

| 命令 | 结果 |
| --- | --- |
| `sh -n Scripts/*.sh` | 退出 0（无输出） |
| `git diff --check` | 退出 0（无输出） |
| `sh Scripts/check-release-version.sh v0.1.0-alpha.6` | `check-release-version: PASSED (tag v0.1.0-alpha.6, MARKETING_VERSION 0.1.0-alpha.6, CURRENT_PROJECT_VERSION 6)`。脚本只做字符串比对，**不检查 git tag 是否存在**（本次 tag 尚未创建） |
| `./Scripts/build.sh` | 退出 0：`Built: build/Pi-Web-Desktop.app`、`Contents/MacOS/PiWebDesktop: Mach-O 64-bit executable arm64` |
| `./Scripts/check-identity.sh` | `check-identity: PASSED (45 checks)`；包内 `CFBundleShortVersionString=0.1.0-alpha.6`、`CFBundleVersion=6`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`LSMinimumSystemVersion=14.0`、`CFBundleIconFile=ApplicationIcon`；并断言 `no hardcoded MARKETING_VERSION outside Configuration/AppIdentity.xcconfig` |
| `codesign --verify --deep --strict build/Pi-Web-Desktop.app` | 退出 0（`valid on disk` / `satisfies its Designated Requirement`，无输出） |
| `codesign -dv --verbose=4 build/Pi-Web-Desktop.app` | `Identifier=io.github.su-luoya.pi-web-desktop`、`Format=app bundle with Mach-O thin (arm64)`、`flags=0x2(adhoc)`、`Signature=adhoc`、`TeamIdentifier=not set`、`Sealed Resources version=2 rules=13 files=1` |
| `spctl -a -vv build/Pi-Web-Desktop.app` | 输出 `rejected`（退出 3）：未公证 ad-hoc 产物的预期结果 |
| `./Scripts/smoke.sh` | 退出 0。启动模式：app exit 0 after 1s、标记 `smoke: ready`；诊断模式：app exit 0 after 0s、标记 `smoke: diagnostics items=6 blockers=3` 与 `smoke: diagnostics ready` |
| `./Scripts/scan-secrets.sh --self-test` | 退出 0：`self-test: PASS (all rules fired, look-alikes stayed clean, suppression and rejection verified, untracked-file gate verified, samples cleaned up)` |
| `./Scripts/scan-secrets.sh` | 退出 0：`scan-secrets: suppressed 15 lines`、`scan-secrets: PASS (no matches in tracked files; no untracked files)`。suppressed 行数与 alpha.5 记录一致（15 行，均为测试夹具的内联 `allow(reason=…)` 豁免） |
| `./Scripts/package-release.sh --tag v0.1.0-alpha.6` | 退出 0：`package-release: OK`，产出 `Pi-Web-Desktop-0.1.0-alpha.6+build.6.zip` 及 `.zip.sha256` / `.evidence.md` / `release-metadata.env`（`VERSION=0.1.0-alpha.6`、`BUILD=6`、`COMMIT=8b591c966e05a5f9b37de76f0fb11abc37be56fa`）。ZIP 1,510,257 字节、SHA-256 `febf404bfe907b9ea676c782cab0dfedca17938e09c5e163c7f3f6f2880ccb89`（**演练值**）；脚本同时复验了“包内条目固定修改时间”“归一化时间后签名仍通过”“白名单条目集合一致（无 `__MACOSX/`）” |
| `unzip -l`（演练 ZIP） | 9 项：`Pi-Web-Desktop.app/` 及其 `Contents/{,_CodeSignature,MacOS,Resources}`、`Contents/Info.plist`、`Contents/MacOS/PiWebDesktop`、`Contents/Resources/ApplicationIcon.icns`、`Contents/_CodeSignature/CodeResources`；无 `__MACOSX/`，无源码、测试、日志或个人路径 |
| `shasum -a 256 -c`（演练 ZIP） | `Pi-Web-Desktop-0.1.0-alpha.6+build.6.zip: OK`（退出 0） |
| `ditto -x -k` + `plutil -p` + `codesign --verify --deep --strict` | 解压到 `mktemp -d` 后：`CFBundleShortVersionString=0.1.0-alpha.6`、`CFBundleVersion=6`、`LSMinimumSystemVersion=14.0`、`CFBundleIdentifier=io.github.su-luoya.pi-web-desktop`、`CFBundleIconFile=ApplicationIcon`；解压出的 bundle 签名校验退出 0（临时目录已删除） |
| `xcodebuild build` / `xcodebuild test` / GUI 手工验收 / 真实更新执行 | 本机未执行：`xcode-select -p` → `/Library/Developer/CommandLineTools`，没有 Xcode；GUI 手工验收与真实更新执行本轮未执行。由 CI 的 `macos-14` job 与维护者真机验收覆盖 |
| CI（`main` 上的三个提交） | `build.yml`：`3306398`（#100）run `35493841592`、`a47dd46`（#102）run `35494635211`、`8b591c9`（#104）run `35494836484`，均为 **success**；覆盖 `xcodebuild build` / `xcodebuild test`、`build.sh`、`check-identity.sh --test-bundle`、`smoke.sh`、秘密扫描与 `sh -n Scripts/*.sh` 等 |

**演练值的工作区状态（如实记录）**：这次本机打包发生在“版本 bump 已写入工作区、但发布提交尚未
创建”的状态下，`release-metadata.env` 的 `COMMIT` 记的是打包时的工作区 `HEAD`（`8b591c9`，即
`v0.1.0-alpha.5` 之后、本说明所在的发布提交之前）。因此演练 ZIP **不等于**发布资产；发布资产由
`release.yml` 在 `v0.1.0-alpha.6` tag（即发布提交）上重新打包，名称、字节数与 SHA-256 一律以
workflow 产物为准。

`./Scripts/smoke.sh`（在 CI 中）只验证窗口、诊断页与退出路径：两种模式都在临时 support 目录里
运行，不写真实 UserDefaults / Application Support / Logs，也不启动真实 pi-web；它不替代
`xcodebuild test`。

## 已知问题

- **本版 delta 安全评审的非阻断发现**（见 [安全评审](security-review-alpha.6.md)）：`Sources/UpdateTransaction.swift:394`
  与同一弹窗的新文案互斥（M-1，中危）、三路日志仍写「旧版本保持不变」（L-1）、`detectedVersion == nil`
  时验证失败句内不自洽（L-2）、CLI 的「更新进行中」文案缺「重启应用可恢复」（L-3）、超时重试上限之后
  仍可能落一条有界的失实「已放弃」记录（L-4）、扩展包 runner 退出时不 `abandon()` 导致重启恢复可能与旧
  `npm` 子进程重叠（L-5）。这些不影响文件操作、进程信号与权限语义，分别在
  [#106](https://github.com/Su-luoya/pi-web-desktop/issues/106) / [#107](https://github.com/Su-luoya/pi-web-desktop/issues/107) / [#108](https://github.com/Su-luoya/pi-web-desktop/issues/108)
  中跟踪。
- **更新执行器审查的剩余条目（W2B，本版只修了 B-6 的 CLI/Web 两路与三条 #16 遗留）**：
  B-4、B-5、B-8 … B-13 仍未修，已按范围分别登记为
  [#105](https://github.com/Su-luoya/pi-web-desktop/issues/105)（验证器边界）、
  [#106](https://github.com/Su-luoya/pi-web-desktop/issues/106)（降级状态与文案）、
  [#107](https://github.com/Su-luoya/pi-web-desktop/issues/107)（扩展包执行器）、
  [#108](https://github.com/Su-luoya/pi-web-desktop/issues/108)（输出与放弃等待窗口），计划在下一版处理。
- **应用自更新审查的剩余条目（W2A）**：**F5**（分块切断多字节 UTF-8 序列时诊断文本里会出现 U+FFFD
  替换字符）、**F6**、**F7** 未处理，登记在 [#108](https://github.com/Su-luoya/pi-web-desktop/issues/108)。
- **安装失败文案仍有两套（同一进程内）**：`Sources/UpdateTransaction.swift:394` 的
  `displayName` 仍是“更新失败，仍在使用旧版本”，而同一文件 `:513` 的持久警告写“本次没有执行任何
  回滚动作”；本次只统一了 CLI / Web / 扩展包三路。登记在
  [#106](https://github.com/Su-luoya/pi-web-desktop/issues/106)。
- **Web 更新执行器的同类排水窗口竞态仍在**：`Sources/PiWebUpdateAdapter.swift` 的
  `stopWaitingLocked` 仍会在“放弃等待”落在排水宽限窗口时写记录（CLI 与扩展包两路本版已修）。
  登记在 [#108](https://github.com/Su-luoya/pi-web-desktop/issues/108)。
- **扩展包执行器的读状态接口仍缺 `isRunning`**：协议 `PiPackageUpdateRunning`
  （`Sources/PiPackageUpdateAdapter.swift`）只有 `run` 与 `abandon`；调用方无法查询“是否忙”。
  本版已让“忙”的拒绝原因区分“已放弃等待、退出未确认”，但扩展包菜单项仍按依赖门控决定是否可点，
  可能出现“点了才提示”。登记在 [#107](https://github.com/Su-luoya/pi-web-desktop/issues/107)。
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

1. 保留上一版的 ZIP 与它的 `.sha256`。回退时解压上一版（`v0.1.0-alpha.5`，资产仍在 Releases 中）
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

## 发布时需要补全的值清单（协调者，发布前删除本节）

1. `{{ZIP_NAME}}`（出现于“校验值”一节）→ 按命名规则预期为
   `Pi-Web-Desktop-0.1.0-alpha.6+build.6.zip`，以 Release assets 为准。
2. 发布产物的字节数与 SHA-256 → 取 workflow 产物 `dist/release-metadata.env` 的 `ZIP_NAME` /
   `SHA256`，替换“校验值”一节的 `<发布后由协调者填写>` 两行；本文件里的
   `1,510,257` 与 `febf404b…` 是**本机演练值，不要当作发布值**。
3. 证据 Markdown 的文件名与其中的 `codesign` / `spctl` 摘要 → 与 workflow 产物核对，以 workflow
   产物为准。
4. 发布完成后，把 Release 页面上的实际 SHA-256 与字节数回填到“校验值”一节，并删除本节。
