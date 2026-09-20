# Pi Web Desktop `0.1.0-alpha.9` 安全评审（delta）

评审对象：`git diff 5f8f38b..8b7e74d` —— 即 `v0.1.0-alpha.8` 的发布提交到本版候选（`v0.1.0-alpha.8` 之后的全部提交）。这段区间里只有两个提交：`8b7e74d`（PR #130，关闭 [#127](https://github.com/Su-luoya/pi-web-desktop/issues/127) 的修复）与它之前的一个纯文档提交（PR #129，回填 alpha.8 的发布值）。真正的代码改动只有 PR #130。

评审性质：只读 delta 评审。逐处对照修复代码、测试与门槛输出，不修改文件、不提交、不联网。

**结论：阻断项 0 条，非阻断性发现 0 条。** 一条既往文案观察（`O-1`）在第 6 节记录，不影响本版发布。

## 1. `L-1`：四条「验证失败」日志行是否都改用三态措辞

- 措辞的唯一来源：`Sources/UpdateTransaction.swift:756` 的 `static func oldVersionClaimText(detectedVersion: String?) -> String` —— 有版本证据 → 「仍在使用更新前的版本 \(detectedVersion)；」；`nil` → 「重新检测没有给出可用的版本结果，无法判断更新前的文件是否仍在原位；」。
- 调用点穷举（`grep -rn oldVersionClaimText Sources/` 恰好 5 处命中，1 处定义 + 4 处调用）：`Sources/PiCLIUpdateAdapter.swift:1350`、`Sources/PiWebUpdateAdapter.swift:1726`、`Sources/PiPackageUpdateAdapter.swift:1598`（`logLine` 的 `.versionUnchanged` 分支）、`Sources/PiPackageUpdateAdapter.swift:1860`（`logOutcome` 路径）。
- 这四行内部已经打印「重新检测到的版本：…」，因此同一条消息里不再出现「未知」与「旧版本保持不变」并列的断言。无版本证据时新句只描述证据缺失，不声称文件状态。
- 持久警告（`Sources/UpdateTransaction.swift` 的 `verificationFailed` 三态）在 `v0.1.0-alpha.7` 已按证据来源给出 `partial` / `unverified` 两套说法；本版没有改动那里的判定，只把日志行的措辞统一到同一个函数。
- 未改变判定结果：`status`、验证状态、是否允许降级、菜单与页面上的其它文案都没有变化（`git diff` 只触及日志字符串与新增函数）。

## 2. 是否还有「无证据即断言旧版本仍在原位」的用户可见句子

- `grep -rn 保持不变 Sources/` 的命中中，除上面四处已修的日志行外，只剩注释、与版本状态无关的用法，以及第 6 节的既往文案。
- `Sources/UpdateTransaction.swift` 的 `displayName`（「更新后验证失败，仍在使用更新前的版本」）保持不变：该状态只在拿到版本相等或路径证据时出现，有证据支撑，不属无证据断言。

## 3. `L-3`：类型复核是否真的收窄了窗口

- `Sources/UpdateVerifier.swift` 的 `openRegularFile(atPath:)`：先 `URL(fileURLWithPath:).resolvingSymlinksInPath()`，再看 `fileType(atPath:) == .typeRegular`，然后 `FileHandle(forReadingAtPath:)`；拿到句柄后调用 `fstat`，只有 `(UInt32(st_mode) & UInt32(S_IFMT)) == UInt32(S_IFREG)` 才把句柄交出去，否则 `try? handle.close()` 并返回 `nil`。
- 也就是说：判定依据从「路径指向什么」变成「已经打开的这个句柄是什么」。即使路径在解析与打开之间被换成 FIFO、目录或设备节点，那个句柄也不会被交给调用方，也不会被读取。
- 可读文件的范围没有变化：常规文件、以及指向常规文件的符号链接仍可读；FIFO / 目录 / 字符设备仍被判为不可读。既有用例继续覆盖这两类结果（见第 5 节）。
- 新增 `import Darwin` 只为 `fstat` / `S_IFMT` / `S_IFREG` 常量，不改变进程能力、不改变权限语义、不涉及特权操作。

## 4. `L-4`：冲刷位置是否只有一处、会不会重复

