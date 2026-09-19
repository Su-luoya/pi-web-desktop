<!--
docs/release-notes-v0.1.0-alpha.1.md — v0.1.0-alpha.1 草稿 Release 的正文。

可以直接粘贴为 GitHub Release 说明（本注释在 GitHub 上不渲染）。发布前必须：
  * 把“校验值”一节的 `<见 Release assets>` 换成草稿资产里实际的 SHA-256；
  * 核对资产名称、版本与 build 和草稿一致；
  * 不要在本文件或发布说明里声称“已签名”“已公证”，也不要指导关闭 Gatekeeper；
  * 不要写入主机名、用户名、凭据、代理端点或真实用户绝对路径。

相关文档：[发布流程](releasing.md)、[Alpha 发布门槛清单](alpha-release-checklist.md)、
[Release notes 模板](release-notes-template.md)、[alpha.1 安全与发布审查](security-review-alpha.1.md)。
-->

# Pi Web Desktop 0.1.0-alpha.1（build 1）— Apple Silicon alpha（未公证）

## 摘要 / Summary

Pi Web Desktop `0.1.0-alpha.1` 是面向 **Apple Silicon（arm64）、macOS 14 或更高版本** 的早期
alpha 预览。它启动、监控并显示本机已安装的 Pi Web 服务，默认只监听 loopback。ZIP 里的应用是
**ad-hoc 签名、未公证** 的：没有 Developer ID 证书，也没有 Apple 公证，因此 Gatekeeper 默认会
阻止直接双击打开，需要用户针对这一个应用手动放行。本版本没有 Intel 支持、没有 SLA、没有应用内
自动更新。

Pi Web Desktop `0.1.0-alpha.1` is an early alpha for **Apple Silicon (arm64) Macs running
macOS 14 or later**. It starts, monitors and displays a locally installed Pi Web service and
listens on loopback by default. The app in the ZIP is **ad-hoc signed and not notarized**:
there is no Developer ID certificate and no Apple notarization, so Gatekeeper blocks a plain
double-click and the user has to approve this app explicitly. This release has no Intel
support, no SLA and no in-app automatic updates.

## 发布信息

| 项目 | 值 |
| --- | --- |
| 版本（tag） | `v0.1.0-alpha.1` |
| `CFBundleShortVersionString` | `0.1.0-alpha.1` |
| `CFBundleVersion` | `1` |
| Bundle identifier | `io.github.su-luoya.pi-web-desktop` |
| 应用包 | `Pi-Web-Desktop.app` |
| 架构 | arm64（Apple Silicon）；**不支持 Intel（x86_64）** |
| 最低系统 | macOS 14.0 |
| 签名 | ad-hoc（`codesign --sign -`），没有证书，`TeamIdentifier=not set` |
| 公证 | 无。Gatekeeper 默认拒绝，需要用户手动放行这一个应用 |
| 发布类型 | GitHub **prerelease**（alpha 预览） |
| 本地数据位置 | UserDefaults、`~/Library/Application Support/Pi Web Desktop/`、`~/Library/Logs/Pi Web Desktop/`、Keychain、WebKit 网站数据，见[隐私说明](privacy.md) |

## 目标平台

| 维度 | 支持范围 |
| --- | --- |
| CPU | Apple Silicon（arm64） |
| 系统 | macOS 14.0 或更高 |
| Intel Mac | 不支持，也没有 x86_64 产物 |
| 依赖 | Node.js `>=22.19.0`、Pi CLI、`@agegr/pi-web`（需用户自行安装，应用不打包也不自动安装） |
| 默认服务地址 | `http://127.0.0.1:30141/`（只监听 loopback） |

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
| `@agegr/pi-web` | 0.9.1 | `npm ls -g --depth=0` → `@agegr/pi-web@0.9.1`；`readlink /opt/homebrew/bin/pi-web` → `../lib/node_modules/@agegr/pi-web/bin/pi-web.js` |
| pi-web 安装来源 | Homebrew 前缀下的 npm 全局安装（`npm config get prefix` → `/opt/homebrew`）；Homebrew formula 列表里没有独立的 `pi-web` | `npm config get prefix`；`brew list --formula` |
| Swift 编译器 | Apple Swift 6.4（`swiftlang-6.4.0.34.1 clang-2100.3.34.1`） | `swift --version` |
| 应用包身份 | `CFBundleShortVersionString=0.1.0-alpha.1`、`CFBundleVersion=1`、`LSMinimumSystemVersion=14.0` | `./Scripts/check-identity.sh` → `check-identity: PASSED (45 checks)` |

