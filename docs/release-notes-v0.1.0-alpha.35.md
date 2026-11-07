# Pi Web Desktop 0.1.0-alpha.35（build 35）— Apple Silicon alpha（未公证）

## 摘要

本版没有功能扩张：一类是原生菜单与窗口向 macOS 惯例看齐，一类是不改变行为的内部收敛（删除重复的版本判定与不再被调用的助手）。更新检查、手机访问、依赖检测的行为都没有变化。

- **菜单栏缺「文件」菜单。** 只有「编辑 / 窗口 / 帮助」，没有 macOS 惯例的「文件」：⌘N 新建窗口在「窗口」菜单里，⌘W 根本不存在。
- **「窗口」菜单里 ⌘N 挂在错误的位置。** 同一快捷键既出现在「窗口」，也重复登记在窗口列表项上。
- **诊断窗口的按钮散落在分组之间。** 「复制诊断 / 关闭 / 继续」夹在滚动内容里，窗口一短按钮就被挤到看不见的地方；超长分组标题在窗口变窄时被整段省略。
- **更新相关窗口在窄宽度下截断。** 进度窗口的标题、状态与已用时长没有截断策略；更新检查偏好设置的底部按钮随内容滚动。
- **重复的版本判定与未使用助手。** `updateVerified` / `versionReached` 在四个类型里各转发一层，`allowsAutomaticExecution` 与三处诊断格式化助手已经没人调用。

## 1. 菜单栏补齐「文件」菜单

### 现象

应用菜单栏是「Pi Web Desktop / 编辑 / 窗口 / 帮助」，没有「文件」。⌘N 出现在「窗口」菜单里，⌘W 没有任何入口，与 macOS 的默认键盘习惯相反。

### 原因

窗口菜单与「新建窗口」项是分两批加进来的，快捷键登记在「窗口」菜单上，而「文件」菜单从未建立。

### 做法

新增「文件」菜单，按 macOS 惯例承载「新建窗口 ⌘N」与「关闭窗口 ⌘W」（`NSWindow.performClose`，走窗口本身的处理链）；「窗口」菜单里重复的 ⌘N 去掉；「设置…」从「帮助」上方移到「关于」下方。

### 验证程度

`AppMenuHygieneTests` 新增 `testFileMenuOwnsNewAndCloseWindowShortcuts`：断言「文件」菜单占用 ⌘N 与 ⌘W、⌘N 在整个菜单树里只被登记一次、「窗口」菜单不再有「新建窗口」。菜单的视觉顺序没有自动化测试。

## 2. 诊断窗口的按钮归位，底部固定

### 现象

依赖与环境诊断窗口把动作按钮放在表单里「继续」和「复制诊断」两个行上，表单一旦长过窗口高度，按钮就被滚出可视区；分组标题（例如「Pi 与 @agegr/pi-web 版本」这类长标题）在窄窗口里被整段省略，用户看不到检查项在说什么。

### 做法

动作按钮移到底部固定栏（分隔线下方，不随表单滚动），表单整体放进滚动视图并设最小尺寸 680×480；长分组标题拆成短标题加一行换行说明；表格行高 28、列宽随窗口伸展、等宽文本 12pt；进度条、日志与阶段符号补上 VoiceOver 标签。

### 验证程度

没有自动化测试：`DiagnosticsWindowController` 不在测试 target 内（需要真实 `NSApplication`）。本机手工打开诊断窗口核对过分组、按钮位置与滚动，未逐项核对 VoiceOver 朗读。

## 3. 更新检查偏好与更新进度窗口的排版

### 做法

- 更新检查偏好设置：底部按钮移到分隔线下方固定，内容区自己滚动，分组间距 20pt，说明文字 12pt。
- 更新进度窗口：标题、状态与已用时长加截断与 tooltip，进度条与日志补辅助功能标签，日志 12pt。
- 设置窗口：字段与「选择…」按钮补辅助功能标签。

### 验证程度

同为手工点验，无自动化测试。

## 4. 内部收敛：判据只留一处（无行为变化）

