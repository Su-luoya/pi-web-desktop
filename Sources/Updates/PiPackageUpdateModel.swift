import Foundation

// MARK: - Pi 扩展包更新（GitHub #22）
//
// 本文件是 Pi 扩展包（`pi list` 报告的那些包）更新路径的唯一实现。边界：
//
// - 策略只有三种（见 `PiPackageUpdatePolicy`）：关闭 / 检查并通知 / 询问后更新。
//   **不做无人值守扩展包更新**：`PiPackageUpdatePlan.isAutomaticallyExecutable`
//   恒为 false，规划器没有任何“直接执行”分支；
// - 只调用 Pi 官方包管理命令。真实子命令已在本机上游包
//   （`@earendil-works/pi-coding-agent` 0.85.1，`docs/packages.md` 与
//   `dist/package-manager-cli.js` 的 `parsePackageCommand`）核实：
//   `pi update <source>`（更新单个包，`--extension <source>` 是等价写法），
//   其中 npm 包的 source 规格是 `npm:<包名>`。因此 argv 恒为
//   `["update", "npm:<包名>"]`（参数数组，不是 shell 字符串），
//   绝不自行拼接 `npm install` / `npm update` / `pnpm add` / `brew upgrade`；
// - 执行入口只对“来源为已验证的 npm 全局安装”的包开放（与 #20/#21 同一原则）。
//   pnpm 全局、Homebrew、nvm/mise、git checkout、本地路径与未知来源一律只给
//   官方命令文本（`pi update --extensions`，只更新扩展包、不更新 pi 自身），
//   不提供执行按钮；
// - 执行入口还要求目标版本来自**本次运行**的网络结果（GitHub #59 / 安全审查
//   A-1）：缓存回退只用于提示，不提供一键执行；“检查并通知”仍只提示；
// - 进程保护：**执行前**必须确认没有任何运行中的 Pi 进程（`noProcesses`）；
//   有运行中的进程或状态不确定时拒绝执行并给出可读原因。本文件没有任何
//   `kill` / `killpg` / 终止调用：超时只放弃等待，不向任何进程发送信号；
// - 结果语义：执行一次后重新检测该包版本；命令非零退出、超时、放弃等待、
//   版本未变化（或无法解析）都记为失败并保留可读提示；不无上限重试、不掩盖
//   失败、不声称回滚（完整回滚框架属于 #23）；
// - 任何拒绝（策略不允许、进程保护、来源不可信、包名不在检测列表内、用户取消）
//   都写入拒绝记录、日志与诊断文本。

// MARK: - 策略

/// Pi 扩展包更新的三种策略（GitHub #22）。
///
/// 与 `UpdateCheckPolicy` 的扩展包允许集合一一对应；`daily` / `weekly` 不属于
/// 扩展包，映射失败时按“策略不支持”处理（不检查、不通知、不执行）。

/// Pi package update policy, candidate/check models, plans and decisions.

enum PiPackageUpdatePolicy: String, CaseIterable, Equatable {
    /// 关闭：不检查、不通知、不执行。
    case off
    /// 检查并通知：按 7 天节奏复查，发现可用更新时只提示版本，不提供一键执行。
    case checkAndNotify = "check-and-notify"
    /// 询问后更新：发现可用更新时给出计划并询问用户；确认后才执行一次。
    case askBeforeUpdate = "ask-before-update"

    init?(_ policy: UpdateCheckPolicy) {
        switch policy {
        case .off: self = .off
        case .checkAndNotify: self = .checkAndNotify
        case .askBeforeUpdate: self = .askBeforeUpdate
        case .daily, .weekly: return nil
        }
    }

    var title: String {
        switch self {
        case .off: return "关闭"
        case .checkAndNotify: return "检查并通知"
        case .askBeforeUpdate: return "询问后更新"
        }
    }

    var underlyingPolicy: UpdateCheckPolicy {
        switch self {
        case .off: return .off
        case .checkAndNotify: return .checkAndNotify
        case .askBeforeUpdate: return .askBeforeUpdate
        }
    }

    /// 是否发起检查（关闭时既不调度也不请求）。
    var checksForUpdates: Bool { self != .off }

    /// 是否提示可用更新（关闭时不提示）。
    var notifiesAboutUpdates: Bool { self != .off }

    /// 是否允许“确认后执行”的入口。只有询问策略提供；且仍受来源与进程保护约束。
    var offersExecutionEntry: Bool { self == .askBeforeUpdate }
}