`pi-web` 当前（0.9.1）没有 `--version` 选项，核对版本请用 `npm ls -g @agegr/pi-web` 或读取该包
`package.json` 的 `version`；诊断逻辑会先尝试 `--version`，失败后回落到 `package.json`。

## 安装

1. 从本 Release 的 assets 下载 `Pi-Web-Desktop-0.1.0-alpha.1.zip` 与它的 `.sha256`、
   evidence Markdown。
2. 校验下载的 ZIP（在下载目录执行；文件名以 assets 实际名称为准）：

   ```bash
   shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.1.zip.sha256
   ```

   输出必须包含 `Pi-Web-Desktop-0.1.0-alpha.1.zip: OK`；不一致就不要安装。
3. 解压：

   ```bash
   ditto -x -k Pi-Web-Desktop-0.1.0-alpha.1.zip .
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
  （只做本机 `bind(2)`，不连网）和 Pi 配置目录 `~/.pi/agent`（只判断存在/可读，不读取内容）。
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

- 资产：`Pi-Web-Desktop-0.1.0-alpha.1.zip`（以及 `Pi-Web-Desktop-0.1.0-alpha.1.zip.sha256`、
  签名与公证证据 Markdown，名称以 Release assets 为准）
- SHA-256：`<见 Release assets>`（草稿发布前从资产或 workflow 摘要复制；同一个值也会记录在
  Release Issue 中。**不要**使用任何在别处看到的哈希，包括本机演练产物。）
- 校验命令（下载目录执行）：`shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.1.zip.sha256`
- 校验失败时不要安装，请在 Release Issue 或普通 Issue 中报告。

另外，`package-release.sh` 生成的 evidence Markdown 会记录 `codesign`/`spctl` 原始输出、ZIP 名称、
SHA-256、构建提交与打包环境；它明确标注打包环境不等于真机实测环境。

## 构建与签名验证记录（本机演练，Apple M4 / macOS 27.0 / arm64）

下表是本机演练的实际命令与结果，全部退出 0（`spctl` 的退出码 3 是预期结果）。
完整记录见 [Alpha 发布门槛清单](alpha-release-checklist.md) 的“本次发布执行记录”一节。

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
| `./Scripts/scan-secrets.sh` | 退出 0；`scan-secrets: suppressed 11 lines`、`scan-secrets: PASS (no matches in tracked files)` |
| `sh Scripts/check-release-version.sh v0.1.0-alpha.1` | 退出 0；tag 与 `MARKETING_VERSION` 一致、预发布计数 `1` 与 `CURRENT_PROJECT_VERSION` 一致 |
| `./Scripts/package-release.sh --tag v0.1.0-alpha.1` | 退出 0；产出 ZIP、`.sha256`、evidence 与 `release-metadata.env` |

`./Scripts/smoke.sh` 只验证窗口、诊断页与退出路径：两种模式都在临时 support 目录里运行，不写真实
UserDefaults / Application Support / Logs，也不启动真实 pi-web；它不替代 `xcodebuild test`。本机
`xcode-select -p` 指向 Command Line Tools，因此没有在本机运行 `xcodebuild build` / `xcodebuild test`
（由 CI 的 `macos-14` job 覆盖，见门槛清单）。

## 已知问题

本版本的未解决风险清单来自 [alpha.1 安全与发布审查](security-review-alpha.1.md)（第 10 节）。
以下各项均为**低风险、非阻断**，本版本按现状发布：

- **R-1（脱敏非幂等，低）**：同一份日志被就地脱敏两次时，第二遍会把紧跟占位符的 `}` 一并吞掉（报告实测：`{"token": <redacted>} trailing-context` → `{"token": <redacted> trailing-context`）。`LogWriter` 在打开子进程日志句柄前都会对已有日志就地脱敏（每次启动服务时执行），所以反复启动服务可能让日志里已脱敏的 JSON 行丢失一个尾随括号——只影响日志文本完整性，**不构成秘密泄漏**。
- **R-2（脱敏规则缺口，低—中）**：引号值、等号带空格的引号值、跨行值和含空格的值只会被部分替换或不替换；受影响的主要是子进程直接写入日志的 stdout/stderr（应用不控制也不解析其格式）。不要把密码或密钥以这些形态写进命令行、URL 或日志，导出诊断前请先自行检查内容。
- **R-3（通配地址只在界面保存路径被拒绝，低）**：`0.0.0.0` 这类“所有接口”地址无法在设置界面保存，
  但加载已有配置文件时不重新校验。默认配置只使用 loopback；不要手工编辑 UserDefaults 写入通配地址。
- **R-4（远程访问只有密码认证，低）**：默认只监听 `127.0.0.1`。远程访问必须自行配置受信任的加密
  隧道或 HTTPS 反向代理；**密码认证只验证访问者，不等于传输加密**，也没有暴力破解防护。
- **R-7（文档与实际能力不一致，低，已在本版本发布前修正）**：`README.md` 曾声称“没有通用 secret
  scanning”，与已实现的 `Scripts/scan-secrets.sh` 及 CI 门禁矛盾；本版本已改为与
  [开发说明](development.md#personal-data-与-secret-扫描能力) 一致的能力描述。
- **R-8 / R-11（扫描能力边界）**：`scan-secrets.sh` 与两条 `git grep` 文本检查都只覆盖固定模式、
  只扫**已跟踪文件**，不做熵分析、不扫 Git 历史、不识别未列出的凭据类型，对未跟踪的新文件会给出
  假绿。**“扫描通过”不等于“仓库里没有秘密”**。
- **未公证**：首次打开必须手动放行，见上文“未公证、ad-hoc 与 Gatekeeper”。
- **依赖需要自行安装**：缺失时应用只显示诊断信息，不会自动安装。
- **无 Intel 支持**：只支持 Apple Silicon（arm64），Intel Mac 不在支持范围。
- **无 SLA**：alpha 预览按“现状”提供，不承诺响应时间或修复时限。
- **无自动更新**：`v0.1.0` 不实现应用内更新，升级需要重新下载 ZIP 并替换应用包。
- **日志轮转只保留 5 份**（每份上限 10 MB），超过上限的旧日志会被删除（见
  [日志与诊断导出](logging-and-diagnostics.md)）。

## 回退

1. 保留上一版的 ZIP 与它的 `.sha256`。回退时解压上一版并替换当前的 `Pi-Web-Desktop.app`，
   然后用 `codesign --verify --deep --strict` 复核（未公证的 ad-hoc 产物仍会被 `spctl` 拒绝，
   这是预期结果）。
2. 卸载 / 回退应用包：应用没有系统级常驻组件或 LaunchAgent，删除应用包不会残留其他系统文件。
   退出应用后：

   ```bash
   rm -rf "$HOME/Applications/Pi-Web-Desktop.app"
   ```

   安装在 `/Applications` 时把路径换成 `/Applications/Pi-Web-Desktop.app`。
3. 需要清理用户目录中的残留数据时才执行（会丢失服务配置、日志与网站数据；删除 Keychain 条目会
   自动关闭远程模式并让监听地址回到 `127.0.0.1`）：

   ```bash
   defaults delete io.github.su-luoya.pi-web-desktop        # 服务配置、首次设置状态、窗口位置
   rm -rf "$HOME/Library/Application Support/Pi Web Desktop" # 运行状态与所有权记录
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
   `v0.1.0-alpha.2`）并在 Release 说明中给出回退路径。

## 支持边界

- 只支持 Apple Silicon（arm64）与 macOS 14 或更高版本；没有 Intel 产物。
- 没有 SLA，没有自动更新，没有 Developer ID 签名、Apple 公证或 Apple 支持渠道。
- 默认只监听 loopback；远程访问必须自备加密传输，并且**密码认证不等于传输加密**。
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
