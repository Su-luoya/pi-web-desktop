# Pi Web Desktop 0.1.0-alpha.32（build 32）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.32` 面向 Apple Silicon（arm64）与 **macOS 26 或更高版本**。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版只有一个改动：**删掉「服务 → 手机访问」里的「在浏览器中打开」**。这个入口在本机永远打不开——浏览器跟随系统代理，把 Tailscale 的 MagicDNS 私有域名交给代理去解析，而代理那侧查不到这个域名；手机没有这层系统代理，同一地址一直正常。Tailscale serve 本身、地址拼接与「没有访问密码」的边界都没有变，手机访问照旧用「显示地址与二维码…」或「复制地址」。

## 1. 删掉「手机访问 → 在浏览器中打开」

### 现象

菜单「服务 → 手机访问」第一行直接显示 `https://<机器名>.<tailnet 域名>/`，点下面的「在浏览器中打开」却打不开，而同一地址在手机浏览器里正常。看起来像手机访问整个功能坏了。

### 原因

不是 Tailscale serve，也不是地址拼接。同一台机器上实测：

| 请求 | 结果 |
| --- | --- |
| `curl --noproxy '*' https://<机器名>.<tailnet 域名>/` | 200，19 ms |
| `curl http://127.0.0.1:<serve 目标端口>/` | 200 |
| `curl -x http://127.0.0.1:<代理端口> https://<机器名>.<tailnet 域名>/` | `SSL_ERROR_SYSCALL` |

本机系统代理（Wi-Fi 与 Ethernet 都指向回环上的同一个代理端口）的绕过列表只有 `localhost`、`*.local`、回环与私网段，没有 tailnet 域名。浏览器按系统代理把请求交给代理，代理在自己那侧做远程 DNS，私有域名在公网查不到，于是连接失败。手机上没有这层系统代理，所以同一地址正常。

`NSWorkspace.shared.open(url)` 这一步没有可修的地方：它只是把 URL 交给默认浏览器，失败发生在浏览器的代理配置上。

### 做法

- 「手机访问」已开启时的菜单只剩地址行、「显示地址与二维码…」「复制地址」「测试访问延迟…」「关闭手机访问」。
- 删掉只为这一项存在的 `AppDelegate.openRemoteAccessAddress(_:)`。
- `docs/settings-and-workspace.md` 的菜单说明同步，并写明删除原因。

若要本机浏览器也能打开 tailnet 域名，需要用户自己在系统代理的绕过列表里加该域名（或在代理规则里把它设为直连）。这属于用户机器配置，不在本仓库范围内，也不值得用代码去猜代理设置。

## 未变的部分

- Tailscale serve 的代理目标仍是本机回环（`http://127.0.0.1:<端口>/`），启动对账的四项条件不变。
- 仍然只做 serve、不做 funnel，仍然没有访问密码：唯一的边界是 tailnet 身份。
- 「启用手机访问」的确认框、监听地址收回回环、允许主机名补齐的流程都没有改动。

## 发布资产

| 资产 | 值 |
| --- | --- |
| ZIP | `Pi-Web-Desktop-0.1.0-alpha.32+build.32.zip` |
| SHA-256 | 见 Release 附件中的 `.zip.sha256` |
| 签名 | ad-hoc（`TeamIdentifier=not set`），未公证 |
| 最低系统 | macOS 26.0 |
| 架构 | arm64（Apple Silicon） |

校验方式：

```sh
shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.32+build.32.zip.sha256
```
