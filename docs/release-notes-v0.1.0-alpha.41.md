# Pi Web Desktop v0.1.0-alpha.41（build 41）

Apple Silicon（arm64）、macOS 26+ 的 alpha prerelease；ad-hoc 签名、未公证，不含 Node.js、Pi CLI 或 Pi Web。

## 摘要

- 应用内更新不再把「装在 `/Applications`」写死：`/Applications` 与 `~/Applications` 两处的应用包都可以被更新流程替换。`Scripts/install.sh` 装的正是 `~/Applications`，修复前用自家装机脚本装出来的包永远走不到更新那一步。
- 除安装位置外的判定与以前完全一致：包名必须精确是 `Pi-Web-Desktop.app`、自身与父目录都不能是符号链接、`Contents/Info.plist` 必须真实存在、父目录写权限要探查通过。
- 两个目录之外的位置（下载目录、`~/Program/...` 这类开发目录）仍然拒绝就地替换，避免把「装到哪」变成不可控。
- 失败提示改成「当前应用不在 /Applications 或 ~/Applications 里，无法自动更新。」

## 范围与安全边界

改动只在更新安装器的前置判定上：`Sources/Updates/DesktopAppUpdate.swift` 的 `canReplaceInstalledApp` 从单一根目录改为根目录列表，`defaultApplicationsRoots` 是 `/Applications` 加 `~/Applications`。替换动作本身（先换 `Pi-Web-Desktop.app.new`、再删旧、重启新包）没有改动，仍要求用户确认后才执行，仍然没有无人值守的自动更新。

留在原处的限制是刻意的：判定对应用名、符号链接、`Info.plist` 与父目录写权限逐项检查，所以「能把应用文件挪到别处」不等于「能让更新流程随便覆盖任意路径」。

## 真机记录

本机（Mac16,10 / Apple M4；macOS 27.2.1（26B131）；arm64；Node.js v26.13.1；Pi 1.5.2；`pi-web` 0.17.0）已用本轮源码构建的包替换 `~/Applications/Pi-Web-Desktop.app`，启动、菜单与更新检查正常，`codesign --verify --deep --strict` 通过。

修复要真正跑通，需要存在一个比已装版本更新的发布包，因此「在 `~/Applications` 里点更新、下载、换包、重启」这一整条只能在 alpha.41 发布之后由本机再走一遍；那一轮的结果按惯例写入逐版本执行记录，不写进这里冒充发布前已验证。

## 验证记录

- 本地全量 XCTest：**1114 tests, 0 failures**（比 alpha.40 多 1 项，为本次新增的安装位置判定用例）；默认 `-O -wmo` 发布构建通过。
- 启动 / 诊断两种 smoke 均退出 0（诊断 fixture 仍为 `items=6 blockers=3`，是确定性测试数据，不是本机依赖缺失）。
- 身份检查 **45 checks** 通过；`check-release-version.sh` 通过（MARKETING_VERSION 0.1.0-alpha.41 / CURRENT_PROJECT_VERSION 41）。
- 并发门禁 `check-concurrency.sh`：clean（103 files, 12 baseline annotations）。
- `scan-secrets.sh` 与其自测均通过；扫描通过不等于没有秘密。
- 签名完整性通过，`Signature=adhoc`、`TeamIdentifier=not set`；未公证，不代表 Developer ID 或 Apple 公证。
- S1 / S2 复核：`git grep -n "kill(" -- Sources` 只有 `DiagnosticsCollector`、`CommandRunning`、`ProcessInspector`、`ServiceOwnership` 的存活探针与单进程终止，无命令行子串匹配的停止路径；`sendGroupSignal` 调用点仍在 `ServiceManager`（3 处）与 `ServiceOwnership`（2 处）；`KeychainStore`、`remoteAccessPassword` 零命中，`PI_WEB_PASSWORD` 只剩 `ServiceLaunching` 的清除逻辑与 `LogRedactor` 的脱敏规则。
- PR、main CI、公开资产 checksum 与 appcast 的最终证据在合并与打 tag 后追加到逐版本执行记录，不以本地演练值冒充 CI 公开资产。

## 已知限制与未验证范围

- ad-hoc 签名、未公证；首次打开或新的应用构建可能需要在「系统设置 → 隐私与安全性」中针对这一个应用放行，或通过 Finder 右键打开。不关闭 Gatekeeper。
- 只支持 Apple Silicon、macOS 26+。
- 应用在 `/Applications`、`~/Applications` 之外时（例如直接在 `build/` 里运行、或解压到下载目录就地打开），应用内更新仍然只给出手动替换的指引。
- 本版没有改动的部分不受影响：更新的下载、换包与重启流程本轮未做代码改动，其可靠性仍以 alpha.40 的验证为上限。
- 未用 VoiceOver 逐项朗读，未在另一台 Mac 验证首次 Gatekeeper 放行。

## 回退

保留 [alpha.40](https://github.com/Su-luoya/pi-web-desktop/releases/tag/v0.1.0-alpha.40) 的 ZIP 与 checksum；退出应用后解压并替换应用包。无设置 schema 或服务数据迁移，应用内安装器不提供自动降级。从 appcast 移除本版条目可停止推送。
