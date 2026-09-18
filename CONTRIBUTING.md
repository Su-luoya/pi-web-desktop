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
git diff --check
./Scripts/build.sh
./Scripts/check-identity.sh
./Scripts/smoke.sh
codesign --verify --deep --strict build/Pi-Web-Desktop.app
```

- `Scripts/build.sh` 生成 arm64、macOS 14 目标、ad-hoc 签名的 `build/Pi-Web-Desktop.app`。
- `Scripts/check-identity.sh` 退出 0 才表示身份与版本一致；它同时扫描仓库文本里的私人默认值。用法见 [开发说明](docs/development.md#一致性检查)。
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

## personal-data 扫描

CI 与 `Scripts/check-identity.sh` 都会扫描仓库文本，确认没有私人默认值。要复现 CI 的那条命令，直接从工作流里取出并执行，避免在文档或注释里复制模式字面值：

```bash
SCAN=$(awk '/^ *! git grep/{sub(/^ */, ""); print; exit}' .github/workflows/build.yml)
sh -c "$SCAN" && echo "personal-data scan: PASS"
```

扫描在匹配到内容时以非零退出。`./Scripts/check-identity.sh` 覆盖同一组检查并额外覆盖 tailnet DNS 后缀、CGNAT 私网地址和固定本地代理端点。

## 代码和隐私要求

- 不提交构建产物、ZIP、用户路径、主机名、代理默认值、密码、token 或认证文件。
- 不读取、复制或迁移 Pi 的认证内容。
- 默认只允许 loopback 服务；远程访问必须使用认证的加密传输，并明确说明密码认证不等于传输加密。
- 使用进程参数数组，不用未经审查的 shell 字符串拼接执行更新或服务命令。
- 身份、版本、bundle identifier 与最低系统版本只改 `Configuration/AppIdentity.xcconfig`，不要在代码、脚本、模板或测试里复制这些字面值。
- 新增第三方依赖前，先记录许可证、维护状态和供应链理由。应用当前没有第三方运行时依赖，CI 只使用 GitHub 托管的 runner，Actions 按提交 SHA 固定，更新由 `.github/dependabot.yml` 每周提出。

## 安全报告

不要在公开 Issue 或 PR 中报告漏洞，也不要粘贴未脱敏日志。流程见 [SECURITY.md](SECURITY.md)。

## 许可

贡献代码表示你同意按仓库 MIT License 提供贡献内容。项目不要求 CLA 或 DCO sign-off。
