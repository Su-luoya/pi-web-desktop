/// Pi process inspection used as the update safety gate.

import Darwin
import Foundation

// MARK: - 检查器

/// Pi 运行进程检查器（GitHub #21）。
///
/// 输入全部注入：进程表（`PiProcessProbing`）、可执行位探针
/// （`DependencyFileSystemProbing`）、脱敏器与时间格式器。因此 unhosted 测试
/// 只构造假进程事实，不会枚举真实进程、不会读取真实磁盘、也不会写任何东西。
struct PiProcessInspector {
    /// 判定为“JS 运行时”的可执行文件名（小写比较）。Pi CLI 以 `#!/usr/bin/env node`
    /// 脚本形式发行，内核报告的镜像路径是 Node 本身，所以必须结合 argv 判定。
    static let interpreterExecutableNames: Set<String> = ["node", "nodejs", "bun", "deno", "tsx", "ts-node"]
    /// Pi CLI 的可执行文件名：精确匹配，不做前缀/子串匹配。
    static let piExecutableName = "pi"

    var probe: PiProcessProbing
    var fileSystem: DependencyFileSystemProbing
    var redactor: LogRedactor
    /// 启动时间格式器（诊断页/确认框显示用；测试注入固定值）。
    var formatStartTime: (Date) -> String

    init(
        probe: PiProcessProbing = .libproc,
        fileSystem: DependencyFileSystemProbing = SystemDependencyFileSystemProbe(),
        redactor: LogRedactor = LogRedactor(),
        formatStartTime: @escaping (Date) -> String = PiProcessInspector.defaultStartTimeFormat
    ) {
        self.probe = probe
        self.fileSystem = fileSystem
        self.redactor = redactor
        self.formatStartTime = formatStartTime
    }