// MARK: - 规划输入（#16 检测结果 + #17 检查结果）

/// 一个待评估的扩展包（来自 #16 的 `pi list` 检测结果）。
struct PiPackageCandidate: Equatable {
    var packageName: String
    var installedVersion: String?
    var source: InstallSource
    var confidence: DetectionConfidence

    /// 只接受 `piPackage` 条目且必须有包名：没有包名的条目（`pi list` 解析失败时
    /// #16 会给出这样的条目）不进入包更新流程。
    init?(installation: ComponentInstallation) {
        guard installation.kind == .piPackage,
              let name = installation.packageName,
              ComponentInstallationDetector.isPackageName(name) else { return nil }
        self.packageName = name
        self.installedVersion = installation.version
        self.source = installation.source
        self.confidence = installation.confidence
    }

    init(packageName: String, installedVersion: String?, source: InstallSource, confidence: DetectionConfidence) {
        self.packageName = packageName
        self.installedVersion = installedVersion
        self.source = source
        self.confidence = confidence
    }

    /// #16 的组件识别结果 → 扩展包候选列表（按输入顺序，去重保留第一条）。
    static func list(from components: [ComponentInstallation]) -> [PiPackageCandidate] {
        var result: [PiPackageCandidate] = []
        var seen: Set<String> = []
        for component in components {
            guard let candidate = PiPackageCandidate(installation: component) else { continue }
            guard seen.insert(candidate.packageName).inserted else { continue }
            result.append(candidate)
        }
        return result
    }
}

/// 一个扩展包的检查结论（来自 #17 的更新检查结果）。
struct PiPackageCheckOutcome: Equatable {
    var packageName: String
    var latestVersion: String?
    var status: UpdateCheckStatus
    var confidence: DetectionConfidence
    var failureText: String?
    /// 检查结果的来源；只有 `.network`（本次运行刚从白名单主机取得）才提供
    /// 可点的执行入口。默认值是最安全的一档，漏传时不会退化成“可执行”。
    var origin: UpdateCheckOrigin = .unavailable
    /// 来源为缓存回退时的缓存写入时间（仅用于展示与拒绝原因）。
    var cacheWrittenAt: Date? = nil

    init(
        packageName: String,
        latestVersion: String?,
        status: UpdateCheckStatus,
        confidence: DetectionConfidence,
        failureText: String? = nil,
        origin: UpdateCheckOrigin = .unavailable,
        cacheWrittenAt: Date? = nil
    ) {
        self.packageName = packageName
        self.latestVersion = latestVersion
        self.status = status
        self.confidence = confidence
        self.failureText = failureText
        self.origin = origin
        self.cacheWrittenAt = cacheWrittenAt
    }

    /// 只接受扩展包分类且带包名的检查结果；其它分类（桌面应用 / Pi CLI / Pi Web）
    /// 不进入包更新流程。来源信息一并带过来，供执行入口的硬前置判定。
    init?(result: UpdateCheckResult) {
        guard result.target.category == .piPackages,
              let name = result.target.packageName,
              !name.isEmpty else { return nil }
        self.packageName = name
        self.latestVersion = result.latestVersion
        self.status = result.status
        self.confidence = result.confidence
        self.failureText = result.failure?.text
        self.origin = result.origin
        self.cacheWrittenAt = result.cacheWrittenAt
    }

    static func list(from results: [UpdateCheckResult]) -> [PiPackageCheckOutcome] {
        results.compactMap(PiPackageCheckOutcome.init(result:))
    }
}

/// 规划所需的全部输入（纯值类型，测试可直接构造）。
struct PiPackageUpdatePlanningInput: Equatable {
    /// 当前扩展包策略（`UpdateCheckPreferences.policy(for: .piPackages)` 的值）。
    var policy: UpdateCheckPolicy = .off
    /// #16 的检测结果。
    var packages: [PiPackageCandidate]
    /// #17 的检查结果。
    var checks: [PiPackageCheckOutcome]
    /// Pi 进程检查结果。默认值是“枚举失败”，即不安全：漏传时不会退化成允许执行。
    var processes: PiProcessInspection = .unknown(.enumerationFailed)
    /// 已通过可执行位确认的 `pi` 可执行文件路径（#16 检测结果里 `piCLI` 的路径）。
    var piExecutablePath: String?
    /// 各包未清除的「已放弃」记录（GitHub #62）。存在记录的包不会被自动执行；
    /// 用户必须在确认框里先看到这条记录，确认后才执行一次。
    /// 默认空数组，旧调用点保持不变。
    var abandonedAttempts: [UpdateAbandonedAttempt] = []
}

