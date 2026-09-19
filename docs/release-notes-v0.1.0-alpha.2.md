<!--
docs/release-notes-v0.1.0-alpha.2.md — v0.1.0-alpha.2 草稿 Release 的正文。

可以直接粘贴为 GitHub Release 说明（本注释在 GitHub 上不渲染）。发布前必须：
  * 把“校验值”一节的 `<见 Release assets>` 换成草稿资产里实际的 SHA-256；
  * 核对资产名称、版本与 build 和草稿一致；
  * 不要在本文件或发布说明里声称“已签名”“已公证”，也不要指导关闭 Gatekeeper；
  * 不要写入主机名、用户名、凭据、代理端点或真实用户绝对路径。

相关文档：[发布流程](releasing.md)、[Alpha 发布门槛清单](alpha-release-checklist.md)、
[Release notes 模板](release-notes-template.md)、[alpha.1 安全与发布审查](security-review-alpha.1.md)、
[v0.1.0-alpha.1 Release 说明](release-notes-v0.1.0-alpha.1.md)。

注意：当前 `.github/workflows/release.yml` 渲染的是 `docs/release-notes-template.md`，不会读本文件；
本文件是 v0.1.0-alpha.2 的现成正文，要把实测值、已知问题与回退说明放进草稿 Release 时，在草稿
编辑页粘贴本文件并把校验值换成草稿资产的实际 SHA-256（若要改成由 workflow 渲染版本化文件，
需要单独修改 `.github/workflows/release.yml`，超出本文件的改动范围）。
-->

# Pi Web Desktop 0.1.0-alpha.2（build 2）— Apple Silicon alpha（未公证）

## 摘要 / Summary

Pi Web Desktop `0.1.0-alpha.2` 是面向 **Apple Silicon（arm64）、macOS 14 或更高版本** 的第二个
alpha 预览。它启动、监控并显示本机已安装的 Pi Web 服务，默认只监听 loopback。相对
`0.1.0-alpha.1`，本版本新增**组件版本与安装来源识别**（诊断界面与导出会标出每个组件来自
npm/pnpm 全局、Homebrew、nvm、mise、官方安装器、Git 检出还是本地路径）和**只读版本更新检查**
（桌面应用 / Pi CLI / Pi Web / Pi 扩展包四类，可分别关闭或改为每周，可忽略某个具体版本）。
更新检查只提示，**不下载、不安装、不降级**。ZIP 里的应用是 **ad-hoc 签名、未公证** 的：没有
Developer ID 证书，也没有 Apple 公证，因此 Gatekeeper 默认会阻止直接双击打开，需要用户针对这一个
应用手动放行。本版本没有 Intel 支持、没有 SLA、没有自动更新安装。

Pi Web Desktop `0.1.0-alpha.2` is the second alpha preview for **Apple Silicon (arm64) Macs
running macOS 14 or later**. It starts, monitors and displays a locally installed Pi Web service
and listens on loopback by default. Compared with `0.1.0-alpha.1` it adds **component version and
install-source identification** in the diagnostics UI/export and a **read-only version update
check** for the desktop app, Pi CLI, Pi Web and Pi packages (each class can be turned off or
switched to weekly, and a specific version can be ignored). The update check only notifies: it
never downloads, installs or downgrades anything. The app in the ZIP is **ad-hoc signed and not
notarized**: there is no Developer ID certificate and no Apple notarization, so Gatekeeper blocks
a plain double-click and the user has to approve this app explicitly. This release has no Intel
support, no SLA and no automatic update installation.

## 发布信息

