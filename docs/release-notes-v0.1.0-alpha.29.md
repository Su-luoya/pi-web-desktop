# Pi Web Desktop 0.1.0-alpha.29（build 29）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.29` 面向 Apple Silicon（arm64）与 **macOS 26 或更高版本**。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版没有新功能。内容是一轮代码评审的产出：修掉一处会让测试进程被 ThreadSanitizer 打死的管道数据竞争与两处管道状态机时序缺陷、去掉一个自 alpha.12 起就已失效的 Finder「打开方式」声明，并合并三份逐字同构的更新告警存取实现。**有一处用户可见行为变化**：Finder 不再把本应用列为任意文件夹的「打开方式」。无破坏性变更。

## 1. 子进程输出管道的数据竞争与状态机（GitHub #245）

### 现象

`ChildOutputPipe.source` 是可变存储属性：主线程在 `makeChildOutputPipe()` 里写入，读取队列上的 `stopChildPipe()` 同时读取它并取消自身。`tsan-test.log:2152/2197/2977/3126` 记录了 4 处 data race，并连带 4 次 `Restarting after unexpected exit` —— 测试进程被这个竞态打死，而失败报告里看到的是「测试崩溃」而不是「数据竞争」。

### 做法

- 改成 `attach(_:)` 在锁内写、`stop()` 在锁内读，`source` 不再是可变属性。
- 顺带修掉 `makeChildOutputPipe()` 的两个时序缺陷：原先先排空旧管道再建新管道，`pipe()` 失败抛错时状态会落在「既没有管道、又声称已排空」，而重启后的子进程 stdout 其实还开着，之后永远不会再被读；改为先建管道、成功后才动旧管道。`source.resume()` 原先早于 `childPipe = pipe`，事件处理器可能在登记前就看到 EOF，`childOutputFinished` 永远差一拍；改为先登记再 `resume()`。

## 2. Finder 不再把本应用列为文件夹的「打开方式」（GitHub #247）

alpha.12 为支持「拖放文件夹切换工作目录」声明了 `CFBundleDocumentTypes`（`public.folder`、role `Editor`）。拖放入口在 GitHub #233 已被移除，`Sources/` 里也早已没有 `application(_:open:)` 的处理器，但声明留在了 `PiWebDesktop.xcodeproj/project.pbxproj` 的 Debug/Release 两处构建设置里。

后果是每个文件夹的「打开方式」菜单里都列着本应用，点下去没有任何反应。本版删掉这两处声明：**Finder 不再把本应用列为文件夹的打开方式**，除此之外没有任何行为变化（应用本来就不处理这类打开事件）。

## 3. 三份同构的更新告警存取合并（GitHub #245）

`PiWebUpdateWarningStore` / `PiCLIUpdateWarningStore` / `PiPackageUpdateWarningStore` 是逐字同构的三份 UserDefaults 读写实现（读回校验、按语义化版本格式拒绝、清除全部键），只有键前缀不同。三份已经出现漂移，新增第四类组件时还要再抄一遍。

抽出 `UpdateWarningKeys` / `StoredUpdateWarning` / `UpdateWarningStore` 到 `Sources/Updates/UpdateSettingsModel.swift`，三个 store 只保留各自的键常量与类型转换；扩展包在写前与读后都额外校验 npm 包名。三个 `enum` 名与 `AppConfiguration` 的调用点不变，行为逐条对齐原实现（UserDefaults 键名与格式完全不变，已有用户的告警记录不受影响）。

`ServiceManager.startService()` 与 `ensureServerIsRunning()` 也是两份完全相同的「探测 → 代次校验 → 门控复检 → 连接或启动」，其中一份漏改就会让菜单「启动服务」与其它入口行为分叉；`startService()` 改为转发。

## 4. 文档与工程文件漂移（GitHub #246）

- `docs/development.md` 的源码统计与实际不符：99 个 Swift 文件（原写 89）、82 个进测试 target（原写 74）、17 个只进 app target（原写 15）；「Test Sources intentionally omits」清单补上漏掉的 `AppDelegate+RemoteAccess.swift` 与 `AppDelegate+UpdateProgress.swift`。
- 17 份历史文档里 217 处失效路径按可唯一映射的关系改写（`Sources/UpdateChecker.swift` → `Sources/Updates/UpdateChecker.swift` 等），每条映射都先确认目标文件存在；被按职责拆分、没有唯一新路径的文件与已删除的文件保持原样，每份文档顶部加一段「路径说明」交代拆分与行号基准。
- `docs/settings-and-workspace.md` 与 `README.md` 里「最近工作目录 / 拖放切换工作目录」的描述按已移除的功能删除，改述为「只有设置窗口一个入口」。

