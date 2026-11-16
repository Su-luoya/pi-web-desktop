# Pi Web Desktop v0.1.0-alpha.40（build 40）

Apple Silicon（arm64）、macOS 26+ 的 alpha prerelease；ad-hoc 签名、未公证，不含 Node.js、Pi CLI 或 Pi Web。

## 摘要

- 关掉远程访问再退出应用之后，下次启动会把 serve 入口自动挂回去，不用每次开机再点一遍「启用」。重挂优先复用退出时的端口，手机书签里带端口的地址（`:8444` 这类）继续有效。
- 重挂时如果 CLI 已经把入口挂上、只是 tailnet 这边没启用 HTTPS，按「已装但打不开」处理：端口与 `remoteAccessCleanupPort` 一并记在自己名下，退出时才撤得掉，不会留下指向 502 的孤儿入口。
- 用户操作优先：重挂是三条 CLI 的后台链，这期间点「启用」或「关闭」，它晚到的结果整个丢弃，不会把刚写出的状态盖掉。
- 菜单去掉「在 Finder 中打开工作目录」。
- `Scripts/install.sh` 改成先装到 `Pi-Web-Desktop.app.new`，签名校验通过后才删旧换新；复制或签名失败不会连旧版一起没了。

## 范围与安全边界

重挂侧只做两件事：启动时读一次 `tailscale status --json` 与 `serve status --json`，必要时写一次 `serve --bg`。命令仍是参数数组、不经过 shell、不调用 sudo。

只在记录的端口启动后仍被本应用自己的服务占用时才重挂。端口被别人占、tailnet 没启用 HTTPS、或入口指向的不是回环地址时，一个字节都不写：丢掉标记，把这次启动交给菜单里的「启用」。

记录里只有端口号（`remoteAccess.restorePending`），不存凭据也不存主机名；它与 `remoteAccessCleanupPort` 同一模式，退出时清除。菜单少一项，不新增入口。

## 真机记录

用户在本机用本轮构建（同代码、同构建）试过一遍，结论是“应该是没问题了”。

发布清单要求的核对项是：启用远程访问后退出、重启是否自动重挂（端口是否与退出前一致）、手机用旧书签能否打开、菜单里是否已无「在 Finder 中打开工作目录」，以及重挂期间点「关闭」后状态是否保持。用户没有逐条回传结果，所以这份记录只到这个粒度：算一次上位冒烟，不等于逐项核对——端口号、手机侧的实际现象与竞态那一步是否真的触发都没有记下来。

本次读取的环境：Mac16,10 / Apple M4；macOS 27.2.1（26B131）；arm64；Node.js v26.13.1；Pi 1.5.2；`pi-web` 0.17.0。

## 验证记录

- 本地全量 XCTest：**1113 tests, 0 failures**；默认 `-O -wmo` 发布构建通过。
- 启动 / 诊断两种 smoke 均退出 0（诊断 fixture 仍为 `items=6 blockers=3`，是确定性测试数据，不是本机依赖缺失）。
- 身份检查 **45 checks** 通过；`check-release-version.sh` 通过（MARKETING_VERSION 0.1.0-alpha.40 / CURRENT_PROJECT_VERSION 40；未带 tag 参数时跳过 tag 比对）。
- 并发门禁 `check-concurrency.sh`：clean（103 files, 12 baseline annotations）。
- 打包自测通过：ZIP 只含 8 个白名单条目、无 `__MACOSX`；本地演练 ZIP `Pi-Web-Desktop-0.1.0-alpha.40+build.40.zip`，SHA-256 `b09690b773ada2902d98af9f9aa45f23d1613c7e91f00ad9f502ec7c50d0e07a`（本地演练值，不作为公开资产校验值）。
- `scan-secrets.sh` 与其自测均通过；扫描通过不等于没有秘密。
- 签名完整性通过，`Signature=adhoc`、`TeamIdentifier=not set`；未公证，不代表 Developer ID 或 Apple 公证。
- S1 / S2 复核：`git grep -n "kill(" -- Sources` 只有 `DiagnosticsCollector`、`CommandRunning`、`ProcessInspector`、`ServiceOwnership` 的存活探针与单进程终止，无命令行子串匹配的停止路径；`sendGroupSignal` 调用点仍在 `ServiceManager`（3 处）与 `ServiceOwnership`（2 处）；`KeychainStore`、`remoteAccessPassword` 零命中，`PI_WEB_PASSWORD` 只剩 `ServiceLaunching` 的清除逻辑与 `LogRedactor` 的脱敏规则。
- PR、main CI、公开资产 checksum 与 appcast 的最终证据在合并与打 tag 后追加到逐版本执行记录，不以本地演练值冒充 CI 公开资产。

## 已知限制与未验证范围

- ad-hoc 签名、未公证；首次打开或新的应用构建可能需要在「系统设置 → 隐私与安全性」中针对这一个应用放行，或通过 Finder 右键打开。不关闭 Gatekeeper。
- 只支持 Apple Silicon、macOS 26+。
- 重挂只在退出前那次远程访问仍记着端口、且该端口在本次启动后仍被自己的服务占用时生效。服务没起来（例如 Pi 未安装）时不写任何东西，需要手动点「启用」。
- 应用内更新只在 `/Applications` 下可用，且需要用户确认后才执行；没有无人值守的自动更新。
- 未用 VoiceOver 逐项朗读，未在另一台 Mac 验证首次 Gatekeeper 放行。隔离测试与 smoke 不证明任意本机安装都能升级。

## 回退

保留 [alpha.39](https://github.com/Su-luoya/pi-web-desktop/releases/tag/v0.1.0-alpha.39) 的 ZIP 与 checksum；退出应用后解压并替换应用包。无设置 schema 或服务数据迁移，应用内安装器不提供自动降级。从 appcast 移除本版条目可停止推送。
