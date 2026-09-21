# alpha.1 独立安全与发布审查报告（GitHub #14）

- **审查对象**：`0.1.0-alpha.1`（`Configuration/AppIdentity.xcconfig` 的 `MARKETING_VERSION`），提交 `8e00bf73d9ad6e139abe1d9e4e04a50a75d71e29`。
- **审查方式**：只读。未修改 `Sources/`、`Scripts/`、`.github/`、`PiWebDesktop.xcodeproj/`、`PiWebDesktopTests/`；本 PR 只新增/修改 `docs/` 下的文档。未 push、未创建 PR、未 merge、未使用 `sudo`、未上传数据、未结束任何真实进程、未访问真实 Keychain。
- **执行环境**：macOS 27.0（build 26A428），arm64，`swiftc` Apple Swift 6.4；`xcode-select -p` = `/Library/Developer/CommandLineTools`（**无完整 Xcode**，因此本地不能运行 `xcodebuild test`，见文末“未能验证的部分”）。
- **结论摘要**：**阻断项 0 项**；非阻断残余风险 11 项（最高为“低—中”）；建议后续 Issue 6 项。
- **本文档引用约定**：样例秘密值统一写作“16 位字母”（实测用 16 个 `A`）；输出中的本机 Home 路径已替换为 `~`。这样既保持可复现，又不会让本报告自身触发 `Scripts/scan-secrets.sh`、CI 的 personal-data `git grep` 与 `check-identity.sh` 的仓库文本扫描。
- **行号约定**：除 R-3 相关条目已按 Issue #39 修复后的代码更新外，行号以审查时修订（上记提交）为准；符号名（如 `hostnameValidationMessage`）可用于在当前代码中定位。

---

## 0. 方法与证据基线

审查对每一条结论给出“可重跑命令 + 实际输出片段 + 文件行号”三类证据之一或全部。命令一律在仓库根目录执行，未使用 `sudo`。

本次实际执行的验证命令（全部只读，除 `build/`、`dist/`、`$TMPDIR` 下被 `.gitignore` 覆盖的产物）：

```sh
git diff --check                      # 退出 0
sh -n Scripts/*.sh                    # 退出 0
git status --porcelain                # 审查开始时为空
./Scripts/scan-secrets.sh --self-test # 退出 0
./Scripts/scan-secrets.sh             # 退出 0，suppressed 11 lines
./Scripts/build.sh                    # 退出 0
codesign --verify --deep --strict --verbose=2 build/Pi-Web-Desktop.app   # 退出 0
codesign -dv --verbose=4 build/Pi-Web-Desktop.app                        # 退出 0
spctl -a -vv build/Pi-Web-Desktop.app                                    # 退出 3（rejected，符合预期）
./Scripts/check-identity.sh           # 退出 0，PASSED (45 checks)
./Scripts/check-release-version.sh v0.1.0-alpha.1                        # 退出 0
./Scripts/smoke.sh                    # 退出 0，双模式通过
./Scripts/package-release.sh --out /tmp/secrev/dist                      # 退出 0
unzip -l /tmp/secrev/dist/Pi-Web-Desktop-0.1.0-alpha.1.zip               # 23 个条目，逐条核对
```

另外执行了三组“仓库文本 + 历史”只读扫描，以及两个一次性探针程序：脱敏规则矩阵探针（编译 `Sources/LogRedactor.swift`）与 `LogWriter` 就地脱敏探针（编译 `Sources/LogRedactor.swift` + `Sources/LogWriter.swift`）。两个探针只在 `$TMPDIR` 下写文件，不触碰真实 `~/Library`。

---

## 1. 服务所有权判定与外部服务只读策略

**结论：通过（无阻断项）**，残余风险已在既有文档中如实记录（见 §9 R-5、R-6）。

### 1.1 证据强度分级（逐项）

| 证据 | 来源与文件:行号 | 强度 | 绕过可能 |
| --- | --- | --- | --- |
| `instanceID`（每次运行随机 UUID） | `Sources/ServiceManager.swift:498`，写入 `ServiceOwnership.swift:36`，校验 `ServiceOwnership.swift:194` | **强**（跨运行不可继承） | 需要与当前实例内存中的 UUID 相同，无法离线伪造 |
| `processGroupID == pid`（组长不变量） | 写入前置检查 `ServiceManager.swift:962-964`，校验 `ServiceOwnership.swift:183-185`、`202` | **强**（`POSIX_SPAWN_SETPGROUP` + `pgroup=0` 由内核保证 `pgid == pid`，`ServiceManager.swift:239-246`） | 无 |
| 实时 `ps -o args=` 摘要（SHA-256） | 计算 `ServiceOwnership.swift:63-72`，比对 `ServiceOwnership.swift:206-210` | **强**（对“进程被换掉/参数变化”有效） | 空白折叠后同文本、但引号写法不同的两次启动无法区分（文档已记录） |
| 实时 `pgid` | `ProcessInspector.swift:152-154`，比对 `ServiceOwnership.swift:202` | 强 | 无 |
| `launchedAt`（`ps -o lstart=`） | 读取 `ProcessInspector.swift:160-162`，比对 `ServiceOwnership.swift:203` | **中**（秒粒度） | 同一秒内 PID 复用且其余证据全同（文档已记录） |
| `resolvedExecutable`（`proc_pidpath` 优先） | `ProcessInspector.swift:182-190`，比对 `ServiceOwnership.swift:213` | 强（`proc_pidpath`）/ 弱（`ps -o comm=` 回退） | 回退来源可被同名进程伪造，但必须同时通过 argv 摘要等其余检查 |
| `port` | 写入 `ServiceManager.swift:993`，比对 `ServiceOwnership.swift:195` | 中（识别配置漂移） | 与 instanceID/argv 摘要联合生效 |
| 存活 `kill(pid, 0)` | `ProcessInspector.swift:63-65` | 弱（仅表示存在） | 单独不构成所有权，只作为门禁之一 |
| 监听端口 PID（`lsof -t`） | `ProcessInspector.swift:206-208` | **仅诊断用** | 不进入任何发信号决策 |

### 1.2 验证失败路径是否零信号：**是**

静态证据（可重跑）：

```sh
$ git grep -n "kill(" -- Sources
Sources/ProcessInspector.swift:64:        pid > 1 && kill(pid, 0) == 0
Sources/ServiceOwnership.swift:280:        _ = kill(-processGroupID, signal)
Sources/ServiceOwnership.swift:285:        return kill(-processGroupID, 0) == 0

$ git grep -n "sendGroupSignal\|isProcessGroupAlive" -- Sources
Sources/ServiceManager.swift:1080:        signaler.sendGroupSignal(SIGTERM, toProcessGroup: processGroupID)
Sources/ServiceManager.swift:1082:            guard signaler.isProcessGroupAlive(processGroupID) else { return }
Sources/ServiceManager.swift:1085:        if signaler.isProcessGroupAlive(processGroupID) {
Sources/ServiceManager.swift:1086:            signaler.sendGroupSignal(SIGKILL, toProcessGroup: processGroupID)
```