| 项目 | 值 |
| --- | --- |
| 版本（tag） | `v0.1.0-alpha.2` |
| `CFBundleShortVersionString` | `0.1.0-alpha.2` |
| `CFBundleVersion` | `2` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 应用包 | `Pi-Web-Desktop.app` |
| 架构 | arm64（Apple Silicon）；**不支持 Intel（x86_64）** |
| 最低系统 | macOS 14.0 |
| 签名 | ad-hoc（`codesign --sign -`），没有证书，`TeamIdentifier=not set` |
| 公证 | 无。Gatekeeper 默认拒绝，需要用户手动放行这一个应用 |
| 发布类型 | GitHub **prerelease**（alpha 预览） |
| 上一版 | `v0.1.0-alpha.1`（build `1`），资产仍在 Releases 中可下载 |
| 本地数据位置 | UserDefaults、`~/Library/Application Support/Pi Web Desktop/`、`~/Library/Logs/Pi Web Desktop/`、Keychain、WebKit 网站数据，见[隐私说明](privacy.md) |

## 目标平台

| 维度 | 支持范围 |
| --- | --- |
| CPU | Apple Silicon（arm64） |
| 系统 | macOS 14.0 或更高 |
| Intel Mac | 不支持，也没有 x86_64 产物 |
| 依赖 | Node.js `>=22.19.0`、Pi CLI、`@agegr/pi-web`（需用户自行安装，应用不打包也不自动安装） |
| 默认服务地址 | `http://127.0.0.1:30141/`（只监听 loopback） |

## alpha.2 相对 alpha.1 的新增与变更

三个功能 Issue 都已合入 `main`（PR #49、#50、#51），本版本是它们的第一个对外构建。

### 1. 组件版本与安装来源识别（#16）

- 首次启动诊断、诊断窗口与“复制诊断”导出里的六项诊断条目，除了状态与版本，还会给出可执行文件
  路径、真实路径、**安装来源**与**可信度**；缺失值显示“未找到/未知”，不会省略整行。
- 安装来源按固定优先级推断：Homebrew Cellar → npm 全局 `lib/node_modules` → npm 前缀 `bin` →
  `~/.npm-global` → Homebrew 前缀 → 用户目录 → 未知；可信度分为“已验证 / 推断 / 未知”。
- 探测是**只读**的：只执行 `--version`、`npm root -g`、`pnpm root -g`、`pi list` 与登录 shell 的
  `command -v`，只读可执行位、符号链接和 `package.json`（最多向上 6 层），只看 `.git` 是否存在。
  不安装、不升级、不联网、不调用 `sudo`、不读 Keychain 或 Pi 认证内容。
- 只在来源为 npm/pnpm 全局且可信度为“已验证”时给出建议安装命令；其他来源只给指引文字。
- 诊断导出新增 `组件安装` 字段（脱敏后只含路径、版本、来源与可信度）。

### 2. 只读版本更新检查（#17）

- 应用启动后立即检查一次，之后四类组件各自按设置复查：桌面应用 / Pi CLI / Pi Web 默认**每日**
  （24 小时），Pi 扩展包默认 7 天。
- 只做 `GET` + JSON 解析，**不下载、不安装、不降级**；应用退出后不再检查（不安装 LaunchAgent，
  不在后台常驻）。
- 网络失败、超时、限流（429）与 5xx 会沿用有效期内的上一次成功结果并标注为缓存结果；超过有效期
  或响应无法解析时显示“无法确定”，检查失败不影响正在运行的服务。
- 菜单里新增“服务 → 检查更新…”（忽略缓存立即检查一次）与“服务 → 更新检查设置”。
- 提示使用**应用内提示框**，不使用通知中心，也不申请通知权限；自动检查对同一版本在一次运行里最多
  提示一次。

### 3. 每类检查策略、忽略版本与 alpha.3 预留位（#18）

- 四类策略都可修改：桌面应用 / Pi CLI / Pi Web 为**关闭 / 每日 / 每周**；Pi 扩展包为
  **关闭 / 检查并通知 / 询问后更新**（后两者复查节奏相同，区别只在提示文案；安装流程尚未实现）。
- **忽略版本**：可以忽略当前提示的那一个具体版本；上游发布更高版本时会重新提示。忽略只保存版本
  字符串与时间戳，不实现版本锁定，也不实现降级。
- **alpha.3 预留位**：“启动前自动更新 Pi Web（alpha.3 起生效）”默认关闭，在本版本**不产生任何
  行为**：只保存开关值，不下载、不安装、不修改任何组件，也不改变检查调度。