## 验证

本机 macOS 27.2（build 26B123），Mac16,10 / Apple M4；Node v26.13.0，Pi 1.5.0，`@agegr/pi-web` 0.13.0（Homebrew 全局安装）。

- `xcodebuild test`：`Executed 1021 tests, with 0 failures (0 unexpected)`，`** TEST SUCCEEDED **`。本版**没有新增用例**：改动是可观察行为等价的重构与一处删除，原有 1021 条用例全部通过即为验收依据。
- `xcodebuild test -enableThreadSanitizer YES`：1021 项 0 失败、**0 处 ThreadSanitizer 告警、0 次测试重启**（修复前同一份全量 TSan 日志有 4 处告警与 4 次重启）。
- `xcodebuild test -enableAddressSanitizer YES`：1021 项 0 失败、0 处 ASan 报告。
- `./Scripts/check-identity.sh`：`PASSED (45 checks)`；`./Scripts/check-release-version.sh v0.1.0-alpha.29`：`PASSED`；`./Scripts/scan-secrets.sh --self-test` 与 `./Scripts/scan-secrets.sh`：`PASS`；`sh -n Scripts/*.sh` 与 `git diff --check` 干净。
- `./Scripts/build.sh`：成功；`./Scripts/smoke.sh`：两种模式均 exit 0；`./Scripts/package-release.sh --tag v0.1.0-alpha.29`：`OK`。
- 本机演练产物（不是发布资产，CI 会重新构建）：SHA-256 `0a31b4970bd7a9a4fedca88931d2c8bbf3125ba9df2017b7ec43948a05799346`，1699881 字节。
- 发布 workflow（tag `v0.1.0-alpha.29`）：build 与 publish 两个 job 通过；发布前 `<待填写` 与 `{{...}}` 计数均为 0；发布后 `gh release download` + `shasum -a 256 -c` 复验 `OK`；appcast 已更新到本版，sha256 与 Release 资产一致。
- PR #245、#247 的 `build` workflow 在 macos-26 runner 上均为绿（含上述全部脚本）。

## 已知限制

- ad-hoc 签名、未公证：首次手动安装需要按 macOS 提示放行；换成另一个 ad-hoc 构建后首次启动可能再次提示放行（CDHash 变化导致的预期行为）。
- 远程访问**没有访问密码**：能进入同一 tailnet 的设备就能完全控制 pi-web；不想这样就不要启用。
- 菜单「重试关闭远程访问」（alpha.28 新增）需要先制造一次撤销失败才能看到，仍未在真机 tailnet 上跑通；「菜单启用 → 扫码打开 → 关闭」端到端流程从 alpha.27 起就没有自动化覆盖。
- 应用自更新的真实替换（`/Applications` 下的换包与重启）仍只有单元测试覆盖失败路径，没有端到端演练记录。
- **Finder「打开方式」的移除未做真机点验**：本版只确认 `project.pbxproj` 里已无该键、构建产物 Info.plist 不含 `CFBundleDocumentTypes`、`Sources/` 内无 `application(_:open:)` 处理函数。Finder 缓存是否会在升级后仍短暂列出本应用，未在真机验证（理论上 LaunchServices 会随 bundle 更新刷新）。
- `Sources/App` 的菜单、窗口与退出时序（含本版 `ServiceManager.startService()` 的转发改动）**只有单元测试覆盖，没有人工点验记录**。
- macOS 14 / 15 不在支持范围，本版不针对它们做任何验证。

上一版 `v0.1.0-alpha.28` 的资产仍然保留；回退会带回「子进程输出管道竞态」与「Finder 列出本应用为文件夹打开方式」的旧行为（缺陷回归，不是功能回退）。回退**不会**损坏已保存的更新告警记录：两版的 UserDefaults 键名与值格式完全一致。

## 发布资产

| 资产 | 值 |
| --- | --- |
| ZIP | `Pi-Web-Desktop-0.1.0-alpha.29+build.29.zip` |
| SHA-256 | `efa0665fa6df5552060399e29b7d40bb9eae23270c73eab9691dfb7145208631` |
| 体积 | 1741878 字节 |
| 签名 | ad-hoc（`TeamIdentifier=not set`），未公证 |
| 最低系统 | macOS 26.0 |
| 架构 | arm64（Apple Silicon） |

校验方式：

```sh
shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.29+build.29.zip.sha256
```

`package-release.sh --tag v0.1.0-alpha.29` 输出 `OK`：ZIP 内容与白名单一致、无 `__MACOSX/`，ad-hoc 签名验证通过，`spctl` 证据记录在 `Pi-Web-Desktop-0.1.0-alpha.29+build.29.evidence.md`。
