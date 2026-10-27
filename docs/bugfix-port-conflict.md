# 缺陷修复：端口冲突与启动失败原因不可见

面向版本：`0.1.0-alpha.23`（待发）。相关代码：`Sources/App/ListeningPortFallback.swift`、`Sources/Services/StartupFailureDiagnosis.swift`。

## 背景

`0.1.0-alpha.22` 修掉了「监听地址不在本机 → pi-web 启动即退出 → 只报通用文案」。同一个失败面还有两半没处理：

1. **端口被占用**：配置端口被别的程序（或上一次没退干净的实例）占着时，pi-web 一 `bind` 就退出。用户看到的仍是 `pi-web 进程已退出。请查看日志：…`，需要自己打开日志、搜 `EADDRINUSE`、再回设置里改端口。
2. **其它启动失败原因不可见**：端口低于 1024 无权限（`EACCES`）、npm 包损坏（`Cannot find module`）、`node` 不在 PATH（`command not found`）等情况，同样只报那句通用文案。日志路径给了，原因没给。

两者叠加的结果是：只要 pi-web 没能起来，用户拿到的永远是同一句话。

## 修复一：端口冲突自动换端口

新增 `ListeningPortFallbackPolicy.resolve(hostname:port:isAvailable:)`，在启动决策点判断配置端口能否绑定：

- 只有**确定不可用**（`bind(2)` 返回 `EADDRINUSE`）才回落。无法判定（主机名解析、权限不足）一律不回落，沿用既有报错路径 —— 绝不因为「看起来可能被占」就把服务挪走。
- 回落从配置端口往后扫最多 20 个端口（`scanLimit`），取第一个可绑定的。整段都被占用时不猜，沿用配置端口，让真实失败原因保持可见。
- **配置不回写**。与地址回落同一套语义：设置里的端口保持原样，下次启动重新探测，端口腾出来就继续用原端口。
- 探测绑在**本次生效的地址**上。地址已经回落到 `127.0.0.1` 时，探测的是 `127.0.0.1:端口` —— 原覆盖网络地址上的占用与本次无关。
- 本应用自己的实例占着端口**不算冲突**：这种情况下 `startDecision()` 仍返回 `.existingProcess`，生效端口保持配置端口。否则界面会去连一个没人监听的端口。

UI 与日志：启动成功前弹一次「端口 30142 已被占用」，说明已临时改用哪个端口、设置没被改动，附「打开设置」按钮；日志写一行 `监听端口回落：…`。

## 修复二：启动失败时说出真实原因

新增 `StartupFailureDiagnosis`，把日志尾部（最多 16KB）交给一组特征判定，命中就把可读原因放在通用文案前面：

| 特征 | 给出的说明 |
| --- | --- |
| `EADDRINUSE` | 端口已被其它程序占用，换端口或结束占用进程 |
| `EADDRNOTAVAIL` | 配置的监听地址当前不在本机（例如 Tailscale 未运行） |
| `EACCES` | 没有权限监听该端口或读取文件，检查端口是否低于 1024 |
| `ENOENT` | 启动所需文件不存在，通常是 pi-web 未正确安装 |
| `Cannot find module` | pi-web 依赖缺失或安装损坏，重新 `npm install -g @agegr/pi-web@latest` |
| `command not found` | 启动命令不存在，`node` 或 pi-web 不在 PATH |

- 顺序有意义：同一次失败可能同时出现多条（`EADDRINUSE` 之后跟着 `Next.js exited unexpectedly`），先匹配最具体的。
- **认不出的失败不猜**，保留原通用文案。
- 日志路径始终保留在提示里。
- 只读文件末尾若干字节，不整份读入；末尾多字节字符被截断时返回 nil 而不是崩溃。

## 验证

本机 macOS 27.0，Apple Silicon。

- `xcodebuild test`：`Executed 954 tests, with 0 failures (0 unexpected)`，`** TEST SUCCEEDED **`。本版新增 19 条用例（端口回落 12 条、启动失败归因 7 条），含「地址回落 + 端口回落同时生效」「本应用实例占端口不算冲突」「认不出的失败保持原文案」等反向用例。
- `./Scripts/check-identity.sh`：`PASSED (45 checks)`；`./Scripts/scan-secrets.sh`：`PASS`；`sh -n Scripts/*.sh` 与 `git diff --check` 干净。
- `./Scripts/build.sh`：成功，0 个源码 warning，`Mach-O 64-bit executable arm64`。

真机端到端（用构建产物，逐项还原现场）：

1. 占用 `127.0.0.1:30142` 后启动：日志 `监听端口回落：端口 30142 当前被其它程序占用，已临时改用 30143 启动。`，实际参数 `pi-web --hostname 100.76.71.55 --port 30143`，监听 `100.76.71.55:30143`，`defaults` 里 `service.port` 仍是 30142。
2. 释放端口后重启：回到 `100.76.71.55:30142`，日志无回落行。
3. 地址与端口同时失效（`service.hostname` 改为本机不存在的地址 + 占用 30142）：日志依次出现 `监听地址回落：…`、`监听端口回落：…`，实际参数 `pi-web --hostname 127.0.0.1 --port 30143`，监听 `127.0.0.1:30143`。
4. 测试结束后 `service.hostname` / `service.port` 已恢复为 `100.76.71.55` / 30142，日志文件还原。

## 已知限制

- 回落只在启动时判断一次。运行中端口被别的程序抢走（本机不允许，除非原进程已退出）不会自动重新绑定。
- 扫满 20 个端口都不可用时仍然失败，此时给出的是原始通用文案加上日志里的真实错误行（如果属于已知特征）。
- 「打开设置」只是打开设置页，不预填建议端口；写回设置需要用户自己决定。
