# Pi Web Desktop 0.1.0-alpha.31（build 31）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.31` 面向 Apple Silicon（arm64）与 **macOS 26 或更高版本**。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版修掉两个长期存在的缺陷。**手机扫码打不开**的根因是 Tailscale serve 的代理目标写成了本机自己的 tailnet 地址，tailscaled 不会把请求转给这种目标；现在代理目标固定为本机回环，手机访问只剩「服务 → 手机访问」这一条入口。**「立即更新 Pi Web」在有新版本时仍报「没有可用的目标版本」**，因为版本查询只认运行中的本机服务；现在服务不可用时回落到 npm，自动与手动更新都能拿到目标版本。另有更新进度窗口的版式重做。**有破坏性变更**，见第 2 节。

## 1. Pi Web 版本查询在本机服务不可用时回落 npm

### 现象

上游发了新版本、菜单也提示有可用更新，点「立即更新 Pi Web…」却弹「当前不能立即更新 Pi Web / 原因：没有可用的目标版本」，日志同时写着「Pi Web 启动前自动更新：不执行（没有可用的目标版本）」。

### 原因

Pi Web 的版本查询只有一个端点工厂 `UpdateEndpoint.piWebAppUpdate(serviceURL:)`，它要求本机 pi-web 服务正在回环地址上运行，由服务自己向 npm 查最新版本。两个场景下这个前置条件不成立：**启动前自动更新发生在服务起来之前**，**手动入口在服务绑到具体地址时**端点工厂也会拒绝非回环地址。于是整轮检查把 Pi Web 这一项跳过（alpha.27 #235 起）。

### 做法

`UpdateChecker.endpoint(for:packageName:)` 的 `.piWeb` 分支改为服务端点 `?? npmLatest(packageName:)`：服务在回环上时仍走 `/api/app-update`，不重复向 npm 问同一个问题；服务没运行或绑在非回环地址时，桌面端直接查 `registry.npmjs.org`。检查入口不再用 `guard` 跳过这一项，两种路径都会真的查一次并写出缓存。更新检查说明里「访问的域名」一节同步说明这条回落。

## 2. 手机扫码打不开：serve 的代理目标改回环（破坏性变更）

### 现象

点「启用远程访问」后，菜单里「手机访问链接」给的 `http://100.x.y.z:<端口>/` 能打开，而弹出的二维码指向的 `https://<机器名>/` 在手机和浏览器里都一直转圈；两个子菜单回答的是同一个问题，答案却互相冲突。

### 原因

`RemoteAccessController.enable` 把代理目标取成 `configuration.serviceURL`，即服务当时的监听地址。服务监听在 tailnet 地址上时，装进 Tailscale 的条目就是 `http://100.x.y.z:<端口>/`。**tailscaled 不会把请求转给指向自己 tailnet 地址的目标**：实测把它改成 `http://127.0.0.1:<端口>` 时 `https://<机器名>/` 立刻 200，改回 tailnet 地址则完全不回响应。这条入口从来没能工作过。

### 做法

- `TailscaleServe.loopbackTarget(port:)` 固定拼 `http://127.0.0.1:<端口>/`，`enable` 改用它。
- 监听地址不是回环时，`enable` 先把它收回 `127.0.0.1`，并把「补允许主机名」合并进同一次 `applyConfiguration`，只重启一次服务。确认框写明会中断当前会话。
- 启动对账 `RemoteAccessController.refresh(configuration:)` 改为四项同时成立才恢复「已开启」：记录里的端口还在 + `serve status` 里那条还在 + 目标确实是回环 + 服务正监听回环。旧版本写下的 tailnet 目标、监听地址已改成非回环的记录，先尽力撤销那一条（只动记录里的端口，不认别人的条目）再作废记录，让「启用」重新装一条干净的。
- 菜单合并为一个「服务 → 手机访问」：已开启时第一行直接显示地址，下面是「显示地址与二维码…」「复制地址」「在浏览器中打开」「测试访问延迟…」「关闭手机访问」；Tailscale 不可用时给原因与「重试关闭手机访问」。删除重复的「手机访问链接」子菜单及其实现（`Sources/App/ServiceAddresses.swift`、`phoneAccessMenus` 接线与对应测试）。

### 破坏性变更

- 服务不再监听具体的局域网地址：**外部入口只剩 Tailscale serve 那条 `https://<机器名>/`**，局域网直连地址（`http://100.x.y.z:<端口>/`）不再提供。
- 「手机访问链接」子菜单消失，改用「服务 → 手机访问」。
- 升级后首次启动会撤销旧版本留下的坏 serve 入口（`remoteAccess.port` 记录一并清掉），需要重新点一次「启用手机访问（Tailscale HTTPS）…」。

回退到 alpha.30 会带回扫码入口不可用的缺陷，也会让 Pi Web 更新重新报「没有可用的目标版本」。

## 3. 更新进度窗口版式重做

进度窗口的阶段列表原来用 `NSTableView` 的三列：列宽会把「说明」文字裁掉，4 行内容还套一层滚动条，窗口里留大片空白。改为普通行视图（定宽的阶段列 + 尾部截断的说明列，绝不裁半），新增一条总进度条，多出来的竖直空间全部给过程日志面板。

## 发布资产

| 资产 | 值 |
| --- | --- |
| ZIP | `Pi-Web-Desktop-0.1.0-alpha.31+build.31.zip` |
| SHA-256 | 见 Release 附件中的 `.zip.sha256` |
| 签名 | ad-hoc（`TeamIdentifier=not set`），未公证 |
| 最低系统 | macOS 26.0 |
| 架构 | arm64（Apple Silicon） |

校验方式：

```sh
shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.31+build.31.zip.sha256
```