- 兼容旧键：GitHub #17 期间保存的布尔开关（`updateChecks.*.enabled`；`true` → 该分类的默认策略，
  `false` → 关闭）仍会被读取，保存新设置时删除旧键，不会同时留下两套值。
- “更新检查偏好设置…”窗口与诊断页显示每类组件的最近检查时间、结果（最新 / 可更新 / 未知 /
  失败）、被忽略版本与下次检查时间。

### 4. 继承的修复（alpha.1 之后合入，本版本首次包含）

- 日志脱敏的规则缺口与非幂等（审查 R-1、R-2）：引号值、等号带空格的引号值、`key:` 续行、含空格值
  现在都被覆盖，重复就地脱敏逐字节一致（PR #45）。
- 通配监听地址（`0.0.0.0`、`::` 等）在保存、加载与启动三处共用同一条地址校验（审查 R-3，PR #47）。
- 门禁脚本对未跟踪文件的处理（审查 R-11）：`scan-secrets.sh` 发现扫描范围内的未跟踪文件时以退出码 3
  拒绝给出结论，`check-identity.sh` 会直接判失败（PR #46）。
- `package-release.sh` 对 `APP_STEM` 施加与 `VERSION` 相同的字符集白名单（审查 R-9，PR #48）。

## 更新检查访问的域名、频率与关闭方式

只读版本检查**不是遥测**：请求只用于比较“本机版本”与“上游最新版”，不携带使用数据、会话内容、
认证信息或诊断报告。

| 检查对象 | 域名与请求 | 请求内容 |
| --- | --- | --- |
| 桌面应用（本应用） | `api.github.com`：`GET /repos/Su-luoya/pi-web-desktop/releases?per_page=20` | 只解析最新 release 的版本 |
| Pi CLI、Pi Web、Pi 扩展包 | `registry.npmjs.org`：`GET /<包名>/latest` | 只解析 `version` 字段 |

- 只有 `GET` + JSON 解析；`User-Agent` 固定为应用名 + 版本 + bundle identifier（来自应用自身的
  Info.plist，不含用户名或主机名）。不发送 cookies、账号凭据、会话内容或诊断字段；应用侧客户端不
  跟随重定向，因此请求不会落到这两个域名之外。
- **关闭方式**：菜单“服务 → 更新检查设置”里的四类快捷开关（打开 = 默认策略，关闭 = 关闭），或
  “服务 → 更新检查设置 → 更新检查偏好设置…”里逐类改成“关闭 / 每日 / 每周”。四类全部关闭时应用
  不发任何请求，也不安排复查。
- 结果缓存写在 `~/Library/Application Support/Pi Web Desktop/update-check-cache.json`，只含版本号、
  时间戳与 etag 等条件请求字段；退出应用后删除该文件只会让下一次检查重新发起普通 GET。
- 忽略版本记录在 UserDefaults（`updateChecks.<组件>.ignoredVersion` 与 `.ignoredVersionAt`），
  只含版本字符串与时间戳。
- 上游服务会看到请求的源 IP、`User-Agent` 与请求时间，按各自隐私政策处理接入日志。完整说明见
  [隐私说明](privacy.md) 的“版本检查、提示与忽略版本”。

## 本机实测环境与版本（可追溯）

下表来自维护者一台 Apple Silicon 真机的实测输出，**不是 CI runner**；每一行的值都能用第三列的
命令复现。CI runner 的版本不会写进本说明。

