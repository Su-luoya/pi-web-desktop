# 文档索引

改文档前先确认自己在改哪一类：下面三类「能不能改」的规则不同。

## 长期文档（随代码一起改）

| 文档 | 内容 |
| --- | --- |
| [architecture.md](architecture.md) | 产品与组件边界、依赖诊断与启动门控、子进程环境、服务所有权、退出状态机 |
| [development.md](development.md) | 从源码构建、测试分层、目录结构、支持矩阵 |
| [releasing.md](releasing.md) | 打 tag 到 release workflow 的完整发布流程与 CI 固定策略 |
| [alpha-release-checklist.md](alpha-release-checklist.md) | 发布前要逐项核对的门槛；逐版本执行记录不在这里 |
| [settings-and-workspace.md](settings-and-workspace.md) | 设置项、工作目录与退出行为 |
| [logging-and-diagnostics.md](logging-and-diagnostics.md) | 日志字段、脱敏规则、诊断导出的数据位置 |
| [privacy.md](privacy.md) | 无遥测承诺、本机写了什么、存在哪、怎么删 |
| [security-ownership.md](security-ownership.md) | 服务所有权、外部服务只读策略、威胁模型与验证项 |
| [orca-workflow.md](orca-workflow.md) | Issue、worktree、分支与 PR 的并发和所有权规则 |

## 历史记录（只追加，不改写）

| 路径 | 内容 |
| --- | --- |
| [release-records/execution-log.md](release-records/execution-log.md) | 每个 alpha 实际执行过的门槛输出、CI run、资产 checksum 与发布后核对 |
| `release-notes-v<版本>.md` | 该版本的发布说明。文件名与位置是发布流程的一部分，见下节 |
| `security-review-<版本>.md` | 该版本的安全评审结论；评审时引用的路径与行号保持原样 |
| [release-notes-template.md](release-notes-template.md) | 发布说明模板，由 `release` workflow 渲染进 Release 正文 |
| [history/](history/) | 已关闭的一次性缺陷修复汇总 |

历史记录不追改：里面的路径、行号、测试计数都是写下当时的。要更正今天的结论，写进长期文档，不要回填到历史文件里；唯一例外是修掉会让链接失效的改名。

## 命名与引用规则

- 版本号统一写成 `v0.1.0-alpha.N`，与 `Configuration/AppIdentity.xcconfig` 的 `MARKETING_VERSION` 一一对应。
- 发布说明必须留在 `docs/` 根目录、名字必须是 `release-notes-<tag>.md`：`.github/workflows/release.yml` 按这个路径渲染 Release 正文，`.github/workflows/appcast.yml` 按同一路径拼 appcast 里的 notes 链接，移进子目录会让发布 workflow 失败。
- 跨文档链接用相对路径；锚点直接用标题，GitHub 会把 `## Release v0.1.0-alpha.13 执行记录` 生成 `#release-v010-alpha13-执行记录`。
- 路径大小写必须与磁盘一致：是 `docs/`，不是 `Docs/`。
