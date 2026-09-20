# `v0.1.0-alpha.8` 安全评审（delta）

- 评审对象：`3ed1a09..c4f26a1`（`c4f26a1` 为本次发布提交，GitHub PR #125 / squash 合并到 `main`）。范围为本 delta 的全部改动文件：`Sources/PiPackageUpdateAdapter.swift`、`Sources/PiWebUpdateAdapter.swift`、`Sources/PiCLIUpdateAdapter.swift`、`Sources/PiWebApp.swift`、`Sources/UpdateVerifier.swift`、`Sources/UpdateTransaction.swift`、`docs/security-ownership.md`、`PiWebDesktop.xcodeproj/project.pbxproj`、`PiWebDesktopTests/`（4 个测试文件）。
- 评审方式：只读 delta 审查。以 `git diff 3ed1a09..c4f26a1` 为准逐文件通读，配合重新读取 `Sources/` 中未改动的相关路径（调用链、渲染点、持久化层）核对跨层语义；对涉及文件系统语义的两处做了本机实测（Swift 6.4；`FileManager.attributesOfItem` 对符号链接返回 `NSFileTypeSymbolicLink` 且 `size` 为链接自身大小（25）而非目标大小（5），对 FIFO 返回 `NSFileTypeUnknown` 且 `size == 0`，`resolvingSymlinksInPath()` 返回目标路径，`FileHandle(forReadingAtPath:)` 可穿过符号链接打开）。评审过程未联网，未执行构建与测试，未修改除本文件外的任何文件。
- 本报告对应的发布物：`docs/release-notes-v0.1.0-alpha.8.md`（工作树中为未跟踪文件，本次评审对其做了逐句与代码的比对）、`Configuration/AppIdentity.xcconfig`（工作树中已有与本 delta 无关的未提交改动，未纳入评审）。
- 已知过程瑕疵：本报告基于静态审查；`xcodebuild test` 未在评审机上执行（本机仅有 Command Line Tools，无 Xcode），因此对测试是否通过、测试是否覆盖未覆盖路径的判断都只依据代码与 CI 记录（`docs/release-notes-v0.1.0-alpha.8.md:253`、`docs/alpha-release-checklist.md:1020` 记录 `c4f26a1` 上 GitHub Actions run 35501956085 全部成功）。对无法从代码确认的项，一律列入「证据不足 / 无法确认」，不做推断。

## 结论

- **阻断项 0 条**（`H-` 无）。
- **非阻断项 5 条**：`L-1`、`L-2`、`L-3`、`L-4`、`L-5`。
  - `L-1` 日志仍断言「旧版本保持不变」（nil 版本路径）——与 `#119` / `L-2` 的同一形态仍残留在 `logLine` / `logOutcome`。
  - `L-2` 发布说明把 `integrity` 的基准版本写成「目标版本」，代码传的是更新前版本。
  - `L-3` `openRegularFile` 的类型检查与打开之间仍有 TOCTOU 窗口（已有类型闸门，非权限边界）。
  - `L-4` 排水宽限到期结束时不定长冲刷解码器暂存，尾部可能少一个不完整字符。
  - `L-5` 放弃等待的日志仍断言「旧版本保持不变」（既有行为，本 delta 未改）。
- 本 delta 的四个议题（`#119` 文案、`#121` `F1`–`F6`、`#124` `npmIntegrity` 基准版本、`#120` `T-1`–`T-3`）中，`#121` 的六项修法与 `#120` 的三项测试均按主张落实，`#119` 的文案修法**除 `L-1` 的四个日志行外**均已落实，`#124` 的代码语义**正确**（传的是更新前已安装版本，与读取时点一致），但其发布说明措辞与代码不符（`L-2`）。
- 未见越权、崩溃、数据损坏、凭据泄漏的新路径；未见判定分支被新代码放宽或收紧到与注释不符的程度（除 `L-4` 的尾部字符这一类可忽略差异）。

## 逐面结论

### 1. 文案是否还有「既写未知又断言旧版本仍在原位」的对偶