// MARK: - 拒绝原因

/// 不执行扩展包更新的原因（也用于“为什么不给执行入口”）。
///
/// 全部是固定文案 + 包名/来源/可信度：不含路径、环境变量值、子进程输出或凭据
/// （可执行文件路径只在展示时单独脱敏拼接）。
enum PiPackageUpdateRefusal: Equatable {
    /// 策略为“关闭”：不检查、不通知、不执行。
    case policyOff
    /// 策略为“检查并通知”：只提示，不提供一键执行。
    case policyNotifiesOnly
    /// 策略不属于扩展包允许集合（例如每日 / 每周）。
    case policyUnsupported
    /// 没有解析出可用于更新的 `pi` 可执行文件。
    case piExecutableUnresolved
    /// 包名不是合法的 npm 包名。
    case invalidPackageName
    /// 包名不在本次检测结果里（不允许凭用户输入构造命令）。
    case packageNotDetected(name: String)
    /// 来源与可信度不可接受：只有“已验证的 npm 全局安装”提供执行入口。
    case sourceNotExecutable(source: InstallSource, confidence: DetectionConfidence)
    /// 本机版本未知，无法判断更新是否有意义。
    case installedVersionUnknown
    /// 没有可用的目标版本（检查结果不是“可更新”或缺少版本号）。
    case noTargetVersion
    /// 目标版本未经上游响应验证。
    case targetNotVerified
    /// 判定所用的检查结果不是本次运行从白名单主机取得的网络结果（缓存回退或
    /// 没有结果）。缓存文件不是可信输入，因此不提供执行入口（GitHub #59）。
    case targetNotFromNetwork(origin: UpdateCheckOrigin, cacheWrittenAt: Date?)
    /// 目标版本不是可比较的语义化版本。
    case invalidTargetVersion
    /// 目标版本不高于本机版本。
    case notNewerTargetVersion
    /// 构造出的命令未通过参数安全校验。
    case unsafeCommand
    /// 进程保护：有运行中的 Pi 进程，拒绝执行。
    case piRunning([PiProcessRecord])
    /// 进程保护：无法确定进程状态，按不安全处理，拒绝执行。
    case processStateUnknown(PiProcessInspectionUnknown)
    /// 用户没有确认（取消或关闭对话框），不执行、不改状态。
    case userCancelled
    /// 同一组件存在未清除的「已放弃」记录（GitHub #62）：不允许自动执行；只有
    /// 用户在确认框里看到这条记录并确认后才执行一次。
    case abandonedAttemptPending(UpdateAbandonedAttempt)
    /// 执行器上还有一次命令没结束（B-1）：本次没有执行，也没有任何状态改动。
    case executorBusy
    /// 执行器上还有一次命令已放弃等待、但退出尚未确认（B-1/W3）：本次没有执行，
    /// 也没有任何状态改动；这种窗口只能靠重启应用可靠恢复。
    case executorBusyAwaitingAbandonedChildExit