    static let defaultStartTimeFormat: (Date) -> String = { date in
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 枚举并判定。只有确认没有任何 Pi 进程时才返回 `.noProcesses`；
    /// 只要确认存在 Pi 进程就返回 `.runningProcesses`（同时存在无法判定的
    /// 进程时仍然以“已经确认在运行”为结论，理由见 `PiProcessInspection`）；
    /// 其余情况返回 `.unknown`。
    func inspect() -> PiProcessInspection {
        switch probe.listProcessIdentifiers() {
        case .failed:
            return .unknown(.enumerationFailed)
        case .pids(let pids):
            var records: [PiProcessRecord] = []
            var unknown: PiProcessInspectionUnknown?
            for pid in Set(pids).sorted() where pid > 1 {
                switch probe.snapshot(pid) {
                case .processGone:
                    continue
                case .snapshot(let identity):
                    // 便宜筛选：非候选进程不读 argv，分类也不会看 argv；候选进程
                    // 读到的 argv 只是补全快照，不确定语义不变（读不到仍按空处理，
                    // 由 classify 归入 unknown）。
                    let snapshot: PiProcessSnapshot
                    if Self.isCandidate(identity) {
                        var candidate = identity
                        candidate.arguments = probe.arguments(identity.pid)
                        snapshot = candidate
                    } else {
                        snapshot = identity
                    }
                    switch classify(snapshot) {
                    case .pi(let record):
                        records.append(record)
                    case .notPi:
                        continue
                    case .unknown(let reason):
                        if unknown == nil { unknown = reason }
                    }
                }
            }
            if !records.isEmpty {
                return .runningProcesses(records)
            }
            if let unknown {
                return .unknown(unknown)
            }
            return .noProcesses
        }
    }

    /// 单个进程的分类。
    func classify(_ snapshot: PiProcessSnapshot) -> PiProcessClassification {
        let imageName = Self.baseName(snapshot.imagePath)
        let kernelName = Self.baseName(snapshot.executableName)

        // 1. 真实镜像路径的文件名就是 pi。
        if let imageName, Self.isPiExecutableName(imageName) {
            return .pi(makeRecord(snapshot, matchSource: .imagePath, scriptPath: nil))
        }

        // 2. 镜像路径不可得，但内核进程名就是 pi（其它用户或受保护进程也能读到
        //    的、仍然是“可执行名匹配”的证据）。
        if snapshot.imagePath == nil, let kernelName, Self.isPiExecutableName(kernelName) {
            return .pi(makeRecord(snapshot, matchSource: .executableName, scriptPath: nil))
        }

        // 3. 镜像路径或进程名表明这是 JS 运行时：Pi CLI 以内核看不到的脚本形式
        //    运行，只有 argv 能证明“脚本/进程标题恰好是 pi”。
        let interpreter = Self.interpreterName(imageName) ?? Self.interpreterName(kernelName)
        if let interpreter {
            if snapshot.imagePath == nil, kernelName == nil {
                return .unknown(.identityUnavailable(pid: snapshot.pid, failure: snapshot.readFailure))
            }
            return classifyInterpreterProcess(snapshot, interpreter: interpreter)
        }

        // 4. 镜像路径可读、文件名既不是 pi 也不是 JS 运行时：确定不是 Pi。
        if imageName != nil { return .notPi }

        // 5. 镜像路径不可得，但内核进程名可读且明确不是 pi：确定不是 Pi。
        if let kernelName, !kernelName.isEmpty { return .notPi }

        // 6. 两个可执行身份都不可读：不确定。
        return .unknown(.identityUnavailable(pid: snapshot.pid, failure: snapshot.readFailure))
    }

    /// JS 运行时进程：只有 argv 里“恰好等于 pi”的脚本路径或进程标题才算命中。
    ///
    /// - `argv[0]` 恰好是 `pi` 时按进程标题命中：Pi CLI 会把进程标题改写成
    ///   `pi`，此时原始脚本路径已经不可见；普通 JS 应用的 `argv[0]` 是运行时
    ///   自己的名字（例如 `node`），不会命中；这是**唯一**接受的非绝对路径形态；
    /// - 其它位置的参数必须既是**绝对路径**、文件名又恰好是 `pi`，并且能解析出
    ///   可执行文件（可执行位，或符号链接能解析到存在的目标）；`node /tmp/notes/pi`
    ///   这类普通文件、符号链接断裂与相对路径因此不会命中；
    /// - 相对路径（`./pi`、`../bin/pi`、解释器的第一个位置参数 `pi`）一律按
    ///   `unknown` 处理：无法确认它相对哪个工作目录解析，不确定即按不安全处理
    ///   （返回 `notPi` 会是漏判方向）；
    /// - 数据参数里的 `pi`（例如 `node app.js pi`、`vim pi`）不会命中：既不是
    ///   `argv[0]`，也不是脚本路径位置。
    private func classifyInterpreterProcess(
        _ snapshot: PiProcessSnapshot,
        interpreter: String
    ) -> PiProcessClassification {
        guard !snapshot.arguments.isEmpty else {
            return .unknown(.argumentsUnavailable(pid: snapshot.pid, interpreter: interpreter))
        }
        var unconfirmed: PiProcessInspectionUnknown?
        func recordUnconfirmed(_ path: String) {
            guard unconfirmed == nil else { return }
            unconfirmed = .scriptPathUnconfirmed(pid: snapshot.pid, path: redactor.redact(path))
        }
        for (index, argument) in snapshot.arguments.enumerated() where !argument.isEmpty {
            guard Self.baseName(argument) == Self.piExecutableName else { continue }
            if argument.hasPrefix("-") { continue }
            if index == 0, !argument.contains("/") {
                return .pi(makeRecord(snapshot, matchSource: .processTitle, scriptPath: nil))
            }
            // 脚本路径候选：含路径分隔符的参数，或解释器的第一个位置参数（index 1
            // 的裸名）。其余位置的裸 `pi` 是数据参数，不读磁盘也不改变判定。
            let looksLikePath = argument.contains("/")
            let isInterpreterScriptPosition = index == 1 && !looksLikePath
            guard looksLikePath || isInterpreterScriptPosition else { continue }
            guard argument.hasPrefix("/") else {
                // 相对路径：无法确认它相对哪个工作目录解析，按不确定处理。
                recordUnconfirmed(argument)
                continue
            }
            if fileSystem.isExecutableFile(atPath: argument) {
                return .pi(makeRecord(
                    snapshot,
                    matchSource: .interpreterScript,
                    scriptPath: redactor.redact(argument)
                ))
            }
            // 符号链接要能解析到存在的目标才算命中；断裂的符号链接按不确定处理
            // （它既不能证明脚本存在，也不能证明它不存在）。
            if fileSystem.symlinkDestination(atPath: argument) != nil,
               fileSystem.resolvedPath(atPath: argument) != nil {
                return .pi(makeRecord(
                    snapshot,
                    matchSource: .interpreterScript,
                    scriptPath: redactor.redact(argument)
                ))
            }
            recordUnconfirmed(argument)
        }
        if let unconfirmed { return .unknown(unconfirmed) }
        return .notPi
    }

    /// 构造已脱敏记录。原始 argv 到这里为止：摘要只保留脱敏后的文本。
    private func makeRecord(
        _ snapshot: PiProcessSnapshot,
        matchSource: PiProcessMatchSource,
        scriptPath: String?
    ) -> PiProcessRecord {
        PiProcessRecord(
            pid: snapshot.pid,
            parentPID: snapshot.parentPID,
            startedAtText: snapshot.startedAt.map(formatStartTime),
            executablePath: snapshot.imagePath.map { redactor.redact($0) },
            scriptPath: scriptPath,
            matchSource: matchSource,
            commandSummary: Self.commandSummary(arguments: snapshot.arguments, redactor: redactor)
        )
    }

    // MARK: - 纯函数

    /// 可执行文件名是否恰好是 `pi`。**精确匹配**：`pi-web`、`pip`、`pi-helper`
    /// 都不命中。
    static func isPiExecutableName(_ name: String) -> Bool {
        name == piExecutableName
    }

    /// JS 运行时的候选名字前缀（GitHub #61）。
    ///
    /// 候选判定故意比分类宽松：`node24`、`npm-cli` 这类带版本或包装后缀的名字也
    /// 按运行时处理。放宽只可能多读一个进程的 argv，不可能漏读，也不可能改变
    /// 分类结论（`classify` 仍然只认 `interpreterExecutableNames` 的精确名字）。
    static let runtimeNamePrefixes: Set<String> = [
        "node", "npm", "npx", "bun", "deno", "tsx", "ts-node"
    ]

    /// 名字是否像已知的 JS 运行时（精确名或已知前缀）。
    static func isRuntimeLikeName(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        let lowered = name.lowercased()
        if interpreterExecutableNames.contains(lowered) { return true }
        return runtimeNamePrefixes.contains { lowered.hasPrefix($0) }
    }

    /// 便宜的候选判定：只用镜像路径与内核进程名，**不读 argv**。
    ///
    /// 只有候选进程的 argv 可能改变判定结果：`pi` 的可执行名（镜像或内核进程名）
    /// 需要 argv 生成命令摘要；JS 运行时（Pi CLI 的 `#!/usr/bin/env node` 形态、
    /// npm/pnpm 全局前缀下的入口脚本都由 `node` 承载）需要 argv 才能看到脚本路径
    /// 与进程标题。系统守护进程、编译器、编辑器的 argv 与判定无关，因此不读。
    ///
    /// 候选判定是读取优化，不是安全判断：它不把任何“不确定”变成“确定”，
    /// 两个可执行身份都读不到的进程仍然走 `unknown`。
    static func isCandidate(imagePath: String?, executableName: String?) -> Bool {
        let imageName = baseName(imagePath)
        let kernelName = baseName(executableName)
        if let imageName, isPiExecutableName(imageName) { return true }
        if let kernelName, isPiExecutableName(kernelName) { return true }
        if isRuntimeLikeName(imageName) { return true }
        if isRuntimeLikeName(kernelName) { return true }
        return false
    }

    /// `PiProcessSnapshot` 版本的候选判定。
    static func isCandidate(_ snapshot: PiProcessSnapshot) -> Bool {
        isCandidate(imagePath: snapshot.imagePath, executableName: snapshot.executableName)
    }

    /// 路径（或裸名）的最后一段；空值返回 nil。
    static func baseName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let base = (path as NSString).lastPathComponent
        return base.isEmpty ? nil : base
    }