- `PiCLIUpdatePlanner` / `PiPackageUpdatePlanner` / `PiWebUpdateCoordinator` 里的 `updateVerified`、`versionReached` 转发层删掉，判定只剩 `UpdateVerifier.versionReached`；测试改为直接断言它。
- `UpdateAbandonedAttemptGate.allowsAutomaticExecution` 删掉，调用方改写为 `blockingAttempt(...) == nil`。
- 删除不再被调用的 `DependencyReportPresenter.diagnosisText`、`ProcessInspector.listenerPIDDescription` / `listenerProcessDescription`、`LoginShellResolver.shellPath`、`UpdateAutomationBoundary`、`UpdateCheckPreferences.autoUpdateBeforeLaunchIsEffective`。
- `WebViewController` 去掉只为兼容旧调用点保留的 `servicePort` 参数，导航判定只读 `serviceURL`。
- README 与 `docs/architecture.md`、`docs/development.md`、`docs/privacy.md` 同步到现状：appcast 优先、预下载不安装、应用包「未经过 Developer ID 签名」。

### 验证程度

行为等价由现有更新流程测试覆盖；`./Scripts/test.sh` 1040 tests, 0 failures。

## 真机实测环境

| 项 | 值 |
| --- | --- |
| 机器与芯片 | Mac16,10 / Apple M4 |
| macOS | 27.2（26B123） |
| 架构 | arm64 |
| Node.js | v26.13.0 |
| Pi（`@earendil-works/pi-coding-agent`） | 1.5.0 |
| `@agegr/pi-web` | 0.15.0（`/opt/homebrew/bin/pi-web` → `/opt/homebrew/lib/node_modules/@agegr/pi-web`，Homebrew 前缀下的全局安装） |
| `./Scripts/test.sh` | 1040 tests, 0 failures |
| `./Scripts/smoke.sh` | 启动模式与诊断模式均 exit 0（`items=6 blockers=3` 来自 `DiagnosticsSmokeFixture` 的确定性样例，不是本机依赖缺失） |
| `./Scripts/check-identity.sh` | PASSED（45 checks） |
| `./Scripts/scan-secrets.sh` | PASS（无匹配、无未跟踪文件；17 行测试夹具按规则抑制） |

## 未变的部分

- 更新通道仍然是 `appcast` 优先、GitHub API 回落；访问域名、脱敏与日志边界都没有改动。
- 下载缓存仍然是「只留一个发布包」，读取时重新核对 SHA-256 之后才交给安装流程。
- 应用内更新仍然只由用户点击触发，没有无人值守路径，也没有降级路径。
- 手机访问仍然只做 serve、不做 funnel，仍然没有访问密码：唯一的边界是 tailnet 身份。
- 依赖检测的检查项与判定阈值没有改动，只有窗口排版变了。

## 已知问题

- 第 1–3 项是排版与菜单结构改动，只有菜单契约有单元测试；诊断窗口与进度窗口的布局没有自动化测试，靠手工点验。
- 诊断窗口的 VoiceOver 标签是本次新增，但没有用屏幕阅读器逐项朗读验证。
- 第 4 项是内部收敛，没有单独的行为测试：等价性由既有更新流程测试间接覆盖，没有做前后版本的差分对比。

## 发布资产

| 资产 | 值 |
| --- | --- |
| ZIP | `Pi-Web-Desktop-0.1.0-alpha.35+build.35.zip` |
| SHA-256 | 见发布说明的「校验」段（CI 重新构建，发布后回填本文件） |
| 签名 | ad-hoc（`TeamIdentifier=not set`），未公证 |
| 最低系统 | macOS 26.0 |
| 架构 | arm64（Apple Silicon） |

本地演练（`./Scripts/package-release.sh --tag v0.1.0-alpha.35`）的产物是
`9e46d6b8429aa8c682f4cae17eb21afe47b99b4a6d700e6e3439fe356fc31e55`，1739994 字节，
只用于发版前自检；用户下载的是 workflow 重新构建的那一份。

校验方式：

```sh
shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.35+build.35.zip.sha256
```