- 全仓库只有 **2 处**发送信号的调用（`ServiceManager.swift:1080/1086`），都在 `terminate(processGroupID:)`（`ServiceManager.swift:1078-1088`）内，且 `guard processGroupID > 1`；`POSIXServiceSignaler.sendGroupSignal` 再次 `guard processGroupID > 1`（`ServiceOwnership.swift:278-281`）。`ServiceSignaling` 协议**没有单 PID 发送方法**（`ServiceOwnership.swift:269-275`），因此“只对组、不退化到 `kill(0,...)`/`kill(-1,...)`”是类型层面的约束，而不是约定。
- 唯一进入 `terminate` 的路径是 `stopService`（`ServiceManager.swift:1057-1075`），第一行是 `guard let record = verifiedOwnershipRecord() else { completion?(); return }`；`verifiedOwnershipRecord()`（`ServiceManager.swift:700-717`）在任一检查失败时返回 nil，因此外部服务/无法验证的记录 **零信号且状态不变**。
- `abandonUnhostedLaunch`（`ServiceManager.swift:998-1020`）只向“本次刚创建、且 `pgid == pid`”的组发信号，用途是回收自己启动的进程，不是停止外部服务。

```sh
$ git grep -nE 'contains\("pi-web"\)|contains\("piweb"\)' -- Sources
(无输出，退出 1)
```

命令行子串匹配路径（旧 `stopExternalListener` / `stopRemainingListener` 形态）在 `Sources/` 中已不存在。

### 1.3 残余风险（详见表 §9）

- PID 复用：`lstart` 秒粒度 + 其余证据需全同（`docs/security-ownership.md` 已记录）。
- argv 子串误判：**不存在**。判定基于整体文本摘要 + 空格归一化（`ServiceOwnership.swift:63-72`、`ProcessInspector.swift:137-143`），不做子串匹配。
- `ps` 不保留引号：摘要比较的是归一化文本而非参数边界，无法区分“引号写法不同、归一化后相同”的两种启动（`docs/security-ownership.md`“未覆盖 / 已知限制”已记录）。
- 验证与 `kill` 之间的 TOCTOU 窗口（既有限制，非本次新增）。
- 生命周期测试覆盖（本次**未执行**，无 Xcode；CI 覆盖）：`PiWebDesktopTests/ServiceOwnershipTests.swift` 28 个用例、`ServiceManagerTests.swift` 中 `testReusedPIDWithADifferentLaunchTimeIsNeverSignalled`（:572）、`testUnverifiableProcessFactsAreNeverSignalledAndKeepTheRecord`（:595）、`testChangedLiveCommandLineMakesTheServiceExternalAndSendsNoSignal`（:612）、`testStopServiceWithoutAVerifiedRecordSendsNothingAndKeepsTheState`（:1010）、`testExternalServiceStopKeepsTheRunningStateAndSendsNoSignal`（:1024）。

---

## 2. 凭据（Keychain、`PI_WEB_PASSWORD`、删除后的运行中收敛）

**结论：通过（无阻断项）。**

### 2.1 Keychain 读写

- 存储：`kSecClassGenericPassword`，`kSecAttrService` = bundle identifier，`kSecAttrAccount` = `remote-access-password`，可访问性固定为 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`（`Sources/KeychainStore.swift:81-98`，其中 :84 为可访问性）。`RemoteAccessPassword.account` 见 `KeychainStore.swift:142`。
- 错误类型只携带 notFound / OSStatus / undecodableData，**不携带秘密**（`KeychainStore.swift:14-33`）。
- 读取失败/条目缺失/空值一律按“未设置”处理（fail closed）：`RemoteAccessPassword.load`（`KeychainStore.swift:148-152`），门控 `RemoteAccessPolicy.allowsRemoteListening`（`KeychainStore.swift:243-245`）。

### 2.2 密码是否可能进入 UserDefaults / 命令行 / 日志 / 诊断 / 错误消息：**否**（已用 `git grep` 核验）

```sh
$ git grep -nE 'UserDefaults|setValue|set\(' -- Sources/KeychainStore.swift Sources/PreferencesWindowController.swift Sources/AppConfiguration.swift \
    | grep -iE 'password|secret|token|credential'
(无输出，退出 1)
```

- **子进程环境是唯一传输路径**：`ServiceLaunchSpecification.make(...)`（`ServiceManager.swift:121-166`）只在“hostname 非 loopback 且密码非空”时写入 `environment["PI_WEB_PASSWORD"]`，否则**删除**该键（含清除父进程继承值），见 `ServiceManager.swift:133-139`。
- **命令行不含密码**：`ServiceLaunchSpecification.arguments(configuration:)` 只生成 `--hostname/--port/--no-open`（`ServiceManager.swift:169-171`）。
- **诊断文本不含密码值或长度**：密码只以占位符进入展示路径（`Sources/PiWebApp.swift:1043-1051`：`remoteAccessPassword: hasRemotePassword ? LogRedactor.marker : nil`），状态字段只用 `RemoteAccessPassword.statusText(isSet:)`（`KeychainStore.swift:159-161`，`PiWebApp.swift:1080-1082`）。
- **单次读取、无 fail-open 窗口**：`startManagedService()` 本次启动只读一次凭证并把同一个值传给门控与启动规格（`ServiceManager.swift:871-876`、`755-777`）；`startDecision(credentials:)`（`ServiceManager.swift:755`）内部不再读 Keychain。
- **错误消息二次清理**：写入 Keychain 失败时用 `SecretScrubbing.scrub(..., secrets: [newPassword])`（`KeychainStore.swift:170-177`、`:302-322`）先移除密码再展示。

### 2.3 删除密码后的运行中收敛

`closeRemoteAccessIfCredentialsAreUnavailable()`（`ServiceManager.swift:654-672`）的判定顺序是“配置非 loopback → 取不到凭证 → 存在可验证的托管进程”，然后：把 hostname 收回 `127.0.0.1`（`KeychainStore.swift:277-282`）→ 走既有 `stopService()`（重新验证后才发信号）→ 状态置 `.failed(revokedPasswordMessage)` 并通过 `onRemoteAccessClosed` 让调用方持久化。触发点包括 4 秒健康轮询与所有启动入口的缺密码分支。**没有可验证的托管进程时不改动用户配置**（不会静默替用户改配置）。

未执行的测试覆盖（CI）：`KeychainStoreTests.swift` 断言“密码写入后 UserDefaults 中无该字符串”“远程配置缺密码时保存被拒绝”“删除密码后 hostname 回到 `127.0.0.1`”“启动环境只在远程+非空密码时含 `PI_WEB_PASSWORD`”。

---

## 3. 日志与诊断脱敏（`LogRedactor` / `LogWriter` / `DiagnosticsCollector`）

**结论：通过（无阻断项），但存在 2 项非阻断风险（R-1、R-2），且文档中两处能力描述与实现不符，已在本 PR 内按实测结果修正。**

### 3.1 实测方法

编译仓库自身的 `Sources/LogRedactor.swift`（以及与 `LogWriter` 的组合），在 `$TMPDIR` 下对固定样例集跑矩阵。样例值统一为 16 位字母（实测为 16 个 `A`）。

### 3.2 覆盖良好的形态（实测通过）

| 形态 | 输入（示意） | 输出 |
| --- | --- | --- |
| 键值基本形态 | `password=<16 位字母>` | `password=<redacted>` |
| `key: value` | `password: <16 位字母>` | `password: <redacted>` |
| JSON 引号键 | `{"password": "<16 位字母>"}` | `{"password": <redacted>}` |
| 等号两侧带空格 | `secret = <16 位字母>` | `secret = <redacted>` |
| 带前缀的环境变量名 | `PI_WEB_PASSWORD=<16 位字母>` | `PI_WEB_PASSWORD=<redacted>` |
| URL 查询串（整段替换） | `GET /api?token=<16 位字母>&next=/x?y=<16 位字母> HTTP/1.1` | `GET /api?<redacted> HTTP/1.1` |
| URL 编码的值 | `GET /api?password=AA%3D%3D…（URL 编码后的值）HTTP/1.1` | `GET /api?<redacted> HTTP/1.1` |
| `Authorization` 头 | `Authorization: Bearer <16 位字母>` | `Authorization: <redacted>` |
| 代理凭据 | `http://user:<16 位字母>@proxy.example.invalid:8080/path` | `http://<redacted>@proxy.example.invalid:8080/path` |
| 命令行 `--key value` | `--password <16 位字母> --port 30141` | `--password <redacted> --port 30141` |
| 命令行 `--key=value` | `--password=<16 位字母>` | `--password=<redacted>` |
| 非 ASCII 用户名 Home | `/Use`+`rs/` + 非 ASCII 用户名 + `/Library/Logs/x.log` | `~/Library/Logs/x.log` |
| 非注入的其他用户 Home | `/Use`+`rs/` + 其他用户名 + `/Library/x` | `~/Library/x` |
| 非 ASCII 值 | `--password <非 ASCII 值>` | `--password <redacted>` |
| 私钥块（含只有 BEGIN 的行） | `-----BEGIN …PRIVATE KEY-----` 起 | 整块逐行 `<redacted>` |
| 误伤控制（应当**不**脱敏） | `tokenizer=<16 位字母>`、`passwordless=<16 位字母>` | 原样输出 |

