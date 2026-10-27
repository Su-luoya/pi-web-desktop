# Pi Web Desktop 0.1.0-alpha.23（build 23）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.23` 面向 Apple Silicon（arm64）与 **macOS 26 或更高版本**。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版处理端口问题：配置端口被占用时自动改用空闲端口启动，并在启动失败时把日志里的真实原因说出来。没有新增功能，没有破坏性变更。

## 缺陷修复一：端口被占用时自动换端口

### 现象

配置端口被别的程序（或上一次没退干净的实例）占着时，pi-web 一 `bind` 就退出，应用弹出：

```
pi-web 进程已退出。请查看日志：~/Library/Logs/Pi Web Desktop/Pi Web Desktop.log
```

日志里的真实原因是 `code: 'EADDRINUSE', errno: -48, syscall: 'listen'`。用户需要自己打开日志、找到这一行、再回设置里改端口。

### 修复

新增 `Sources/App/ListeningPortFallback.swift`，在启动决策点探测配置端口：

- 只有**确定不可用**（`bind(2)` 返回 `EADDRINUSE`）才回落。无法判定（主机名解析、权限不足）一律不回落，沿用既有报错路径 —— 绝不因为「看起来可能被占」就把服务挪走。
- 从配置端口往后扫最多 20 个端口，取第一个可绑定的。整段都被占用时不猜，沿用配置端口，让真实失败原因保持可见。
- **设置里的端口保持原样**，不回写。下次启动重新探测，端口腾出来就继续用原端口。
- 探测绑在**本次生效的地址**上。地址已回落到 `127.0.0.1` 时探测的是回环地址 —— 原覆盖网络地址上的占用与本次无关。
- 本应用自己的实例占着端口**不算冲突**：这种情况下仍按「已有实例在运行」处理，不会把界面指向一个没人监听的端口。

回落时弹窗说明「端口 30142 已被占用 / 已临时改用 30143」，附「打开设置」按钮，日志写一行 `监听端口回落：…`。

## 缺陷修复二：启动失败时说出真实原因

新增 `Sources/Services/StartupFailureDiagnosis.swift`，启动失败时读取日志尾部（最多 16KB），识别已知特征并把可读原因放在通用文案前面：

| 日志特征 | 给出的说明 |
| --- | --- |
| `EADDRINUSE` | 端口已被其它程序占用，换端口或结束占用进程 |
| `EADDRNOTAVAIL` | 配置的监听地址当前不在本机（例如 Tailscale 未运行） |
| `EACCES` | 没有权限监听该端口或读取文件，检查端口是否低于 1024 |
| `ENOENT` | 启动所需文件不存在，通常是 pi-web 未正确安装 |
| `Cannot find module` | pi-web 依赖缺失或安装损坏，重新 `npm install -g @agegr/pi-web@latest` |
| `command not found` | 启动命令不存在，`node` 或 pi-web 不在 PATH |

- 顺序有意义：同一次失败可能同时出现多条，先匹配最具体的。
- **认不出的失败不猜**，保留原通用文案；日志路径始终保留在提示里。
- 只读文件末尾若干字节，不整份读入；末尾多字节字符被截断时返回 nil 而不是崩溃。

## 验证

本机 macOS 27.0，Apple Silicon。

- `xcodebuild test`：`Executed 954 tests, with 0 failures (0 unexpected)`，`** TEST SUCCEEDED **`。本版新增 19 条用例（端口回落 12 条、启动失败归因 7 条），含「地址回落与端口回落同时生效」「本应用实例占端口不算冲突」「认不出的失败保持原文案」等反向用例。
- `./Scripts/check-identity.sh`：`PASSED (45 checks)`；`./Scripts/scan-secrets.sh`：`PASS`；`sh -n Scripts/*.sh` 与 `git diff --check` 干净。
- `./Scripts/build.sh`：成功，0 个源码 warning。
- 真机端到端，逐项还原现场：
  1. 占用 `127.0.0.1:30142` 后启动：日志 `监听端口回落：端口 30142 当前被其它程序占用，已临时改用 30143 启动。`，实际参数 `pi-web --hostname <覆盖网络地址> --port 30143`，`defaults` 里 `service.port` 仍是 30142；
  2. 释放端口后重启：回到原端口，日志无回落行；
  3. 地址与端口同时失效：日志依次出现地址回落与端口回落两行，实际参数 `pi-web --hostname 127.0.0.1 --port 30143`；
  4. 测试结束后配置与日志文件均已还原。

## 发布后补的修复：TIME_WAIT 误判为端口占用

打包 alpha.23 后做真机验证时发现：`30142` 上没有任何进程监听，应用仍判定「被占用」并回落到 `30143`。

根因是启动前探测用的 `bind(2)` 没有开 `SO_REUSEADDR`。上一个实例退出后留下的连接处于 `TIME_WAIT`，此时 `bind` 返回 `EADDRINUSE`，但端口其实可以立刻复用 —— 于是每次重启都可能触发一次没必要的端口回落和一条「端口被占用」弹窗。

修复（`Sources/Services/DependencyProbing.swift`）：探测 socket 加 `SO_REUSEADDR`。补 3 条真绑定用例，其中「端口只有 `TIME_WAIT` 残留时探针必须报可用」在改前会失败。

重新验证（全量 957 tests / 0 failures）：

- 连续三次退出并重启应用，均直接使用 `30142`，日志无回落行；
- 在配置地址的 `:30142` 上真占一个监听套接字后启动，正确回落到 `30143`；
- 在 `127.0.0.1:30142` 上占用、配置地址是覆盖网络地址时**不**回落 —— 两个地址互不冲突，探测结论正确。

本版 Release 资产已在上述修复后重新打包，上面的 SHA-256 对应最终产物。

## 已知限制

- ad-hoc 签名、未公证：首次手动安装需要按 macOS 提示放行；
- macOS 14 / 15 不在支持范围，本版不针对它们做任何验证；
- 回落只在启动时判断一次，运行中不会重新绑定端口或地址；
- 连续 20 个端口都被占用时仍然启动失败，此时给出原始文案加上日志里的真实错误行（若属于已知特征）；
- 「打开设置」只打开设置页，不预填建议端口；是否写回设置由你决定。

上一版 `v0.1.0-alpha.22` 的资产仍然保留，回退会带回本版修掉的端口冲突问题。

## 发布资产

| 资产 | 值 |
| --- | --- |
| ZIP | `Pi-Web-Desktop-0.1.0-alpha.23+build.23.zip` |
| SHA-256 | `7dbab2c0df4a22b4f2708d54dfcf4691adc5913f656de1da01ead10225dd9357` |
| 体积 | 1638923 字节 |
| 签名 | ad-hoc（`TeamIdentifier=not set`），未公证 |
| 最低系统 | macOS 26.0 |
| 架构 | arm64（Apple Silicon） |

校验方式：

```sh
shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.23+build.23.zip.sha256
```

`package-release.sh --tag v0.1.0-alpha.23` 输出 `OK`：ZIP 内容与白名单一致（8 个条目，无 `__MACOSX/`），ad-hoc 签名验证通过，`spctl` 证据已记录在 `Pi-Web-Desktop-0.1.0-alpha.23+build.23.evidence.md`。

`./Scripts/smoke.sh`：两种模式均 exit 0（`smoke: ready` / `smoke: diagnostics ready`）。