改动中新增/修正的文案均为「三态」措辞：`warning.reason` 的 nil 分支已改为「更新后验证失败：更新命令已结束，但重新检测没有给出可用的版本结果，因此无法判断是否达到目标版本」（`Sources/PiCLIUpdateAdapter.swift:1070-1071`、`Sources/PiPackageUpdateAdapter.swift:1574-1575`、`Sources/PiWebUpdateAdapter.swift:1452-1453`），持久警告同源（`Sources/PiCLIUpdateAdapter.swift:1527`、`Sources/PiWebUpdateAdapter.swift:1882`）；扩展包把「未执行」明确记为「不写安装失败，也不断言旧版本是否还在原位」（`Sources/PiPackageUpdateAdapter.swift:1760-1766`）。但**还有四条日志行**保留旧措辞（`L-1`），以及一条既有日志行（`L-5`）。

### 2. `#124` 的基准版本语义是否为「更新前已安装版本」（而非目标版本）

是「更新前版本」，且与读取时点自洽：三个采集点传的都是更新前的已知版本——`version: installation?.version ?? plan.installedVersion`（`Sources/PiCLIUpdateAdapter.swift:1250`）、`capture(installation:probe:)` 内的 `version: installation?.version`（`Sources/PiWebUpdateAdapter.swift:1620`，实现见 `Sources/UpdateTransaction.swift:229-238`）、`versionOnly(version: plan.installedVersion, …)`（`Sources/PiPackageUpdateAdapter.swift:1750-1753`，实现见 `Sources/UpdateTransaction.swift:296-306`）；采集发生在安装命令之前（`Sources/PiCLIUpdateAdapter.swift:1259`、`Sources/PiWebUpdateAdapter.swift:1629`、`Sources/PiPackageUpdateAdapter.swift:1758`），目标是更新前的安装树。`expectedVersion` 的取值顺序（`Sources/UpdateVerifier.swift:263-265`）会让该基准与从 `node_modules/<name>/package.json` 读到的版本互相校验（`Sources/UpdateVerifier.swift:715-738`）。唯一问题是发布说明的措辞（`L-2`）。

### 3. `F1` 扩展包交付队列

`deliveryQueue`（`Sources/PiPackageUpdateAdapter.swift:1109`，注释见 `:1108`）把回调搬离 `stateQueue`；忙拒时把局部 `completion` 投到该队列（`:1224-1225`），成功收尾同样在 `deliveryQueue.async` 里回调（`:1462-1497` 的 `completeLocked`），两处使用同一个自定义队列，不存在「投递到不同队列导致顺序颠倒」的形态。`isRunning` / `abandonedChildrenUnconfirmed`（`:1183-1187`）仍在 `stateQueue.sync` 上取值；忙拒判定用的是 `guard !running, abandonedProcesses.isEmpty`（本 delta 未改），不依赖门闩刷新。结论：**无新问题**（详见「已核实无问题」第 1 条）。

### 4. `F2` 增量 UTF8 解码

解码器把未收齐的多字节序列暂存到下一块（`Sources/PiWebUpdateAdapter.swift:6-45`，另两份同型实现），EOF 路径以空块 + `final: true` 冲刷（`Sources/PiPackageUpdateAdapter.swift:1373-1376`），每轮开始前重置（`:1298-1299`），配合子进程句柄身份拦截（`:1366-1368`）防止跨轮串流。跨块边界不产生多字节损坏。唯一差异是宽限到期结束的路径不冲刷（`L-4`）。

### 5. `F4` 每次读取前的文件识别

`fileType(atPath:)`（`Sources/UpdateVerifier.swift:164-167`）对末级符号链接报 `NSFileTypeSymbolicLink`（本机实测确认，与注释「不跟随末级符号链接，与 `lstat` 同语义」一致）；`openRegularFile`（`:170-174`）先解引用、再要求 `.typeRegular`、最后打开；`readBoundedData`（`:179-208`）在大小闸门之外把实际上限收紧到 `maximumSize`（超限即返回 nil）。整体语义与 `#120` / `F4` 的修法一致；残余 TOCTOU 窗口记为 `L-3`。新增测试覆盖 FIFO（`PiWebDesktopTests/UpdateVerifierTests.swift:233`）与符号链接（`:243`）两种形状。