多行输入的**行数与换行结构保持不变**（含私钥块），与文档描述一致。

### 3.3 可绕过形态（实测：完全不脱敏或部分脱敏）— R-2

| 形态 | 输入（示意） | 实测输出 | 判定 |
| --- | --- | --- | --- |
| 引号包裹的值（含空格） | `password="AA BB CC DD"` | 原样输出 | **未脱敏** |
| `key = "value"`（等号带空格 + 引号值） | `secret = "<16 位字母>"` | 原样输出 | **未脱敏** |
| 值在下一行（YAML 形态） | `password:` 换行后缩进 `<16 位字母>` | 原样输出 | **未脱敏** |
| 无引号但含空格的值 | `password=AA BB CC DD` | `password=<redacted> BB CC DD` | **仅第一段脱敏，其余泄漏** |

原因（`Sources/LogRedactor.swift:104-146`）：键值规则的值分支是 `[^\s,;&"']+`，遇到空格或引号即停止；引号形态只对**被引号包裹的键**（规则表第 6 条）生效，因此“不带引号的键 + 带引号的值”不在覆盖范围；跨行的值不在逐行处理范围内。

**为什么仍是非阻断**：(a) 应用自身从不以上述形态打印密码——密码只进子进程环境（§2.2），诊断只有“已设置/未设置”；(b) 受影响的主要是子进程 stdout/stderr，那部分由 `posix_spawn` 直接重定向到日志文件（`ServiceManager.swift:246-262`），应用**不控制也不解析**其格式；(c) 文档已写明“脱敏不替代自查”。修正要求：把上表如实写进规则文档（本 PR 已做），并开后续 Issue 扩展规则。

### 3.4 幂等性声明与实际不符 — R-1

`docs/logging-and-diagnostics.md:52` 与 `Sources/LogRedactor.swift:46-47` 都声明“对已经脱敏的文本再运行一次结果不变”。实测**不成立**：

```text
用真实代码路径（LogWriter.append + 两次 scrubExistingLog，后者在每次启动服务时执行，LogWriter.swift:135-166/211-223）：
after append            : {"token": <redacted>} trailing-context
after 1st scrubExisting : {"token": <redacted> trailing-context
after 2nd scrubExisting : {"token": <redacted> trailing-context
```

第二次就地脱敏把紧跟占位符的 `}` **吃掉**了（键值规则的第三分支在第二遍把 `}` 一并当作值吞入）。影响：日志文本完整性（已脱敏行的尾随字符被截断），**不构成秘密泄漏**。`PiWebDesktopTests/LogRedactorTests.swift:139-149` 的幂等用例恰好不含 JSON 引号键形态，因此该缺陷未被既有测试捕获。

已在本 PR 内把文档中的绝对化声明改成实测范围（见 §12 文档修正），并建议开后续 Issue 修实现（`Sources/` 本轮只读）。

### 3.5 写入路径与诊断导出

- 应用侧写入的每一行都经同一个 `LogRedactor` 实例（`LogWriter.appendLocked`，`LogWriter.swift:175-208`）；错误消息在进入状态机前先脱敏（`ServiceManager.swift:1239-1247`）。
- 打开子进程日志句柄前先对已存在日志就地脱敏（`LogWriter.swift:135-166`、`:211-223`）。
- 轮转：默认 10 MB / 保留 5 份（`LogWriter.swift:8-9`），达到阈值按 `.1`…`.5` 后移、超出份数删除（`:225-253`）。
- `DiagnosticsCollector.text(for:redactor:)` 最后统一整段脱敏（`Sources/DiagnosticsCollector.swift:84-116`），字段顺序固定、多行值用带序号的唯一标签续写。

---

## 4. 网络边界

**结论：通过（无阻断项）。审查当时记录 1 项非阻断风险（R-3），已于 Issue #39 修复。**