    /// 单行原因文案（固定文本 + 已脱敏的进程记录摘要）。
    var text: String {
        switch self {
        case .policyOff:
            return "扩展包更新策略为“关闭”：不检查、不通知、不执行"
        case .policyNotifiesOnly:
            return "扩展包更新策略为“检查并通知”：只提示有更新，不提供一键执行"
        case .policyUnsupported:
            return "扩展包更新策略不属于允许集合（关闭 / 检查并通知 / 询问后更新）"
        case .piExecutableUnresolved:
            return "没有解析出可用于更新的 Pi CLI 可执行文件"
        case .invalidPackageName:
            return "包名不符合 npm 包名规范"
        case .packageNotDetected(let name):
            return "包名 \(name) 不在本次检测结果里：不接受检测结果之外的包名，也不凭用户输入构造命令"
        case .sourceNotExecutable(let source, let confidence):
            return "来源是 \(source.displayName)（可信度 \(confidence.displayName)）：只有来源为已验证的 npm 全局安装才提供执行入口，"
                + "其它来源只展示官方命令文本"
        case .installedVersionUnknown:
            return "无法确定该包的本机版本"
        case .noTargetVersion:
            return "没有可用的目标版本（检查结果不是“可更新”或缺少版本号）"
        case .targetNotVerified:
            return "目标版本未经上游响应验证"
        case .targetNotFromNetwork(let origin, let cacheWrittenAt):
            return origin.autoInstallRefusalText(cacheWrittenAt: cacheWrittenAt)
        case .invalidTargetVersion:
            return "目标版本无法解析为语义化版本"
        case .notNewerTargetVersion:
            return "目标版本不高于本机版本"
        case .unsafeCommand:
            return "构造出的更新命令未通过参数安全校验"
        case .piRunning(let records):
            let summary = records.map(\.shortText).joined(separator: "；")
            return "检测到 \(records.count) 个运行中的 Pi 进程（\(summary)）：更新会让正在进行的会话读到被替换的文件，"
                + "因此拒绝执行。应用不会结束、暂停或接管任何 Pi 进程，也不会向它们发送任何信号。"
        case .processStateUnknown(let reason):
            return "无法确定 Pi 进程状态（\(reason.text)）：按不安全处理，拒绝执行。应用不会结束任何进程，也不会发送任何信号。"
        case .userCancelled:
            return "用户取消了更新（未确认）：不执行、不改状态"
        case .abandonedAttemptPending(let attempt):
            return UpdateAbandonedAttemptPresenter.automaticRefusalText(attempt)
        case .executorBusy:
            return "执行器上还有一次更新命令没有结束：本次不执行、不改状态，也不向任何进程发送信号"
        case .executorBusyAwaitingAbandonedChildExit:
            return "上一次更新命令已放弃等待，但还不能确认它已经退出，因此不会启动第二次更新。"
                + "如果长时间没有变化，重启应用即可恢复（重启后这个未确认窗口不会保留）"
        }
    }
}

/// 一条拒绝记录（包名 + 原因），写入日志与诊断。
struct PiPackageUpdateRefusalRecord: Equatable {
    /// nil 表示整类策略级拒绝（例如策略关闭）。
    var packageName: String?
    var reason: PiPackageUpdateRefusal

    var logLine: String {
        if let packageName {
            return "Pi 扩展包更新：不执行（包 \(packageName)）：\(reason.text)"
        }
        return "Pi 扩展包更新：不执行：\(reason.text)"
    }
}

// MARK: - 参数与环境策略

/// 更新命令的参数与安全校验。
///
/// 只接受“字面量参数”形态：ASCII 字母、数字与 `@ / . _ - + ~ = :`。因此参数
/// 里不可能出现空白、引号、`;`、`|`、`&`、`$`、反引号、`(`、`)`、`>`、`<`、
/// `*`、`?`、`!`、换行等 shell 元字符。`sudo` 与 shell 解释器名也被显式拒绝，
/// 即使未来有人把参数来源换成别的输入。
///
/// 注意：参数里的 `npm:` 是 Pi 自己的**包来源规格前缀**（上游
/// `parsePackageCommand` / `parseSource` 接受 `npm:<包名>`），不是 `npm` 命令：
/// 可执行文件始终是 `pi`，argv 永远不含 `install` / `update -g` 这类 npm 参数。
enum PiPackageUpdateArgumentPolicy {
    /// 允许的参数字符集（包名与来源规格前缀都落在其中）。
    static let allowedCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@/._-+~=:"
    )

    /// 显式禁止的整词参数（提权命令与 shell 包装）。
    static let forbiddenTokens: Set<String> = ["sudo", "sh", "bash", "zsh", "eval", "exec", "env", "-c"]

    static func isSafe(argument: String) -> Bool {
        guard !argument.isEmpty else { return false }
        guard !forbiddenTokens.contains(argument) else { return false }
        return argument.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    static func isSafe(_ arguments: [String]) -> Bool {
        !arguments.isEmpty && arguments.allSatisfy(isSafe(argument:))
    }

    /// 展示用的 argv 文本。参数已通过安全校验，因此用空格连接不会有歧义。
    static func displayText(for arguments: [String]) -> String {
        arguments.map { "\"\($0)\"" }.joined(separator: ", ")
    }
}