### 6. `F5` 收尾窗口内的取消请求

`PiWebAttempt.cancelRequestedDuringFinish`（`Sources/PiWebUpdateAdapter.swift:702`、默认值 `:714`、赋值 `:725`、结构体字段 `:1076`、结果字段 `:1380`）在 `cancel()` 的收尾分支（`:1140-1143`）被置位后立即返回，不再向已经结束的子进程发信号；协调器在收尾窗口收到取消时记一行「Pi Web 取消请求落在收尾窗口内…」（`:1640-1644`）。

### 7. `F6` 尾输出脱敏

`Sources/PiWebUpdateAdapter.swift:1673` 先 `result.outputTail.map { self.environment.redactor.redact($0) }`，`:1679` 再把 `outcomeTail` 交给 `installFailed`；路径参数 `logOutputTail(result.outputTail)`（`:1668`）在函数体内部脱敏（`:1831-1837`）。CLI 的 `outputTailText`（`Sources/PiCLIUpdateAdapter.swift:1404-1412`）与扩展包的 `outputTailText`（`Sources/PiPackageUpdateAdapter.swift:1899-1907`）同样脱敏，UI 标注为「命令输出片段（已脱敏）」（`Sources/PiWebApp.swift:1693`）；持久化层同样经过脱敏（`Sources/UpdateTransaction.swift:432`、`:444`、`:588`）。

### 8. `F3` 文档

`docs/security-ownership.md:88` 新增「不固定可执行文件位置、不校验签名（`PATH` 即信任边界）」；`Sources/PiCLIUpdateAdapter.swift:166-175` 的 `isSafeExecutablePath` 新增注释说明同一信任模型。

### 9. 工程完整性

`PiWebDesktop.xcodeproj/project.pbxproj` 四处新增齐全且无 ID 冲突：`:90` `BuildFile A1…5B`、`:162` `FileReference A2…60`、`:180` 分组 children、`:200` `Test Sources` 阶段；`A1…5B` 出现 2 次（`PBXBuildFile` + `PBXSourcesBuildPhase`），`A2…60` 出现 3 次（`PBXFileReference` + 两处 `children`）。`PiWebDesktopTests/UpdateVerifierTests.swift:1-2` 有 `import Darwin` / `import XCTest`，测试目标依赖 `Darwin` 与 `XCTest` 为系统模块，无需新链接项。

## 发现

### L-1（低，非阻断）验证失败的日志行仍断言「旧版本保持不变」

- **Sources**：`Sources/PiPackageUpdateAdapter.swift:1594`（结果对象 `logLine` 的 `.versionUnchanged` 分支）、`Sources/PiPackageUpdateAdapter.swift:1855`（协调器 `logOutcome`）、`Sources/PiCLIUpdateAdapter.swift:1350`、`Sources/PiWebUpdateAdapter.swift:1726`。
- **机制**：四条路径都是同一形态：先写「重新检测到的版本是 未知」（`detected` 为 nil 时用 `detected ?? "未知"` 插值），紧接一句「旧版本保持不变 / 旧版本语义保持不变」。这些路径的入口是 `guard journal.recordVerification(report, detectedVersion:)`（`Sources/PiPackageUpdateAdapter.swift:1833`、`Sources/PiCLIUpdateAdapter.swift:1328`、`Sources/PiWebUpdateAdapter.swift:1704`），而 `detectedVersion == nil` 正是其中一种失败原因——同一个分支的 `warning.reason` 就是为此写了 nil 文案（见逐面结论 1）。
- **为什么是问题**：这正是 `#119` / `L-2` 要消除的形态（同一句里既写「重新检测到的版本是 未知」又断言旧版本还在原位）。`L-2` 修了 `warning.reason` 与持久警告，未修这四条日志行；而 `docs/release-notes-v0.1.0-alpha.8.md:92-97` 的表述是「不再在同一句里既写『仍在使用更新前的版本』又写『重新检测到的版本是 未知』」，因此发布说明对 `L-2` 的完成度有轻微过度声明。日志是排障的第一手材料：当探针因权限/路径问题读不到新版本时，日志会把「不知道」写成「旧版本仍在」，把技术员引向错误结论。
- **影响边界**：只影响日志与结果对象的展示行（`Sources/PiPackageUpdateAdapter.swift:1615`、`Sources/PiWebApp.swift:1987` 会把这些行写进日志/界面），不改变任何判定、文件操作、信号处理或凭据处理。
- **建议**：把这四处的尾句改成与 `warning.reason` 同源的措辞（例如「是否达到目标版本无法判断；本次没有执行任何回滚动作」），并给 `PiWebDesktopTests/PiPackageUpdateAdapterTests.swift` 补一条「nil 版本 + 日志文案」的断言，防止回归。