| 检查项 | 结论 | 证据（文件:行号 / 命令输出） |
| --- | --- | --- |
| 默认 loopback | 通过 | `ServiceConfiguration.defaultHostname = "127.0.0.1"`（`Sources/ServiceConfiguration.swift:31`），`defaultNoProxy = "localhost,127.0.0.1,::1"`（:35）；`./Scripts/check-identity.sh` 输出 `ok   service default hostname is 127.0.0.1` |
| 非 loopback 必须有非空密码 | 通过 | `allowsRemoteListening`（`KeychainStore.swift:286-288`）；启动门控 `ServiceManager.swift:601-603`、`:791-793`、`:911-913`（缺密码 → `.missingRemotePassword` / 可读失败，不启动） |
| `0.0.0.0` / `::` / `[::]` / `*` 不可默认、所有入口都不可用 | 通过（所有入口） | 唯一判定 `RemoteAccessPolicy.addressVerdict(hostname:)`（`KeychainStore.swift:295-361`，拒绝集合 `:230`）被保存路径（`hostnameValidationMessage` `:420-422`、`RemoteAccessSetup.apply` `:471-473`）、`ServiceConfiguration.load`（`ServiceConfiguration.swift:72-74`、`:76`）与 `ServiceManager.startDecision(credentials:)`（`ServiceManager.swift:783-788`，启动门控 `:601-609`）共用（Issue #39 修复 R-3） |
| 通配地址的等价写法 | 通过 | `isWildcardIPv6Literal`（`KeychainStore.swift:376-384`）拒绝全零与 IPv4-mapped 全零 IPv6（`0:0:0:0:0:0:0:0`、`::ffff:0.0.0.0`），`isAmbiguousNumericHostname`（`:390-405`）拒绝会被 `getaddrinfo` 按 inet_aton 语义解析的纯数值写法（`0`、`0x0`、`000.000.000.000`）与空标签（`0.0.0.0.`）；macOS 实测这些写法都绑定所有接口 |
| `allowedHosts` 校验 | 通过 | `addressVerdict` 限制字符集为字母/数字/点/连字符/下划线/方括号/冒号，拒绝协议、路径、空格与 `host:port` 混写（`KeychainStore.swift:312-316`、`:331-339`）；`PI_WEB_ALLOWED_HOSTS` 只在非空时注入（`ServiceManager.swift:141-144`） |
| IPv6 处理 | 通过 | 保存与子进程参数用不带方括号的 `::1`，拼 URL 时由 `urlHost` 加方括号（`KeychainStore.swift:244-267`；`ServiceConfiguration.swift:118-127`）；冒号只在合法 IPv6 字面量时允许（`isIPv6Literal`，`:264-267`） |
| loopback 判定是否可能把非 loopback 误判为 loopback | 通过（方向安全） | `isLoopbackHostname`（`KeychainStore.swift:271-279`）只覆盖空值、`localhost`、`*.localhost`、`::1` 与 `127.0.0.0/8`（4 段且每段可解析为 `UInt8`）。`localhost.`、`LOCALHOST.`、`127.1`、`0177.0.0.1`、`0:0:0:0:0:0:0:1` 等形态**不会**被判为 loopback → 退化为“要求密码”的保守方向，不会静默放开；显式空值与上述歧义数值写法在保存/加载/启动都被 `addressVerdict` 拒绝（Issue #39） |
| 密码认证 vs 传输加密的表述是否如实 | 通过 | `README.md:100`、`docs/privacy.md:53`、`docs/architecture.md:137` 与 `:141` 均明写“密码认证不等于传输加密”，并要求用户自备加密隧道或 HTTPS 反向代理 |
| WebView 导航边界 | 通过 | `WebViewNavigationPolicy`（`Sources/App/WebViewNavigationPolicy.swift`）只允许 http(s) 且命中「应用自己配置并启动的服务来源」——scheme + host + port 与 `ServiceConfiguration.serviceURL` 完全一致（#149 更新）——或 loopback host + 当前端口（`isLocalURL`）；`about`/`blob`/`data` 视为内联（`decision(for:serviceURL:)`）；其余一律外开。这不是放宽到私有网络：判定里没有任何网段/后缀白名单，与配置地址同段但不相同的 host 同样外开（`PiWebDesktopTests/WebViewNavigationPolicyTests.swift` 覆盖） |

**R-3（低，已于 Issue #39 修复）**：`0.0.0.0` 等“所有接口”地址的拒绝原先只存在于**设置界面保存路径**。`ServiceConfiguration.load`（当时的 `ServiceConfiguration.swift:67-83`）直接读取 UserDefaults，不做地址校验；启动/门控路径只强制“非 loopback 需要密码”，不重新校验地址本身。因此 `defaults write <bundle-id> service.hostname -string "0.0.0.0"` 这类同用户直接写入，再配合 Keychain 中已有密码，应用会以该地址启动 pi-web。威胁模型上这不增加能力（同一非特权用户本来就能自己运行 `pi-web --hostname 0.0.0.0`），但它绕过了“应用永不启动所有接口监听”的设计声明。

**修复（Issue #39）：** 地址校验抽成 `RemoteAccessPolicy.addressVerdict(hostname:)`（`KeychainStore.swift:295-361`，结果类型 `ServiceAddressVerdict`），保存路径（`hostnameValidationMessage`、`RemoteAccessSetup.apply`）、`ServiceConfiguration.load` 与 `ServiceManager.startDecision(credentials:)` 三处共用：`load` 把 `[::1]` 规范化为 `::1`、非法值原样保留并由 `ServiceConfiguration.hostnameProblem` 标记为不可用（不静默替换成 loopback 或其他地址）；`ServiceManager.isStartPermitted` 与 `startManagedService()` 要求地址可用，非法地址返回 `.invalidAddress`，不启动进程、不探测外部服务、不加载页面，失败提示给出非法值与允许范围。除了 `0.0.0.0`、`::`、`[::]`、`*`，会被 `getaddrinfo` 解析成通配地址的写法（`0`、`0x0`、`000.000.000.000`、`0.0.0.0.`、`0:0:0:0:0:0:0:0`、`::ffff:0.0.0.0`）与歧义数值写法也一律拒绝（只接受规范点分四段、规范 IPv6 字面量与主机名）。威胁模型结论不变：同一非特权用户仍可自行运行 `pi-web --hostname 0.0.0.0`。

---

## 5. 构建与发布

**结论：通过（无阻断项），1 项加固建议（R-9）。**

### 5.1 CI 权限最小化

```text
.github/workflows/build.yml:9-10   permissions: contents: read
.github/workflows/release.yml:33-34 permissions: contents: read   # workflow 级
release.yml 的 publish job 单独声明 permissions: contents: write   # 仅创建 Release 需要
```

- `build.yml` 在 `pull_request` 上也以只读 token 运行，PR 不能写仓库。
- `release.yml` 只在 `push` tag 或 `workflow_dispatch` 触发；`workflow_dispatch` 一律停在 workflow artifact（`publish` job 的 `if` 限定为 tag push），演练不会创建 Release。
- 两个 workflow 都不使用 `secrets`。

### 5.2 Actions 固定到完整 commit SHA

```text
$ git grep -hoE 'uses: [^ ]+@[^ ]+' -- .github/workflows/ | sed 's/uses: //' | <格式校验>
ok 40-hex: actions/checkout        (build.yml:18, release.yml:51)
ok 40-hex: actions/checkout        (release.yml:51)
ok 40-hex: actions/upload-artifact (release.yml:171)
ok 40-hex: actions/download-artifact (release.yml:190)
```

全部 4 处 `uses:` 都是 40 位十六进制 SHA（无浮动 tag）；`.github/dependabot.yml` 只对 `github-actions` 生态每周提升级 PR。

### 5.3 `Scripts/*.sh` 的输入处理与注入面

