# Pi Web Desktop 0.1.0-alpha.22（build 22）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.22` 面向 Apple Silicon（arm64）与 **macOS 26 或更高版本**。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版只有一处修复：监听地址在本机不存在时，启动不再直接失败。没有新增功能，没有破坏性变更。

## 缺陷修复：监听地址失效导致 pi-web 启动即退出

### 现象

设置里把监听地址保存为 Tailscale 这类覆盖网络地址后，一旦 Tailscale 未运行或地址发生变化，应用弹出：

```
pi-web 进程已退出。请查看日志：~/Library/Logs/Pi Web Desktop/Pi Web Desktop.log
```

而日志里的真实原因与地址有关：

```
code: 'EADDRNOTAVAIL',
errno: -49,
syscall: 'listen',
address: '100.x.y.z',
port: 30142
[pi-web] Next.js exited unexpectedly (code 1)
```

本机没有这个地址，pi-web 一 `bind` 就失败并立即退出。应用只看到「子进程退出了」这件事，于是报出通用文案；用户无法判断是地址问题、端口问题还是安装问题。

### 修复

新增 `Sources/App/ListeningAddressFallback.swift`，在启动前判断「本机当前是否真的有这个地址」：

- 先过既有的地址校验：空值、含空白、非法字符、通配地址一律不参与回落，诊断文案仍由原有路径给出；
- loopback（`127.0.0.1`、`::1`、`localhost` 等）永远视为存在；
- IPv4 / IPv6 字面量直接与本机接口快照（`getifaddrs`）比较，不查 DNS；
- 主机名走 `getaddrinfo`，并要求解析结果至少有一条属于本机接口地址；
- 只有「确定不存在」才回落，回落目标是 `127.0.0.1`。

回落时：

- **设置里的地址保持原样**，不回写。下次启动会重新检测，地址恢复就继续用原地址；
- 弹一次警告说明「监听地址不在本机」，附「打开设置」按钮，并在日志写一行 `监听地址回落：…`；
- 子进程参数、健康探测 URL、窗口加载地址、系统代理告警与诊断导出的 `launchCommand` 全部使用本次实际生效的地址，不会出现「进程用了 A、界面连 B」。

首次启动路径（`startAtLaunch` 直达 `ensureServerRunning`，不经过配置更新回调）也做了重算，否则首次启动仍会使用失效地址。

### 权衡

生效地址在启动决策点算一次并缓存，不在每次访问时重算 —— `getaddrinfo` 可能阻塞主线程。代价是运行过程中 Tailscale 恢复不会自动切回，需要重启应用。这与「下次启动重新检测」的设计一致。

## 验证

本机 macOS 27.0，Apple Silicon。

- `xcodebuild test`：`Executed 937 tests, with 0 failures (0 unexpected)`；本版新增 12 条用例，其中包含首次启动路径与「地址仍在本机时不回落」的反向用例；
- `./Scripts/build.sh`：成功，`CFBundleShortVersionString=0.1.0-alpha.22`，`CFBundleVersion=22`，`LSMinimumSystemVersion=26.0`，`Mach-O 64-bit executable arm64`；
- `./Scripts/check-identity.sh`：`PASSED (45 checks)`；
- `./Scripts/check-release-version.sh v0.1.0-alpha.22`：`PASSED`；
- `./Scripts/smoke.sh`：`OK`（两种模式均 exit 0）；
- `./Scripts/scan-secrets.sh`：`PASS`；
- 真机端到端：把监听地址临时改成本机不存在的地址后启动，实际执行 `pi-web --hostname 127.0.0.1 --port 30152`，监听 `127.0.0.1:30152`，日志出现 `监听地址回落：…`，不再出现「进程已退出」；改回原地址后启动仍使用原地址。

## 已知限制

- ad-hoc 签名、未公证：首次手动安装需要按 macOS 提示放行；
- macOS 14 / 15 不在支持范围，本版不针对它们做任何验证；
- 回落只在启动时判断一次。运行中网络地址消失（例如 Tailscale 掉线）不会触发重新绑定，port/地址变更需要重启应用；
- 本版只覆盖「地址不在本机」这一种启动失败。端口被占用、npm 包损坏等其它原因仍会显示通用提示，具体原因需要看日志。

上一版 `v0.1.0-alpha.21` 的资产仍然保留，回退会带回本版修掉的启动失败。