/// 子进程环境变量白名单（与 #20/#21 同一组允许键）。
///
/// Pi CLI 是 `#!/usr/bin/env node` 脚本，需要 `HOME`（`~/.pi` 配置）与 `PATH`
/// （解析 `node`），所以只保留这些键；`NODE_OPTIONS`、`NPM_TOKEN` 等
/// `npm_config_*`、代理与任何凭据都不进入子进程。日志与诊断只记录键名。
enum PiPackageUpdateEnvironment {
    static func environment(base: [String: String], piExecutablePath: String) -> [String: String] {
        var result = PiWebUpdateEnvironment.sanitized(base)
        // PATH 合并复用 `ToolPathBuilder`（GitHub #89）：pi 自己所在目录排在最前，
        // 其余目录由构建器给出（登录 shell PATH、已知目录、node 目录、npm prefix/bin）。
        let builder = ToolPathBuilder(
            appEnvironment: result,
            homeDirectory: result["HOME"] ?? ""
        )
        result["PATH"] = builder.path(prioritizing: [
            (piExecutablePath as NSString).deletingLastPathComponent
        ])
        return result
    }

    /// 只用于展示/日志：按键排序的键名，不含值。
    static func keyDescription(_ environment: [String: String]) -> String {
        PiWebUpdateEnvironment.keyDescription(environment)
    }
}

// MARK: - 更新计划

/// 一个扩展包的更新计划（GitHub #22 第 1 项）。
///
/// `arguments` 精确等于将要传给子进程的 argv（不含可执行文件本身），且被构造
/// 逻辑固定为 `["update", "npm:<包名>"]`：没有 shell 字符串、没有 `sudo`、
/// 没有包管理器命令。`isAutomaticallyExecutable` 对扩展包**恒为 false**。
struct PiPackageUpdatePlan: Equatable {
    /// Pi 官方更新子命令名（上游 `pi update <source>`）。
    static let commandName = "update"
    /// npm 包在 Pi 里的来源规格前缀（上游 `parseSource` 的 `npm:` 分支）。
    static let packageSourceSpecPrefix = "npm:"
    /// 扩展包对“无人值守执行”的常量答案：永远不允许。
    static let allowsUnattendedExecution = false
    /// 包名字符数上限（与 #16 的 npm 包名校验一致）。
    static let maximumPackageNameLength = 214
    /// 唯一允许的可执行文件基名（Pi CLI 官方可执行文件）。
    static let piExecutableName = "pi"

