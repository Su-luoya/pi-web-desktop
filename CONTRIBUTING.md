# 贡献指南

## 讨论范围

Pi Web Desktop 是 `agegr/pi-web` 的非官方 macOS companion app。它负责启动、管理和显示本机 Pi Web，不维护上游 Web 服务。

请先搜索已有 Issue。大功能、架构调整和安全相关变更请先开 Issue，说明用户问题、范围、约束和验收方式。

## 开发流程

1. 为一个可独立验收的结果创建或选择一个 GitHub Issue。
2. Issue 满足 Definition of Ready 后，使用 `issue-<number>-<slug>` 创建分支。
3. 所有功能代码通过 Pull Request 合并到 `main`。
4. PR 必须关联 Issue；维护者会在验证后使用 squash merge。
5. 合并后删除分支。Issue 的关闭状态由 GitHub 记录，Orca 只管理执行期间的 task 和 worktree。

## 本地构建

```bash
./Scripts/build.sh
```

当前 alpha 基线使用系统 Swift 编译 Apple Silicon、macOS 14 目标。标准 Xcode 工程和测试 target 会按里程碑推进。

## 提交前检查

```bash
sh -n Scripts/build.sh Scripts/install.sh
./Scripts/build.sh
codesign --verify --deep --strict build/Pi-Web-Desktop.app
```

如果改动了 Swift 代码，请在 PR 中写明测试结果。无法自动测试的 UI、Keychain、WebKit 或 Gatekeeper 行为必须提供人工验证步骤。

## 代码和隐私要求

- 不提交构建产物、ZIP、用户路径、主机名、代理默认值、密码、token 或认证文件。
- 不读取、复制或迁移 Pi 的认证内容。
- 默认只允许 loopback 服务；远程访问必须使用认证的加密传输。
- 使用进程参数数组，不用未经审查的 shell 字符串拼接执行更新或服务命令。
- 新增第三方依赖前，先记录许可证、维护状态和供应链理由。

## 许可

贡献代码表示你同意按仓库 MIT License 提供贡献内容。项目不要求 CLA 或 DCO sign-off。