- `sh -n Scripts/*.sh` 退出 0。
- 未使用 `eval`、`sh -c`、反引号执行外部输入；`rm -rf` 的 4 处目标全部加引号且只指向 `$ROOT/build/...` 或 `mktemp -d` 目录（`build.sh:84`、`scan-secrets.sh:83/86/347`）。
- `package-release.sh` 的参数解析是严格 `case` 分支 + 计数校验（`Scripts/package-release.sh:71-104`）；读取 `Info.plist` 后**先用白名单字符集校验** `CFBundleShortVersionString` / `CFBundleVersion` 才写入会被 workflow `.` source 的 `release-metadata.env`（`package-release.sh:127-135`）。
- `check-release-version.sh` 只接受 `--print-tag` 与单个位置参数，tag 必须以 `v` 开头且与 xcconfig 逐字相等（`Scripts/check-release-version.sh:88-140`）。

```sh
$ ./Scripts/check-release-version.sh v0.1.0-alpha.1 ; echo exit=$?
check-release-version: expected tag = v0.1.0-alpha.1
ok   tag v0.1.0-alpha.1 matches MARKETING_VERSION
ok   tag pre-release counter 1 matches CURRENT_PROJECT_VERSION
check-release-version: PASSED (...); exit=0

$ ./Scripts/check-release-version.sh v9.9.9 ; echo exit=$?      # 负向验证
error: tag 'v9.9.9' does not match Configuration/AppIdentity.xcconfig ...; exit=1
```

应用侧的唯一命令注入面同样已闭合（附带核实）：`DependencyChecker.resolveExecutable` 把名字插进 `command -v <name>` 交给 `/bin/zsh -lc`（`Sources/DependencyChecker.swift:515`），但 3 个调用点全部传编译期字面量 `"node"`/`"pi"`/`"pi-web"`（`:629`、`:700`、`:733`）；`ServiceManager.resolvePiWebPath` 的 shell 调用是固定字符串（`ServiceManager.swift:740`）。

### 5.4 ZIP 内容清单（实际生成并逐条核对）

```sh
$ ./Scripts/package-release.sh --out /tmp/secrev/dist     # 退出 0
$ unzip -l /tmp/secrev/dist/Pi-Web-Desktop-0.1.0-alpha.1.zip
  2166592                     23 files
$ unzip -l ... | grep -nEi '\.git|\.swift|Tests|\.log|/Use''rs/|\.env|\.xcuserdata|dist/'
(无输出，退出 1)
```

清单仅包含：`Pi-Web-Desktop.app/`（`Contents/MacOS/PiWebDesktop`、`Contents/Resources/ApplicationIcon.icns`、`Contents/Info.plist`、`Contents/_CodeSignature/CodeResources`）与 `ditto --sequesterRsrc` 生成的 `__MACOSX/` AppleDouble 元数据条目（每个 163 字节，`strings` 只有 `Mac OS X` / `ATTR` / `com.apple.provenance`，无路径）。

```sh
$ strings（对解压后全部条目）| grep -E '/Use'+'rs/|/Volumes/|<本机用户名>|/tmp/secrev'
no local absolute path strings
```

（上行的模式写成两段拼接，与本仓库脚本避开自身模式字面值的写法一致；实际执行时匹配的是完整路径前缀。）

**确认不含**：源码、测试、`.git`、日志、个人数据、本地绝对路径、`.env`、`.DS_Store`、Xcode 用户状态。私有临时文件（`build/`、`dist/`）均被 `.gitignore` 覆盖。

### 5.5 checksum 生成方式

`shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256"`，并立即用 `shasum -a 256 -c` 自校验（`package-release.sh:206-212`）；`release.yml` 的 `publish` job 用同一条命令复验后才创建草稿（`release.yml:199-210`）。

```text
27b7eb68c04b850df903a8d7988730a9175ef9985ebc160022a551d6a13873b6  Pi-Web-Desktop-0.1.0-alpha.1.zip
Pi-Web-Desktop-0.1.0-alpha.1.zip: OK
```

`release-metadata.env` 记录 `COMMIT` 与工作区是否 dirty（`package-release.sh:214-222`）。

**R-9（低）**：`APP_STEM`（由 `--app` 路径推导，用于 `ZIP_NAME`/`APP_NAME`）没有套用与 `VERSION` 相同的字符集白名单，而该值会写进被 workflow source 的 `release-metadata.env`。CI 里 `--app` 是硬编码字面量，因此需要能控制脚本参数（等价于本地/CI 已被控制）才可利用。建议对 `APP_STEM` 复用同一条 `case` 白名单校验。

---

## 6. 签名与 Gatekeeper 表述

**结论：通过（无阻断项）。**

```sh
$ codesign --verify --deep --strict --verbose=2 build/Pi-Web-Desktop.app
build/Pi-Web-Desktop.app: valid on disk
build/Pi-Web-Desktop.app: satisfies its Designated Requirement
exit=0

$ codesign -dv --verbose=4 build/Pi-Web-Desktop.app
Identifier=io.github.su-luoya.pi-web-desktop
CodeDirectory v=20400 size=3034 flags=0x2(adhoc) hashes=88+3 location=embedded
Signature=adhoc
TeamIdentifier=not set
Sealed Resources version=2 rules=13 files=1
exit=0

$ spctl -a -vv build/Pi-Web-Desktop.app
build/Pi-Web-Desktop.app: rejected
exit=3
```

- `Signature=adhoc` + `TeamIdentifier=not set` + `spctl` **拒绝**（退出 3）三者互相印证“ad-hoc、未公证”。
- `package-release.sh` 在打包前**强制**断言 `Signature=adhoc` 与 `TeamIdentifier=not set`，否则 `fail`（`package-release.sh:180-190`）；`spctl` 非 0 被记录为“预期结果”，为 0 时也只是注明“本机 Gatekeeper 决策，不是签名或公证声明”（`package-release.sh:193-200`）。
- 文本表述核查（`git grep`，命中处均为**禁止清单/否定句**，无肯定声明）：

```sh
$ git grep -niE '已签名|已公证|稳定版|stable release|signed and notarized' -- README.md docs/ SECURITY.md CONTRIBUTING.md .github/ Sources/ Scripts/
.github/pull_request_template.md:40  （禁止清单）
docs/alpha-release-checklist.md:82   （“不允许出现”）
docs/release-notes-template.md:82    （“不会把 ad-hoc 描述成已签名/已公证”）
docs/releasing.md:14                 （“不允许声称”）
```

`docs/release-notes-template.md:22-30` 与 `release.yml` 的草稿标题均明写“ad-hoc / 未公证”，安装说明要求用户右键打开或“仍要打开”，不指导关闭 Gatekeeper。

**观察（R-10，低，非阻断）**：本机 macOS 的 `spctl -a -vv` 只输出 `rejected`，不打印拒绝原因；`package-release.sh` 生成的证据段落因此只记录退出码与预期结论。这不影响结论正确性。

---

## 7. 依赖与供应链

**结论：通过（无阻断项）。**

