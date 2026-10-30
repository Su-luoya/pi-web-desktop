# Pi Web Desktop 0.1.0-alpha.24（build 24）— Apple Silicon alpha（未公证）

> 说明：本文件在 `v0.1.0-alpha.25` 发布时补齐（alpha.24 发布时只用了 workflow 渲染的模板正文，漏了这一份存档）。内容记录的是该版实际包含的改动与当时实测的结果，没有补充当时没跑过的验证。

## 摘要

Pi Web Desktop `0.1.0-alpha.24` 面向 Apple Silicon（arm64）与 **macOS 26 或更高版本**。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版是一次全仓库代码评审的产物（GitHub PR #216）：修掉 5 个已复现的缺陷，没有新增功能，没有破坏性变更。

## 服务侧三处修复

### 1. 自定义可执行路径绕过解析与校验

`Sources/Services/ServiceManager.swift`：启动时直接使用配置里的原始路径，导致 `~/bin/pi-web` 这类带 `~` 的路径、前后带空白的路径启动失败，完全不存在的路径也会进入启动流程后才报错。改为统一走路径解析器：展开 `~`、清理首尾空白、检查可执行位，不合法时在启动前就给出可读原因。

### 2. 切换监听地址后残留旧端口回落

同一文件：旧地址因为端口被占用而回落到 `30142` 之后，切换到新地址仍会连 `30142`——旧结论被当成新地址的结论。改为地址变化时清除旧端口结论，页面与健康检查不会指向一个没人在听的端口。

### 3. 重试连接成功后没有恢复健康监控

同一文件：启动失败会停止健康监控，但重试发现服务已经就绪时不会恢复，之后真断线了界面还显示“运行中”。补齐了重试、菜单启动与配置重载三条入口的恢复逻辑，并验证不会重复创建计时器。

## 更新检查两处修复

### 4. 局部更新检查整包覆盖汇总（P1）

`Sources/Updates/UpdateChecker.swift`：周期复查只检查到期对象（`onlyDue`），但发布时用本轮结果整体替换 `summary`，把刚展示过的手动全量结果冲掉——菜单和界面会闪变，未到期对象的状态丢失。新增合并规则 `mergedSummary(_:)`：本轮覆盖的对象用新结果，未覆盖的保留旧结论，已关闭分类的旧结论作废，分类状态按合并结果重建。两处发布点（`finishCheck(with:)` 与 `finishCheckWithoutNewSummary`）统一走该入口。

### 5. 无窗口时弹窗崩溃（P2）

`Sources/App/AppDelegate+*.swift` 共 27 处 `beginSheetModal(for: window)`：`window` 是隐式解包，启动前更新检查、后台失败等路径下窗口可能为 nil，直接崩溃。新增统一入口 `presentAlert(_:completionHandler:)`：窗口可见就挂 sheet，否则激活应用后 `runModal`；隐藏的窗口不会被强制显示。原本已有防护的 4 处调用点未动。

## 验证

- `xcodebuild test`：`Executed 962 tests, with 0 failures (0 unexpected)`，`** TEST SUCCEEDED **`。本版新增 5 条回归测试：`ServiceManagerTests.swift` 4 条（自定义路径解析、地址变化清除端口回落、重试恢复监控、不重复创建计时器），`UpdateCheckerTests.swift` 1 条（`testScheduledDueCheckKeepsResultsOfTargetsThatWereNotDue`：3 天后每日分类到期复查，扩展包结果与 `checkedAt` 保持不变）。
- `./Scripts/check-identity.sh`、`./Scripts/scan-secrets.sh`、`sh -n Scripts/*.sh`、`git diff --check` 全绿；`./Scripts/build.sh` 成功。
- 发布 workflow（tag `v0.1.0-alpha.24`）：通过；发布后 `shasum -a 256 -c` 复验 `OK`。

## 已知限制

- 上一轮评审记录的非阻塞项未在本版处理：非 loopback 监听没有认证层（需可信网络或外部保护）；`UpdateChecker` 中三处 `Task { }` 的取消语义。
- ad-hoc 签名、未公证：首次手动安装需要按 macOS 提示放行。
- macOS 14 / 15 不在支持范围。

## 发布资产

| 资产 | 值 |
| --- | --- |
| ZIP | `Pi-Web-Desktop-0.1.0-alpha.24+build.24.zip` |
| SHA-256 | `4f90e9b550f289cd7ed66cf800d3af2d821095b0bc4bdf659fdd0970e70326aa` |
| 体积 | 1678626 字节 |
| 签名 | ad-hoc（`TeamIdentifier=not set`），未公证 |
| 最低系统 | macOS 26.0 |
| 架构 | arm64（Apple Silicon） |

校验方式：

```sh
shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.24+build.24.zip.sha256
```
