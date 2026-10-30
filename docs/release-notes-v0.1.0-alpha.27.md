# Pi Web Desktop 0.1.0-alpha.27（build 27）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.27` 面向 Apple Silicon（arm64）与 **macOS 26 或更高版本**。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版三处变化，无破坏性变更：手机或另一台机器连 pi-web 有了正经入口（「服务 → 远程访问」挂一条 tailnet HTTPS 入口，不设密码、不开公网）；Pi Web 的版本检查改问本机服务，桌面端不再直连 npm；顺手删掉两处没人用的功能（菜单「最近工作目录」切换、启动时的“系统代理已开启”告警）。

## 1. 远程访问：一条 tailnet 入口（GitHub #234）

### 现象

以前想从手机或另一台电脑用 pi-web，只有两条路：把监听地址改成 `0.0.0.0`（等于对整个网段完全开放，而 pi-web 没有认证层），或者自己搭一条隧道。两条都不是应用该让用户操心的事。

### 做法

「服务 → 远程访问」直接在本机的 tailnet 上挂一条 HTTPS 入口：

- 命令固定为 `tailscale serve --bg --https=<port> <target>`；CLI 候选路径包括 App Store 版放在 app bundle 内的那份（它不在 `PATH` 里）。
- 端口按 443 → 8444 → 9443 选：先看 `serve status` 里谁被占用，已指向本服务的端口直接复用，不重复挂。
- 主机名不在「允许的主机名」里时，先把主机名写进配置再挂入口（这一步要重启服务，确认框里明说会中断当前会话）。
- 挂好之后给地址和二维码：菜单里可以「显示地址与二维码…」「复制远程地址」「在浏览器中打开远程地址」，不必在手机上敲一长串域名。
- **退出应用时撤销**，按记录的端口精确撤销那条映射，从不执行 `reset`（`reset` 会连带清掉用户自己配的其它 serve 规则）。
- 启动时对账：记录里还有端口，但 `serve status` 里那条已经不在（配置被改过、上次异常退出），就清掉记录，不假装还开着。

### 取舍

**只用 serve、不用 funnel。** funnel 会把入口发布到公网，而这个功能不加访问密码——唯一的边界是 tailnet 身份。少了 password 字段，也就少了“密码写在配置里、和 tailnet 身份两套机制打架”的问题；代价是**能进入这条 tailnet 的设备就能完全控制 pi-web**，确认框里原样写出这句话，不靠文档兜底。

443 被别的服务占着时会退到 8444 / 9443，URL 因此带端口号。这是取舍：不抢别人的端口，代价是地址不那么好看。

## 2. Pi Web 版本检查改由本机服务代理（GitHub #235）

### 现象

桌面端为了拿 Pi Web 的最新版本，自己去问 `registry.npmjs.org`；而本机跑着的 pi-web 早就在做同一件事（`/api/app-update`，自带 12 小时缓存、5 秒超时、同类 npm 回源）。同一份判断在两个进程里各做一遍，还多出一条“桌面端必须能直连 npm”的隐性要求。

### 做法

- 端点新增 `piWebAppUpdate` 类型：`http://127.0.0.1:<port>/api/app-update`，主机取自 `ServiceManager` 的生效服务 URL。
- **只接受回环地址**（`localhost` / `127.0.0.1` / `::1`）：服务绑到局域网地址时，版本查询不会跟着发到别的机器上。
- 只采信 `latestVersion`；`currentVersion` 与 `updateAvailable` 一律重算（服务进程的版本可能和本机装的不是同一份）。
- 服务没运行就跳过这一类：不发请求、不记失败、不写缓存。

### 边界

检查的节奏、缓存、忽略版本、失败提示都不变；变的只是“问谁要这个数字”。Pi CLI 与扩展包仍然直连 npm（那里没有配额与重复请求的问题）。

## 3. 删掉两处没人用的功能（GitHub #233）

- **菜单「服务 → 最近工作目录」**：只在菜单里存 10 条路径、点一下切配置，但目录本来就只有一个文本框可填，切完还要重启服务。设置窗口已能选目录，「服务 → 在 Finder 中打开工作目录」保留。
- **启动时“系统代理已开启”的告警**：应用自己从不读取系统代理，也从不经它发请求；这条提示只是拿 `scutil --proxy` 的结果吓人一跳。

