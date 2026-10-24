# Pi Web Desktop 0.1.0-alpha.20（build 20）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.20` 面向 Apple Silicon（arm64）与 **macOS 26 或更高版本**。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版是一次**稳定性修复发布**，没有新增功能，也没有破坏性变更。修的是两个长期存在、但只有翻日志才看得出来的缺陷。

## 缺陷修复：日志条目全部粘成一行

`Sources/Diagnostics/LogWriter.swift`：`record` 拼出 `[时间戳] 事件` 之后没有补行尾换行，于是所有日志条目首尾相接写成一行。

生产日志实证（本机 `~/Library/Logs/Pi Web Desktop/Pi Web Desktop.log`）：

```
最长行 19286 字符
[2026-10-24 19:26:36] 服务进程已退出[2026-10-24 19:26:36] 启动失败：pi-web 进程已退出。…
[2026-10-24 19:26:36] 忽略过期的启动轮询回调（回调代次 1，当前代次 1）[2026-10-24 19:26:39] 健…
```

后果是日志基本不可读：`grep` 只能匹配到整行、`tail -n 20` 只给出一个巨型行、任何按行解析的排查手段全部失效。用户按应用提示去"查看日志"时，看到的是一坨没有结构的长文本。

修复只在写入末尾补一个换行，块内已有的 `\n` 保持原样 —— `PiCLIUpdateModel.logLine` 依赖它在一条记录里拼多行决策详情，整体替换会破坏那个格式。

**注意**：修复只影响之后的写入。已经存在的日志文件不会自动重排，旧内容仍是粘连的。

## 缺陷修复：启动失败后健康监控空转

`Sources/App/AppDelegate+Service.swift`：启动失败走 `reportStartupFailure` 时把状态设成 `.failed`，但没有停止健康监控。

之后监控按 4 秒周期继续探测一个已经死掉的进程。生产日志记录到**17 分钟内 258 条「连续失败」**。而断开/重启判定只对 `.running` 状态生效，所以 `.failed` 下这些探测既改不了状态、也永远触发不了重启，纯粹是空转：白烧 CPU，还把真正的日志冲掉。

修复：启动失败时调用 `stopHealthMonitor()`。同时把重试入口改成幂等 —— 原来重复调用会叠加计时器，叠加后探测频率翻倍，停止时还会漏掉一个。

## 测试修复：一条从未真正断言过的循环

`PiWebDesktopTests/QuitPolicyTests.swift`：一条循环断言的是静态常量 `QuitPlan.stopsExternalService`，循环变量 `plan` 拿到就扔了。每个 behavior 都在重复断言同一个 `false`。

改为比对 `plan.stopsManagedService == (behavior == .stopService)`，循环现在真的按 behavior 逐项校验。

## 验证

本机 macOS 27.0，Apple Silicon。

- `./Scripts/build.sh`：成功，`CFBundleShortVersionString=0.1.0-alpha.20`，`CFBundleVersion=20`，`LSMinimumSystemVersion=26.0`，`Mach-O 64-bit executable arm64`；
- `xcodebuild test`：`Executed 923 tests, with 0 failures (0 unexpected)`；
- 连续 3 轮完整测试：923 / 923 / 923，均 0 失败（无 flaky）；
- 启动/退出循环 20 次：20/20 通过；
- 并发启动 6 个实例：6/6 通过（单实例锁行为正常）；
- `./Scripts/check-identity.sh`：`PASSED (45 checks)`；
- `./Scripts/check-release-version.sh v0.1.0-alpha.20`：`PASSED`；
- `./Scripts/smoke.sh`：`OK`（两种模式均 exit 0）；
- `./Scripts/scan-secrets.sh`：`PASS`；
- 干净构建警告扫描：0 warning、0 error（排除 Xcode 工具链的 AppIntents 提示）。

真实更新链路演练（对 `v0.1.0-alpha.19` 的发布资产）：

- 下载 `Pi-Web-Desktop-0.1.0-alpha.19+build.19.zip` → 1662862 bytes；
- 公布 SHA-256 与实际 `shasum -a 256` 完全一致；
- 解压后 `Info.plist` 为 `0.1.0-alpha.19` / `26.0`；
- `codesign --verify --deep --strict` 退出 0。

## 已知限制

- ad-hoc 签名、未公证：首次手动安装需要按 macOS 提示放行；
- macOS 14 / 15 不在支持范围，本版不针对它们做任何验证；
- 日志粘行的历史内容不会自动修复。

上一版 `v0.1.0-alpha.19` 的资产仍然保留，回退会带回本版修掉的两个缺陷。
