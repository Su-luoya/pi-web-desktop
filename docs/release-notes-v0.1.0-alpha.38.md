# Pi Web Desktop v0.1.0-alpha.38（build 38）

Apple Silicon（arm64）、macOS 26+ 的 alpha prerelease；ad-hoc 签名、未公证，不含 Node.js、Pi CLI 或 Pi Web。

## 摘要

- 这是一个**内部质量版本**，只有一个用户可见的修复，其余改动不改变产品行为。
- 用户可见：`更新 → 更新检查偏好设置…` 里的进程状态行不再展开每个 Pi 进程的 PID、父进程与启动时间。本机 21 个 Pi 进程时那一行是 936 字符，折行后占掉大半个可视区，其余设置项要滚动才看得到；现在改为「检测到 N 个运行中的 Pi 进程（详情见「依赖与环境诊断」）」，32 字符单行。完整的进程列表仍保留在诊断页。
- 严格并发检查（`-strict-concurrency=complete`）从 **906 条告警降到 0**，全仓 101 个 Swift 文件。没有 `@preconcurrency`、没有逐个 `nonisolated(unsafe)` 静默；12 处保留的标注都是带注释的既有基线（详见 `Scripts/check-concurrency.sh` 的白名单与理由）。
- `UpdateSettingsWindowController` 与 `DiagnosticsWindowController` 的视图构建拆成具名方法；`QuitTimeline`、`LogRotationPolicy` 抽成无状态策略类型，因此第一次有独立单元测试覆盖退出时间线与日志轮转判定。
- 新增 `Scripts/check-concurrency.sh` 并接入 CI：严格并发告警数回归就让构建失败。

## 范围与安全边界

不新增第三方依赖，不新增 `Package.swift`，不变更设置 schema，不改监听地址默认值（仍为 loopback），不改服务所有权校验，不改任何网络或凭据路径。本版本没有触碰 Tailscale、PWA 图标同步或更新下载链路的行为。

`Scripts/check-concurrency.sh` 只做静态检查：它对 101 个源文件跑 `swiftc -typecheck -strict-concurrency=complete`，统计告警并比对基线。它不执行代码、不联网、不写用户目录。

## 真机记录

本机环境：Mac16,10 / Apple M4；macOS 27.2；arm64；Node.js v26.13.0；Pi 1.5.2；`@agegr/pi-web` 0.15.0。

- `./Scripts/smoke.sh`：启动模式与诊断模式均退出 0，marker 齐备（`smoke: ready`、`smoke: diagnostics ready`）；诊断模式 `items=6 blockers=3`。
- **用户可见的点击验证尚未进行。** 两个窗口控制器的视图构建被重排，验证手段是编译、smoke 启动与既有测试，没有逐项点击确认。具体未验证项见「已知限制与未验证范围」第 1 条。这一条在打 tag 前必须由维护者在本机完成，不能用自动 smoke 代替。

## 验证记录

- 本地全量 XCTest：**1095 tests, 0 failures**（alpha.37 为 1091）。新增的 4 条测试覆盖调度器的并发投递、后台执行与 `after` / `repeating` 定时行为。
- `./Scripts/check-concurrency.sh`：`clean (101 files, 12 baseline annotations)`；同一套 `swiftc` 不加 `-strict-concurrency=complete` 时也是 0 告警、0 错误。
- `./Scripts/build.sh` 发布构建（`-O -wmo`）通过，产物 `build/Pi-Web-Desktop.app`，arm64。
- `./Scripts/check-identity.sh`：**45 checks** 通过。`./Scripts/check-release-version.sh v0.1.0-alpha.38`：tag、`MARKETING_VERSION`、`CURRENT_PROJECT_VERSION` 三者一致。
- `sh -n Scripts/*.sh` 与 `git diff --check` 通过。
- `./Scripts/scan-secrets.sh --self-test` 通过；`./Scripts/scan-secrets.sh` 通过，`suppressed 17 lines`、无 rejected、本版无新增抑制标记。扫描通过不等于没有秘密。
- 签名完整性：`Signature=adhoc`、`TeamIdentifier=not set`；本机 `spctl` 报 `rejected`，是未公证产物的预期结果。

## 已知限制与未验证范围

- **两个窗口的交互未逐项人工验证。** `更新检查偏好设置` 窗口需要确认：四个分类的下拉菜单可展开、忽略按钮可用、状态行在窗口变宽变窄时正确折行、底部按钮行不随内容滚动。`诊断` 页需要确认三个代码文本框的滚动、折行与字体一致（它们的配置被合并到 `SettingsFormMetrics.configureCodeTextView`，漏掉一项的表现是某一个框长得不一样）。
- **严格并发清零不等于没有数据竞争。** 它只证明编译器在 `-strict-concurrency=complete` 下不再报告跨隔离访问。未运行 Thread Sanitizer，未做并发压力下的运行时验证；部分闭包参数用 `@unchecked Sendable` 接受人工审阅的保证，这些保证没有被测试覆盖。
- ad-hoc 签名、未公证；首次打开或新的应用构建可能需要在「系统设置 → 隐私与安全性」中针对这一个应用放行，或通过 Finder 右键打开。不关闭 Gatekeeper。
- 只支持 Apple Silicon、macOS 26+；不承诺 Intel 或其他系统版本。
- 未执行真实 CLI / 扩展安装端到端，未用 VoiceOver 逐项朗读，未在另一台 Mac 验证首次 Gatekeeper 放行。
- 自动 smoke 不启动真实 pi-web，但会创建默认 WKWebView；应用自己的状态/日志隔离到临时目录，WebKit 的网站数据仍由系统框架管理。
- `ServiceManager`（1384 行）与 `UpdateChecker`（1101 行）**未拆分**。按扩展拆分会把 55 个 `private` 成员提升为 `internal`，用封装换行数；不做，理由记录在 PR #280。
- secret scanner 与 personal-data 检查只覆盖固定形状，不扫描全部 Git 历史、任意自由文本或二进制秘密；检查通过不等于没有秘密。

## 回退

保留 [alpha.37](https://github.com/Su-luoya/pi-web-desktop/releases/tag/v0.1.0-alpha.37) 的 ZIP 与 checksum；退出应用后解压并替换应用包。无设置 schema 或服务数据迁移，应用内安装器不提供自动降级。从 appcast 移除本版条目可停止推送。

本版本没有改变任何持久化数据的形状，回退不需要迁移或清理。