净变化：`Sources` 32,138 → 31,444 行、98 → 96 个文件。

## 验证

本机 macOS 27.2（build 26B123），Mac16,10 / Apple M4；Node v26.13.0，Pi 1.4.0，`@agegr/pi-web` 0.13.0（Homebrew 全局安装）。

- `xcodebuild test`：`Executed 1005 tests, with 0 failures (0 unexpected)`，`** TEST SUCCEEDED **`。本版新增 23 条用例（`PiWebDesktopTests/TailscaleServeTests.swift`）：CLI 候选路径、`status --json` 的 DNSName 解析、`serve status` 端口占用、命令构造、允许主机名拼接、启用计划的选端口与失败分支；`UpdateCheckerTests` 里直接构造检查器的用例补了显式 `piWebServiceURL`，并新增回环拒绝、`502` → `unknown`、服务未运行不发请求等断言。
- `./Scripts/check-identity.sh`：`PASSED (45 checks)`；`./Scripts/check-release-version.sh`：`PASSED`；`./Scripts/scan-secrets.sh --self-test` 与 `./Scripts/scan-secrets.sh`：`PASS`；`sh -n Scripts/*.sh` 与 `git diff --check` 干净。
- `./Scripts/build.sh`：成功；`./Scripts/package-release.sh --tag v0.1.0-alpha.27`：`OK`（白名单条目一致、无 `__MACOSX/`、ad-hoc 签名验证通过）；`./Scripts/smoke.sh`：两种模式均 exit 0（冒烟启动会构建整份菜单，包括新的「远程访问」子菜单）。
- 真机 tailnet 实测（命令行层面）：443 端口上 `tailscale serve --bg --https=443 http://127.0.0.1:<port>` 之后 `https://<机器名>/` 直接打开 pi-web，`tailscale serve status` 显示 `(tailnet only)`；撤销后同一地址连接失败。菜单点按的完整流程没有自动化覆盖，只有上述命令行验证与单元测试。
- 发布 workflow（tag `v0.1.0-alpha.27`）：build 与 publish 两个 job 通过；发布前占位符计数为 0；发布后 `gh release download` + `shasum -a 256 -c` 复验。

## 已知限制

- ad-hoc 签名、未公证：首次手动安装需要按 macOS 提示放行；换成另一个 ad-hoc 构建后首次启动可能再次提示放行（CDHash 变化导致的预期行为）。
- 远程访问**没有访问密码**：能进入同一 tailnet 的设备就能完全控制 pi-web；不想这样就不要启用。
- 远程访问需要主机名被服务接受。主机名不在允许列表时，启用会重启服务、断开当前会话（确认框里事先说明）。
- 通过菜单点按的远程访问端到端流程（启用 → 扫码打开 → 关闭）没有自动化覆盖；命令行层面的启用/撤销与状态解析已在真机验证。
- 退出应用才撤销入口：应用崩溃或被杀时，那条映射会留到下次启动的对账（对账只清本机记录，不动别人的 serve 规则）。
- macOS 14 / 15 不在支持范围，本版不针对它们做任何验证。

上一版 `v0.1.0-alpha.26` 的资产仍然保留；回退会带回“最近工作目录菜单”“系统代理告警”“Pi Web 直连 npm”的旧行为（功能回退，不是缺陷回归）。

## 发布资产

| 资产 | 值 |
| --- | --- |
| ZIP | `Pi-Web-Desktop-0.1.0-alpha.27+build.27.zip` |
| SHA-256 | 见 Release 页面同名资产（CI 重新构建，发布后回填到本节） |
| 签名 | ad-hoc（`TeamIdentifier=not set`），未公证 |
| 最低系统 | macOS 26.0 |
| 架构 | arm64（Apple Silicon） |

校验方式：

```sh
shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.27+build.27.zip.sha256
```

`package-release.sh --tag v0.1.0-alpha.27` 输出 `OK`：ZIP 内容与白名单一致、无 `__MACOSX/`，ad-hoc 签名验证通过，`spctl` 证据记录在 `Pi-Web-Desktop-0.1.0-alpha.27+build.27.evidence.md`。