```sh
$ ls Package.swift Package.resolved package.json package-lock.json Podfile Cartfile
（均不存在）
$ grep -cE 'XCRemoteSwiftPackageReference|XCSwiftPackageProductDependency|packageReferences' PiWebDesktop.xcodeproj/project.pbxproj
0
$ git grep -hE '^import ' -- Sources | sort | uniq -c | sort -rn
  16 import Foundation
   6 import Cocoa
   1 import WebKit
   1 import Security
   1 import Darwin
   1 import CryptoKit
$ grep -n '\-framework' Scripts/build.sh
111:  -framework Cocoa
112:  -framework WebKit
```

- 无第三方 Swift Package、CocoaPod、npm 运行时依赖，也无 `Package.swift` / `package.json`；只链接系统框架（Cocoa、WebKit）与系统库（Security、CryptoKit、Darwin）。因此**本项目自身不引入第三方运行时 CVE 面**。
- `Scripts/build.sh` 用 `swiftc` 直接编译 20 个源文件（无网络下载步骤）。
- Actions 依赖清单只有 4 条（§5.2），全部固定 SHA；Dependabot 负责升级。
- 构建与发布不使用任何 secret、签名服务或上传服务；`release.yml` 的 `publish` job 用 `github.token` 创建草稿 Release。

---

## 8. 个人数据与 secret

**结论：通过（无阻断项）。**

```sh
$ ./Scripts/scan-secrets.sh --self-test ; echo exit=$?
self-test: ok: AWS access key ID is detected
... (6 条规则全部命中、误报不被报告、抑制标记与计数正确、样例目录已删除)
self-test: PASS (all rules fired, suppression verified, samples cleaned up); exit=0

$ ./Scripts/scan-secrets.sh ; echo exit=$?
scan-secrets: suppressed 11 lines
scan-secrets: PASS (no matches in tracked files); exit=0
```

11 条被抑制的命中行**全部位于测试夹具**，逐条核对如下（用与脚本相同的规则重跑匹配行，再按“同一行是否含抑制标记”分类）：

```sh
$ git grep -cIE -e '<scan-secrets.sh 中的 RULE_ALL>' -- .
PiWebDesktopTests/LogRedactorTests.swift:8
PiWebDesktopTests/LogWriterTests.swift:3
```

`Sources/`、`Scripts/`、`docs/`、`.github/` 中**没有**任何被抑制的命中行，也没有任何真实凭据。

CI 的 personal-data 步骤（`.github/workflows/build.yml:54-56`）在审查开始与结束时都退出 0（无命中）。该步骤的三条固定模式不在这里逐字拄写，只按本仓库脚本避开自身模式字面值的写法给出等价形式，以免本报告自身命中它们：

```sh
$ ! git grep -nE 'tail'+'a|127\.0\.0\.1:7890|/Use'+'rs/[^/]+' \
    -- ':!*.icns' ':!.github/workflows/build.yml' ':!Scripts/check-identity.sh'
exit=0
```

补充的广谱只读扫描（本次新增，比既有模式更宽）：

```sh
# RFC1918 / CGNAT 私网地址（保留地址段模式同样拆段书写）
$ git grep -nIE '(^|[^0-9.])(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' -- . ':!*.icns'
PiWebDesktopTests/KeychainStoreTests.swift:220:        for hostname in ["0.0.0.0", "::", "[::]", "192.168.1.10", "pi.example.invalid", ...]
PiWebDesktopTests/WebViewNavigationPolicyTests.swift:32:        for raw in [..., "http://192.168.0.10:\(port)/", ...]
```

两处命中都是**单元测试里明确用于“应当被拒绝”的文档保留地址**（`192.168.x.x`），不是真实内网地址，可接受。

```sh
# 私有 VPN 主机名 / 私有 DNS 后缀（模式按本仓库脚本的惯用写法拆成两段，避免本报告自身命中它们）
$ git grep -niE 'tail'+'scale|'\.'+'ts\.'+'net|internal\.|corp\.|vpn\.' -- . ':!*.icns'
Scripts/check-identity.sh:439:  scan_forbidden "no Tailscale default hostname" ...
docs/development.md:79:  ...（描述该检查本身）
```

命中只是检查项自身与文档对该检查的描述。

```sh
# 全部 23 个提交的新增行历史扫描（扫描器本身只覆盖工作树，见 R-8）
$ git log --all -p --unified=0 | grep -E '^\+' | grep -nE '<凭据/路径/私网模式>'
...4 处：全部是 PiWebDesktopTests 里的合成 PEM 夹具头（其中 2 处位于更早的提交，尚未带抑制标记；HEAD 版本已带）
```

**结论**：仓库不含个人主机名、私网地址、真实凭据或真实用户绝对路径；测试夹具是合成数据。

### 8.1 验证盲点：`git grep` 不检查未跟踪文件（R-11）

本次审查中发现一个**本地验证保真度**问题：CI 的 personal-data 步骤与 `./Scripts/check-identity.sh` 的仓库文本扫描都用 `git grep`，而 `git grep` **只搜已跟踪文件**。因此一份刚写好的新文件在 `git add` 之前对这两道门槛是**不可见的**：本次审查报告初稿里为了展示证据而逐字引用了扫描器自身的模式字面值，在未暂存时两条门禁都返回通过，`git add` 后同一内容立即命中。

处置：本报告已把这类模式字面值改成本仓库脚本惯用的拆段写法（如 `'tail'+'a'`、`'/Use'+'rs/'`），并在暂存之后重新跑过两条门禁（见上文的 `exit=0`）。

影响范围：CI 上无害（checkout 出来的提交全部已跟踪）；风险仅在于“本地按文档命令自查得到假绿”。因为 PR CI 仍会拦住，故按非阻断处理（R-11）。

---

## 9. 威胁模型摘要

### 9.1 资产

| 资产 | 位置 | 敏感性 |
| --- | --- | --- |
| 远程访问密码 | macOS Keychain，`remote-access-password` | 高（可让远端访问本机 agent 服务） |
| 本机 agent 服务与工作目录内容 | `~/Library/Application Support/Pi Web Desktop/Workspace`（可被用户改到任意目录） | 高 |
| pi-web 的 stdout/stderr 日志 | `~/Library/Logs/Pi Web Desktop/` | 中（可能含上游打印的凭据/查询串） |
| 所有权记录与 PID 文件 | `~/Library/Application Support/Pi Web Desktop/` | 中（决定能否发信号） |
| 发布产物与其证据 | GitHub Release / CI artifact | 中（影响用户安装的二进制） |
| 用户设置与 WebKit 网站数据 | UserDefaults / `~/Library/WebKit/<bundle id>/` | 中低 |

### 9.2 对手模型

