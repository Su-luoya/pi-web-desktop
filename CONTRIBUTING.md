# 贡献指南

Pi Web Desktop 是 [`agegr/pi-web`](https://github.com/agegr/pi-web) 的**非官方** macOS companion app，与上游维护者没有隶属关系。它负责启动、管理和显示本机 Pi Web，不维护上游 Web 服务；上游问题请先到上游仓库确认。支持范围与“未承诺”事项见 [README 支持矩阵](README.md#支持矩阵)。

## Issue

请先搜索[已有 Issue](https://github.com/Su-luoya/pi-web-desktop/issues)。可复现问题用 [Bug 表单](https://github.com/Su-luoya/pi-web-desktop/issues/new/choose)，用户能力提议用 Feature 表单，构建/测试/文档类改动用 Maintenance 表单。大功能、架构调整和安全相关变更请先开 Issue，说明用户问题、范围、约束和验收方式。

Issue 标签统一使用仓库现有体系：

- `type:`：`bug`、`feature`、`maintenance`、`documentation`、`security`。
- `area:`：`app`、`service`、`diagnostics`、`security`、`updates`、`build-release`、`documentation`。
- `status:`：`needs-decision`、`ready`、`blocked`、`needs-reproduction`。
- `priority:`：`P0`（安全、数据损坏或广泛不可启动）、`P1`（里程碑阻塞）、`P2`（正常计划工作）、`P3`（可延后改进）。

`priority:` 由维护者在分诊时按影响设置，不由模板自动套用。进入 `status: ready` 前必须满足 [Definition of Ready](docs/orca-workflow.md#definition-of-ready)。

## 开发流程

1. 为一个可独立验收的结果创建或选择一个 GitHub Issue。
2. Issue 满足 Definition of Ready 后，使用 `issue-<number>-<slug>` 创建分支。
3. 所有功能代码通过 Pull Request 合并到 `main`。
4. PR 必须关联 Issue，并按 [PR 模板](.github/pull_request_template.md)填写变更说明、验收证据、安全与兼容性影响。维护者验证后使用 squash merge。
5. 合并后删除分支。Issue 的关闭状态由 GitHub 记录，Orca 只管理执行期间的 task 和 worktree。

一个 Issue 对应一个主要实现 task、worktree、分支和 PR；并发、所有权与失败处理规则见 [Orca 工作流](docs/orca-workflow.md)。

## 本地构建与测试

```bash
sh -n Scripts/*.sh
./Scripts/scan-secrets.sh --self-test
./Scripts/scan-secrets.sh
git diff --check
./Scripts/build.sh
./Scripts/check-identity.sh
./Scripts/smoke.sh
codesign --verify --deep --strict build/Pi-Web-Desktop.app
```

- `Scripts/build.sh` 生成 arm64、macOS 14 目标、ad-hoc 签名的 `build/Pi-Web-Desktop.app`。
- `Scripts/check-identity.sh` 退出 0 才表示身份与版本一致；它同时用固定模式集扫描仓库文本里的私人默认值，并在扫描前检查未跟踪文件：落在扫描范围内的未跟踪文件判失败（先 `git add` 或删除），被扫描 pathspec 排除的 `*.icns` 只输出 info 行。用法见 [开发说明](docs/development.md#personal-data-与-secret-扫描能力)。
- `Scripts/scan-secrets.sh --self-test` 先用临时目录里的样本证明每条凭据规则都会命中、`scan-secrets: allow` 抑制标记只跳过带标记的那一行且计数正确，再在临时 Git 仓库里证明未跟踪文件门禁（默认退出 3、加 `--include-untracked` 能扫到未跟踪文件里的样例凭据、没有未跟踪文件时行为不变；该自测因此需要 `git`）；`Scripts/scan-secrets.sh` 再扫描所有已跟踪文件，工作区没有未跟踪文件时必须退出 0，有未跟踪文件时如实退出 3（先 `git add` 或删除，本地排查时可显式加 `--include-untracked`）。提交前可以用 `./Scripts/scan-secrets.sh <file>` 只扫一个文件（未跟踪的文件也可以直接指定）。
- `Scripts/smoke.sh` 在临时 support 目录里验证主窗口与诊断页启动路径，不写真实 UserDefaults、Application Support 与 Logs，也不启动真实 pi-web。

如果改动了 Swift 代码，还要运行工程构建和 XCTest（需要完整 Xcode，只有 Command Line Tools 时会失败）：

```bash
DERIVED_DATA_PATH="$(mktemp -d "${TMPDIR:-/tmp}/PiWebDesktopDerivedData.XXXXXX")"
trap 'rm -rf "$DERIVED_DATA_PATH"' EXIT
XCODEBUILD_ARGS=(
  -project PiWebDesktop.xcodeproj
  -scheme PiWebDesktop
  -sdk macosx
  -derivedDataPath "$DERIVED_DATA_PATH"
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY=-
)
xcodebuild "${XCODEBUILD_ARGS[@]}" build
xcodebuild "${XCODEBUILD_ARGS[@]}" test
./Scripts/check-identity.sh \
  --test-bundle "$DERIVED_DATA_PATH/Build/Products/Debug/PiWebDesktopTests.xctest" \
  "$DERIVED_DATA_PATH/Build/Products/Debug/PiWebDesktop.app" build/Pi-Web-Desktop.app
```

无法自动测试的 UI、Keychain、WebKit 或 Gatekeeper 行为必须在 PR 里提供人工验证步骤和观察结果。

测试分两层（见 [开发说明的“测试分层”](docs/development.md#测试分层)）：单元测试全部用注入替身，不碰真实进程/网络/Keychain/`~/.pi`；集成测试 `PiWebDesktopTests/ServiceIntegrationTests.swift` 用真实代码路径加真实子进程，但只执行 `$TMPDIR` 里临时生成的假 `pi`/`pi-web`/`node` 脚本、只连接 `127.0.0.1` 上系统分配端口的本地 HTTP 测试服务器，并且涉及信号路径的测试会断言不在受管进程组里的诱饵进程没有被终止或收到信号。新增这类测试时必须保持同样的边界：不访问真实 npm、GitHub、用户 Keychain、`~/.pi` 或真实 Home，不调用 `sudo`，fixture 写进临时目录并在失败路径上也清理，用轮询加超时（不用固定 `sleep`）等待异步状态。

## personal-data 与 secret 扫描能力

仓库与 CI 共有三层自动文本检查，覆盖的是固定模式，不是通用泄露检测（CI 的步骤只覆盖 checkout 出来的已跟踪内容，本地运行见下面的未跟踪文件处理）：

- `Scripts/check-identity.sh`（仓库文本扫描在 `# --- 6. repository text scan ---` 一节）：小写的私有 VPN 主机名、tailnet DNS 后缀、CGNAT 私网地址段、以 `/Users` 开头的主目录路径、固定本地代理端点，以及 `Sources/`、`Scripts/`、`PiWebDesktop.xcodeproj/`、`PiWebDesktopTests/` 里出现 `MARKETING_VERSION` 字面值。扫描前用 `git ls-files --others --exclude-standard` 检查未跟踪且未被 `.gitignore` 忽略的文件：落在上述范围内的未跟踪文件判定失败（消息列出前 5 条并提示 `git add`），被扫描 pathspec 排除的 `*.icns` 只输出 info 行。
- CI 的 `Check for accidental personal data` 步骤（`.github/workflows/build.yml`）：一条 `git grep` 字面量检查，排除 `*.icns`、该 workflow 自身和 `Scripts/check-identity.sh`；它只覆盖已 checkout 的已跟踪提交，而 CI 上不存在未跟踪文件。
- `Scripts/scan-secrets.sh`（#11 新增，CI 上由 `Self-test the secret scanner` 与 `Scan tracked files for committed secrets` 两步执行）：按固定形状扫描已跟踪文件里的 AWS access key ID、GitHub token、PEM 私钥头、JWT 和 `password=`/`secret=`/`api_key=`/`token=` 这类赋值；默认的仓库级扫描在存在未跟踪且未被 `.gitignore` 忽略的文件时**拒绝给出结论并退出 3**，消息列出前 5 条并提示 `git add <path>` 或 `--include-untracked`；该开关把未跟踪文件就地一并扫描，只用于本地排查（未 `git add` 的文件 CI 永远扫不到）。`--self-test` 除了证明规则与误报边界，还在临时 Git 仓库里断言这条门禁。
- 内联抑制：匹配行只有在**同一行**带 `scan-secrets: allow` 时才被跳过，脚本没有按文件、目录或路径整体放行的开关；每次实际执行的扫描在结尾输出 `scan-secrets: suppressed N lines`（未跟踪文件导致的退出 3 在扫描前结束，不打印该行）。这个标记只允许加在确定是样例数据的行上（例如脱敏测试夹具），不允许用来消音真实或来源不明的命中。

退出码：0 表示没有命中，1 表示至少命中一处，2 表示用法/环境错误，3 表示工作区存在未跟踪且未被 `.gitignore` 忽略的文件、仓库级扫描拒绝给出结论（先 `git add`，或用 `--include-untracked` 本地排查后重跑）。

本地复现 CI 的那条命令（从工作流里取出，避免在文档或注释里复制模式字面值）：

```bash
SCAN=$(awk '/^ *! git grep/{sub(/^ */, ""); print; exit}' .github/workflows/build.yml)
sh -c "$SCAN" && echo "personal-data scan: PASS"
```

命令匹配到内容时以非零退出。三层检查都只覆盖上面列出的模式；CI 的 personal-data `git grep` 只看已 checkout 的已跟踪内容（CI 上没有未跟踪文件），本地默认不再对未跟踪文件给出假绿：`scan-secrets.sh` 退出 3，`check-identity.sh` 对扫描范围内的未跟踪文件判失败。三层都不做熵分析、扫描 Git 历史、检查二进制/加密载荷或未列出的凭据类型；命中不等于一定泄漏（例如文档里的示例形状），漏报也不等于安全。凭据泄漏防线仍然是评审和作者自查，不要在 PR 或发布说明里把“scan-secrets 通过”写成“没有秘密”。能力边界与本地用法见 [开发说明](docs/development.md#personal-data-与-secret-扫描能力)。

`scan-secrets: allow` 只用于样例数据，并且必须逐条评审：

- 只有“同一行”的标记生效，所以标记不会连带放过文件里的其他命中。
- 加标记的行必须在 PR 描述里说明它是样例数据以及用途；评审逐行确认该行确实不是真实凭据，而不是只看扫描器变绿。
- 把运行结尾的 `scan-secrets: suppressed N lines` 与本次改动新增的标记数量对照；N 多于本次新增的标记数、或者标记出现在非夹具文件里，都应当先质疑再合并。
- 真实凭据、疑似凭据、来源不明的字面值一律不加标记；先按 [SECURITY.md](SECURITY.md) 处理。

## 代码和隐私要求

- 不提交构建产物、ZIP、用户路径、主机名、代理默认值、密码、token 或认证文件。
- `scan-secrets: allow` 内联标记只能加在确定是样例数据的行上，并在 PR 里逐条说明；不要用它消音真实命中。
- 不读取、复制或迁移 Pi 的认证内容。
- 默认只允许 loopback 服务；远程访问必须使用认证的加密传输，并明确说明密码认证不等于传输加密。
- 使用进程参数数组，不用未经审查的 shell 字符串拼接执行更新或服务命令。
- 身份、版本、bundle identifier 与最低系统版本只改 `Configuration/AppIdentity.xcconfig`，不要在代码、脚本、模板或测试里复制这些字面值。
- 新增第三方依赖前，先记录许可证、维护状态和供应链理由。应用当前没有第三方运行时依赖，CI 只使用 GitHub 托管的 runner，Actions 按提交 SHA 固定，更新由 `.github/dependabot.yml` 每周提出。

## 安全报告

不要在公开 Issue 或 PR 中报告漏洞，也不要粘贴未脱敏日志。流程见 [SECURITY.md](SECURITY.md)。

## 许可

贡献代码表示你同意按仓库 MIT License 提供贡献内容。项目不要求 CLA 或 DCO sign-off。
