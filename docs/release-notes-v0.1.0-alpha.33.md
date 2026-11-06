# Pi Web Desktop 0.1.0-alpha.33（build 33）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.33` 面向 Apple Silicon（arm64）与 **macOS 26 或更高版本**。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版修两个问题：

- **Tailscale 明明开着，菜单「服务 → 手机访问」却说没打开。** 应用调用 Tailscale CLI 时没带 `TAILSCALE_BE_CLI=1`；macOS 独立版把 GUI 与 CLI 放在同一个可执行文件里，缺这个变量时它去拉起 GUI，往 stdout 打的不是 JSON（退出码仍是 0），解析失败就退化成「没有安装/没有运行」。现在每次调用都带上这个变量。
- **启动慢。** 打开「Pi Web 启动前自动更新」时，启动路径要等一次覆盖 Pi Web 的检查结果才放行服务；启动第一轮检查拿不到 Pi Web 版本，门控于是又串一次检查。同一构建实测 Ready 从 +2.91s 降到 **+1.08s**（服务启动 +2.83s → +0.92s）。现在服务先起来，检查在后台跑完只用于提示；发现可用更新时记一位「下次启动安装」，下一次启动才等一次检查并安装。目标版本仍然只能来自当次网络响应，运行中的服务挡住安装的判定没有放宽。

## 1. 「手机访问」误报 Tailscale 未运行

### 现象

Tailscale 已在菜单栏正常运行，本机也能连上 tailnet，但应用菜单「服务 → 手机访问」一直显示 Tailscale 没有打开，只能看到「启用手机访问」的入口。

### 原因

应用把 `/Applications/Tailscale.app/Contents/MacOS/Tailscale` 当成 CLI 直接调 `status --json`。macOS 独立版的 GUI 与 CLI 是同一个可执行文件：没有 `TAILSCALE_BE_CLI=1` 时它按「GUI 启动器」行为走，往 stdout 打一段非 JSON 的提示并**以 0 退出**，所以既不是「命令失败」也不是「没安装」，表现出来就是「Tailscale 没有打开」。本机实测：不带该变量时输出不是 JSON、退出码 0；带上之后是正常的 `{"BackendState":"Running",…}`。

### 做法

- 所有 Tailscale CLI 调用统一经 `TailscaleServe` 的环境辅助方法带上 `TAILSCALE_BE_CLI=1`，其余环境变量照旧继承。
- 新增 `TailscaleServeTests.testEveryCLICallAsksForCLIMode`，锁住 6 个调用点（`detect` / `snapshot` / `peers` / `ping` / `netcheck` / `disable`）都带这个变量，且继承的环境没被弄丢。
- 代码注释记下原因（GUI 与 CLI 同二进制、退出码 0、输出不是 JSON），避免以后被人「清理」掉。

## 2. 启动不再等更新检查

### 现象

打开「Pi Web 启动前自动更新」（默认关闭）时，从点开应用到服务就绪有明显停顿；关掉这个开关就快得多。

### 原因

`beginMainWindowLaunch` 为了拿到「服务未运行」这一条判定，必须先等到一次覆盖 Pi Web 的检查结果。而启动第一轮检查拿不到 Pi Web 的本机版本（日志里的「无法确定 2 项」），门控放行后依赖检测完成的复查又串了一次检查，启动路径因此要等两轮网络。

同一构建 A/B 已确认停顿就是这一段：关掉开关后服务启动从 +2.83s 回到 +1.11s。

| 时间点 | 修复前 | 修复后 |
| --- | --- | --- |
| 服务启动 | +2.83s | +0.92s |
| Next Ready | +2.91s | +1.08s |

### 做法

- 启动不再等检查：服务先起来，检查在后台跑完，结果只用于提示。
- 发现可用更新时记一位 `updateChecks.piWeb.deferredInstallPending`（只有布尔位，不含版本号）；**下一次启动**才等一次检查并安装。没有东西会根据本机或缓存里的旧结论安装。
- 目标版本仍然必须来自当次运行从白名单主机取得的网络响应；`.serviceRunning` 判定、包名与来源校验、版本重检测与健康检查都没有改动。
- 同一构建实测：服务启动 +2.83s → **+0.92s**，Ready +2.91s → **+1.08s**。

## 真机实测环境

| 项 | 值 |
| --- | --- |
| 机器与芯片 | Mac16,10 / Apple M4 |
| macOS | 27.2（26B123） |
| 架构 | arm64 |
| Node.js | v26.13.0 |
| Pi（`@earendil-works/pi-coding-agent`） | 1.5.0 |
| `@agegr/pi-web` | 0.15.0（Homebrew 全局安装） |
| `./Scripts/smoke.sh` | 启动模式与诊断模式均 exit 0（`items=6 blockers=3` 来自 `DiagnosticsSmokeFixture` 的确定性样例，不是本机依赖缺失） |

## 未变的部分

- 手机访问仍然只做 serve、不做 funnel，仍然没有访问密码：唯一的边界是 tailnet 身份。
- 「Pi Web 启动前自动更新」仍然默认关闭，仍然只对已验证的 npm 全局安装生效；Pi 扩展包仍然永不无人值守更新。
- 更新检查的访问域名、脱敏与日志边界都没有改动。

## 已知问题

- 启动日志里仍会出现两次「更新检查完成（启动）」（一次来自应用自己的启动检查，一次来自依赖检测完成后的复查）。两次都发生在服务就绪之后，不影响启动观感，本版没有合并它们。
- 「下次启动安装」这条路径本版只有单元测试覆盖：本机 Pi Web 当前没有可用更新，没有在真实更新上跑过端到端。

## 发布资产

| 资产 | 值 |
| --- | --- |
| ZIP | `Pi-Web-Desktop-0.1.0-alpha.33+build.33.zip` |
| SHA-256 | 以 Release 正文的校验值为准（由 workflow 从本次构建产物写入） |
| 签名 | ad-hoc（`TeamIdentifier=not set`），未公证 |
| 最低系统 | macOS 26.0 |
| 架构 | arm64（Apple Silicon） |

校验方式：

```sh
shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.33+build.33.zip.sha256
```