    /// 可执行文件名是否是已知 JS 运行时（小写比较；macOS 上 `Node` 也可能出现）。
    static func interpreterName(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        let lowered = name.lowercased()
        return interpreterExecutableNames.contains(lowered) ? lowered : nil
    }

    /// `KEY=VALUE` 形状的环境变量片段：不进摘要。
    static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let separator = token.firstIndex(of: "="), separator != token.startIndex else { return false }
        let key = token[token.startIndex..<separator]
        guard let first = key.first, first.isLetter || first == "_" else { return false }
        return key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    // MARK: - Token 级凭据脱敏

    /// 敏感键名片段（与 `LogRedactor` 的判据同一组：token/password/secret/
    /// api_key…，大小写不敏感）。
    static let sensitiveKeyFragments = [
        "token", "password", "passwd", "secret", "api_key", "apikey",
        "api-key", "private_key", "private-key", "credential"
    ]

    /// 文本里是否含敏感键名片段。
    static func containsSensitiveKeyFragment(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let lowered = text.lowercased()
        return sensitiveKeyFragments.contains { lowered.contains($0) }
    }

    /// 文本是否以敏感键名片段结尾（`--api-key` 是开关名；`--api-key<值>` 不是）。
    static func endsWithSensitiveKeyFragment(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let lowered = text.lowercased()
        return sensitiveKeyFragments.contains { lowered.hasSuffix($0) }
    }

