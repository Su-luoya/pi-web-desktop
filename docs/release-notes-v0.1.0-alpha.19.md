# Pi Web Desktop 0.1.0-alpha.19（build 19）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.19` 面向 Apple Silicon（arm64）与 **macOS 26 或更高版本**。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版是一次**界面与更新链路的整理发布**，包含一处用户可见的功能删除、一个真实的功能缺陷修复，以及若干减少说明文字的界面调整。

**破坏性变更：访问密码功能整体删除。** 之前设置过访问密码的用户，升级后远程访问不再要求密码。详见下节。

## 破坏性变更：删除访问密码

`Sources/Services/KeychainStore.swift` 整体删除（611 行），`PiWebDesktopTests/KeychainStoreTests.swift` 一并删除（616 行）。随之移除：

- 设置窗口的「远程访问密码」输入、生成、保存与删除；
- 启动 `pi-web` 时注入的 `PI_WEB_PASSWORD` 环境变量；
- `ServiceManager` 中与密码状态相关的公开接口与用户可见提示。

**行为变化**：监听地址设为非 loopback（例如具体的局域网地址）时，应用不再要求先设置密码，而是直接以 `pi-web` 的默认行为启动 —— `pi-web` 自身在缺少 `PI_WEB_PASSWORD` 时会打印一行警告并继续运行。也就是说，**明文 HTTP 上的远程访问现在没有任何认证**。

删除理由：这套密码只是把 `PI_WEB_PASSWORD` 转交给 `pi-web` 进程，应用自身不参与校验，也不改变传输层；它提供的唯一实际保护是"知道密码才能打开页面"，而在明文 HTTP 上这层保护既挡不住同网络抓包，也挡不住直接访问端口。维护一个 611 行的 Keychain 封装去传递一个 `pi-web` 本来就支持的字符串，收益不足以抵消复杂度与"看起来安全其实不安全"的误导。

**替代方案**：需要远程访问时，在应用之外套 HTTPS 反向代理或加密隧道（SSH 端口转发、Tailscale、Cloudflare Tunnel 等）。应用内的界面文案已改为提示这一点，不做静默放行。非 loopback 监听地址仍然允许，只是不再有凭证门控。

上一版 `v0.1.0-alpha.18` 的资产仍然保留，回退会带回密码功能。

## 缺陷修复：Pi CLI 自动更新开关完全失效

`Sources/Updates/UpdateSettingsWindowController.swift`：`autoUpdatePiCLIButton`（标题「启动前自动更新 Pi CLI」）创建后从未设置 `target` / `action`，只有并排的 `autoUpdateButton` 设置了。点击时 `NSButton` 会自己翻转 `state`，但没有任何代码把它写进偏好；窗口下一次刷新就把状态抹回去。

用户看到的现象是"这个开关点了没反应"——**从该开关加入以来从未生效过**。两个标题相似的开关并排，漏接其中一个不会产生任何编译错误，也没有运行时断言。

修复：补上 `target` / `action`，两个开关各自接到 `autoUpdateChanged(_:)` 与 `autoUpdatePiCLIChanged(_:)`。

**注意**：这个修复不会补写之前丢失的设置。之前点过但未生效的那次操作没有留下记录，升级后该开关仍是关闭状态，需要手动勾选一次。

## 更新链路：中间结果不再污染手动检查

`Sources/App/AppDelegate+UpdateChecks.swift`：`handleUpdateCheckResults` 在 Pi CLI 受限自动更新（GitHub #21）判定后缺少 in-flight 守卫。

推迟路径（检测到运行中的 Pi 进程）会在同一个回调里立刻再次发起检查，于是 `handleUpdateCheckResults` 会二次进入。缺少守卫时，中间结果会参与 `notifyAboutAutomaticUpdates` 弹框，并清掉 `pendingManualUpdateCheck` —— 用户主动点「检查更新 Pi CLI」反而可能拿不到结果窗口。