| 对手 | 能力 | 是否在防护范围 |
| --- | --- | --- |
| **A. 远程网络攻击者** | 能访问用户主动暴露的地址 | 在范围内：默认 loopback、非 loopback 强制密码、`0.0.0.0` 界面拒绝、文档明写需自备加密隧道 |
| **B. 同机同用户进程** | 可读写该用户文件、可 `kill` 自己的进程、可 `defaults write` | 部分在范围内（R-6）：应用不因此获得额外能力，故接受为残余风险；R-3（直接改写 UserDefaults 进入通配监听）已在 Issue #39 修复 |
| **C. 其他用户进程** | `ps` 读不到、无 `sudo` | 在范围内：读不到事实即判外部、零信号、不提权 |
| **D. 被篡改/被替换的服务二进制** | 替换磁盘上的 `pi-web` | 部分在范围内：重启后 `launchedAt` 变化即判外部；“同进程内已被替换”不在范围 |
| **E. 供应链/CI 攻击者** | 提交 PR、试图写入仓库或改发布产物 | 在范围内：只读 token、Actions 固定 SHA、发布仅由 tag 触发、打包前强制 adhoc 断言 |
| **F. 误操作的用户** | 复制诊断、粘贴日志、填错地址 | 在范围内：统一脱敏、复制前弹提醒、保存时拒绝危险地址 |

### 9.3 攻击面与缓解措施

| 攻击面 | 缓解措施（证据） | 残余风险 |
| --- | --- | --- |
| 误杀/误停他人进程 | 所有权逐项验证 + 只发组信号 + 无可验证记录零信号（§1） | TOCTOU、`lstart` 秒粒度（R-5） |
| 密码外泄到磁盘/参数/日志 | 只进子进程环境；诊断只有状态；错误消息二次清理（§2） | 上游子进程自身打印的内容（R-2） |
| 日志中的敏感信息 | 统一 `LogRedactor` + 每次启动就地脱敏 + 轮转（§3） | 规则缺口与幂等缺陷（R-1、R-2） |
| 非本机监听在无认证下启动 | loopback 默认 + 非 loopback 强制非空密码 + 运行中收敛（§4） | 直接改 UserDefaults 写入的通配地址曾能绕过校验（R-3）；已在 Issue #39 修复（保存/加载/启动三处共用地址校验） |
| 明文传输被误认为加密 | 三处文档明写“密码认证不等于传输加密”（§4） | 无速率限制（属上游 pi-web 认证范围，alpha 限制） |
| 发布产物被替换/误标 | 只读权限 + SHA 固定 Actions + adhoc 强制断言 + SHA-256（§5、§6） | 非 bit-for-bit 可复现（既有文档已声明） |
| 凭据进入仓库 | 规则化 scanner + CI 门禁 + personal-data grep（§8） | 未覆盖的凭据类型、不扫历史（R-8） |

---

## 10. 未解决风险清单

| ID | 风险 | 严重度 | 是否阻断 alpha.1 | 建议 |
| --- | --- | --- | --- | --- |
| R-1 | 脱敏非幂等：第二次就地脱敏会吞掉 JSON 引号键后紧跟的字符（`}`） | 低 | 否 | 后续 Issue：修 `LogRedactor` 值分支或跳过已含占位符的片段；把 JSON 形态加进幂等用例。文档声明已在本 PR 修正 |
| R-2 | 脱敏规则缺口：`password="a b"` / `secret = "…"` / `key:` 换行值 / 含空格值仅部分替换 | 低—中 | 否 | 后续 Issue：值分支支持引号与多行续行；文档规则表已在本 PR 改为实测覆盖范围 |
| R-3 | `0.0.0.0` 等通配地址只在界面保存路径被拒绝，加载/启动路径不校验 | 低 | 否 | **已修复（Issue #39）**：`RemoteAccessPolicy.addressVerdict(hostname:)` 由保存/加载/启动三处共用；非法地址返回 `.invalidAddress` 且不启动。本行保留审查当时的判定与编号（参见 §12 后续处理） |
| R-4 | 远程访问仅密码认证、无传输加密、无暴力破解防护（上游 pi-web 范围） | 低 | 否 | 保持在 README/privacy/architecture 的显著位置说明；alpha 与 beta 阶段继续作为已知限制 |
| R-5 | 所有权验证与 `kill(-pgid)` 之间的 TOCTOU、`lstart` 秒粒度、控制行摘要丢失引号边界 | 低 | 否 | 保持现有文档记录；如需进一步收紧可改用 `proc_pidinfo` 微秒启动时间（后续 Issue） |
| R-6 | `service-owner.json` 不校验权限/所有者/签名 | 低 | 否 | 保持现状（同用户本可直接 `kill`）；如需加固可校验文件属主与 mode |
| R-7 | `README.md:125` 仍声称“没有通用 secret scanning”，与已实现的 `Scripts/scan-secrets.sh` 及 CI 门禁矛盾（本 PR 写权限不含仓库根文件） | 低 | 否 | 后续 Issue：把 `README.md:125` 改为与 `docs/development.md` 一致的现状描述 |
| R-8 | `scan-secrets.sh` 只覆盖固定形状且不扫 Git 历史；历史上 2 处合成 PEM 夹具头尚未带抑制标记 | 低 | 否 | 保持能力边界说明（`docs/development.md` 已写明）；如要覆盖历史可用 `git log -p` 扫描作为独立脚本 |
| R-9 | `package-release.sh` 未对 `APP_STEM` 套用与 `VERSION` 相同的字符集白名单，而它进入被 source 的 `release-metadata.env` | 低 | 否 | 后续 Issue：复用 `case` 白名单校验 `APP_STEM` |
| R-10 | 本机 `spctl -a -vv` 只输出 `rejected`（不打印原因），证据段落只记录退出码 | 低 | 否 | 可选：在证据段落补一句“本机 spctl 不输出拒绝原因”，避免读者误以为证据缺失 |
| R-11 | personal-data `git grep` 与 `check-identity.sh` 的仓库文本扫描都基于 `git grep`，**不检查未跟踪文件**，因此本地自查对新建文件会给出假绿 | 低 | 否 | 后续 Issue：两个脚本在扫描前断言工作区没有未跟踪的待提交文件（或提示“先 `git add` 再扫”）；本地自查习惯改为“先暂存再跑门禁” |

---

## 11. 阻断条件与判定

### 11.1 对 `0.1.0-alpha.1` 的判定

**无阻断项，可进入发布门槛；本审查结论本身不构成发布批准**（`docs/alpha-release-checklist.md` 的其他门槛仍需逐项满足）。

### 11.2 预先设定的阻断条件（本次全部未触发）

| 编号 | 阻断条件 | 判定 | 证据 |
| --- | --- | --- | --- |
| B1 | 存在任何“未验证所有权即可发信号”的路径（含命令行子串匹配） | 未触发 | §1.2 |
| B2 | 密码值或长度可进入 UserDefaults / 命令行 / 日志 / 诊断 / 错误消息 | 未触发 | §2.2 |
| B3 | 默认或经界面可保存为非 loopback 且无需密码的监听配置 | 未触发 | §4 |
| B4 | ZIP 内含源码、测试、`.git`、日志、个人数据或本地绝对路径 | 未触发 | §5.4 |
| B5 | 发布产物可被描述为“已签名/已公证/稳定版”，或脚本不再强制 adhoc | 未触发 | §6 |
| B6 | CI/Release 需要写权限或未固定的第三方 Actions | 未触发 | §5.1、§5.2 |
| B7 | 仓库含真实凭据、私钥或个人主机名/私网地址 | 未触发（在报告被 `git add` 之后重跑两条门禁确认，见 §8.1） | §8 |
| B8 | 用户可见文档把未实现/已失效的安全能力写成已完成 | **触发过，已在本 PR 内修复**：`docs/logging-and-diagnostics.md:52` 的幂等声明被实测否定；`docs/privacy.md:47`、`docs/releasing.md:165`、`docs/orca-workflow.md:55` 的“通用 secret scan 尚未实现”与实际 CI 门禁矛盾。修复后重新判定为未触发 | §12 文档修正 |