| 项目 | 实测值 | 实测命令（本机输出摘要） |
| --- | --- | --- |
| 机器与芯片 | Apple M4（Mac mini，`Mac16,10`） | `sysctl -n machdep.cpu.brand_string` → `Apple M4`；`system_profiler SPHardwareDataType` → `Chip: Apple M4` |
| macOS | 27.0（BuildVersion `26A428`），满足 `>= 14` | `sw_vers` |
| 架构 | arm64 | `uname -m` → `arm64` |
| Node.js | v24.21.0（Homebrew `node@24`） | `node --version` → `v24.21.0` |
| npm | 11.19.0 | `npm --version` → `11.19.0` |
| Pi CLI（`@earendil-works/pi-coding-agent`） | 0.85.1 | `pi --version` → `0.85.1`；`npm ls -g --depth=0` → `@earendil-works/pi-coding-agent@0.85.1` |
| `@agegr/pi-web` | 0.9.1 | `npm ls -g @agegr/pi-web` → `@agegr/pi-web@0.9.1` |
| Swift 编译器 | Apple Swift 6.4（`swiftlang-6.4.0.34.1 clang-2100.3.34.1`） | `swift --version` |
| 应用包身份 | `CFBundleShortVersionString=0.1.0-alpha.2`、`CFBundleVersion=2`、`LSMinimumSystemVersion=14.0` | `./Scripts/check-identity.sh` → `check-identity: PASSED (45 checks)` |

`pi-web` 当前（0.9.1）没有 `--version` 选项，核对版本请用 `npm ls -g @agegr/pi-web` 或读取该包
`package.json` 的 `version`；诊断逻辑会先尝试 `--version`，失败后回落到 `package.json`，并在
诊断界面标出安装来源与可信度。

## 安装

1. 从本 Release 的 assets 下载 `Pi-Web-Desktop-0.1.0-alpha.2.zip` 与它的 `.sha256`、证据 Markdown。
2. 校验下载的 ZIP（在下载目录执行；文件名以 assets 实际名称为准）：

   ```bash
   shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.2.zip.sha256
   ```

   输出必须包含 `Pi-Web-Desktop-0.1.0-alpha.2.zip: OK`；不一致就不要安装。
3. 解压：

   ```bash
   ditto -x -k Pi-Web-Desktop-0.1.0-alpha.2.zip .
   ```

4. 把 `Pi-Web-Desktop.app` 移到 `~/Applications` 或 `/Applications`。
5. 首次打开：在 Finder 中按住 Control 点按（或右键）应用 → “打开” → 再确认一次“打开”。
   如果系统不再提供这个选项，请打开“系统设置 → 隐私与安全性”，找到刚被拦截的条目并选择
   “仍要打开”。**不要关闭 Gatekeeper**，也不要执行全局关闭的指令。
6. 安装依赖（应用不打包也不自动安装它们）：

   ```bash
   npm install -g --ignore-scripts @earendil-works/pi-coding-agent
   npm install -g @agegr/pi-web
   ```

   需要 Apple Silicon Mac、macOS 14+、Node.js `>=22.19.0`。应用不会调用 `sudo`，也不会读取或
   迁移 Pi 的认证内容。

## 依赖前置与首次启动诊断

- 应用**不打包** Node.js、Pi CLI 和 `@agegr/pi-web`；这三项必须在 `PATH`（或用诊断窗口里的
  “选择 pi-web 路径…”指定）上可执行，且 Node.js 版本不低于 `22.19.0`。
- 启动时 `DependencyChecker` 会检查 Apple Silicon / macOS 14+、Node.js 版本、Pi CLI、
  pi-web（可执行文件、版本、真实路径与符号链接目标、`package.json` 名称）、默认端口
  （只做本机 `bind(2)`，不连网）和 Pi 配置目录 `~/.pi/agent`（只判断存在/可读，不读取内容）；
  六项诊断条目现在还会给出安装来源与可信度。
- 硬性前置（Node.js / Pi CLI / pi-web）缺失、报告缺项或版本无法解析时，应用停在依赖诊断页：
  列出要处理的项与下一步，启动/停止/重启按钮全部禁用，WebView 显示诊断页而不是服务页。
  缺项、`unknown` 与“缺失”一样不放行。
- 前置满足但首次设置未完成时，同样先显示诊断页；点“开始使用 Pi Web”或“重新检测”后进入主窗口。
- 诊断窗口可随时从菜单“服务 → 依赖与环境诊断…”打开；“复制安装命令”只复制静态命令，
  应用不会执行安装命令、不调用 `sudo`、不联网、不读取凭据。