### L-2（低，非阻断）发布说明把 `integrity` 的基准版本写成「目标版本」

- **Sources**：`docs/release-notes-v0.1.0-alpha.8.md:121-124`（「…`Sources/UpdateTransaction.swift` 在采集时传入本次更新的目标版本。」）；代码：`Sources/PiCLIUpdateAdapter.swift:1250`、`Sources/PiWebUpdateAdapter.swift:1620` → `Sources/UpdateTransaction.swift:229-238`、`Sources/PiPackageUpdateAdapter.swift:1750-1753`、`Sources/UpdateVerifier.swift:263-265`。
- **机制**：三个采集点传的都是**更新前已安装版本**（`plan.installedVersion` / `installation?.version`），而不是 `plan.targetVersion`；采集发生在安装命令之前，读取的是更新前的安装树，"读更新前的锁文件 + 拿更新前的版本当基准"因此是自洽的一对。发布说明写成「目标版本」与代码不符。
- **为什么是问题**：措辞混淆了两个语义不同的值。若按发布说明的措辞去实现（传 `plan.targetVersion`），反而会引入 `#124` 想避免的错误路径：`readIntegrityValue` 在条目带 `version` 且与基准不符时返回 nil（`Sources/UpdateVerifier.swift:298-302`），更新前锁文件里的条目会被整体跳过，指纹里 `integrity` 一律记成「未获取」——「合法更新被误判为不一致」只有在按错误措辞实现时才成立。
- **影响边界**：只影响发布说明的可核对性与后续维护者的理解；运行时行为正确。
- **建议**：把该句改成「在采集时传入更新前的已安装版本（`installation.version` / `plan.installedVersion`）」，并保留「与读取时点相同」这一理由。

### L-3（低，非阻断）`openRegularFile` 的类型检查与打开之间仍有 TOCTOU 窗口

- **Sources**：`Sources/UpdateVerifier.swift:170-174`。
- **机制**：`let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path`，随后 `guard fileType(atPath: resolved) == .typeRegular`，最后 `FileHandle(forReadingAtPath: resolved)`。检查与打开是两次独立的路径查找，中间存在可替换窗口；在窗口内把 `resolved` 从常规文件换成 FIFO（或让路径指向被替换的目录项）即可绕过类型闸门，`FileHandle.read` 可能长时间阻塞。阻塞发生在调用方线程上（调用点：`Sources/PiPackageUpdateAdapter.swift:1813`、`Sources/PiCLIUpdateAdapter.swift:1314`、`Sources/PiWebUpdateAdapter.swift:1690`）。
- **为什么是问题**：alpha.7 的 `F4`（「有界读只约束字节数，不约束时长」）的原始关切是「读 FIFO 无超时阻塞」。本版用「解引用 + 类型检查」把它从**无条件**收窄为**需要精确撞上窗口**（`attributesOfItem` 对 FIFO 报 `0` 字节且类型不是常规文件，替换必须恰好落在两次调用之间）；窗口极小，且需要本地写权限才能触发，因此不是权限边界被跨越——`docs/security-ownership.md:88` 明确把可执行文件位置的信任交给了 `PATH`。
- **影响边界**：最坏情况是一次读取挂起（需本地写权限），不产生越权读取、不写文件、不泄漏凭据。
- **建议**：若要彻底关闭，可改为不解引用路径的原子打开（`open(O_RDONLY|O_NOFOLLOW)` 后对 fd 做 `fstat` 判 `S_IFREG`），或把探针读取放到带超时的队列并采用「放弃即返回 nil」；也可接受现状，但应在注释里写明「检查与打开之间仍存在窗口，这里靠『不跟随末级符号链接 + 类型闸门』把风险收窄到需要本地写权限的竞态」。

