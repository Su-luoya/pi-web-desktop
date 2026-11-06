# Pi Web Desktop 0.1.0-alpha.34（build 34）— Apple Silicon alpha（未公证）

## 摘要

Pi Web Desktop `0.1.0-alpha.34` 面向 Apple Silicon（arm64）与 **macOS 26 或更高版本**。应用包使用 ad-hoc 签名，未经过 Apple 公证；首次手动安装仍需按 macOS 提示放行。

本版四个修复，没有新功能：

- **更新检查偶发「未知」。** 桌面应用先读 `appcast`；拿到 `304`（缓存仍然有效）时，回落判定只认 `2xx`，于是又打一次 GitHub API。GitHub 未认证配额耗尽时，一次正常的「没有更新」会变成「未知」。
- **更新包缓存不是可信路径。** 缓存目录用户可写，读取时却直接拼 `archiveName`，也没检查条目类型：`../`、符号链接或同名目录都能被当成缓存的发布包。现在读写共用一条文件名校验，读只认目录内的普通文件。
- **手机访问撤不掉时记录还会丢。** 对账发现那条 serve 条目过期却撤销失败时，旧逻辑照样忘掉端口：菜单显示「未开启」，退出时也没有记录可收尾。现在撤销失败保留记录并进「不可用」，菜单能重试关闭。
- **切换手机访问方式后地址记录不一致。** 启用 Tailscale 前先删掉自定义地址，失败后地址就丢了；关闭时只删端口、留下自定义地址，下次对账又显示「已开启」。改成成功后才清理，关闭成功时两类记录一起清。

## 1. 更新检查：`304` 不再回落到 GitHub API

### 现象

「检查更新」偶发把桌面应用报成「未知」，同一时刻 GitHub API 返回 `403`（未认证配额用尽）。日志里能看到同一轮里先请求 `appcast`、再请求 GitHub。

### 原因

`UpdateChecker.fallbackEndpoint` 决定 `appcast` 是否要回落到 GitHub API，只把 `2xx` 当作「主端点成功」：

```swift
case .success(let http) where (200..<300).contains(http.statusCode):
    return nil
```

条件请求命中缓存时状态码是 `304`，于是走进回落分支，多打一次 GitHub 请求。配额耗尽的 `403` 覆盖掉本来有效的缓存结论，结果退化成 `unknown`。

### 做法

- 判定改成 `(200..<300).contains(http.statusCode) || http.statusCode == 304`；`.offline` / `.cancelled` 的既有豁免不变。
- `testNotModifiedKeepsFreshnessButMarksCacheOrigin` 增加两条断言：假客户端只收到 **1** 次请求，且那次请求打在 feed 主机上；测试里的回答器也改成对 `appcast` 主机回 `304`、其余主机当作传输失败——修复前这两条会分别失败在 2 次请求与「回落到 GitHub」。

### 验证程度

机制与请求次数由单元测试锁住。本版没有在真机上等到 GitHub 配额耗尽再复现一次原症状。

## 2. 更新包缓存只认目录内的普通文件

### 现象

没有用户可见的报错。这是一个路径边界问题：`Application Support` 下的缓存目录是用户可写的，而读取路径把元数据里的 `archiveName` 直接拼到自己目录上。

### 原因

`DesktopUpdatePackageCache.package(matching:releaseTag:)` 只检查 `fileManager.fileExists`，写入侧也只检查资产名非空，所以：

- 被改过的元数据可以指向目录外的同名文件（`../`）；
- 同一路径换成符号链接或目录，也会被当成缓存里的发布包交给安装流程。

### 做法

- 新增 `archiveURL(named:version:)`：名字不得含 `/`，且必须通过 `DesktopAppReleaseAssetSelector.isArchiveName(_:version:)`；读写两条路径都走它。
- 读取额外要求条目是 `typeRegular`（`attributesOfItem` 的 `.type`），符号链接与目录一律当作未缓存。
- 写入时先算出目标路径再动文件：非法资产名在删除上一版缓存之前就抛 `fileWriteInvalidFileName`，不会把可用缓存清掉。
- 新增 `testRejectsMetadataPointingOutsideCache`、`testRejectsArchiveSymlinkAndDirectory`、`testRejectsUnsafeArchiveNameBeforeChangingFiles`，分别锁住「元数据越界」「符号链接/目录」「非法名字不改动文件」；最后一条同时断言目录外的同名文件内容没有被覆盖、下载到的临时文件仍在。

## 3. 手机访问：撤销失败时保留端口记录

### 现象

Tailscale 那条 serve 条目需要撤销（上次异常退出留下的残迹、旧版本把代理目标写成 tailnet 地址、监听地址改成非回环），但撤销命令失败时，菜单会显示「未开启」，而入口其实还在；退出应用后连端口记录也没了，没有地方再收尾。