- `Sources/PiPackageUpdateAdapter.swift` 的 `completeLocked` 在取消 `timer` / `drainTimer`、把 `finished` 置位之后、清 `readabilityHandler` 之前，对 `stdoutDecoder` 与 `stderrDecoder` 各做一次 `decode(Data(), final: true)`，把结果追加到对应的尾部缓冲。
- `completeLocked` 有 `guard !finished` 且是唯一的收尾入口，因此每次结束流程恰好冲刷一次。EOF 路径先前已经冲刷；重复冲刷在空暂存上是空操作。
- 语义后果：宽限到期结束时，尾部不完整的多字节序列现在产出一个替换字符（`U+FFFD`），而不是被静默丢弃。这把「静默丢字节」变成「可见的替换字符」，与 Pi CLI / Pi Web 的收尾路径一致。
- 新增用例 `testRealExecutorDrainGraceExpiryFlushesPendingDecoderBytes` 专门走这条路：父脚本只写半个多字节序列，后台子进程继续持有 stdout 写端（父进程退出后读不到 EOF），结束流程只能由宽限到期触发；断言尾部是替换字符而不是空。

## 5. 测试面

- 新增两个用例：`testOldVersionClaimFollowsTheDetectedVersionEvidence`（`PiWebDesktopTests/UpdateTransactionTests.swift`，覆盖有/无版本证据两种措辞）、`testRealExecutorDrainGraceExpiryFlushesPendingDecoderBytes`（`PiWebDesktopTests/PiPackageUpdateAdapterTests.swift`，覆盖 `L-4`）。
- `L-5` 由 `Sources/PiWebApp.swift:1684` 退出日志的直接复核覆盖（语句本身不再断言文件在位）。
- `L-3` 是窗口收窄而非新接口：窗口本身依赖调度，无法用确定性用例复现。本版以代码复核 + 既有类型闸门用例（「指向常规文件的符号链接可读」「FIFO 被判为不可读」）承担，**不作窗口级的断言**，这一点在此明确记录。
- 本机串行结果：`UpdateVerifierTests` 9 / 0、`PiPackageUpdateAdapterTests` 57 / 0、`UpdateTransactionTests` 36 / 0、`PiWebUpdateAdapterTests` 44 / 0、`PiCLIUpdateAdapterTests` 44 / 0（合计 190 passed / 0 failed）。并行跑多个测试文件时出现过两个依赖亚秒级进程启动的既有用例假失败（0.3s / 1s 窗口被启动耗时吃掉），单独跑该文件时全绿；CI 串行执行不受影响。

## 6. 发现

- 阻断项：**无**。
- 非阻断项：**无**。
- 观察 `O-1`（既往文案，非本次 delta，未改）：`Sources/PiCLIUpdateAdapter.swift:1528` 与 `Sources/PiWebUpdateAdapter.swift:1883` 的持久警告以「旧版本语义保持不变：应用不会自动回滚已替换的文件，也不声称更新成功」开头。这里说的是语义（冒号后即定义），不是「文件仍在原位」的断言，因此不构成与证据冲突的句子；它早于本版 delta，本次保持原样。若后续要继续压缩误读空间，可单独排一次措辞收敛。

## 7. 已核实无问题

- 版本唯一来源与一致性：`Configuration/AppIdentity.xcconfig` 是唯一来源，`Scripts/check-release-version.sh v0.1.0-alpha.9` `PASSED`；`Scripts/check-identity.sh` `PASSED (45 checks)`。
- 门槛与产物：`build.sh`、`smoke.sh`（默认与 `--diagnostics`）、`scan-secrets.sh`、`package-release.sh`、`codesign --verify --deep --strict` 均按预期通过；`spctl` 判 `rejected` 属未公证的预期结果。
- 改动范围：`git diff 5f8f38b..8b7e74d` 只包含文档回填（PR #129）与 PR #130 的一个修复；`L-3`、`L-4` 以外的运行时行为没有变化。

## 8. 证据不足 / 无法确认（不作猜测）

- `L-3` 的窗口是否在实际使用中被触发过：没有证据，本版只把判定依据从路径搬到句柄，不对历史行为下结论。
- 真机 GUI 手工验收、真实更新端到端演练：本机没有 Xcode、也没有在真机上走完整的更新流程，因此本评审不对 GUI 行为作断言。
- `O-1` 的两行在真实用户那里是否会被误读：无数据，只记录文案本身的性质。

## 9. 发布决定

不阻断发布。本版 delta 只做四件事：把四处日志措辞的来源统一到一个三态函数、把验证器的文件类型判定搬到已打开的句柄上、在扩展包执行器的收尾路径补一次解码器冲刷、去掉退出日志里对文件状态的断言。它不改变信号语义（不额外发送任何信号）、不改变文件操作范围（可读文件集合不变）、不改变权限与网络语义。