### 11.3 未来版本的持续阻断条件（建议写入门槛）

1. 新增任何联网或本地数据位置而未同步更新 `docs/privacy.md`。
2. 新增非系统框架依赖而未记录许可证与供应链理由。
3. 首次对外发布非 alpha 版本（`beta.1` 及以后）时仍无 Developer ID 签名与公证。
4. `./Scripts/scan-secrets.sh`、`./Scripts/check-identity.sh`、`./Scripts/smoke.sh` 任一非 0 退出。
5. 出现“运行中密码被删除但远程进程仍在监听”的可复现路径。

---

## 12. 本 PR 内的文档修正

只修改 `docs/` 下的文件；`Sources/`、`Scripts/`、`.github/`、`PiWebDesktop.xcodeproj/`、测试均未改动。

| 文件 | 修正 | 原因 |
| --- | --- | --- |
| `docs/logging-and-diagnostics.md:52` | 把“脱敏是幂等的”改为实测范围（哪些形态幂等、JSON 引号键形态不幂等且会截断尾随字符） | §3.4 实测否定原声明 |
| `docs/logging-and-diagnostics.md` 规则表 | 补上“引号值 / 等号带空格 + 引号值 / 跨行值 / 含空格值”这四类**不**被覆盖的形态，并说明子进程输出只在下次启动时才被就地脱敏 | §3.3 实测 |
| `docs/logging-and-diagnostics.md` 验证表 | `幂等` 一项改为指向实际被断言的形态集合 | 同上 |
| `docs/privacy.md:47` | 删去“通用 secret scan 尚未实现”，改为“`Scripts/scan-secrets.sh` 已实现且由 CI 门禁；能力边界与未覆盖类型见开发说明” | 与 `docs/development.md:178` 及 CI 现状一致 |
| `docs/releasing.md:165` | 同上，并把“不要在检查清单里写成已完成门槛”改为“按 `Scripts/scan-secrets.sh` 退出码记录该项证据” | 同上 |
| `docs/orca-workflow.md:55` | 同上 | 同上 |

`README.md:125` 属于仓库根文件，超出本任务允许的写范围，列入 R-7 后续 Issue。

**后续处理（#15，v0.1.0-alpha.1 发布文档，本报告写完之后）：** R-7 已解决。`README.md` 里“没有通用
secret scanning”那一条已改为与 `docs/development.md` 及 CI 门禁一致的描述：三层固定模式文本检查、
`Scripts/scan-secrets.sh` 已实现且由 `Self-test the secret scanner` 与 `Scan tracked files for
committed secrets` 两步门禁、只扫已跟踪文件（先 `git add` 再扫）、不扫 Git 历史、通过不等于
“没有秘密”；发布门槛把 `./Scripts/scan-secrets.sh` 与 `--self-test` 的退出码及结尾的
`scan-secrets: suppressed N lines` 记入证据。相关记录见 [alpha 发布门槛清单](alpha-release-checklist.md)
的“本次发布执行记录”一节与 [v0.1.0-alpha.1 Release 说明](release-notes-v0.1.0-alpha.1.md)。
本报告 §10 的 R-7 行保留审查当时的判定，不再代表现状。

**后续处理（#39，启动与加载路径复用监听地址校验，本报告写完之后）：** R-3 已解决。`Sources/` 新增唯一的地址判定
`RemoteAccessPolicy.addressVerdict(hostname:)`（结果类型 `ServiceAddressVerdict`），保存路径、`ServiceConfiguration.load`
与 `ServiceManager.startDecision(credentials:)` 三处共用：通配地址（`0.0.0.0`、`::`、`[::]`、`*`）及其会被 `getaddrinfo` 解析成通配地址的等价写法（`0`、`0x0`、`000.000.000.000`、`0.0.0.0.`、`0:0:0:0:0:0:0:0`、`::ffff:0.0.0.0`）、空地址、前后空白与
非法字符在任何入口都被拒绝；`load` 规范化 `[::1]` 并把非法值原样标记为 `hostnameProblem`（不静默回退）；启动入口返回
`.invalidAddress` 并不启动进程、不探测外部服务、不加载页面，提示包含非法值与允许范围。本报告 §10 的 R-3 行保留审查当时
的判定与编号，已在“建议”列标注修复。相关文档同步在 `docs/architecture.md` 与 `docs/settings-and-workspace.md`。

本报告自身也做了两处“以防自伤”的处理：报告里展示的扫描器模式字面值全部按本仓库脚本惯用的拆段写法给出（避免报告命中这些门禁），且加入文档后在**暂存之后**重新跑过 CI personal-data `git grep`、`./Scripts/check-identity.sh`、`./Scripts/scan-secrets.sh`（均退出 0）。这个盲点本身记入 R-11。

---

## 13. 未能验证的部分（诚实边界）

1. **本地未运行 XCTest**：`xcode-select -p` 指向 Command Line Tools，`xcodebuild` 不可用（`error: tool 'xcodebuild' requires Xcode`）。因此 `PiWebDesktopTests/` 下约 17 个测试文件（`ServiceOwnershipTests` 28 个用例、`LogRedactorTests` 12 个、`LogWriterTests` 11 个等）与 `PiWebDesktopTests/ServiceIntegrationTests.swift` 的真实子进程集成层**未在本机执行**；本文引用它们时只作为“存在该覆盖”的静态证据，不作为已通过的运行结果。CI 的 `macos-14` job 覆盖这两条命令。
2. **`check-identity.sh --test-bundle` 未在本地运行**：需要 Xcode 产出的 `PiWebDesktopTests.xctest`。本地只运行了不带该参数的版本（45 项检查全通过）。
3. **未做真机 smoke 记录**：本机 `./Scripts/smoke.sh` 双模式通过，但 alpha 门槛要求的“真机 Apple Silicon + 真实 Node/Pi/pi-web 版本”记录属于 Release Issue 的范围，不在本次审查内。
4. **未访问真实 Keychain、未启动真实 pi-web、未结束任何真实进程**：所有权与外部服务策略的运行时结论来自静态代码路径、既有测试的覆盖清单与只读探针，不含真实进程行为观测。
5. **未扫描完整 Git 历史**：只对全部 23 个提交的新增行做了定向模式扫描（§8）；未做熵分析、二进制/加密载荷检查或全历史凭据审计。
6. **未评估上游 pi-web / Pi CLI / Node.js 的自身安全性**：属上游范围（`README.md`、`SECURITY.md` 已声明）。
7. **未覆盖 `docs/architecture.md` 与代码的逐条一致性**：本次只核查了与安全边界直接相关的章节（远程访问、网络边界、数据位置、所有权、日志），其余描述未逐句比对。