`Sources/Updates/UpdateChecker.swift`：`preferences` 变更后立即执行一次 `checkIfDue(triggeredBy: .scheduled)`。此前把某一类检查从「关闭」改为开启后，新建的周期计时器从现在起算，用户要等满一整个周期才可能看到当前版本。现在打开后立刻补一次到期检查；没有到期对象时是空操作。

## 界面：减少说明文字

用户反馈「服务栏各种东西非常混乱、不清晰，说明文字太多」。本版按"设置里只留结论，细节归诊断页"的原则收敛：

**菜单**：更新相关命令从「服务 →」二级子菜单提升为顶层「更新」菜单。菜单项在命令进行中或上一次更新退出未确认时置灰并加后缀说明（GitHub #107：「（正在更新）」/「（上一次更新未确认退出，重启应用可恢复）」）。

**偏好设置窗口的状态行**：新增 `UpdateStatusPresenter.shortLine`。此前每类组件的状态行是完整诊断信息，四类叠起来是一段读不完的说明文字：

| 此前（每类一行） | 现在（每类一行） |
| --- | --- |
| 策略：每天 · 最近检查：10月24日 21:40 · 被忽略版本：无 · 下次检查：10月25日 21:40 · 结论来源：本次响应 | 最新 · 上次检查 10月24日 21:40 |

被忽略版本、下次检查时间、缓存来源与失败分类（含 HTTP 状态码）移入诊断页；策略由同一行的下拉框展示，不再重复成文字。失败的类别仍补一次可读原因（如「失败 · 上次检查 … · 网络不可用」），但不再出现状态码。已关闭的类别只显示「已关闭」，不再残留旧结论——关掉之后还显示「可更新」只会让人以为有待处理的更新。

**复选框标题**：只留动作本身（「启动前自动更新 Pi Web」/「启动前自动更新 Pi CLI」），生效范围移到下面一行提示（「仅对已验证的 npm 全局安装生效；其它来源只提示，不安装。」）。分组标题去掉「（受限）」「（不做无人值守更新）」这类与提示行重复的限定。

## 界面：两个设置窗口支持自由缩放

`Sources/App/PreferencesWindowController.swift`、`Sources/Updates/UpdateSettingsWindowController.swift` 此前用固定尺寸且 `styleMask` 缺少 `.resizable`，无法像主窗口一样拖拽缩放。

现在两个窗口都可缩放，`contentMinSize` 取自共享的 `SettingsFormMetrics`（新增 `Sources/App/SettingsFormViews.swift`）；内容超出视口时由 `NSScrollView` 承担，不靠撑大最小高度。主窗口、偏好设置、更新检查偏好设置三个窗口的缩放行为因此一致。

`PiWebDesktopTests/AppMenuHygieneTests.swift` 新增 5 条断言覆盖窗口样式位、最小尺寸、滚动兜底与最小宽度下限。

## 测试

- 总数 953 → **919**（净减少 34：密码功能带着整个 `KeychainStoreTests.swift` 一起删除）。
- `AppMenuHygieneTests.swift`：+5（窗口可缩放、最小尺寸来源、垂直滚动、最小宽度下限、设置窗口注册）。
- `UpdateSettingsTests.swift`：+4（`shortLine` 的结论/时间、从未检查、已关闭、失败原因四个分支）。其中一条用例先失败过：初版 `shortLine` 在无记录时输出「尚未检查 · 尚未检查」，说明 `resultTitle` 已覆盖该分支，代码据此收敛。
- `DesktopAppUpdateTests.swift`：+1（`testSha256DetectsMismatchedDownloadBytes`，覆盖 SHA-256 校验失败路径；`sha256(of:)` 因此从 `private` 提到 `internal`）。
- 删除：`KeychainStoreTests.swift` 整个文件（616 行，随着密码功能一起移除）。
- `ServiceManagerTests.swift`、`ServiceAddressesTests.swift`、`DiagnosticsCollectorTests.swift`、`ToolPathTests.swift`：随密码与监听地址逻辑调整更新断言。

## 目标平台与安装

