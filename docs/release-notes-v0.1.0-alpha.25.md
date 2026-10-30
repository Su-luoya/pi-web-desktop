# Pi Web Desktop 0.1.0-alpha.25（build 25）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.25` 面向 Apple Silicon（arm64）与 **macOS 26 或更高版本**。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版解决“更新过程中什么都看不到”的问题：四类更新（桌面应用自更新、Pi Web、Pi CLI、Pi 扩展包）在真正开始执行时弹出「更新进度」窗口，逐行显示当前阶段、已脱敏的过程日志与已用时长。没有破坏性变更，更新判定逻辑一行未改。

## 新功能：更新进度窗口（GitHub #219）

### 现象

在此之前，点「立即更新 Pi Web…」「立即更新 Pi CLI…」「查看 Pi 扩展包更新…」或「下载并安装桌面应用更新…」并确认之后，应用界面上没有任何变化。一次 `npm install -g` 可能跑几十秒到几分钟，期间用户只能干等，无法判断是“还在装”还是“已经卡死”，也看不到失败在哪一步。

### 窗口内容

窗口从上到下是标题、阶段表格、过程日志、底部状态行：

| 阶段 | 含义 |
| --- | --- |
| 准备 | 记录更新前的可执行文件路径、版本与指纹，确认来源可验证 |
| 执行安装 | 运行该组件的安装命令 |
| 验证 | 版本重检测、包名与可执行文件校验、服务健康检查 |
| 启用/提交 | 提交事务，写入统一历史 |
| 降级 | 只在真的记录了降级时出现，固定在最后一行 |

每行显示状态符号、阶段名和一句说明（说明文案全部来自固定的中文短语表，不拼接进程输出）。底部状态行显示 `已用 00:32`，结束后固定为 `已用 01:05 · 更新完成（到 1.2.3）`。

### 数据来源

三处，全部是既有路径的旁路，不新增任何执行路径：

1. **事务阶段**：`UpdateTransactionJournal` 新增可选 `onPhase` 回调，三个协调器把它接到 `UpdateTransactionEnvironment.reportPhase`（默认空实现，因此未接入的调用点与现有测试行为不变）；
2. **桌面应用自更新的四个固定步骤**（核对发布页 → 下载更新包 → 校验安装包 → 替换应用），在网络回调与安装器回调处推进；
3. **统一日志**：`updateLog` 在写诊断日志的同一处把同一行（已过 `LogRedactor` 脱敏）推给窗口。

线程约定与既有代码一致：`UpdateProgressCenter` 主线程独占、不加锁，后台线程上的阶段、历史写入与日志行都由调用方 `DispatchQueue.main.async` 后再进来。

### 结束与关闭

- 结束信号只有一处——统一历史写入（`UpdateHistoryEntry`）。成功显示「更新完成（到 <版本>）」并在 2 秒后自动关窗；失败用历史里记录的第一句原因停在最前，**窗口不自动关闭**，需要用户看过再关。
- 收尾时仍在“进行中”的那一行改记为「跳过」，不留永远不完成的假进行中；重复结束只保留第一次结论。
- 会话第一次变化时自动出现一次；后续日志行不会把用户手动关掉的窗口重新弹出来。菜单「更新 → 显示更新进度…」可随时重开。
- `PI_WEB_DESKTOP_SMOKE` 启动路径不弹窗。

### 边界

- 窗口不联网、不执行命令、不读写配置、不发信号，也没有「取消更新」按钮——更新路径本身没有取消语义，加一个点了没用的按钮只会误导。
- 窗口只显示进度，不改变任何更新判定、不新增任何安装路径。
- 文本只由固定文案、已校验的版本号/包名与已脱敏日志行组成；日志最多保留 400 行。

## 验证

本机 macOS 27.2（build 26B123），Mac16,10 / Apple M4。

- `xcodebuild test`：`Executed 981 tests, with 0 failures (0 unexpected)`，`** TEST SUCCEEDED **`。本版新增 19 条用例（`PiWebDesktopTests/UpdateProgressTests.swift`），覆盖阶段映射、成功推进/失败不推进、降级行只在记录时追加、无会话与越界的晚到回调、日志去空与 400 行上限、成功收尾把进行中改记为跳过、失败沿用历史原因、重复结束只留第一次结论、窗口渲染与无会话占位文案。
- `./Scripts/check-identity.sh`：`PASSED (45 checks)`；`./Scripts/scan-secrets.sh --self-test` 与 `./Scripts/scan-secrets.sh`：`PASS`（`suppressed 17 lines`，无 `rejected` 行）；`sh -n Scripts/*.sh` 与 `git diff --check` 干净。
- `./Scripts/build.sh`：成功；`./Scripts/package-release.sh --tag v0.1.0-alpha.25`：`OK`（8 个白名单条目、无 `__MACOSX/`、ad-hoc 签名验证通过）；`./Scripts/smoke.sh`：两种模式均 exit 0。
- 真机 smoke：Node.js v26.13.0、Pi 1.4.0、`@agegr/pi-web` 0.13.0（Homebrew 全局安装）；`smoke: ready` 与 `smoke: diagnostics ready` 均出现，退出码 0。
- 发布 workflow（tag `v0.1.0-alpha.25`）：build 与 publish 两个 job 均通过；发布前占位符计数为 0；发布后 `gh release download` + `shasum -a 256 -c` 复验 `OK`。

## 已知限制

- ad-hoc 签名、未公证：首次手动安装需要按 macOS 提示放行；换成另一个 ad-hoc 构建后首次启动可能再次提示放行（CDHash 变化导致的预期行为）。
- 没有「取消更新」按钮：更新一旦开始就跑到结束或失败；关掉窗口不会中断更新。
- 手动关闭窗口后不会被后续日志行重新弹出，需要从菜单重新打开。
- 进度窗口显示的是阶段级进度，不显示 npm 的下载百分比或剩余时间——上游命令不提供这些信息，编不出来。
- macOS 14 / 15 不在支持范围，本版不针对它们做任何验证。

上一版 `v0.1.0-alpha.24` 的资产仍然保留；回退会带回“更新过程中没有任何进度可见”的体验问题（功能缺失，不是缺陷回退）。

## 发布资产

| 资产 | 值 |
| --- | --- |
| ZIP | `Pi-Web-Desktop-0.1.0-alpha.25+build.25.zip` |
| SHA-256 | `6333a829c973824649bd0e76b304ae22472218980282c8f42e2078a2eaec938a` |
| 体积 | 1701696 字节 |
| 签名 | ad-hoc（`TeamIdentifier=not set`），未公证 |
| 最低系统 | macOS 26.0 |
| 架构 | arm64（Apple Silicon） |

校验方式：

```sh
shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.25+build.25.zip.sha256
```

`package-release.sh --tag v0.1.0-alpha.25` 输出 `OK`：ZIP 内容与白名单一致（8 个条目，无 `__MACOSX/`），ad-hoc 签名验证通过，`spctl` 证据已记录在 `Pi-Web-Desktop-0.1.0-alpha.25+build.25.evidence.md`。

本地演练产物（`dist/` 里那一份）的 SHA-256 是 `7cc029d463724337e508773ce36ed783868ebfd9a76cd8c40f19d26bddc26f68`，与上面发布的 CI 产物不同——同一提交在不同机器上构建的 ZIP 字节不同，发布校验值以上表的 workflow 产物为准。
