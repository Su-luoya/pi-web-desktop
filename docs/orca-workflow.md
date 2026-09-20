# Orca 工作流

GitHub Issue 是公开需求、验收标准和发布状态的事实来源。Orca task、Run 和 worktree 只负责一次执行，不替代 GitHub 状态，也不作为对外记录。贡献者侧的 Issue/PR 约定见 [CONTRIBUTING.md](../CONTRIBUTING.md)。

## 角色与所有权

- **coordinator**：分诊 Issue、设置标签与 Milestone、创建 task 和 worktree、验证 worker 产物、push 分支、创建 PR、映射 GitHub 状态与关闭 Issue。
- **worker**：在指定 worktree 内实现一个 task，默认只提交本地 commit。worker 不 push、不创建 PR、不合并 `main`、不关闭 Issue、不改 Issue 标签。
- 一个 worktree 同一时间只有一个实现 worker；只读 review task 可以在同一分支上并行，但不直接改实现分支。
- worker 只能修改 task 的 Ownership 列出的文件；需要越界时先回报 coordinator，不要自行扩大范围。
- 文档、模板、`.github/dependabot.yml` 与 workflow 逻辑属于不同文件所有权；一个 task 不得在未声明的情况下同时改动实现与工作流逻辑。

## 标签体系

仓库只用以下四个前缀，取值必须与仓库现有标签完全一致（不存在自定义临时标签）：

| 前缀 | 取值 | 含义 |
| --- | --- | --- |
| `type:` | `bug`、`feature`、`maintenance`、`documentation`、`security` | 变更类型，模板会自动套用 |
| `area:` | `app`、`service`、`diagnostics`、`security`、`updates`、`build-release`、`documentation` | 影响面，由维护者按变更内容设置 |
| `status:` | `needs-decision`、`ready`、`blocked`、`needs-reproduction` | 分诊状态；只有 `ready` 可以进入执行 |
| `priority:` | `P0`、`P1`、`P2`、`P3` | 影响与排期，由维护者在分诊时设置，不由模板自动套用 |

`status:` 与 Orca 的对应关系：`needs-decision`、`needs-reproduction` 不是可执行状态；`blocked` 必须写明阻塞 Issue；Issue 完成 PR 合并后才改为关闭，不会被 Orca 单独关闭。

## Definition of Ready

Issue 进入 `status: ready` 前必须满足：

- 用户问题或维护目标明确。
- 范围内、范围外事项明确。
- 验收标准可观察或可执行。
- 安全和兼容约束明确。
- 依赖 Issue 已完成或显式标记。
- 没有等待产品决策的问题。
- 文件所有权不与正在执行的 task 冲突。
- 一个 PR 可以完成。

## Task contract

每个实现 task 的标题和 spec 都引用 `GitHub #N`，并包含：

- **Target**：目标组件和文件边界。
- **Change**：实现内容。
- **Constraints**：安全、兼容、依赖和范围限制。
- **Ownership**：worker 可以修改的文件；未列出的文件需要先回报 coordinator。
- **Observable acceptance**：命令、测试和人工验证结果。

## 生命周期

1. 将 Ready Issue 加入 Milestone。
2. 在对应版本的 Orca Run 中创建 task。
3. 创建 `issue-N-slug` worktree，并用 `orca worktree set --issue N` 关联。
4. 启动一个实现 worker。worker 默认只提交本地 commit，不 push、不创建 PR、不合并。
5. coordinator 检查 diff、测试、personal-data 文本扫描、`./Scripts/scan-secrets.sh`（退出 0，并核对结尾的 `scan-secrets: suppressed N lines` 与是否出现 `scan-secrets: rejected` 行；若 worktree 里有未跟踪文件，脚本会拒绝给出结论并退出 3，先 `git add` 或删除再重跑）和 worktree 状态；secret scan 只覆盖固定凭据形状，默认只扫已跟踪文件，不要把它写成“没有秘密”（[#11](https://github.com/Su-luoya/pi-web-desktop/issues/11) 已实现，能力边界见[开发说明](development.md#personal-data-与-secret-扫描能力)）。
6. 重要 Issue 可在同一分支上启动独立只读 review task；review worker 不直接改实现分支。
7. coordinator 创建 PR，等待 CI，并按 [PR 模板](../.github/pull_request_template.md)把证据和遗留不确定项写入 PR。
8. squash merge 后关闭 Issue，标记 Orca workspace completed，清理 worktree 和终端。
9. Milestone 没有未结 task 或未处理终端后结束 Run。

## 证据要求

- worker 必须在报告里列出实际执行的命令和结果，而不是复述文档或凭记忆写版本号、路径和默认值。
- 身份、版本、bundle identifier 或最低系统版本的改动必须重跑 `./Scripts/build.sh` 与 `./Scripts/check-identity.sh`，并确认后者退出 0。
- 文档里新增的命令必须在同一 PR 里实际执行过；无法在当前环境执行的命令（例如只有 Command Line Tools 时的 `xcodebuild`）必须显式标注为未执行，并说明由哪一步 CI 覆盖。
- 无法自动测试的行为（UI、Keychain、WebKit、Gatekeeper）必须在 PR 中给出人工验证步骤和观察结果。
- 失败、超时或未验证的检查不得写成通过。

## 并发

仓库完成模块化前只执行一个实现 Issue。之后最多并行两个文件所有权不重叠的 Issue。一个 worktree 只能有一个实现 worker。

## 失败处理

worker 遇到未确认的产品决策、跨越文件所有权或安全边界时暂停并回报。不要用 task 完成状态替代测试证据，也不要让 worker 自行关闭 Issue 或合并 `main`。