| 项目 | 值 |
| --- | --- |
| CPU | Apple Silicon（arm64）；不支持 Intel（x86_64） |
| 最低系统 | macOS 26.0 |
| 应用包 | `Pi-Web-Desktop.app` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 签名 | ad-hoc；没有 Developer ID 证书 |
| 公证 | 无 |

ZIP 下载后请先使用配套的 `.zip.sha256` 校验，再将应用放入 `~/Applications` 或 `/Applications`。不要为了运行本 alpha 关闭 Gatekeeper；首次打开时在 Finder 中右键选择"打开"，或在"系统设置 → 隐私与安全性"中针对该应用放行。

应用不打包 Node.js、Pi CLI 或 `@agegr/pi-web`，这些依赖需要用户自行安装。应用内桌面自更新仍只允许用户确认后执行，并且只支持位于 `/Applications/Pi-Web-Desktop.app` 的安装；它不是无人值守更新，也不提供新版本启动失败后的自动回滚。自更新会读取候选包的 `LSMinimumSystemVersion`，版本高于本机时停止安装并保留旧安装（alpha.18 引入）。

## 验证

- 本地 `xcodebuild test`：919 个测试，0 失败；
- `./Scripts/build.sh`：成功，`LSMinimumSystemVersion=26.0`，`CFBundleShortVersionString=0.1.0-alpha.19`，`CFBundleVersion=19`；
- `./Scripts/check-identity.sh`：`PASSED (45 checks)`；
- `./Scripts/check-release-version.sh`：`PASSED`（`CURRENT_PROJECT_VERSION=19` 与 `MARKETING_VERSION=0.1.0-alpha.19` 的推导规则一致）；
- `./Scripts/smoke.sh`：两种模式均 OK；
- `./Scripts/scan-secrets.sh`：PASS；
- `sh -n Scripts/*.sh`、`git diff --check`：通过；
- CI：`build` workflow 在 `macos-26` runner 上通过（含 `xcodebuild test`、身份校验、个人数据检查、secret 扫描自检、smoke 启动与打包）。

## 变更边界

本版删除了一个功能（访问密码），没有新增第三方 Swift 包或 npm 运行时依赖。未新增 UserDefaults 键。信任边界有一处变化且方向是**放松**：非 loopback 监听不再有应用层凭证门控，明文 HTTP 上没有认证。更新事务链、`/Applications` 写权限探针、解压器路径处理、信号处理语义均未改动。

自动更新仍使用既有的 GitHub / npm 检查与发布边界，不把同源 SHA-256 校验描述成开发者身份验证。

## 回退

保留上一版 `v0.1.0-alpha.18` 的 ZIP 与 checksum。若本版应用不可用，手动解压上一版并替换应用包；应用没有系统级常驻组件。

回退到 alpha.18 会带回访问密码功能；此前保存的密码已从 Keychain 删除（本版不再读它，也没有迁移逻辑），需要重新设置。同时回退会丢掉本版的 Pi CLI 自动更新开关修复与窗口缩放。

## 已知限制

- ad-hoc、未公证，首次手动安装需要用户放行；
- 非 loopback 访问是明文 HTTP 且**没有认证**（本版起不再有密码）；只能放在可信网络，或由用户自行套 HTTPS 反向代理 / 加密隧道；
- Pi CLI 自动更新开关的修复不会补写此前丢失的设置，需要手动勾选一次；
- 桌面应用自更新仅支持 `/Applications`，需要用户确认；
- 自更新失败会保留旧安装，但新版本安装后启动失败不会自动回滚；
- GUI 菜单与设置窗口的观感只有源码级断言覆盖（窗口样式位、最小尺寸、滚动兜底），没有自动化真机截图比对；
- `Sources/Diagnostics/` 尚未做过独立审计；
- 解压器对恶意归档路径的处理与 `/Applications` 写权限探针的 TOCTOU 属继承项，本轮未重新审计；
- `flock` 在网络家目录（NFS / SMB）上的语义未测试；
- alpha 版本不提供 SLA。
