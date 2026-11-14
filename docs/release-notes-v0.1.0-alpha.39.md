# Pi Web Desktop v0.1.0-alpha.39（build 39）

Apple Silicon（arm64）、macOS 26+ 的 alpha prerelease；ad-hoc 签名、未公证，不含 Node.js、Pi CLI 或 Pi Web。

## 摘要

- 「检查更新…」从“只提醒”改成一条可执行的路径：检查 → 确认 → 按 Pi CLI、扩展包、Pi Web、桌面应用的固定顺序执行 → 汇总结果。「更新」菜单只剩三项：检查更新…、更新设置…、更新记录…。
- 自动更新恢复可用：判定不再落在本机缓存结果上。检查不再发条件请求头（304 没有响应体，版本只能来自缓存文件），429/5xx 重试一次，本机 `/api/app-update` 失败时回落 npm。
- 扩展包更新不再要求“退出所有 Pi 会话”：改为在确认框里提示已运行的会话需要重启才用新版本。
- `pi update --self` 报告 already up to date 且目标版本未知时，版本未变化不再被判成验证失败。
- **升级提示**：alpha.31–38 的自动更新被上一版判定卡住，拿不到本版，请手动下载安装一次；从此之后应用内检查与更新可正常工作。

## 范围与安全边界

检查侧：只去掉了 `If-None-Match` / `If-Modified-Since` 两个请求头，并把 429/5xx 判为可重试一次；主机白名单不变，新增的回退目标只有 `registry.npmjs.org`（扩展包检查本来就在用）。桌面应用的 appcast 与 GitHub 回退顺序不变。所有请求仍是参数数组、不经过 shell、不调用 sudo。

执行侧：原来的四个组件入口（立即更新 Pi Web… / 立即更新 Pi CLI… / 查看 Pi 扩展包更新… / 下载并安装桌面应用更新…）连同各自的策略勾选框一起删除，执行只经过统一流程里的确认框（取消是默认按钮）。删除入口后应用能发起的更新动作更少，不是更多。

进程相关行为：扩展包路径不再枚举进程作为前置，但 `PiProcessInspector` 仍服务于 Pi CLI 更新与诊断页；停止受管服务仍只走 `ServiceManager` 的 `sendGroupSignal`，所有权验证失败时零信号。

## 真机记录

用户在本机实测的候选应用（同代码、同构建）确认：

1. 菜单「更新」只有三项，没有残留的分组件入口。
2. 点「检查更新…」后四类组件的结论是“已是最新”，对话框没有任何可执行更新项。
3. 更新记录里的 Pi CLI「已是最高版本」不再出现在失败项里。

本次读取的环境：Mac16,10 / Apple M4；macOS 27.2.1（26B131）；arm64；Node.js v26.13.1；Pi 1.5.2；`@agegr/pi-web` 0.16.0。

## 验证记录

- 本地全量 XCTest：**1103 tests, 0 failures**；默认 `-O -wmo` 发布构建通过。
- 启动 / 诊断两种 smoke 均退出 0（诊断 fixture 仍为 `items=6 blockers=3`，是确定性测试数据，不是本机依赖缺失）。
- 身份检查 **45 checks** 通过；`check-release-version.sh v0.1.0-alpha.39` 通过（MARKETING_VERSION 0.1.0-alpha.39 / CURRENT_PROJECT_VERSION 39）。
- 打包自测通过：ZIP 只含 8 个白名单条目、无 `__MACOSX`；本地演练 ZIP `Pi-Web-Desktop-0.1.0-alpha.39+build.39.zip` 为 1,768,779 bytes，SHA-256 `a5f13a0ea92d8f9b1a820a13695836abf9f12a50f8e0a1ffb3373694fd55cebb`（本地演练值，不作为公开资产校验值）。
- `scan-secrets.sh` 与其自测均通过，`suppressed 17 lines`、无 rejected，本版无新增抑制标记；扫描通过不等于没有秘密。
- 签名完整性通过，`Signature=adhoc`、`TeamIdentifier=not set`；未公证，不代表 Developer ID 或 Apple 公证。
- S1 / S2 复核：`git grep -n "kill(" -- Sources` 与 `sendGroupSignal` 调用点仍在 `ServiceManager` / `ServiceOwnership` / 进程探针，无命令行子串匹配的停止路径；`KeychainStore`、`remoteAccessPassword` 零命中，`PI_WEB_PASSWORD` 只剩 `ServiceLaunching` 的清除逻辑与 `LogRedactor` 的脱敏规则。
- PR、main CI、公开资产 checksum 与 appcast 的最终证据在合并与打 tag 后追加到 Release Issue 与 [逐版本执行记录](release-records/execution-log.md)，不以本地演练值冒充 CI 公开资产。

## 已知限制与未验证范围

- ad-hoc 签名、未公证；首次打开或新的应用构建可能需要在「系统设置 → 隐私与安全性」中针对这一个应用放行，或通过 Finder 右键打开。不关闭 Gatekeeper。
- 只支持 Apple Silicon、macOS 26+。
- 未执行真实 Pi CLI / 扩展包安装的端到端验证：本机的 `pi update --self` 是“已是最新”的空操作，扩展包一步在本轮检查里没有可执行更新项。
- 桌面应用一步（下载、换包、重启）在本轮没有真实跑过；自动更新判定改为基于本次网络结果后，仍需下一次上游发布才能观测到真实的自动安装。
- 未用 VoiceOver 逐项朗读，未在另一台 Mac 验证首次 Gatekeeper 放行。隔离测试与 smoke 不证明任意本机安装都能升级。
- alpha.31–38 无法通过应用内更新拿到本版，必须手动下载；这是旧判定的后果，本版不提供迁移脚本。
- 失败时同一条消息可能在日志里出现两次（coordinator 与完成回调各写一次），属于噪音，不影响结果判定。

## 回退

保留 [alpha.38](https://github.com/Su-luoya/pi-web-desktop/releases/tag/v0.1.0-alpha.38) 的 ZIP 与 checksum；退出应用后解压并替换应用包。无设置 schema 或服务数据迁移，应用内安装器不提供自动降级。从 appcast 移除本版条目可停止推送。
