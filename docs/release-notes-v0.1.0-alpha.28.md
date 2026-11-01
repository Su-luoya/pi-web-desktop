# Pi Web Desktop 0.1.0-alpha.28（build 28）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.28` 面向 Apple Silicon（arm64）与 **macOS 26 或更高版本**。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版没有新功能，修的全是 alpha.27 新功能的失败路径：读不到 tailscale serve 配置时不再把端口当成空闲（会覆盖别人的入口）、关不掉远程访问时不再静默丢掉记录而是留一个重试入口、应用自更新失败时不再把暂存目录和权限移交做成半成品。无破坏性变更。

## 1. 读不到 serve 配置时不再当成「端口都空闲」（GitHub #239）

### 现象

alpha.27 的 `TailscaleServe.snapshot()` 在读 `tailscale serve status --json` 失败时返回空快照。空快照的含义是「443、8444、9443 都没人用」，于是启用流程会直接往 443 上挂一条新入口——如果那一刻 443 上本来有用户自己的 serve 规则，这条映射就被覆盖了。

`serve status` 在**尚未配置任何 serve 条目**时输出的是 JSON `null`，与「命令失败」「输出不是 JSON」是完全可以区分的两种情况，把它们混在一起处理没有理由。

### 做法

- `snapshot()` 改成返回可选值：命令失败返回 `nil`，只有 CLI 明确输出 `null` 才当作空配置。
- `enable()` 拿到 `nil` 时抛 `commandFailed`，拒绝改写；启动时的对账（`refresh()`）同样在 `nil` 时**不清记录**——读不到不等于「没开」。
- 解析上收紧：端口必须是 1–65535（`0` 与 `65536` 一律判为坏数据）；同一端口上出现多个 host 或多个 handler 时记为空串（**归属未知即视为占用**，绝不覆盖）；`AllowFunnel` 里的端口也计入占用；Proxy 目标比较前按根路径归一化，`http://127.0.0.1:4317` 与 `http://127.0.0.1:4317/` 视为同一目标，不再因为一个斜杠误判成「被占用」而白白换端口。

## 2. 关不掉远程访问时给一个重试入口（GitHub #239）

alpha.27 的撤销流程在 `tailscale serve` 撤销命令失败时只写日志，然后把本机记录一起清掉。结果是菜单显示「未启用」，而 tailnet 上那条入口还在——应用已经不知道它的存在，用户也没有入口去关它。

现在：撤销失败**保留**端口与记录，并写一条持久提示；菜单里出现「重试关闭远程访问」，重试成功才清记录。退出应用时撤销失败同样保留记录，交给下次启动的对账处理。为了让这条路径可测，`RemoteAccessController` 增加了 `TailscaleServe` 的注入点。

## 3. 应用自更新失败不再留垃圾（GitHub #239）

`DesktopAppUpdate` 在解压后、启动替换脚本前失败时，暂存目录和「权限移交」标记会残留下来；下一次更新可能复用这些残留状态。现在暂存服务与替换脚本都改用 `defer` 收尾：**只有替换脚本成功启动**才移交后续责任，其余路径清理干净。`installArchive` 改为 `internal` 以便直接测试失败分支。

## 4. 取消命令时逐个终止子进程（GitHub #239）

`SystemCommandRunner` 原先只记录最后启动的那个子进程，取消时也只对它发 `SIGTERM`，同时启动的其它子进程会变成孤儿。现在按 token 跟踪全部在跑的子进程，取消时逐个发送 `SIGTERM`。

## 验证

本机 macOS 27.2（build 26B123），Mac16,10 / Apple M4；Node v26.13.0，Pi 1.4.0，`@agegr/pi-web` 0.13.0（Homebrew 全局安装）。

- `xcodebuild test`：`Executed 1021 tests, with 0 failures (0 unexpected)`，`** TEST SUCCEEDED **`。本版新增 14 条用例：`TailscaleServeTests` 覆盖配置不可读、`null` 与坏 JSON 的区分、多 host/多 handler 占端口、`AllowFunnel` 占用、端口上下界、根路径归一化；`RemoteAccessController` 覆盖关闭失败保留记录与重试；`DesktopAppUpdateTests` 覆盖解压后失败不留暂存；`ProcessInspectorTests` 覆盖多子进程取消。
- `./Scripts/check-identity.sh`：`PASSED (45 checks)`；`./Scripts/check-release-version.sh v0.1.0-alpha.28`：`PASSED`；`./Scripts/scan-secrets.sh --self-test` 与 `./Scripts/scan-secrets.sh`：`PASS`（`suppressed 17 lines`，无 `rejected` 行）；`sh -n Scripts/*.sh` 与 `git diff --check` 干净。
- `./Scripts/build.sh`：成功；`./Scripts/package-release.sh --tag v0.1.0-alpha.28`：`OK`（8 条白名单条目、无 `__MACOSX/`、ad-hoc 签名验证通过）；`./Scripts/smoke.sh`：两种模式均 exit 0。
- 本机演练产物（不是发布资产，CI 会重新构建）：SHA-256 `b42bef966e38cafa357fc8338c6cd6ae8bc5dc425e7a4e1b5b496b8ff43c7b17`，1699881 字节。

## 已知限制

- ad-hoc 签名、未公证：首次手动安装需要按 macOS 提示放行；换成另一个 ad-hoc 构建后首次启动可能再次提示放行（CDHash 变化导致的预期行为）。
- 远程访问**没有访问密码**：能进入同一 tailnet 的设备就能完全控制 pi-web；不想这样就不要启用。
- 菜单「重试关闭远程访问」需要先制造一次撤销失败才能看到，本版**没有**在真机 tailnet 上跑通这条点按流程；它由单元测试（注入失败的 serve）覆盖。alpha.27 起就存在的「菜单启用 → 扫码打开 → 关闭」端到端流程同样没有自动化覆盖。
- 远程访问需要主机名被服务接受。主机名不在允许列表时，启用会重启服务、断开当前会话（确认框里事先说明）。
- 应用自更新的真实替换（`/Applications` 下的换包与重启）仍只有单元测试覆盖失败路径，没有端到端演练记录。
- macOS 14 / 15 不在支持范围，本版不针对它们做任何验证。

上一版 `v0.1.0-alpha.27` 的资产仍然保留；回退会带回「读不到 serve 配置当成空闲」「撤销失败丢记录」「更新失败留暂存」的旧行为（缺陷回归，不是功能回退）。

## 发布资产

| 资产 | 值 |
| --- | --- |
| ZIP | `Pi-Web-Desktop-0.1.0-alpha.28+build.28.zip` |
| SHA-256 | 见 Release 页面同名资产（CI 重新构建，发布后回填到本节） |
| 签名 | ad-hoc（`TeamIdentifier=not set`），未公证 |
| 最低系统 | macOS 26.0 |
| 架构 | arm64（Apple Silicon） |

校验方式：

```sh
shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.28+build.28.zip.sha256
```

`package-release.sh --tag v0.1.0-alpha.28` 输出 `OK`：ZIP 内容与白名单一致、无 `__MACOSX/`，ad-hoc 签名验证通过，`spctl` 证据记录在 `Pi-Web-Desktop-0.1.0-alpha.28+build.28.evidence.md`。