### L-4（低，非阻断）排水宽限到期结束时冲刷解码器暂存

- **Sources**：`Sources/PiPackageUpdateAdapter.swift:1449-1460`（`scheduleDrainDeadlineLocked`，到期时 `:1457-1458` 直接调用 `completeLocked(exitCode: pending.exitCode, launchFailed: pending.launchFailed)`），对照 EOF 路径 `:1373-1376`（`decode(Data(), final: true)`）。
- **机制**：正常路径是「管道读到 EOF → 冲刷未收齐的多字节尾部 → 标记 drained → 收尾」；宽限到期路径只把暂存结果收尾，不调用 `decode(Data(), final: true)`，`IncrementalUTF8Decoder` 里 `pending` 的不完整序列被直接丢弃（同型实现对 `pending` 的处理一致：`Sources/PiWebUpdateAdapter.swift:6-45`）。
- **为什么是问题**：与发布说明 `#121 F2` 的承诺（「进程退出时以空块冲刷暂存的不完整序列」，`docs/release-notes-v0.1.0-alpha.8.md:105-108`）不完全一致：只有 EOF 路径承诺成立，宽限到期路径不成立。影响是尾部可能少一个不完整的多字节字符（≤3 字节），也就是 `:1449` 注释自己写的「只是尾部可能少一段」。
- **影响边界**：只少字符，不产生 U+FFFD、不重复、不跨轮（下一轮开始前 `resetRunStateLocked` 重建解码器，`Sources/PiPackageUpdateAdapter.swift:1298-1299`；跨轮管道事件另有句柄身份拦截 `:1366-1368`）。
- **建议**：若要与承诺完全一致，可在 `completeLocked` 里对两个解码器做一次 `final: true` 冲刷再拼尾部（代价是可能出现的 U+FFFD）；否则把发布说明这一条写成「EOF 时冲刷暂存序列；排水宽限到期时尾部可能少一段（代码注释已注明）」与之对齐。

### L-5（低，非阻断，既有行为）放弃等待的日志行仍断言「旧版本保持不变」

- **Sources**：`Sources/PiWebApp.swift:1684`。
- **机制**：`case .commandFailed(_, let failure, let oldVersion, _, _)` 中，`failure == .abandoned` 时只记一行日志：「Pi CLI 更新已放弃等待（应用退出）：\(oldVersion) 保持不变，下次启动重新检测。」；而紧邻的注释（`:1679-1681`）写的是「命令可能仍在后台自己完成，下次启动的检查会给出结论」。
- **为什么是问题**：与 `L-1` 同类——把「不知道」写成「旧版本保持不变」。放弃等待的定义就是「不再等这个子进程」，命令随后仍可能成功替换文件。
- **影响边界**：只影响日志；不写持久告警、不弹框（同处注释说明这是有意为之）。
- **归属**：本 delta 没有改这一行（`git diff 3ed1a09..c4f26a1 -- Sources/PiWebApp.swift` 只加了 `:1705-1711` 的恢复提示），属既有行为；因为本次任务书问题 1 明确要求排查「是否还有路径写出与事实不符的句子」，故登记。
- **建议**：与文件内其他处置保持一致——删去「保持不变」，改成「本次没有继续等待，也没有确认退出」（或复用 CLI 的措辞）。