    /// 去掉前导 `-`（`--token` → `token`）。
    static func strippingLeadingDashes(_ text: String) -> String {
        var result = text
        while result.hasPrefix("-") { result.removeFirst() }
        return result
    }

    /// `键=值` / `键:值` 形态的分隔符位置；不是键值形态时返回 nil。
    /// `scheme://` 不当作键值分隔符。
    static func keyValueSeparatorIndex(in token: String) -> String.Index? {
        if let index = token.firstIndex(of: "=") { return index }
        guard !token.contains("://") else { return nil }
        return token.firstIndex(of: ":")
    }

    /// 敏感短开关字母：`-p<值>` / `-t<值>` / `-s<值>` 这类单字母短开关紧贴值
    /// （或后面跟一个 token）时按凭据处理。只覆盖凭证习惯用法，不做任意字母猜测。
    /// 匹配大小写不敏感：`-P<值>` / `-T<值>` / `-S<值>` 同样命中。
    static let sensitiveShortSwitchLetters: Set<Character> = ["p", "t", "s"]

    /// 敏感短开关名（不含前导 `-`）：`p`/`t`/`s` 是单字母习惯用法，`pw` 是常见的
    /// 多字母简写。匹配大小写不敏感，并且取**最长**命中（`-pw` 必须识别为 `pw`，
    /// 不能切成 `p` + 值 `w`，否则 `-pw <值>` 会把值留在摘要里）。
    static let sensitiveShortSwitchNames = ["p", "t", "s", "pw"]

    /// 单横线 token 的敏感短开关切分结果。
    struct SensitiveShortSwitchSplit: Equatable {
        /// 命中的开关名，保留原大小写。
        var switchName: String
        /// 开关名之后的剩余文本；可能是空串、以 `=` 开头，或紧贴的值。
        var remainder: String
        /// 剩余文本是否只由敏感短开关字母组成（`-pt`、`-tsp` 这类开关组：每个
        /// 字母都是裸开关，取值同样在下一个 token）。
        var remainderIsSwitchGroup: Bool
    }

    /// 单横线 token 的开关体（已去掉前导 `-`）是否以已知敏感短开关名开头。
    /// 取最长命中，因此 `-pw` 是 `pw` 而不是 `p` + 值 `w`。
    static func splitSensitiveShortSwitch(_ body: String) -> SensitiveShortSwitchSplit? {
        guard !body.isEmpty else { return nil }
        let lowered = body.lowercased()
        guard let match = sensitiveShortSwitchNames
            .filter({ lowered.hasPrefix($0) })
            .max(by: { $0.count < $1.count }) else { return nil }
        let remainder = String(body.dropFirst(match.count))
        let remainderIsSwitchGroup = !remainder.isEmpty && remainder.allSatisfy { character in
            guard let lowered = character.lowercased().first else { return false }
            return sensitiveShortSwitchLetters.contains(lowered)
        }
        return SensitiveShortSwitchSplit(
            switchName: String(body.prefix(match.count)),
            remainder: remainder,
            remainderIsSwitchGroup: remainderIsSwitchGroup
        )
    }