- 手工排查的只读命令：

  ```bash
  node --version
  npm prefix -g
  pi --version
  npm ls -g @agegr/pi-web
  pi-web --help
  ```

## 未公证、ad-hoc 与 Gatekeeper

- ZIP 内应用只有 ad-hoc 签名：能证明 bundle 打包后未被改动（`codesign --verify --deep --strict`
  通过、`satisfies its Designated Requirement`），但**不包含开发者身份**，Apple 也没有对它做过公证。
- `codesign -dv --verbose=4` 显示 `Signature=adhoc` 与 `TeamIdentifier=not set`；`spctl -a -vv`
  以非 0 退出码（本机为 3）输出 `rejected`，这是未公证 ad-hoc 产物的预期结果。
- 未公证的后果：无法验证发布者身份，也无法使用依赖 Developer ID 的能力（例如部分系统权限的持久
  授权和自动更新）。
- 放行是“针对这一个应用”的决定，系统会把它记录在“隐私与安全性”里；重新下载（quarantine 属性
  存在时）可能需要再次确认。
- 安装说明在这里给出的 Gatekeeper 处理只有两条：右键/Control 点按后选择“打开”，或在
  “系统设置 → 隐私与安全性”中针对被拦截的应用选择“仍要打开”。本项目不会建议关闭 Gatekeeper。
- 本项目不会把 ad-hoc 签名或“本机校验通过”描述成“已签名”或“已公证”。

## 校验值

- 资产：`Pi-Web-Desktop-0.1.0-alpha.2.zip`（以及 `Pi-Web-Desktop-0.1.0-alpha.2.zip.sha256`、
  签名与公证证据 Markdown，名称以 Release assets 为准）
- SHA-256：`见 Release assets`（草稿发布前从资产或 workflow 摘要复制；同一个值也会记录在
  Release Issue 中。**不要**使用任何在别处看到的哈希，包括本机演练产物。）
- 校验命令（下载目录执行）：`shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.2.zip.sha256`
- 校验失败时不要安装，请在 Release Issue 或普通 Issue 中报告。

另外，`package-release.sh` 生成的 evidence Markdown 会记录 `codesign`/`spctl` 原始输出、ZIP 名称、
SHA-256、构建提交与打包环境；它明确标注打包环境不等于真机实测环境。

## 构建与签名验证记录（本机演练）

下表是本机演练的实际命令与结果（`spctl` 的退出码 3 是预期结果）。完整记录见
[Alpha 发布门槛清单](alpha-release-checklist.md) 的“本次发布执行记录（v0.1.0-alpha.2）”一节。

| 命令 | 结果 |
| --- | --- |
| `sh -n Scripts/*.sh` | 退出 0 |
| `git diff --check` | 退出 0（无空白错误） |
| `./Scripts/build.sh` | 退出 0；`Mach-O 64-bit executable arm64` |
| `./Scripts/check-identity.sh` | 退出 0；`check-identity: PASSED (45 checks)` |
| `codesign --verify --deep --strict build/Pi-Web-Desktop.app` | 退出 0；`valid on disk` / `satisfies its Designated Requirement` |
| `codesign -dv --verbose=4 build/Pi-Web-Desktop.app` | `Signature=adhoc`、`TeamIdentifier=not set`、`Format=app bundle with Mach-O thin (arm64)` |
| `spctl -a -vv build/Pi-Web-Desktop.app` | 输出 `rejected`，退出 3（未公证的预期结果；本机 `spctl` 不打印拒绝原因） |
| `./Scripts/smoke.sh`（启动模式） | 退出 0；标记 `smoke: ready` |
| `./Scripts/smoke.sh`（诊断模式） | 退出 0；标记 `smoke: diagnostics items=6 blockers=3` 与 `smoke: diagnostics ready` |
| `./Scripts/scan-secrets.sh --self-test` | 退出 0；`self-test: PASS` |
| `./Scripts/scan-secrets.sh` | 退出 0；`scan-secrets: suppressed 11 lines`、`scan-secrets: PASS` |
| `sh Scripts/check-release-version.sh v0.1.0-alpha.2` | 退出 0；tag 与 `MARKETING_VERSION` 一致、预发布计数 `2` 与 `CURRENT_PROJECT_VERSION` 一致 |
| `./Scripts/package-release.sh --tag v0.1.0-alpha.2` | 退出 0；产出 ZIP、`.sha256`、evidence 与 `release-metadata.env`，版本为 `0.1.0-alpha.2` / build `2` |

