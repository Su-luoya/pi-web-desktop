# Orca 工作流

GitHub Issue 是公开需求、验收标准和发布状态的事实来源。Orca task、Run 和 worktree 只负责一次执行，不替代 GitHub 状态。

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
5. coordinator 检查 diff、测试、secret scan 和 worktree 状态。
6. 重要 Issue 可在同一分支上启动独立只读 review task；review worker 不直接改实现分支。
7. coordinator 创建 PR，等待 CI，并把证据写入 PR。
8. squash merge 后关闭 Issue，标记 Orca workspace completed，清理 worktree 和终端。
9. Milestone 没有未结 task 或未处理终端后结束 Run。

## 并发

仓库完成模块化前只执行一个实现 Issue。之后最多并行两个文件所有权不重叠的 Issue。一个 worktree 只能有一个实现 worker。

## 失败处理

worker 遇到未确认的产品决策、跨越文件所有权或安全边界时暂停并回报。不要用 task 完成状态替代测试证据，也不要让 worker 自行关闭 Issue 或合并 `main`。
