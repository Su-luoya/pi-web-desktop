# Pi Web Desktop

非官方 macOS 应用（AppKit + WebKit）。它在本机启动 [Pi Web](https://github.com/agegr/pi-web) 服务，再把服务页面显示在一个普通窗口里，让双击应用代替记命令、开终端。上游项目是 [`agegr/pi-web`](https://github.com/agegr/pi-web)。

- 适合已经在用 Pi 或 Pi Web、想在 Mac 上双击启动的人。
- 服务、agent 和你的数据都留在这台 Mac 上。应用不上传数据，不代替 Pi，也不提供把服务托管到别人机器上的云服务。
- 应用不打包 Node.js、Pi CLI 和 Pi Web，只检查它们是否存在，再启动服务。

**当前是早期 alpha，只提供 Apple Silicon 版本，应用未经 Apple 公证。** 第一次打开会被 macOS 拦下，按第 2 步放行。

## 1. 下载

打开 [Releases](https://github.com/Su-luoya/pi-web-desktop/releases)，在最新版本（标着 `Pre-release`）的 Assets 里下载 `Pi-Web-Desktop-<版本>.zip`，解压后把 `Pi-Web-Desktop.app` 拖进「应用程序」。

想核对文件完整：把同一个 Assets 里的 `Pi-Web-Desktop-<版本>.zip.sha256` 也下载到同一文件夹，打开「终端」进入该文件夹，运行

```bash
shasum -a 256 -c Pi-Web-Desktop-*.zip.sha256
```

输出里出现 `OK` 再继续；不一致就重新下载。

## 2. 第一次打开

双击应用，macOS 会提示「无法验证开发者」或「Apple 无法检查是否包含恶意软件」。应用只有 ad-hoc 签名、没有 Apple 公证，这个提示是预期行为，不是文件损坏。**不要关闭 Gatekeeper，也不要关闭 SIP。**

- macOS 14：在 Finder 里按住 Control 点按（或右键点按）应用，选「打开」，确认框里再点一次「打开」。
- macOS 15 及更新版本：右键打开不再有效。打开「系统设置 → 隐私与安全性」，向下找到被拦下的这个应用，点「仍要打开」，再按提示用密码或 Touch ID 确认。

放行只对这一个应用生效。重新下载 ZIP 后可能要再放行一次。

## 3. 补齐依赖

应用不会替你安装依赖，也不会调用 `sudo`。它只检查下面三项，缺任何一项就停在诊断页，「启动 / 重启 / 停止服务」保持灰色。

| 依赖 | 要求 | 安装命令 |
| --- | --- | --- |
| Node.js | 22.19.0 或更高 | 按官方说明安装：<https://nodejs.org/en/download> |
| Pi CLI | `pi` 命令可用 | `npm install -g --ignore-scripts @earendil-works/pi-coding-agent` |
| Pi Web | `pi-web` 命令可用 | `npm install -g @agegr/pi-web` |

在诊断页点「复制安装命令」，到「终端」粘贴执行，回到应用点「重新检测」，三项都变绿后点「开始使用 Pi Web」。应用只复制命令文本，不会替你执行。

诊断页还会提示默认端口 `30141` 是否被占用、`~/.pi/agent` 是否存在，这两项只提示，不阻塞启动。手工核对依赖：`node --version`、`pi --version`、`npm ls -g @agegr/pi-web`。上游的 `pi-web` 目前没有 `--version` 选项，所以用 `npm ls -g` 看版本。

`pi-web` 装在非标准位置时，在诊断窗口点「选择 pi-web 路径…」手动指定。

## 4. 日常使用

- 主窗口就是服务页面，默认地址 `http://127.0.0.1:30141/`，只监听本机。
- 菜单「服务」里能启动、重启、停止服务，用浏览器打开页面，复制地址，打开日志，复制诊断，重做依赖诊断，检查更新。
- 菜单「服务 → 最近工作目录」里能切回最近用过的目录（最多 10 条，可单独清除），也可以把文件夹拖到应用图标或窗口来切换；切到非当前目录前会先确认，托管中的服务按新目录重启。
- 日志写在 `~/Library/Logs/Pi Web Desktop/Pi Web Desktop.log`，超过 10 MB 自动轮转，保留 5 份。
- 「复制诊断」复制的是脱敏后的文本，复制前会弹提醒。脱敏不能保证万无一失，粘贴到公开 Issue 或讨论前自己再看一遍。
- 默认退出行为是「每次退出时询问」。菜单里另有「退出 Pi Web Desktop（保持服务运行）」和「退出 Pi Web Desktop（停止服务）」两个明确入口。应用不会停止不是它启动的服务。

设置项、工作目录和退出行为的完整说明：[设置、工作目录与退出行为](docs/settings-and-workspace.md)。

## 常见问题

### 打开时被系统拦下

见第 2 步。旧版 macOS 用右键「打开」，macOS 15 及更新版本走「系统设置 → 隐私与安全性 → 仍要打开」。

### 诊断页说缺 Node.js 或 pi-web

应用不会替你装依赖。点「复制安装命令」，到「终端」执行，回来点「重新检测」。仍然识别不到时，先确认命令本身可用（`node --version`、`pi --version`、`npm ls -g @agegr/pi-web`），`pi-web` 装在非标准位置就在诊断窗口手动指定路径。

### 端口 30141 被占用

如果占用者就是你自己那个 Pi Web 服务，应用会直接复用它。确实是冲突时，在「设置… → 服务 → 端口」换成空闲端口并保存，应用会用新端口重启服务。

### 想从手机或另一台电脑访问

默认只监听本机回环地址，局域网里其它设备连不上。在「设置… → 远程访问」里先保存一个非空密码，再把「监听地址」改成你要监听的具体地址（应用拒绝 `0.0.0.0`、`::` 这类写法），保存后重启服务。

**密码认证只验证访问者，不等于传输加密。** 明文 HTTP 在网络上可能被偷看，请自备加密隧道（例如 SSH 端口转发）或 HTTPS 反向代理，并且只在你信任的网络里开放。用完把监听地址改回 `127.0.0.1`，或删除密码（应用会把地址收回 `127.0.0.1`）。

### 想彻底删掉

1. 退出应用；如果之前选过「保持服务运行」，先停掉仍在运行的 `pi-web`。
2. 把 `Pi-Web-Desktop.app` 拖进废纸篓，放到过几处就删几处。
3. 打开「终端」，执行下面的命令清理应用留下的内容（`~` 是你的用户主目录）：

   ```bash
   defaults delete io.github.su-luoya.pi-web-desktop 2>/dev/null || true
   rm -rf ~/Library/Application\ Support/Pi\ Web\ Desktop
   rm -rf ~/Library/Logs/Pi\ Web\ Desktop
   rm -rf ~/Library/WebKit/io.github.su-luoya.pi-web-desktop
   rm -rf ~/Library/Caches/io.github.su-luoya.pi-web-desktop
   ```

4. 设过远程访问密码的话，打开「钥匙串访问」搜索 `Pi Web Desktop`（服务名 `io.github.su-luoya.pi-web-desktop`），删除账号为 `remote-access-password` 的条目；也可以删应用前先在应用里点「删除密码」。

以上不会影响 Pi CLI、Pi Web 或 Node.js 自己的数据。完整清单：[隐私说明](docs/privacy.md#本地数据一览与删除)。

## 更新与隐私

- 应用不收集遥测。检查更新只发只读 `GET` 请求：桌面应用查 `api.github.com`，Pi CLI、Pi Web 和扩展包查 `registry.npmjs.org`。请求不带会话内容、账号凭据或诊断内容。有新版本时用应用内提示框提示，不用系统通知。
- 启动后立即检查一次，之后桌面应用、Pi CLI、Pi Web 每 24 小时一次，扩展包每 7 天一次。四类都能在「服务 → 更新检查设置」里单独改成每周或关闭。应用退出后不检查，也不装后台组件。
- 自动更新默认关闭。打开后只对应用能验证的 npm 全局安装生效，目标版本还必须来自本次网络检查结果，缓存回退只提示。**Pi Web 的「启动前自动更新」会运行上游包自己的安装脚本**，以你的用户权限、用你的 npm 配置运行；不想这样就别打开这个开关。
- 手动更新入口（「立即更新 Pi Web…」「立即更新 Pi CLI…」「查看 Pi 扩展包更新…」）会先展示命令与版本，需要你确认；取消是默认选择。
- 更新超时或你退出应用时放弃等待，应用会写一条「已放弃、结束时间未知」的记录：它停止等待后不知道那个进程何时结束、有没有结束，所以不写假时间。有这条记录的组件不会自动重复更新，手动更新仍可用。清除入口是「服务 → 更新检查设置 → 已放弃的更新记录…」，组件后来成功更新一次也会自动清除。
- 回滚能力有限。只有来源是应用能验证的 npm 全局安装、旧可执行文件仍在原位且身份与指纹一致时，应用才会把服务或版本重检测指回旧文件；其它情况写「无法自动回滚」并给出手动命令（应用不执行）。更新后的验证只检查可执行文件、版本、包名和健康检查，不做代码签名验证与安装包比对。

字段、脱敏规则和本地数据位置见 [隐私说明](docs/privacy.md) 与 [日志与诊断导出](docs/logging-and-diagnostics.md)。

## 已知限制

- 未公证：只有 ad-hoc 签名，第一次打开需要手动放行。
- 只有 Apple Silicon（arm64）产物，需要 macOS 14 或更高。Intel Mac 不在支持范围。
- 早期 alpha：可能有 bug 和行为变化，没有响应或修复时限。
- 扩展包没有无人值守更新，只有「关闭 / 检查并通知 / 询问后更新」；确认一次只执行一次。
- 远程访问默认关闭，应用不提供加密隧道或反向代理。

其他维度（应用内更新、支持承诺等）见[开发说明的支持矩阵](docs/development.md#支持矩阵与非承诺)。

## 参与项目

- 从源码构建、跑测试、目录结构：[开发说明](docs/development.md)
- 发布流程、版本门槛与 CI 固定策略：[发布流程](docs/releasing.md)
- 提 Issue 与 PR 的流程：[贡献指南](CONTRIBUTING.md)
- 安全漏洞请按[安全政策](SECURITY.md)私密报告，不要在公开 Issue、PR 或日志里粘贴凭据或未脱敏内容
- 其他文档：[架构说明](docs/architecture.md)、[安全设计](docs/security-ownership.md)、[设置、工作目录与退出行为](docs/settings-and-workspace.md)

Pi Web、Pi CLI、Pi packages 自身的问题请先到对应上游仓库确认；本仓库是社区维护的非官方项目，与上游维护者没有隶属、赞助或背书关系，也不分发上游代码。

以 MIT License 发布，见 [LICENSE](LICENSE)；参与讨论和贡献前请读[行为准则](CODE_OF_CONDUCT.md)。