`./Scripts/smoke.sh` 只验证窗口、诊断页与退出路径：两种模式都在临时 support 目录里运行，不写真实
UserDefaults / Application Support / Logs，也不启动真实 pi-web；它不替代 `xcodebuild test`。本机
`xcode-select -p` 指向 Command Line Tools，因此没有在本机运行 `xcodebuild build` / `xcodebuild test`
（由 CI 的 `macos-14` job 覆盖，见门槛清单）。

## 已知问题

未解决风险清单来自 [alpha.1 安全与发布审查](security-review-alpha.1.md)（第 10 节）。本版本发布前
已修复其中 6 项（R-1、R-2、R-3、R-7、R-9、R-11）；下列各项均为**低风险、非阻断**，本版本按现状
发布：

- **R-4（远程访问只有密码认证，低）**：默认只监听 `127.0.0.1`。远程访问必须自行配置受信任的加密
  隧道或 HTTPS 反向代理；**密码认证只验证访问者，不等于传输加密**，也没有暴力破解防护。
- **R-5（所有权验证与信号之间的 TOCTOU，低）**：所有权记录校验与实际发送信号之间存在时间窗口，
  `lstart` 只有秒级粒度。只对通过所有权验证的进程组发信号，外部服务零信号；如需进一步收紧可改用
  `proc_pidinfo` 微秒启动时间（后续 Issue）。
- **R-6（`service-owner.json` 不校验权限/所有者，低）**：应用不阻止同用户手工编辑所有权记录、也
  不校验文件属主与 mode（同用户本就可直接 `kill`；如需加固可在后续版本校验文件属主与 mode）。
- **R-8（扫描能力边界）**：`scan-secrets.sh` 与两条 `git grep` 文本检查都只覆盖固定模式，不做熵
  分析、不扫 Git 历史、不识别未列出的凭据类型。**“扫描通过”不等于“仓库里没有秘密”**。本版本已
  加强对未跟踪文件的处理（发现扫描范围内的未跟踪文件时不再给出假绿）。
- **R-10（本机 `spctl` 不打印拒绝原因，低）**：证据段落只记录 `spctl -a -vv` 的原始输出与退出码
  （本机为 `rejected`，退出 3），这是未公证 ad-hoc 产物的预期结果。
- **本版本修掉的既有风险（R-1、R-2、R-3、R-7、R-9、R-11）**：脱敏缺口与幂等、通配地址在加载/启动
  路径的校验、README 的过时表述、`APP_STEM` 白名单、门禁对未跟踪文件的处理，都已在 alpha.1 之后
  的 PR #45–#48 与 #15 中修复；审查报告 §10 的对应行保留审查当时的判定，不再代表现状。
- **未公证**：首次打开必须手动放行，见上文“未公证、ad-hoc 与 Gatekeeper”。
- **依赖需要自行安装**：缺失时应用只显示诊断信息，不会自动安装。
- **更新检查只提示**：本版本不下载、不安装任何更新，也不提供自动回滚；“忽略此版本”只抑制那一个
  版本，不是版本锁定。alpha.3 的“启动前自动更新 Pi Web”设置位在 alpha.2 不产生任何行为。
- **无 Intel 支持**：只支持 Apple Silicon（arm64），Intel Mac 不在支持范围。
- **无 SLA**：alpha 预览按“现状”提供，不承诺响应时间或修复时限。
- **日志轮转只保留 5 份**（每份上限 10 MB），超过上限的旧日志会被删除（见
  [日志与诊断导出](logging-and-diagnostics.md)）。

