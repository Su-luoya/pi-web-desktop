# 修复：监听地址不在本机时 pi-web 秒退，界面只报「进程已退出」

## 现象

设置里把监听地址保存成覆盖网络地址（Tailscale 的 CGNAT 网段）后，
Tailscale 掉线或地址变化时应用显示：

```
pi-web 进程已退出。请查看日志：~/Library/Logs/Pi Web Desktop/Pi Web Desktop.log
```

日志里真正的原因是 `bind` 失败：

```
code: 'EADDRNOTAVAIL',
errno: -49,
syscall: 'listen',
address: '100.x.y.z',
port: 30142
```

本机没有这个地址，pi-web 启动即退出；应用把「启动命令执行失败」笼统报成
「进程已退出」，用户无从判断是配置问题、网络问题还是安装问题。

## 判定与策略

新增 `Sources/App/ListeningAddressFallback.swift`（纯判定，无副作用）：

- `ListeningAddressFallbackPolicy.presence(of:localAddresses:resolvesToLocalHost:)`
  只回答「本机有没有这个地址」，返回 `.present` / `.missing` / `.unknown`。
- 先过既有 `RemoteAccessPolicy.addressVerdict`：空值、带空白、非法字符、通配
  地址一律 `.unknown`，诊断文案仍由原有路径给出，不被「看起来可用」放行。
- loopback（`127.0.0.1`、`::1`、`localhost` 等）永远 `.present`。
- IPv4/IPv6 字面量按字符串与本机接口快照比较（`getifaddrs`，不查 DNS）；
  主机名走 `getaddrinfo` 并要求解析结果至少有一个属于本机接口地址。
- 只有 `.missing` 才回落；回落目标是 `ServiceConfiguration.defaultHostname`。

## 行为

- **不写回配置**：`ServiceConfiguration.hostname` 保持用户设置的原值。
- 本次启动的生效地址单独保存在 `ServiceManager.effectiveListeningAddress`，
  子进程参数、健康探测 URL（`effectiveServiceURL`）、窗口加载地址、系统代理
  告警、诊断导出的 `launchCommand` 全部以它为准——不会出现「进程用了 A、
  界面连 B」。
- 发生回落后弹一次警告：「监听地址不在本机」+ 说明 + 「打开设置」按钮，
  并在日志写一行 `监听地址回落：…`。
- 下一次启动重新检测：地址恢复就继续用原地址，不残留回落状态。

## 覆盖的调用点

首次启动（`startAtLaunch` → `ensureServerIsRunning`）不会经过
`updateConfiguration`，所以回落在 `startDecision()` 与 `startAtLaunch()` 里
都重算，避免「首次启动仍用坏地址」。

## 验证

- `PiWebDesktopTests/ListeningAddressFallbackTests.swift`（9 例）：补丁级判定
  表，含 IPv6 大小写、主机名解析器注入、非法值不回落。
- `PiWebDesktopTests/ServiceManagerTests.swift` 新增 3 例：
  - `testMissingListeningAddressLaunchesOnLoopbackAndNotifies`
  - `testPresentListeningAddressKeepsTheConfiguredHostname`
  - `testFirstLaunchAlsoFallsBackBeforeStarting`
- 全量 `xcodebuild test`：937 tests / 0 failures。
- `./Scripts/check-identity.sh` PASSED（45 checks）、`./Scripts/scan-secrets.sh`
  PASS、`./Scripts/build.sh` + `./Scripts/smoke.sh` 两种模式 OK。