### 原因

`refresh` 的 `.stale` 分支以前不看撤销结果：`serve.disable(port:)` 之后无条件返回 `.stale`，调用方据此 `forget()`。

### 做法

- 条目不存在 → `.stale`（没有要撤的，忘掉记录是对的）。
- 条目存在 → 撤销成功才 `.stale`，失败返回 `.unavailable(.commandFailed)`，端口记录保留。
- 两个新用例：`testRefreshKeepsPortWhenStaleEntryCannotBeRevoked`（记 `activePort == 443`、状态为不可用）、`testRefreshForgetsMissingEntryWithoutRevokingThePort`（记录清空、状态 `off`，且一次 `off` 子命令都没发）。后者给假 runner 加了 `commands` 记录，用来断言「没有多余的命令」。

## 4. 手机访问：切换方式后地址记录与实际状态一致

### 现象

两种入口二选一（Tailscale serve / 自填地址）：

- 从自填地址切到 Tailscale、启用失败时，自定义地址记录已经没了；
- 关闭手机访问成功后，自定义地址记录还在，下次对账又显示「已开启」。

### 原因

启用路径在开跑之前就 `defaults.removeObject(forKey: DefaultsKey.customURL)`；关闭路径只调 `forget()`（只清端口）。

### 做法

- 启用：`serve.enable` 与地址解析都成功之后才 `forgetCustomAddress()`，失败时自定义地址记录原样保留。
- 关闭：成功时 `forget()` + `forgetCustomAddress()`，两类记录一起清；失败不动记录。
- 新用例 `testFailedEnablePreservesCustomAddress`（失败后记录仍在、状态仍是 `on`、没有端口）与 `testSuccessfulDisableClearsBothAddressRecords`（成功后两条记录都为空，`refresh` 之后状态为 `off`）。

## 真机实测环境

| 项 | 值 |
| --- | --- |
| 机器与芯片 | Mac16,10 / Apple M4 |
| macOS | 27.2（26B123） |
| 架构 | arm64 |
| Node.js | v26.13.0 |
| Pi（`@earendil-works/pi-coding-agent`） | 1.5.0 |
| `@agegr/pi-web` | 0.15.0（`/opt/homebrew/bin/pi-web` → `/opt/homebrew/lib/node_modules/@agegr/pi-web`，Homebrew 前缀下的全局安装） |
| `./Scripts/test.sh` | 1041 tests, 0 failures |
| `./Scripts/smoke.sh` | 启动模式与诊断模式均 exit 0（`items=6 blockers=3` 来自 `DiagnosticsSmokeFixture` 的确定性样例，不是本机依赖缺失） |

## 未变的部分

- 手机访问仍然只做 serve、不做 funnel，仍然没有访问密码：唯一的边界是 tailnet 身份。
- 更新通道仍然是 `appcast` 优先、GitHub API 回落；访问域名、脱敏与日志边界都没有改动。
- 下载缓存仍然是「只留一个发布包」，仍然在读取时重新核对 SHA-256 之后才交给安装流程。
- 应用内更新仍然只由用户点击触发；没有无人值守路径，也没有降级路径。

## 已知问题

- 第 3、4 项的失败路径只有单元测试覆盖：本机没有可用的失败注入，没有在真机 tailnet 上把「撤销失败」和「启用失败」实际演练一遍；`refresh` / `disable` 的常规成功路径也没有逐项点验菜单。
- 第 1 项没有在真机上等到 GitHub 配额耗尽复现；「只发一次请求」是单元测试断言。
- 第 2 项只收紧缓存读写这两条路径；应用内安装仍然只替换 `/Applications/Pi-Web-Desktop.app`，行为不变。

## 发布资产

| 资产 | 值 |
| --- | --- |
| ZIP | `Pi-Web-Desktop-0.1.0-alpha.34+build.34.zip` |
| SHA-256 | `79f4b9f411b19046a9ab0a3f4cac23f180ee807c4cd484fad7331491e3af3532` |
| 签名 | ad-hoc（`TeamIdentifier=not set`），未公证 |
| 最低系统 | macOS 26.0 |
| 架构 | arm64（Apple Silicon） |

本地演练（`./Scripts/package-release.sh --tag v0.1.0-alpha.34`）的产物是
`7dc75bceb2b7c4ba0c95f504e28aafd393e37879c134437e3fa006fec550b89e`，1736443 字节，
只用于发版前自检；用户下载的是 workflow 重新构建的那一份。

校验方式：

```sh
shasum -a 256 -c Pi-Web-Desktop-0.1.0-alpha.34+build.34.zip.sha256
```