## 已核实无问题

1. **`F1` 交付队列**：`deliveryQueue` 声明与忙拒投递、成功收尾投递使用同一自定义队列（`Sources/PiPackageUpdateAdapter.swift:1109`、`:1224-1225`、`:1462-1497`），不会出现「不同队列导致回调顺序颠倒」；`isRunning` / `abandonedChildrenUnconfirmed` 仍在 `stateQueue.sync` 上取值（`:1183-1187`）；忙拒判定 `guard !running, abandonedProcesses.isEmpty` 未被改坏；协调器的忙拒完成回调不再在 `stateQueue` 上运行（新增测试 `PiWebDesktopTests/PiPackageUpdateAdapterTests.swift:1221` 用信号量把完成阻塞住 1 秒并断言 `isRunning` 能读到，覆盖该性质）。
2. **`F2` 增量 UTF8 解码**：跨块边界的多字节序列被暂存到下一块，EOF 路径冲刷（`Sources/PiPackageUpdateAdapter.swift:1373-1376`），轮次开始前重置（`:1298-1299`），句柄身份拦截防止跨轮串流（`:1366-1368`）；新增测试把「☃」分三段写入（`printf '\342'` / `sleep` / `printf '\230\203'`）并断言尾输出为 `☃`（`PiWebDesktopTests/PiPackageUpdateAdapterTests.swift:1246`，另见 `PiWebDesktopTests/PiWebUpdateAdapterTests.swift` 的同型用例，本 delta 未改 Web 侧解码器）。
3. **`F4` 文件读取**：类型闸门在解引用之后判断 `.typeRegular`（`Sources/UpdateVerifier.swift:170-174`）；有界读把实际上限收紧到 `maximumSize`（`:179-208`）；FIFO 不被读取（`PiWebDesktopTests/UpdateVerifierTests.swift:233`，`mkfifo` 后断言 `fileType != .typeRegular` 且 `readBoundedData` 返回 nil）；符号链接可读（`:243`，断言 `fileType(atPath: link.path) == .typeSymbolicLink` 且能读到内容）。
4. **`F5` 收尾窗口内的取消请求**：`cancel()` 在收尾分支只置位 `cancelRequestedDuringFinish` 并返回，不向已结束子进程发信号（`Sources/PiWebUpdateAdapter.swift:1140-1143`）；该字段随结果传到协调器并被记入日志（`:1380`、`:1640-1644`）。
5. **`F6` 尾输出脱敏**：尾输出在进入结果对象前脱敏（`Sources/PiWebUpdateAdapter.swift:1673`、`:1679`）；按路径取用的尾输出在函数体内脱敏（`:1668` → `:1831-1837`）；三份 `outputTailText` 实现均脱敏（`Sources/PiCLIUpdateAdapter.swift:1404-1412`、`Sources/PiPackageUpdateAdapter.swift:1899-1907`）；UI 标注「命令输出片段（已脱敏）」（`Sources/PiWebApp.swift:1693`）；持久化层同源脱敏（`Sources/UpdateTransaction.swift:432`、`:444`、`:588`）。
6. **`F3` 文档与信任模型**：`docs/security-ownership.md:88` 与 `Sources/PiCLIUpdateAdapter.swift:166-175` 的说明一致（不固定位置、不校验签名、`PATH` 即边界）。
7. **`#124` 基准版本语义**：三个采集点传的都是更新前已安装版本，且读取发生在安装命令之前（`Sources/PiCLIUpdateAdapter.swift:1249-1259`、`Sources/PiWebUpdateAdapter.swift:1619-1629`、`Sources/PiPackageUpdateAdapter.swift:1748-1758`）；`expectedVersion` 让基准与 `package.json` 版本互相校验（`Sources/UpdateVerifier.swift:263-265`、`:715-738`）；`npmIntegrity` 仅作为证据文本使用（`Sources/UpdateTransaction.swift:210-213`、`:588`），不参与任何判定。
8. **锁文件选择与形状判定**：`readIntegrityValue` 以 `node_modules/<name>` 精确路径优先、`version` 不符或条目歧义返回 nil、形状校验限制长度与算法白名单（`Sources/UpdateVerifier.swift:230-241`、`:287`–`:302`）；新增测试覆盖精确路径、歧义、版本基准相符/不符、`dependencies` 回退、形状异常（`PiWebDesktopTests/UpdateVerifierTests.swift:53`、`:75`、`:98`、`:125`、`:148`）；协调器侧的「重新检测发现版本未变 → 不写成功、不静默重试」与「验证失败 → 不自动回滚」判定未被放宽（`Sources/UpdateTransaction.swift:620-700`）。
9. **`#119` 文案的其余部分与 `#120` 测试**：`UpdateWarningText.installFailed` / `verificationFailed` 的措辞与三态判定（nil 时写「未知」且不声称回滚）一致（`Sources/UpdateTransaction.swift:743-752`、`:766-773`、`:417-440`）；`PiWebDesktopTests/UpdateTransactionTests.swift:46` 的 `npmIntegrity: { [self] path,_,_ in npmIntegrities[path] }`（真实可执行文件 + 假探针）测的是「传指纹版本为基准」这一条（`:38-73`）；`PiWebApp.swift:1708-1713` 的恢复提示只使用 `abandonedChildrenUnconfirmed`（`Sources/PiCLIUpdateAdapter.swift:648`）这一既有状态，未引入新的等待/轮询路径。
10. **工程完整性**：`project.pbxproj` 四处新增（`PiWebDesktop.xcodeproj/project.pbxproj:90`、`:162`、`:180`、`:200`）齐全、无 ID 冲突（`A1…5B` 2 处、`A2…60` 3 处）；新测试文件只依赖 `Darwin` / `XCTest` 系统模块（`PiWebDesktopTests/UpdateVerifierTests.swift:1-2`）；无新增第三方依赖。

