# Pi Web Desktop v0.1.0-alpha.42（build 42）

Apple Silicon（arm64）、macOS 26+ 的 alpha prerelease；ad-hoc 签名、未公证，不含 Node.js、Pi CLI 或 Pi Web。

## 摘要

- 应用内更新不再把结果投递到任意队列：桌面更新的完成回调改为在主线程交付，下载与换包仍走后台队列；失败时保留重试缓存，重试不会因为上一次的旧回调而串结果。
- 服务就绪探测收成一条路径：启动、配置变更与「服务未运行」三种情形共用 `ServiceManager.connectToReadyService`，生命周期代际与启动门控的判定只写一次，未就绪时的后续动作由调用方给。
- 更新命令的环境变量有了唯一定义：`UpdateCommandEnvironment.make` 只传 `PATH`/`HOME`/`TMPDIR`/`LANG`/`LC_ALL`/`LC_CTYPE` 里非空的值，并把命令所在目录放在 `PATH` 最前，npm 与 pi 都能找到自己的 `node`。
- 构建与校验脚本共用一份 xcconfig 读取规则（`Scripts/xcconfig.sh`），`check-identity.sh`、`check-release-version.sh`、`build.sh` 不再各自解析同一个文件。
- 清理：删掉无引用的历史文档与未使用的测试辅助类型；`AllowlistRedirectDelegate` 从两份几乎相同的委托收成一份带判定闭包的实现。

## 范围与安全边界

更新的信任边界没有放宽：appcast 仍只取 tag，zip 地址与 SHA-256 仍由 `DesktopAppReleaseAssetSelector.select` 钉死在 `github.com/<repo>/releases/download/<tag>/<name>` 与 64 位十六进制；重定向仍逐跳判定，拿不到 URL 时拒绝。换包脚本的动作与顺序没变（等本进程退出 → 备份旧包 → 换新包 → 删备份 → 启动新包），仍要求用户在对话框里确认，仍然没有无人值守的自动更新。

服务侧只合并了探测流程，没有新增信号路径：`sendGroupSignal` 调用点仍在 `ServiceManager` 与 `ServiceOwnership`，停止仍只对通过所有权验证的进程组生效。

## 真机记录

- 机器与芯片：Mac16,10 / Apple M4
- macOS：27.2.1（26B131）
- 架构：arm64
- Node.js：v26.13.1
- Pi（`@earendil-works/pi-coding-agent`）：1.6.0
- `@agegr/pi-web`：0.17.0
- `./Scripts/smoke.sh`：启动模式 `smoke: ready`（退出 0）、诊断模式 `smoke: diagnostics items=6 blockers=3` + `smoke: diagnostics ready`（退出 0），脚本整体退出 0
- 应用包：`Pi-Web-Desktop.app`，`CFBundleShortVersionString=0.1.0-alpha.42`，`CFBundleVersion=42`

本轮构建、签名、smoke 与扫描都是在本机这个候选提交上跑出来的；应用内就地更新（41 → 42）要等本版发布后才有可下载的新包，因此不在发布前记录里冒充已验证，结果按惯例追加到逐版本执行记录。

## 验证记录

- 本地全量 XCTest：**1115 tests, 0 failures**（在 `c6a4ddf` 合并后的 main 上跑过；本版没有改测试）。
- 默认 `-O -wmo` 发布构建通过；`check-identity.sh` **45 checks** 通过；`check-release-version.sh v0.1.0-alpha.42` 通过（MARKETING_VERSION 0.1.0-alpha.42 / CURRENT_PROJECT_VERSION 42）。
- 并发门禁 `check-concurrency.sh`：clean（104 files, 7 baseline annotations）。
- 启动 / 诊断两种 smoke 均退出 0（诊断 fixture 仍为 `items=6 blockers=3`，是确定性测试数据，不是本机依赖缺失）。
- `scan-secrets.sh` 与其自测均通过（`suppressed 17 lines`、无 rejected）；扫描通过不等于没有秘密。
- 签名完整性通过，`Signature=adhoc`、`TeamIdentifier=not set`，`spctl` 预期 `rejected`（退出 3）；未公证，不代表 Developer ID 或 Apple 公证。
- S1 / S2 复核：`git grep -n "kill(" -- Sources` 只有存活探针与单进程终止，无命令行子串匹配的停止路径；`KeychainStore`、`remoteAccessPassword` 零命中，`PI_WEB_PASSWORD` 只剩 `ServiceLaunching` 的清除逻辑与 `LogRedactor` 的脱敏规则。
- PR、main CI、公开资产 checksum 与 appcast 的最终证据在合并与打 tag 后追加到逐版本执行记录，不以本地演练值冒充 CI 公开资产。

## 已知限制与未验证范围

- ad-hoc 签名、未公证；首次打开或新的应用构建可能需要在「系统设置 → 隐私与安全性」中针对这一个应用放行，或通过 Finder 右键打开。不关闭 Gatekeeper。
- 只支持 Apple Silicon、macOS 26+。
- 应用在 `/Applications`、`~/Applications` 之外时，应用内更新仍然只给出手动替换的指引。
- 本版没有改动的部分不受影响：更新下载与换包的判定逻辑本轮只做结构整理，其可靠性仍以 alpha.41 的验证为上限；`/Applications` 内的就地更新仍未实测。
- 未用 VoiceOver 逐项朗读，未在另一台 Mac 验证首次 Gatekeeper 放行。

## 回退

保留 [alpha.41](https://github.com/Su-luoya/pi-web-desktop/releases/tag/v0.1.0-alpha.41) 的 ZIP 与 checksum；退出应用后解压并替换应用包。无设置 schema 或服务数据迁移，应用内安装器不提供自动降级。从 appcast 移除本版条目可停止推送。