    /// 可执行文件路径允许的字符集（绝对路径，不含空白与 shell 元字符）。
    static let executablePathAllowedCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@~:"
    )

    var executablePath: String
    var arguments: [String]
    var packageName: String
    var installedVersion: String
    /// 目标版本；调用方可以给 nil（此时由官方更新命令决定更新到哪个版本，
    /// 执行后只比较“版本是否发生变化”）。
    var targetVersion: String?
    var source: InstallSource
    var confidence: DetectionConfidence

    /// 对扩展包永远为 false：不存在无人值守更新路径。
    var isAutomaticallyExecutable: Bool { Self.allowsUnattendedExecution }

    /// 执行前必须由用户显式确认。
    var requiresUserConfirmation: Bool { true }

    /// 构造计划；任何一项不满足都返回 nil（调用方按 `.unsafeCommand` 等处理）。
    ///
    /// 前置条件包含来源约束：只有 `npmGlobal` + `verified` 才有计划（= 执行入口）。
    /// 其它来源连计划都没有，自然没有执行按钮。
    static func make(
        executablePath: String?,
        packageName: String?,
        installedVersion: String?,
        targetVersion: String?,
        source: InstallSource,
        confidence: DetectionConfidence
    ) -> PiPackageUpdatePlan? {
        guard let executablePath, isSafeExecutablePath(executablePath) else { return nil }
        // 只允许 Pi CLI 自身的可执行文件：可执行文件名字必须是 pi（与 #16 的识别
        // 名称、#21 的 `pi update --self` 一致），因此不可能构造出 `sudo`/`env` 之类的 argv[0]。
        guard (executablePath as NSString).lastPathComponent == piExecutableName else { return nil }
        guard let packageName,
              packageName.count <= maximumPackageNameLength,
              ComponentInstallationDetector.isPackageName(packageName) else { return nil }
        guard let installedVersion, let installed = SemanticVersion(installedVersion),
              installed.description == installedVersion else { return nil }
        if let targetVersion {
            guard let target = SemanticVersion(targetVersion), target.description == targetVersion else { return nil }
        }
        guard source == .npmGlobal, confidence == .verified else { return nil }
        let arguments = [commandName, packageSourceSpecPrefix + packageName]
        guard isExpectedArgumentArray(arguments, packageName: packageName) else { return nil }
        guard PiPackageUpdateArgumentPolicy.isSafe(arguments) else { return nil }
        return PiPackageUpdatePlan(
            executablePath: executablePath,
            arguments: arguments,
            packageName: packageName,
            installedVersion: installedVersion,
            targetVersion: targetVersion,
            source: source,
            confidence: confidence
        )
    }

    /// argv 形状校验：恰好两个元素，第一个是官方子命令，第二个是 `npm:<同一个包名>`。
    static func isExpectedArgumentArray(_ arguments: [String], packageName: String) -> Bool {
        guard arguments.count == 2 else { return false }
        guard arguments[0] == commandName else { return false }
        guard arguments[1] == packageSourceSpecPrefix + packageName else { return false }
        return true
    }

    /// 绝对路径、无空白、无 shell 元字符、非空段。
    static func isSafeExecutablePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count > 1 else { return false }
        guard path.unicodeScalars.allSatisfy({ executablePathAllowedCharacters.contains($0) }) else { return false }
        guard !path.contains("//"), !path.hasSuffix("/") else { return false }
        let base = (path as NSString).lastPathComponent
        return !base.isEmpty && base != "." && base != ".."
    }

    /// 展示用的命令文本；可执行文件路径由调用方用 `LogRedactor` 脱敏。
    var commandText: String {
        ([executablePath] + arguments).joined(separator: " ")
    }

    /// 更新前展示的完整信息（日志、诊断、确认框共用）。
    func displayLines(redactingWith redactor: LogRedactor) -> [String] {
        [
            "包名：\(packageName)",
            "当前版本：\(installedVersion)",
            "目标版本：\(targetVersion ?? "未知（由 Pi 官方更新命令决定）")",
            "来源：\(source.displayName)；可信度：\(confidence.displayName)",
            "可执行文件：\(redactor.redact(executablePath))",
            "参数数组：\(PiPackageUpdateArgumentPolicy.displayText(for: arguments))",
            "命令：\(redactor.redact(commandText))",
            "自动执行：不允许（扩展包更新必须由用户确认）",
            "不使用 shell 字符串、不调用 sudo、不向任何 Pi 进程发送信号。"
        ]
    }

    /// 执行前展示的风险说明（固定文本 + 包名与版本）。
    func riskText() -> String {
        [
            "风险说明：更新会替换扩展包 \(packageName) 在本机的安装文件。",
            "· 正在运行或稍后恢复的 Pi 会话可能读到更新后的文件，行为可能与会话开始时不同；",
            "· 扩展包（含第三方 npm 包）的代码在 Pi 会话里拥有完整系统访问权限，更新前请核对上游来源与包元数据；",
            "· 应用不会结束、暂停或接管任何 Pi 进程与会话，也不会向它们发送任何信号；",
            "· 应用只执行 Pi 官方更新命令，不保证成功，也不做回滚；失败只记录原因并保留可读提示。"
        ].joined(separator: "\n")
    }
}

/// 一条“只提示、不执行”的扩展包更新提示（检查并通知策略，或来源不能执行）。
struct PiPackageUpdateNotice: Equatable {
    var packageName: String
    var installedVersion: String?
    var targetVersion: String?
    var source: InstallSource
    var confidence: DetectionConfidence
    /// 可以复制给用户手动执行的官方命令文本；nil 表示没有可给出的命令。
    var manualCommandText: String?
    /// 只有官方命令文本、没有执行入口。
    var executionAvailable: Bool { false }

    /// 展示文本（不含本机绝对路径；命令文本里的可执行文件路径由调用方脱敏）；
    /// 调用方为“执行入口”判断提供 `reasonText`。
    func displayLines(reasonText: String?) -> [String] {
        var lines = [
            "包名：\(packageName)",
            "当前版本：\(installedVersion ?? "未知")",
            "可用版本：\(targetVersion ?? "未知")",
            "来源：\(source.displayName)；可信度：\(confidence.displayName)"
        ]
        if let reasonText {
            lines.append("不提供一键执行的原因是：\(reasonText)")
        }
        if let manualCommandText {
            lines.append("可复制的官方命令（只展示文本，应用不会执行）：\(manualCommandText)")
        } else {
            lines.append("没有可给出的官方命令：请按该包自己的官方文档更新。")
        }
        return lines
    }
}