## 回退

1. 保留上一版的 ZIP 与它的 `.sha256`。回退时解压上一版（`v0.1.0-alpha.1`，资产仍在 Releases 中）
   并替换当前的 `Pi-Web-Desktop.app`，然后用 `codesign --verify --deep --strict` 复核（未公证的
   ad-hoc 产物仍会被 `spctl` 拒绝，这是预期结果）。
2. 卸载 / 回退应用包：应用没有系统级常驻组件或 LaunchAgent，删除应用包不会残留其他系统文件。
   退出应用后：

   ```bash
   rm -rf "$HOME/Applications/Pi-Web-Desktop.app"
   ```

   安装在 `/Applications` 时把路径换成 `/Applications/Pi-Web-Desktop.app`。
3. 需要清理用户目录中的残留数据时才执行（会丢失服务配置、日志、更新检查设置与网站数据；删除
   Keychain 条目会自动关闭远程模式并让监听地址回到 `127.0.0.1`）：

   ```bash
   defaults delete io.github.su-luoya.pi-web-desktop        # 服务配置、首次设置状态、窗口位置、更新检查设置与忽略版本
   rm -rf "$HOME/Library/Application Support/Pi Web Desktop" # 运行状态、所有权记录与更新检查缓存
   rm -rf "$HOME/Library/Logs/Pi Web Desktop"                # 日志与轮转文件
   rm -rf "$HOME/Library/WebKit/io.github.su-luoya.pi-web-desktop" \
          "$HOME/Library/Caches/io.github.su-luoya.pi-web-desktop"  # WebKit 网站数据
   security delete-generic-password -s io.github.su-luoya.pi-web-desktop -a remote-access-password
   ```

   以上路径与删除方式以[隐私说明](privacy.md#本地数据一览与删除)为准；删除这些不会影响 Pi Web、
   Pi CLI 或 Node.js 自身的数据。
4. Node.js、Pi 与 `@agegr/pi-web` 的版本回退由用户自行管理；本项目不承诺能恢复第三方包的旧版本，
   也不提供自动回滚。升级前请记录当前版本，并确认安装来源提供可靠的恢复路径。
5. 已经发布的版本不会静默替换 ZIP 或 checksum；新版本有问题时发布新的 alpha（例如
   `v0.1.0-alpha.3`）并在 Release 说明中给出回退路径。

## 支持边界

- 只支持 Apple Silicon（arm64）与 macOS 14 或更高版本；没有 Intel 产物。
- 没有 SLA，没有自动更新安装，没有 Developer ID 签名、Apple 公证或 Apple 支持渠道。
- 默认只监听 loopback；远程访问必须自备加密传输，并且**密码认证不等于传输加密**。
- 更新检查只访问 `api.github.com` 与 `registry.npmjs.org`，只读、可逐类关闭；除此之外应用不主动
  向任何上游发送数据。
- 不要在公开 Issue、PR 或 Release 评论里粘贴密码、token、私有主机名、代理凭据或未脱敏日志。

## 反馈与安全报告

- 普通问题与功能建议：使用本仓库的
  [Issue 表单](https://github.com/Su-luoya/pi-web-desktop/issues/new/choose)；请附版本、安装与依赖
  信息（脱敏后的诊断导出），以及可复现步骤。上游 Pi Web、Pi CLI 或 Pi packages 的问题请先到对应
  上游仓库确认。
- 安全漏洞：**不要**开公开 Issue、不要粘贴到 PR 或 Release 评论。请使用
  [私密漏洞报告](https://github.com/Su-luoya/pi-web-desktop/security/advisories/new)，
  范围、处理流程与“不承诺 SLA”的说明见 [SECURITY.md](../SECURITY.md)。
- 提交内容前请按[贡献指南](../CONTRIBUTING.md)运行构建、身份检查、smoke 与文本扫描；
  本版本的门槛证据见[Alpha 发布门槛清单](alpha-release-checklist.md)。