    /// 已知凭据前缀：命中即把整个 token 换成占位符（不保留任何可见片段）。
    /// 与仓库 secret 扫描的高信号形状对齐，但不依赖它。
    static let secretValuePrefixes = [
        "sk-", "sk_live_", "sk_test_", "rk_live_", "rk_test_",
        "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_",
        "xoxa-", "xoxb-", "xoxp-", "xoxr-", "xoxs-",
        "glpat-", "npm_", "AKIA"
    ]

    /// 长位置参数的遮罩阈值：长度达到它并且只由 base64/十六进制/不透明标识符
    /// 字符组成时，按“疑似秘密”处理（短于阈值的不遮罩，见 `docs/privacy.md` 的
    /// 已知边界）。
    static let opaqueSecretMinimumLength = 32

    /// token 是否以已知凭据前缀开头。
    static func hasKnownSecretPrefix(_ token: String) -> Bool {
        secretValuePrefixes.contains { token.hasPrefix($0) }
    }

    /// 位置参数形态的疑似秘密：长 base64/十六进制/不透明串。
    ///
    /// 路径与 URL 不算（`/` 开头、`~` 开头或含 `://`）：它们交给 `LogRedactor`
    /// 的 Home 路径与查询串规则，也避免把普通路径整体换成占位符。普通单词、
    /// 版本号与短标识符都不到阈值，因此不会被误遮罩。
    static func isOpaqueSecretToken(_ token: String) -> Bool {
        guard token.count >= opaqueSecretMinimumLength else { return false }
        guard !token.hasPrefix("/"), !token.hasPrefix("~"), !token.contains("://") else {
            return false
        }
        return token.allSatisfy { character in
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber
                || character == "+" || character == "/" || character == "="
                || character == "-" || character == "_"
        }
    }