## 证据不足 / 无法确认（不作猜测）

- **测试是否在评审机上通过**：本机没有 Xcode（只有 Command Line Tools），未执行 `xcodebuild test`。只能引用 CI 记录（`docs/release-notes-v0.1.0-alpha.8.md:253`、`docs/alpha-release-checklist.md:1020`、`:1069` 记录 run 35501956085 在 `c4f26a1` 上成功）。新增测试断言的具体文案是否与实现逐字一致，只能靠静态比对，未动态验证。
- **`L-4` 的实际发生概率**：宽限到期路径是否真的会在真实机器上先于 EOF 触发（例如子进程持有管道写端但已停止输出），本次未做进程级实验，只能确认代码形态上不冲刷。
- **`L-3` 的窗口可利用性**：未做竞态实验（需要本地写权限与精确时序），仅依据代码结构判定窗口存在。
- **`L-1` / `L-5` 的日志是否被任何下游消费方（如遥测、支持脚本）按语义解析**：仓库内只见渲染与持久化，未见解析器；不排除仓库外消费方。
- **`Configuration/AppIdentity.xcconfig` 的工作树改动**：与本 delta 无关（未提交改动），未纳入评审。
- **重试/超时参数**：`F5` 之外的信号与超时逻辑（如 `environment.timeout`、排水宽限值的取值）本 delta 未改，未复核其上游来源。

## 发布决定

- **不阻断发布**：无 `H-` 项；`L-1`≈`L-5` 均为低危、只影响日志或发布说明文本，`L-3` / `L-4` 的残余窗口与字符差异不构成权限或数据完整性问题，且都可用后续小版本单独收敛。
- **建议在 `v0.1.0-alpha.9` 之前修**：`L-1`（四条 nil 版本日志行，与 `L-2` 的修法同源，`#119` 的完成度问题）与 `L-2`（发布说明措辞，属发布物可核对性）。
- **可继续观察**：`L-3`（若接受现状，建议补注释说明窗口）、`L-4`（若接受现状，建议把发布说明措辞与代码注释对齐）、`L-5`（既有行为，随文案统一一起处理即可）。