    /// Token 级预处理：把 `--token=值`、`token:值` 形态的值换成占位符，
    /// 把 `--password 值` 的下一个 token 换成占位符，把短开关（`-p值`、`-p=值`、
    /// `-p 值`；大小写不敏感，支持 `-pw` 这类多字母名字）的值换成占位符，并把
    /// 已知凭据前缀与长不透明串（疑似 base64/十六进制）整段换成占位符。
    ///
    /// 取值形态的取舍（`docs/privacy.md` 同步说明）：裸开关（`--password`、`-p`）
    /// 后面的 token 不以 `-` 开头时只遮那一个 token（值）；以 `-` 开头时无法可靠
    /// 区分“值”与“下一个开关”，因此连尾巴一起隐藏。代价是 `-p 8080` 这类非秘密
    /// 数值也会被遮成 `-p <占位符>`——宁可少展示，不少脱敏。
    ///
    /// 这一步不能省：`LogRedactor` 的键值规则在同一行里匹配时，未加引号的值会
    /// 贪婪吐掉后面的所有内容（`[^\n,;&]+` 允许空格）。一旦后面的内容里已经出现
    /// 占位符（例如同一行的 URL 查询串先被替换），幂等保护会让整条规则跳过，
    /// 凭据就会原样留在摘要里。按 token 边界先处理，就不依赖匹配顺序。
    ///
    /// 已知边界（如实说明，不夸大）：这是模式化遮罩，不是“凡秘密必被遮”。不符合
    /// 任何已知形状的自由文本（例如短于 `opaqueSecretMinimumLength`、又没有已知
    /// 前缀的位置参数，或与已知键名无关的普通句子）会原样保留；因此不要把秘密
    /// 直接放进命令行。`docs/privacy.md` 与对应测试都把这个保留行为写成断言。
    static func maskSensitiveTokens(_ tokens: [String], marker: String = LogRedactor.marker) -> [String] {
        var masked: [String] = []
        masked.reserveCapacity(tokens.count)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            // 1. `键=值` / `键:值`：保留键，只换值。URL（含 `://`）交给
            //    `LogRedactor` 的查询串规则整体处理。
            if !token.contains("://"),
               let separator = keyValueSeparatorIndex(in: token),
               containsSensitiveKeyFragment(String(token[token.startIndex..<separator])) {
                masked.append(String(token[token.startIndex...separator]) + marker)
                index += 1
                continue
            }
            if token.hasPrefix("-") {
                let name = strippingLeadingDashes(token)
                // 2. 敏感键名（长开关与单横线长开关，大小写不敏感）。不含 `=` 的
                //    形态里，`--token` / `--password` 这类裸开关的取值在下一个
                //    token；`--api-key<值>` 这种键名夹值整段替换。
                if !token.contains("=") {
                    if endsWithSensitiveKeyFragment(name) {
                        index = appendSensitiveSwitchValue(
                            switchText: token,
                            tokens: tokens,
                            index: index,
                            masked: &masked,
                            marker: marker
                        )
                        continue
                    }
                    if containsSensitiveKeyFragment(name) {
                        masked.append(marker)
                        index += 1
                        continue
                    }
                }
                // 3. 短开关（大小写不敏感，支持 `-p` / `-t` / `-s` / `-pw`）：
                //    `-p<值>`、`-p=<值>`、`-p <值>` 三种形态都要遮值。单横线
                //    长开关（`-password`）已在第 2 步处理，不会走到这里。
                if !token.hasPrefix("--"), let split = splitSensitiveShortSwitch(name) {
                    if split.remainder.isEmpty || split.remainderIsSwitchGroup {
                        // 裸短开关（或纯短开关字母组成的开关组）：取值在下一个 token。
                        index = appendSensitiveSwitchValue(
                            switchText: token,
                            tokens: tokens,
                            index: index,
                            masked: &masked,
                            marker: marker
                        )
                        continue
                    }
                    if split.remainder.hasPrefix("=") {
                        masked.append("-" + split.switchName + "=" + marker)
                    } else {
                        masked.append("-" + split.switchName + marker)
                    }
                    index += 1
                    continue
                }
            }
            // 4. 位置参数形式的已知凭据前缀（`sk-` / `ghp_` / `xoxb-` …）。
            if hasKnownSecretPrefix(token) {
                masked.append(marker)
                index += 1
                continue
            }
            // 5. 位置参数形式的长不透明串（疑似 base64/十六进制秘密）。
            if isOpaqueSecretToken(token) {
                masked.append(marker)
                index += 1
                continue
            }
            masked.append(token)
            index += 1
        }
        return masked
    }

    /// 裸敏感开关（`--password` / `-p` / `-pw`）的取值处理：下一个 token 不以
    /// `-` 开头时只遮那一个 token（值）；否则无法可靠区分“值”与“下一个开关”，
    /// 连尾巴一起隐藏（宁可少展示，不少脱敏）。返回新的下标。
    private static func appendSensitiveSwitchValue(
        switchText: String,
        tokens: [String],
        index: Int,
        masked: inout [String],
        marker: String
    ) -> Int {
        masked.append(switchText)
        masked.append(marker)
        let next = index + 1
        guard next < tokens.count, !tokens[next].hasPrefix("-") else { return tokens.count }
        return next + 1
    }

    /// 命令摘要：丢掉空参数与环境片段，token 级凭据脱敏，`LogRedactor` 整体脱敏，
    /// 折叠空白，截断到 `PiProcessRecord.commandSummaryLimit`。
    static func commandSummary(arguments: [String], redactor: LogRedactor) -> String {
        let tokens = arguments.filter { !$0.isEmpty && !isEnvironmentAssignment($0) }
        guard !tokens.isEmpty else { return "（无参数）" }
        let joined = maskSensitiveTokens(tokens).joined(separator: " ")
        let redacted = redactor.redact(joined)
        let collapsed = redacted.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count > PiProcessRecord.commandSummaryLimit else { return collapsed }
        return String(collapsed.prefix(PiProcessRecord.commandSummaryLimit)) + "…"
    }
}
