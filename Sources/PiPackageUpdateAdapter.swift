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

    init(
        packageName: String,
        latestVersion: String?,
        status: UpdateCheckStatus,
        confidence: DetectionConfidence,
        failureText: String? = nil
    ) {
        self.packageName = packageName
        self.latestVersion = latestVersion
        self.status = status
        self.confidence = confidence
        self.failureText = failureText
    }

    /// 只接受扩展包分类且带包名的检查结果；其它分类（桌面应用 / Pi CLI / Pi Web）
    /// 不进入包更新流程。
    init?(result: UpdateCheckResult) {
        guard result.target.category == .piPackages,
              let name = result.target.packageName,
              !name.isEmpty else { return nil }
        self.packageName = name
        self.latestVersion = result.latestVersion
        self.status = result.status
        self.confidence = result.confidence
        self.failureText = result.failure?.text
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
        var directories: [String] = []
        let directory = (piExecutablePath as NSString).deletingLastPathComponent
        if !directory.isEmpty, directory != "/", !directories.contains(directory) {
            directories.append(directory)
        }
        for entry in (result["PATH"] ?? "").split(separator: ":") {
            let text = String(entry)
            guard !text.isEmpty, !directories.contains(text) else { continue }
            directories.append(text)
        }
        for entry in PiWebUpdateEnvironment.fallbackPathDirectories where !directories.contains(entry) {
            directories.append(entry)
        }
        result["PATH"] = directories.joined(separator: ":")
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

// MARK: - 决策

/// 单个扩展包的决策。
enum PiPackageUpdateDecision: Equatable {
    /// 策略关闭：不检查、不通知、不执行。
    case disabled(packageName: String)
    /// 已是最新或没有可用更新：不提示、不执行。
    case upToDate(packageName: String, installedVersion: String?, latestVersion: String?)
    /// 检查并通知：只提示有更新，不提供一键执行。
    case notifyOnly(PiPackageUpdateNotice)
    /// 询问后更新：计划就绪，必须由用户确认；确认前不执行。
    case awaitingConfirmation(PiPackageUpdatePlan)
    /// 计划就绪但被拒绝执行（进程保护）：给出可读原因，不执行。
    case executeBlocked(plan: PiPackageUpdatePlan, reason: PiPackageUpdateRefusal)
    /// 没有执行入口，只展示官方命令文本（来源/可信度不可接受等）。
    case manualOnly(PiPackageUpdateNotice, reason: PiPackageUpdateRefusal)
    /// 没有可用信息（包名非法、目标版本缺失等）。
    case unavailable(packageName: String, reason: PiPackageUpdateRefusal)

    var packageName: String {
        switch self {
        case .disabled(let name), .upToDate(let name, _, _), .unavailable(let name, _):
            return name
        case .notifyOnly(let notice), .manualOnly(let notice, _):
            return notice.packageName
        case .awaitingConfirmation(let plan), .executeBlocked(let plan, _):
            return plan.packageName
        }
    }

    /// 可以执行的计划（已经通过全部前置条件与进程保护）。
    var executablePlan: PiPackageUpdatePlan? {
        if case .awaitingConfirmation(let plan) = self { return plan }
        return nil
    }

    /// 任何计划（包含被进程保护拒绝的），用于展示与诊断。
    var anyPlan: PiPackageUpdatePlan? {
        switch self {
        case .awaitingConfirmation(let plan): return plan
        case .executeBlocked(let plan, _): return plan
        default: return nil
        }
    }

    var refusalReason: PiPackageUpdateRefusal? {
        switch self {
        case .executeBlocked(_, let reason), .manualOnly(_, let reason), .unavailable(_, let reason):
            return reason
        case .awaitingConfirmation:
            return nil
        case .notifyOnly:
            return .policyNotifiesOnly
        case .disabled:
            return .policyOff
        case .upToDate:
            return nil
        }
    }

    /// 决策摘要（已脱敏）。用于日志与诊断页。
    func logLine(redactingWith redactor: LogRedactor) -> String {
        switch self {
        case .disabled(let name):
            return "Pi 扩展包更新（\(name)）：策略为“关闭”，不检查、不通知、不执行"
        case .upToDate(let name, let installed, let latest):
            return "Pi 扩展包更新（\(name)）：已是最新（当前 \(installed ?? "未知")，上游 \(latest ?? "未知")）"
        case .notifyOnly(let notice):
            var line = "Pi 扩展包更新（\(notice.packageName)）：只通知不执行（当前 \(notice.installedVersion ?? "未知")，"
                + "可用 \(notice.targetVersion ?? "未知")）"
            if let command = notice.manualCommandText {
                line += "；手动命令：\(redactor.redact(command))"
            }
            return line
        case .awaitingConfirmation(let plan):
            return "Pi 扩展包更新（\(plan.packageName)）：等待用户确认（允许自动执行：否）\n"
                + plan.displayLines(redactingWith: redactor).joined(separator: "\n")
        case .executeBlocked(let plan, let reason):
            return "Pi 扩展包更新（\(plan.packageName)）：拒绝执行（\(reason.text)）；"
                + "将执行的命令：\(redactor.redact(plan.commandText))"
        case .manualOnly(let notice, let reason):
            var line = "Pi 扩展包更新（\(notice.packageName)）：不提供执行入口（\(reason.text)）"
            if let command = notice.manualCommandText {
                line += "；手动命令：\(redactor.redact(command))"
            }
            return line
        case .unavailable(let name, let reason):
            return "Pi 扩展包更新（\(name)）：不可用（\(reason.text)）"
        }
    }
}

/// 一次规划的结果集合。
struct PiPackageUpdatePlanSet: Equatable {
    /// 生效的策略；nil 表示策略不属于扩展包允许集合。
    var policy: PiPackageUpdatePolicy?
    /// 是否真的发起了检查。策略关闭时恒为 false（0 次检查）。
    var didCheck: Bool
    /// 待检查的包数量（0 表示没有可检查对象）。
    var packageCount: Int
    /// 每个检测到的包一条决策（顺序与输入一致）。
    var decisions: [PiPackageUpdateDecision]
    /// 额外拒绝记录：检查结果引用了检测列表之外的包名，或整类策略级拒绝。
    var extraRefusals: [PiPackageUpdateRefusalRecord]

    static let disabledForPolicyOff = PiPackageUpdatePlanSet(
        policy: .off,
        didCheck: false,
        packageCount: 0,
        decisions: [],
        extraRefusals: [PiPackageUpdateRefusalRecord(packageName: nil, reason: .policyOff)]
    )

    /// 已就绪、等待用户确认的计划（= 执行入口）。
    var executablePlans: [PiPackageUpdatePlan] {
        decisions.compactMap(\.executablePlan)
    }

    /// 全部计划（含被进程保护拒绝的）。
    var allPlans: [PiPackageUpdatePlan] {
        decisions.compactMap(\.anyPlan)
    }

    /// 只提示的条目。
    var notices: [PiPackageUpdateNotice] {
        decisions.compactMap { decision in
            switch decision {
            case .notifyOnly(let notice), .manualOnly(let notice, _): return notice
            default: return nil
            }
        }
    }

    var executionAvailable: Bool { !executablePlans.isEmpty }

    /// 需要记录的全部拒绝（含策略级与逐包）。
    var refusalRecords: [PiPackageUpdateRefusalRecord] {
        let perPackage: [PiPackageUpdateRefusalRecord] = decisions.compactMap { decision in
            guard let reason = decision.refusalReason else { return nil }
            return PiPackageUpdateRefusalRecord(packageName: decision.packageName, reason: reason)
        }
        return extraRefusals + perPackage
    }

    /// 日志/诊断摘要（已脱敏）。
    func logLines(redactingWith redactor: LogRedactor) -> [String] {
        var lines: [String] = []
        let policyText = policy?.title ?? "不支持（只允许 关闭 / 检查并通知 / 询问后更新）"
        lines.append("Pi 扩展包更新策略：\(policyText)；本次是否检查：\(didCheck ? "是" : "否")；包数量：\(packageCount)")
        lines.append(contentsOf: decisions.map { $0.logLine(redactingWith: redactor) })
        lines.append(contentsOf: refusalRecords.map(\.logLine))
        return lines
    }
}

// MARK: - 规划器

/// 前置条件、来源约束与命令构造的纯逻辑（GitHub #22 第 1/2/5 项）。
enum PiPackageUpdatePlanner {
    /// 唯一允许执行扩展包更新的来源：npm 全局且经过验证。
    static func isExecutableSource(_ source: InstallSource, confidence: DetectionConfidence) -> Bool {
        source == .npmGlobal && confidence == .verified
    }

    /// 非 npm 全局来源的官方命令文本：`pi update --extensions`（只更新已安装扩展包，
    /// 不更新 pi 自身）。应用只展示这段文本，不执行它，也不拼接包管理器命令。
    static func nonNPMGlobalManualCommandText(piExecutablePath: String?) -> String? {
        guard let piExecutablePath,
              PiPackageUpdatePlan.isSafeExecutablePath(piExecutablePath),
              (piExecutablePath as NSString).lastPathComponent == PiPackageUpdatePlan.piExecutableName else { return nil }
        let arguments = ["update", "--extensions"]
        guard PiPackageUpdateArgumentPolicy.isSafe(arguments) else { return nil }
        return ([piExecutablePath] + arguments).joined(separator: " ")
    }

    /// 可信来源的手动命令文本：`<pi> update npm:<包名>`，包名必须通过 npm 校验。
    static func manualCommandText(piExecutablePath: String?, packageName: String) -> String? {
        guard ComponentInstallationDetector.isPackageName(packageName) else { return nil }
        guard let piExecutablePath,
              PiPackageUpdatePlan.isSafeExecutablePath(piExecutablePath),
              (piExecutablePath as NSString).lastPathComponent == PiPackageUpdatePlan.piExecutableName else { return nil }
        let arguments = [PiPackageUpdatePlan.commandName, PiPackageUpdatePlan.packageSourceSpecPrefix + packageName]
        guard PiPackageUpdatePlan.isExpectedArgumentArray(arguments, packageName: packageName) else { return nil }
        guard PiPackageUpdateArgumentPolicy.isSafe(arguments) else { return nil }
        return ([piExecutablePath] + arguments).joined(separator: " ")
    }

    /// 显式指定包名时的执行前校验：包名必须出现在本次检测结果里。
    /// 返回 nil 表示可以继续走计划构造；否则是拒绝原因。
    static func executionRefusal(packageName: String, candidates: [PiPackageCandidate]) -> PiPackageUpdateRefusal? {
        guard ComponentInstallationDetector.isPackageName(packageName) else { return .invalidPackageName }
        guard candidates.contains(where: { $0.packageName == packageName }) else {
            return .packageNotDetected(name: packageName)
        }
        return nil
    }

    /// 单个包的决策（纯函数）。
    ///
    /// 顺序：策略 → 包名 → 检查结论 → 目标版本 → 来源 → 命令安全 → 进程保护。
    /// 进程保护只让“已经就绪的计划”变成 `executeBlocked`，不会掩盖其它拒绝原因。
    static func decide(
        _ candidate: PiPackageCandidate,
        check: PiPackageCheckOutcome?,
        policy: PiPackageUpdatePolicy,
        processes: PiProcessInspection,
        piExecutablePath: String?
    ) -> PiPackageUpdateDecision {
        let name = candidate.packageName
        switch policy {
        case .off:
            return .disabled(packageName: name)
        case .checkAndNotify, .askBeforeUpdate:
            break
        }
        guard ComponentInstallationDetector.isPackageName(name) else {
            return .unavailable(packageName: name, reason: .invalidPackageName)
        }
        guard let check, check.status == .updateAvailable,
              let targetVersion = check.latestVersion, !targetVersion.isEmpty else {
            let latest = check?.latestVersion
            if check?.status == .upToDate {
                return .upToDate(packageName: name, installedVersion: candidate.installedVersion, latestVersion: latest)
            }
            return .manualOnly(
                notice(for: candidate, check: check, piExecutablePath: piExecutablePath),
                reason: .noTargetVersion
            )
        }
        guard check.confidence == .verified else {
            return .manualOnly(
                notice(for: candidate, check: check, piExecutablePath: piExecutablePath),
                reason: .targetNotVerified
            )
        }
        guard let target = SemanticVersion(targetVersion), target.description == targetVersion else {
            return .manualOnly(
                notice(for: candidate, check: check, piExecutablePath: piExecutablePath),
                reason: .invalidTargetVersion
            )
        }
        guard let installedVersion = candidate.installedVersion,
              let installed = SemanticVersion(installedVersion) else {
            return .manualOnly(
                notice(for: candidate, check: check, piExecutablePath: piExecutablePath),
                reason: .installedVersionUnknown
            )
        }
        guard installed < target else {
            return .manualOnly(
                notice(for: candidate, check: check, piExecutablePath: piExecutablePath),
                reason: .notNewerTargetVersion
            )
        }
        guard policy == .askBeforeUpdate else {
            return .notifyOnly(notice(for: candidate, check: check, piExecutablePath: piExecutablePath))
        }
        guard isExecutableSource(candidate.source, confidence: candidate.confidence) else {
            return .manualOnly(
                notice(for: candidate, check: check, piExecutablePath: piExecutablePath),
                reason: .sourceNotExecutable(source: candidate.source, confidence: candidate.confidence)
            )
        }
        guard let piExecutablePath else {
            return .manualOnly(
                notice(for: candidate, check: check, piExecutablePath: nil),
                reason: .piExecutableUnresolved
            )
        }
        guard let plan = PiPackageUpdatePlan.make(
            executablePath: piExecutablePath,
            packageName: name,
            installedVersion: installedVersion,
            targetVersion: targetVersion,
            source: candidate.source,
            confidence: candidate.confidence
        ) else {
            return .manualOnly(
                notice(for: candidate, check: check, piExecutablePath: piExecutablePath),
                reason: .unsafeCommand
            )
        }
        // 进程保护：只有“确认没有任何 Pi 进程”才允许进入确认流程；否则拒绝执行。
        switch processes {
        case .noProcesses:
            return .awaitingConfirmation(plan)
        case .runningProcesses(let records):
            return .executeBlocked(plan: plan, reason: .piRunning(records))
        case .unknown(let reason):
            return .executeBlocked(plan: plan, reason: .processStateUnknown(reason))
        }
    }

    private static func notice(
        for candidate: PiPackageCandidate,
        check: PiPackageCheckOutcome?,
        piExecutablePath: String?
    ) -> PiPackageUpdateNotice {
        let manualCommand: String?
        if isExecutableSource(candidate.source, confidence: candidate.confidence) {
            manualCommand = manualCommandText(piExecutablePath: piExecutablePath, packageName: candidate.packageName)
        } else {
            manualCommand = nonNPMGlobalManualCommandText(piExecutablePath: piExecutablePath)
        }
        return PiPackageUpdateNotice(
            packageName: candidate.packageName,
            installedVersion: candidate.installedVersion,
            targetVersion: check?.latestVersion,
            source: candidate.source,
            confidence: candidate.confidence,
            manualCommandText: manualCommand
        )
    }

    /// 批量决策。不发起检查：检查结果由调用方（#17 的检查器）作为数据传入。
    static func decide(_ input: PiPackageUpdatePlanningInput) -> PiPackageUpdatePlanSet {
        guard let policy = PiPackageUpdatePolicy(input.policy) else {
            return PiPackageUpdatePlanSet(
                policy: nil,
                didCheck: false,
                packageCount: 0,
                decisions: [],
                extraRefusals: [PiPackageUpdateRefusalRecord(packageName: nil, reason: .policyUnsupported)]
            )
        }
        guard policy != .off else { return .disabledForPolicyOff }
        let checks = Dictionary(input.checks.map { ($0.packageName, $0) }, uniquingKeysWith: { first, _ in first })
        let decisions = input.packages.map { candidate in
            decide(
                candidate,
                check: checks[candidate.packageName],
                policy: policy,
                processes: input.processes,
                piExecutablePath: input.piExecutablePath
            )
        }
        let candidates = Set(input.packages.map(\.packageName))
        let orphanChecks = input.checks
            .filter { !candidates.contains($0.packageName) }
            .map { PiPackageUpdateRefusalRecord(packageName: $0.packageName, reason: .packageNotDetected(name: $0.packageName)) }
        return PiPackageUpdatePlanSet(
            policy: policy,
            didCheck: true,
            packageCount: input.packages.count,
            decisions: decisions,
            extraRefusals: orphanChecks
        )
    }

    /// 带策略门控的规划：策略为“关闭”（或不属于扩展包允许集合）时**不调用**
    /// `check`，因此关闭策略下检查次数恒为 0。
    static func plan(
        policy: UpdateCheckPolicy,
        packages: [PiPackageCandidate],
        processes: PiProcessInspection = .unknown(.enumerationFailed),
        piExecutablePath: String?,
        check: () -> [PiPackageCheckOutcome]
    ) -> PiPackageUpdatePlanSet {
        guard let mapped = PiPackageUpdatePolicy(policy), mapped != .off else {
            return PiPackageUpdatePlanSet(
                policy: PiPackageUpdatePolicy(policy),
                didCheck: false,
                packageCount: 0,
                decisions: [],
                extraRefusals: [
                    PiPackageUpdateRefusalRecord(
                        packageName: nil,
                        reason: PiPackageUpdatePolicy(policy) == nil ? .policyUnsupported : .policyOff
                    )
                ]
            )
        }
        let checks = check()
        return decide(PiPackageUpdatePlanningInput(
            policy: policy,
            packages: packages,
            checks: checks,
            processes: processes,
            piExecutablePath: piExecutablePath
        ))
    }

    /// 用户取消确认：不执行、不改状态，只产出拒绝记录。
    static func cancellationRecords(for plans: [PiPackageUpdatePlan]) -> [PiPackageUpdateRefusalRecord] {
        plans.map { PiPackageUpdateRefusalRecord(packageName: $0.packageName, reason: .userCancelled) }
    }

    /// 重新检测的版本是否确认更新成功。
    ///
    /// 有目标版本时要求“达到或超过目标版本”；没有目标版本时只要版本发生变化
    /// 就算成功；版本不可解析一律算失败。
    static func updateVerified(detected: String?, old: String, target: String?) -> Bool {
        guard let detected, let detectedVersion = SemanticVersion(detected) else { return false }
        if let target, let targetVersion = SemanticVersion(target) {
            return detectedVersion >= targetVersion
        }
        guard let oldVersion = SemanticVersion(old) else { return false }
        return detectedVersion != oldVersion
    }
}

// MARK: - 命令执行

/// 命令失败类别。固定枚举，不含子进程输出或路径。
enum PiPackageUpdateCommandFailure: String, Equatable {
    case launchFailed
    case timedOut
    case abandoned
    case nonZeroExit

    var text: String {
        switch self {
        case .launchFailed: return "无法启动更新命令"
        case .timedOut: return "更新命令超时（已放弃等待，没有向任何进程发送信号）"
        case .abandoned: return "更新命令被放弃等待（没有向任何进程发送信号）"
        case .nonZeroExit: return "更新命令以非零退出码结束"
        }
    }
}

/// 一次命令执行的结果。`stdoutTail` / `stderrTail` 是子进程输出的有界末尾片段，
/// 只在调用方脱敏后展示或记录。
struct PiPackageUpdateCommandResult: Equatable {
    var exitCode: Int32?
    var launchFailed: Bool
    var timedOut: Bool
    var abandoned: Bool
    var startedAt: Date
    var finishedAt: Date
    var stdoutTail: String?
    var stderrTail: String?

    init(
        exitCode: Int32?,
        launchFailed: Bool = false,
        timedOut: Bool = false,
        abandoned: Bool = false,
        startedAt: Date,
        finishedAt: Date,
        stdoutTail: String? = nil,
        stderrTail: String? = nil
    ) {
        self.exitCode = exitCode
        self.launchFailed = launchFailed
        self.timedOut = timedOut
        self.abandoned = abandoned
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
    }

    /// nil 表示执行成功（退出码 0 且未超时/放弃/启动失败）。
    var failure: PiPackageUpdateCommandFailure? {
        if abandoned { return .abandoned }
        if timedOut { return .timedOut }
        if launchFailed { return .launchFailed }
        guard let exitCode else { return .launchFailed }
        return exitCode == 0 ? nil : .nonZeroExit
    }

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

/// 更新命令执行器的注入点。生产实现是 `ProcessPiPackageUpdateCommand`。
///
/// 接口里没有任何发送信号、终止或修改进程的方法：超时与退出只“放弃等待”，
/// 子进程继续按自己的方式结束。测试注入记录调用的替身，绝不执行真实 `pi`。
protocol PiPackageUpdateRunning: AnyObject {
    /// 以参数数组执行计划里的命令。`completion` 可能在任何队列上被调用。
    func run(
        _ plan: PiPackageUpdatePlan,
        timeout: TimeInterval,
        completion: @escaping (PiPackageUpdateCommandResult) -> Void
    )
    /// 放弃等待进行中的命令。**不发送任何信号**，也不终止子进程。
    func abandon()
}

/// 生产执行器：`Process` + 固定参数数组，没有 shell、没有 `sudo`、没有信号。
///
/// - 可执行文件与 argv 只来自 `PiPackageUpdatePlan`（`["update", "npm:<包名>"]`）；
/// - 环境变量白名单化（与 #20/#21 同一组键）：不把无关凭据、`npm_config_*`、
///   代理变量透传给子进程；PATH 前置 `pi` 所在目录并补上系统目录；
/// - stdout/stderr 分别合并进有界尾部片段，只用于诊断；
/// - 超时或 `abandon()` 只标记结果并停止等待：本类型不调用任何信号或终止 API。
final class ProcessPiPackageUpdateCommand: PiPackageUpdateRunning {
    /// 保留的子进程输出上限（每条流，字符）。
    static let outputTailLimit = 2000
    /// 进程结束后等两条管道读到 EOF 的宽限时间（有界；超时后照常结束）。
    static let pipeDrainGrace: TimeInterval = 0.5

    private let stateQueue = DispatchQueue(label: "io.github.su-luoya.pi-web-desktop.pi-package-update-command")
    private let clock: () -> Date
    private let baseEnvironment: [String: String]

    private var process: Process?
    private var timer: DispatchSourceTimer?
    private var drainTimer: DispatchSourceTimer?
    private var completion: ((PiPackageUpdateCommandResult) -> Void)?
    private var finished = false
    private var timedOut = false
    private var abandoned = false
    private var startedAt: Date?
    private var stdoutTail = ""
    private var stderrTail = ""
    private var stdoutDrained = false
    private var stderrDrained = false
    private var pendingFinish: (exitCode: Int32?, launchFailed: Bool)?

    init(
        clock: @escaping () -> Date = { Date() },
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.clock = clock
        self.baseEnvironment = baseEnvironment
    }

    func run(
        _ plan: PiPackageUpdatePlan,
        timeout: TimeInterval,
        completion: @escaping (PiPackageUpdateCommandResult) -> Void
    ) {
        stateQueue.async { [weak self] in
            self?.startLocked(plan, timeout: timeout, completion: completion)
        }
    }

    func abandon() {
        stateQueue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.abandoned = true
            self.finishLocked(exitCode: nil)
        }
    }

    // MARK: - 内部（全部在 stateQueue 上执行）

    private func startLocked(
        _ plan: PiPackageUpdatePlan,
        timeout: TimeInterval,
        completion: @escaping (PiPackageUpdateCommandResult) -> Void
    ) {
        guard !finished else { return }
        self.completion = completion
        self.startedAt = clock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.environment = PiPackageUpdateEnvironment.environment(
            base: baseEnvironment,
            piExecutablePath: plan.executablePath
        )
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.receive(data, toStdout: true, from: handle)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.receive(data, toStdout: false, from: handle)
        }
        process.terminationHandler = { [weak self] finishedProcess in
            self?.stateQueue.async {
                self?.finishLocked(exitCode: finishedProcess.terminationStatus)
            }
        }
        self.process = process
        do {
            try process.run()
        } catch {
            finishLocked(exitCode: nil, launchFailed: true)
            return
        }
        scheduleTimeoutLocked(timeout)
    }

    private func scheduleTimeoutLocked(_ timeout: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + max(0.05, timeout))
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            // 超时只放弃等待：不发送信号、不终止子进程。
            self.timedOut = true
            self.finishLocked(exitCode: nil)
        }
        timer.resume()
        self.timer = timer
    }

    /// 管道回调统一入口：空数据 = 读到 EOF，标记已经读完（可能触发暂存的结束）。
    private func receive(_ data: Data, toStdout: Bool, from handle: FileHandle) {
        stateQueue.async { [weak self] in
            guard let self, !self.finished else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                if toStdout {
                    self.stdoutDrained = true
                } else {
                    self.stderrDrained = true
                }
                self.completePendingLocked()
                return
            }
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            if toStdout {
                self.stdoutTail = Self.bounded(self.stdoutTail + text)
            } else {
                self.stderrTail = Self.bounded(self.stderrTail + text)
            }
        }
    }

    private static func bounded(_ text: String, limit: Int = ProcessPiPackageUpdateCommand.outputTailLimit) -> String {
        guard text.count > limit else { return text }
        return String(text.suffix(limit))
    }

    private func finishLocked(exitCode: Int32?, launchFailed: Bool = false) {
        guard !finished, pendingFinish == nil else { return }
        // 正常结束时先等两条管道读到 EOF（有界），保证尾部输出不丢；
        // 超时/放弃路径直接结束：不做任何阻塞，也不向任何进程发送信号。
        if exitCode != nil, !(stdoutDrained && stderrDrained) {
            pendingFinish = (exitCode, launchFailed)
            scheduleDrainDeadlineLocked()
            return
        }
        completeLocked(exitCode: exitCode, launchFailed: launchFailed)
    }

    /// 管道读完且进程已结束时，用暂存的结果完成。
    private func completePendingLocked() {
        guard let pending = pendingFinish, !finished, stdoutDrained, stderrDrained else { return }
        pendingFinish = nil
        completeLocked(exitCode: pending.exitCode, launchFailed: pending.launchFailed)
    }

    /// 等管道读完的宽限计时：到期还没有 EOF 就照常结束（只是尾部可能少一段）。
    private func scheduleDrainDeadlineLocked() {
        guard drainTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + Self.pipeDrainGrace)
        timer.setEventHandler { [weak self] in
            guard let self, let pending = self.pendingFinish, !self.finished else { return }
            self.pendingFinish = nil
            self.completeLocked(exitCode: pending.exitCode, launchFailed: pending.launchFailed)
        }
        timer.resume()
        self.drainTimer = timer
    }

    private func completeLocked(exitCode: Int32?, launchFailed: Bool) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        drainTimer?.cancel()
        drainTimer = nil
        if let handle = (process?.standardOutput as? Pipe)?.fileHandleForReading {
            handle.readabilityHandler = nil
        }
        if let handle = (process?.standardError as? Pipe)?.fileHandleForReading {
            handle.readabilityHandler = nil
        }
        let finishedAt = clock()
        let result = PiPackageUpdateCommandResult(
            exitCode: exitCode,
            launchFailed: launchFailed,
            timedOut: timedOut,
            abandoned: abandoned,
            startedAt: startedAt ?? finishedAt,
            finishedAt: finishedAt,
            stdoutTail: stdoutTail.isEmpty ? nil : stdoutTail,
            stderrTail: stderrTail.isEmpty ? nil : stderrTail
        )
        let completion = self.completion
        self.completion = nil
        self.process = nil
        self.pendingFinish = nil
        completion?(result)
    }
}

// MARK: - 执行结果

/// 一次命令执行的记录：退出码、耗时与失败类别（成功时 failure 为 nil）。
struct PiPackageUpdateCommandRecord: Equatable {
    var exitCode: Int32?
    var duration: TimeInterval
    var failure: PiPackageUpdateCommandFailure?

    var durationText: String { String(format: "%.1f 秒", max(0, duration)) }
}

/// 一个扩展包的更新结果。
enum PiPackageUpdateRunOutcome: Equatable {
    /// 没有尝试执行：策略不允许、来源不可信、未确认（取消）。
    case notAttempted(packageName: String, reason: PiPackageUpdateRefusal)
    /// 进程保护拒绝执行（执行前复查或确认后复查）。
    case refused(plan: PiPackageUpdatePlan, reason: PiPackageUpdateRefusal)
    /// 命令失败（非零退出 / 超时 / 启动失败 / 放弃等待）：旧版本保持不变。
    case commandFailed(
        plan: PiPackageUpdatePlan,
        failure: PiPackageUpdateCommandFailure,
        record: PiPackageUpdateCommandRecord,
        outputTail: String?
    )
    /// 命令退出码 0，但重新检测的版本没有达到目标版本（未变化或不可解析）。
    case versionUnchanged(
        plan: PiPackageUpdatePlan,
        detectedVersion: String?,
        record: PiPackageUpdateCommandRecord
    )
    /// 版本已经更新。
    case succeeded(plan: PiPackageUpdatePlan, newVersion: String, record: PiPackageUpdateCommandRecord)

    var packageName: String {
        switch self {
        case .notAttempted(let name, _): return name
        case .refused(let plan, _), .commandFailed(let plan, _, _, _),
             .versionUnchanged(let plan, _, _), .succeeded(let plan, _, _):
            return plan.packageName
        }
    }

    var isSucceeded: Bool {
        if case .succeeded = self { return true }
        return false
    }

    var isFailure: Bool { warning != nil }

    /// 失败路径的持久警告记录；成功、拒绝与未尝试返回 nil。
    var warning: PiPackageUpdateWarning? {
        switch self {
        case .notAttempted, .refused, .succeeded:
            return nil
        case .commandFailed(let plan, let failure, _, _):
            return PiPackageUpdateWarning(
                kind: .commandFailed,
                packageName: plan.packageName,
                oldVersion: plan.installedVersion,
                newVersion: plan.installedVersion,
                targetVersion: plan.targetVersion,
                reason: failure.text
            )
        case .versionUnchanged(let plan, let detectedVersion, _):
            return PiPackageUpdateWarning(
                kind: .versionUnchanged,
                packageName: plan.packageName,
                oldVersion: plan.installedVersion,
                newVersion: detectedVersion,
                targetVersion: plan.targetVersion,
                reason: "更新命令已结束，但重新检测到的版本是 \(detectedVersion ?? "未知")，未达到目标版本"
            )
        }
    }

    /// 日志/诊断行（已脱敏）。
    func logLine(redactingWith redactor: LogRedactor) -> String {
        switch self {
        case .notAttempted(let name, let reason):
            return "Pi 扩展包更新（\(name)）：未执行（\(reason.text)）"
        case .refused(let plan, let reason):
            return "Pi 扩展包更新（\(plan.packageName)）：拒绝执行（\(reason.text)）"
        case .commandFailed(let plan, let failure, let record, _):
            return "Pi 扩展包更新（\(plan.packageName)）失败：\(failure.text)；退出码 "
                + "\(record.exitCode.map(String.init) ?? "无")，耗时 \(record.durationText)，"
                + "当前版本 \(plan.installedVersion)，目标版本 \(plan.targetVersion ?? "未知")。旧版本保持不变。"
        case .versionUnchanged(let plan, let detected, let record):
            return "Pi 扩展包更新（\(plan.packageName)）未通过版本验证：命令退出码 0、耗时 \(record.durationText)，"
                + "但重新检测到的版本是 \(detected ?? "未知")，目标版本 \(plan.targetVersion ?? "未知")。"
                + "旧版本保持不变；应用不会自动重试无上限，也不声称更新成功。"
        case .succeeded(let plan, let newVersion, let record):
            return "Pi 扩展包更新（\(plan.packageName)）完成：\(plan.installedVersion) → \(newVersion)，"
                + "退出码 \(record.exitCode.map(String.init) ?? "未知")，耗时 \(record.durationText)。"
        }
    }
}

/// 一次“确认后执行”的批量结果。
struct PiPackageUpdateBatchOutcome: Equatable {
    var outcomes: [PiPackageUpdateRunOutcome]

    /// 全部执行成功（至少一项）才算成功。
    var isSucceeded: Bool { !outcomes.isEmpty && outcomes.allSatisfy(\.isSucceeded) }

    var failures: [PiPackageUpdateRunOutcome] { outcomes.filter(\.isFailure) }

    /// 最近一条失败警告（跨启动保留）。
    var latestWarning: PiPackageUpdateWarning? { failures.last?.warning }

    func logLines(redactingWith redactor: LogRedactor) -> [String] {
        outcomes.map { $0.logLine(redactingWith: redactor) }
    }
}

// MARK: - 编排

/// 确认 →（执行前复查）→ 执行 → 重新检测版本的顺序编排。
///
/// 全部副作用都注入（进程检查、命令执行器、版本重检测、日志、投递队列、时钟），
/// 因此 unhosted 测试可以用同步替身断言每一步，不枚举真实进程、不执行真实 `pi`、
/// 不访问网络。
final class PiPackageUpdateCoordinator {
    struct Environment {
        /// 进程检查器（生产：`PiProcessInspector`；测试：假进程表）。
        var inspectProcesses: () -> PiProcessInspection
        /// 命令执行器（生产：`ProcessPiPackageUpdateCommand`；测试：记录替身）。
        var runner: PiPackageUpdateRunning
        /// 重新检测某个包的版本（复用 #16 的 `pi list` 识别结果）。
        var detectPackageVersion: (String) -> String?
        /// 统一脱敏器（与日志/诊断共用同一个实例）。
        var redactor: LogRedactor
        /// 日志入口；每条消息写入前都必须经过 `redactor`。
        var log: (String) -> Void
        /// 结果投递队列（生产：主队列；测试：立即执行）。
        var deliver: (@escaping () -> Void) -> Void
        /// 命令超时（秒）。超时按失败处理，但不发送任何信号。
        var timeout: TimeInterval

        init(
            inspectProcesses: @escaping () -> PiProcessInspection,
            runner: PiPackageUpdateRunning,
            detectPackageVersion: @escaping (String) -> String?,
            redactor: LogRedactor,
            log: @escaping (String) -> Void,
            deliver: @escaping (@escaping () -> Void) -> Void,
            timeout: TimeInterval = PiPackageUpdateCoordinator.defaultTimeout
        ) {
            self.inspectProcesses = inspectProcesses
            self.runner = runner
            self.detectPackageVersion = detectPackageVersion
            self.redactor = redactor
            self.log = log
            self.deliver = deliver
            self.timeout = timeout
        }
    }

    /// 默认命令超时：10 分钟。有界，但超时不会终止子进程。
    static let defaultTimeout: TimeInterval = 600

    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    /// 用户取消/未确认：不执行、不改状态，只记录原因。
    func recordCancellation(_ plans: [PiPackageUpdatePlan]) {
        for record in PiPackageUpdatePlanner.cancellationRecords(for: plans) {
            logOutcome(record.logLine)
        }
    }

    /// 执行一批已经由用户确认的计划。每个包执行前都重新检查一次进程状态：
    /// 有运行中的 Pi 进程或状态不确定时，该包与其后的包一律拒绝执行。
    func runConfirmed(
        _ plans: [PiPackageUpdatePlan],
        completion: @escaping (PiPackageUpdateBatchOutcome) -> Void
    ) {
        guard !plans.isEmpty else {
            environment.deliver { completion(PiPackageUpdateBatchOutcome(outcomes: [])) }
            return
        }
        runPlans(plans, at: 0, collected: []) { outcomes in
            self.environment.deliver { completion(PiPackageUpdateBatchOutcome(outcomes: outcomes)) }
        }
    }

    private func runPlans(
        _ plans: [PiPackageUpdatePlan],
        at index: Int,
        collected: [PiPackageUpdateRunOutcome],
        completion: @escaping ([PiPackageUpdateRunOutcome]) -> Void
    ) {
        guard index < plans.count else {
            completion(collected)
            return
        }
        let plan = plans[index]
        switch environment.inspectProcesses() {
        case .noProcesses:
            execute(plan: plan) { outcome in
                self.runPlans(plans, at: index + 1, collected: collected + [outcome], completion: completion)
            }
        case .runningProcesses(let records):
            let reason = PiPackageUpdateRefusal.piRunning(records)
            let remaining = plans[index...].map { PiPackageUpdateRunOutcome.refused(plan: $0, reason: reason) }
            logOutcome("Pi 扩展包更新（\(plan.packageName)）：执行前复查发现运行中的 Pi 进程，已拒绝执行（\(reason.text)）")
            completion(collected + remaining)
        case .unknown(let reason):
            let refusal = PiPackageUpdateRefusal.processStateUnknown(reason)
            let remaining = plans[index...].map { PiPackageUpdateRunOutcome.refused(plan: $0, reason: refusal) }
            logOutcome("Pi 扩展包更新（\(plan.packageName)）：执行前复查无法确定进程状态，已拒绝执行（\(refusal.text)）")
            completion(collected + remaining)
        }
    }

    private func execute(
        plan: PiPackageUpdatePlan,
        completion: @escaping (PiPackageUpdateRunOutcome) -> Void
    ) {
        environment.log(environment.redactor.redact(
            "Pi 扩展包更新：用户已确认执行\n"
                + plan.displayLines(redactingWith: environment.redactor).joined(separator: "\n")
        ))
        environment.runner.run(plan, timeout: environment.timeout) { [weak self] result in
            guard let self else { return }
            let record = PiPackageUpdateCommandRecord(
                exitCode: result.exitCode,
                duration: result.duration,
                failure: result.failure
            )
            if let failure = result.failure {
                let tail = Self.outputTailText(result, redactingWith: self.environment.redactor)
                self.logOutcome(
                    "Pi 扩展包更新（\(plan.packageName)）失败：\(failure.text)；退出码 "
                        + "\(result.exitCode.map(String.init) ?? "无")，耗时 \(record.durationText)，"
                        + "当前版本 \(plan.installedVersion)，目标版本 \(plan.targetVersion ?? "未知")。旧版本保持不变。"
                )
                if let tail {
                    self.logOutcome("Pi 扩展包更新命令输出片段（已脱敏）：\(tail)")
                }
                completion(.commandFailed(plan: plan, failure: failure, record: record, outputTail: tail))
                return
            }
            let detected = self.environment.detectPackageVersion(plan.packageName)
            guard PiPackageUpdatePlanner.updateVerified(
                detected: detected,
                old: plan.installedVersion,
                target: plan.targetVersion
            ) else {
                self.logOutcome(
                    "Pi 扩展包更新（\(plan.packageName)）未通过版本验证：命令退出码 0，但重新检测到的版本是 "
                        + "\(detected ?? "未知")，目标版本 \(plan.targetVersion ?? "未知")。"
                        + "旧版本保持不变；应用不会自动重试无上限，也不声称更新成功。"
                )
                completion(.versionUnchanged(plan: plan, detectedVersion: detected, record: record))
                return
            }
            let newVersion = detected ?? plan.targetVersion ?? plan.installedVersion
            self.logOutcome(
                "Pi 扩展包更新（\(plan.packageName)）完成：\(plan.installedVersion) → \(newVersion)，耗时 \(record.durationText)。"
            )
            completion(.succeeded(plan: plan, newVersion: newVersion, record: record))
        }
    }

    private func logOutcome(_ message: String) {
        environment.log(environment.redactor.redact(message))
    }

    /// 标准输出/错误尾部：合并、脱敏、折叠空白；没有输出时返回 nil。
    static func outputTailText(_ result: PiPackageUpdateCommandResult, redactingWith redactor: LogRedactor) -> String? {
        var parts: [String] = []
        if let stdout = result.stdoutTail, !stdout.isEmpty { parts.append("标准输出：\(stdout)") }
        if let stderr = result.stderrTail, !stderr.isEmpty { parts.append("标准错误：\(stderr)") }
        guard !parts.isEmpty else { return nil }
        let joined = redactor.redact(parts.joined(separator: "\n"))
        let collapsed = joined.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
}

// MARK: - 执行后的版本重检测

/// 执行后的聚焦版本重检测：复用 #16 识别器的 `pi list` 路径，只识别扩展包。
enum PiPackageUpdateRedetection {
    static func detect(
        piPath: String?,
        commandRunner: CommandRunning,
        fileSystem: DependencyFileSystemProbing = SystemDependencyFileSystemProbe(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String? = nil
    ) -> [ComponentInstallation] {
        guard let piPath, !piPath.isEmpty else { return [] }
        let detector = ComponentInstallationDetector(
            commandRunner: commandRunner,
            fileSystem: fileSystem,
            environment: environment,
            homeDirectory: homeDirectory
        )
        return detector.detectPiPackages(piExecutablePath: piPath)
    }

    /// 包名 → 版本（只保留带包名与可解析版本的条目）。
    static func versions(from installations: [ComponentInstallation]) -> [String: String] {
        var result: [String: String] = [:]
        for installation in installations {
            guard installation.kind == .piPackage,
                  let name = installation.packageName,
                  let version = installation.version,
                  SemanticVersion(version) != nil else { continue }
            result[name] = version
        }
        return result
    }

    /// 只查一个包的重检测闭包（生产路径用）。
    static func versionProvider(
        piPath: String?,
        commandRunner: CommandRunning,
        fileSystem: DependencyFileSystemProbing = SystemDependencyFileSystemProbe(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String? = nil
    ) -> (String) -> String? {
        { packageName in
            detect(
                piPath: piPath,
                commandRunner: commandRunner,
                fileSystem: fileSystem,
                environment: environment,
                homeDirectory: homeDirectory
            ).first { $0.kind == .piPackage && $0.packageName == packageName }?.version
        }
    }
}

// MARK: - 确认文案与状态展示

/// 执行前的确认对话框文案（固定顺序，已脱敏）。
enum PiPackageUpdateConfirmation {
    /// 整批确认：每个计划一段完整信息，最后给出进程状态与风险说明。
    static func text(
        plans: [PiPackageUpdatePlan],
        inspection: PiProcessInspection,
        redactingWith redactor: LogRedactor
    ) -> String {
        var lines: [String] = []
        lines.append("共 \(plans.count) 个扩展包待更新。执行前会再次检查 Pi 进程；"
            + "检测到运行中的 Pi 进程或状态不确定时不会执行。")
        for (index, plan) in plans.enumerated() {
            lines.append("")
            lines.append("【\(index + 1)/\(plans.count)】")
            lines.append(contentsOf: plan.displayLines(redactingWith: redactor))
            lines.append(plan.riskText())
        }
        lines.append("")
        lines.append("当前 Pi 进程状态：\(inspection.statusText)")
        for record in inspection.records {
            lines.append(contentsOf: record.displayLines)
            lines.append("")
        }
        lines.append("取消是默认按钮：不确认就不会执行，也不会改动任何状态。")
        return lines.joined(separator: "\n")
    }
}

/// 诊断页/设置页用的状态文本（纯函数；输入都是已经脱敏或可安全展示的值）。
///
/// `inspection` 为 nil 表示本次运行还没有做过进程检查（smoke 启动不会枚举真实
/// 进程），此时只展示策略与拒绝原因，不展示进程结论。
enum PiPackageUpdateStatusPresenter {
    /// 更新失败告警的展示文本（跨启动保留）。
    static func lines(
        policy: UpdateCheckPolicy,
        planSet: PiPackageUpdatePlanSet?,
        inspection: PiProcessInspection?,
        warning: PiPackageUpdateWarning?
    ) -> [String] {
        var lines: [String] = []
        let mapped = PiPackageUpdatePolicy(policy)
        lines.append("Pi 扩展包更新：策略 \(mapped?.title ?? "\(policy.title)（不属于扩展包允许集合）")"
            + "；不做无人值守更新（执行入口必须经用户确认）")
        lines.append("Pi 扩展包进程保护：\(inspection?.statusText ?? "尚未检查（本次运行还没有枚举本机进程）")")
        if let planSet {
            lines.append("本次规划：已检查 \(planSet.didCheck ? "是" : "否")；包数量 \(planSet.packageCount)；"
                + "待确认计划 \(planSet.executablePlans.count)；只提示 \(planSet.notices.count)")
            for plan in planSet.executablePlans {
                lines.append("待确认：\(plan.packageName) \(plan.installedVersion) → \(plan.targetVersion ?? "由官方命令决定")"
                    + "（参数数组 \(PiPackageUpdateArgumentPolicy.displayText(for: plan.arguments))）")
            }
            for plan in planSet.allPlans where planSet.executablePlans.allSatisfy({ $0.packageName != plan.packageName }) {
                lines.append("已就绪但被拒绝执行：\(plan.packageName)（原因见下面的拒绝记录）")
            }
            for notice in planSet.notices {
                lines.append("只提示：\(notice.packageName) \(notice.installedVersion ?? "未知") → \(notice.targetVersion ?? "未知")")
            }
            for record in planSet.refusalRecords {
                lines.append("拒绝记录：\(record.logLine)")
            }
        }
        if let warning {
            lines.append(warning.text)
        }
        lines.append("手动入口：菜单“服务 → 更新检查设置 → 查看 Pi 扩展包更新…”（策略为“关闭”时不检查、不提示、不执行）")
        return lines
    }
}

// MARK: - 持久警告

/// 一次失败的扩展包更新的持久记录。
///
/// 只保存类别、包名（已通过 npm 包名校验）、旧/新/目标版本、固定原因文案与
/// 时间：不含路径、环境变量值、凭据或子进程输出。警告在界面与诊断文本里持续
/// 显示，直到下一次成功更新或用户清除。
struct PiPackageUpdateWarning: Equatable {
    enum Kind: String, Equatable {
        case commandFailed
        case versionUnchanged
    }

    var kind: Kind
    var packageName: String
    var oldVersion: String?
    var newVersion: String?
    var targetVersion: String?
    var reason: String
    var recordedAt: Date

    init(
        kind: Kind,
        packageName: String,
        oldVersion: String? = nil,
        newVersion: String? = nil,
        targetVersion: String? = nil,
        reason: String,
        recordedAt: Date = Date()
    ) {
        self.kind = kind
        self.packageName = packageName
        self.oldVersion = oldVersion
        self.newVersion = newVersion
        self.targetVersion = targetVersion
        self.reason = reason
        self.recordedAt = recordedAt
    }

    /// 用户可见的持久警告：明确说明旧版本保持不变、没有回滚这回事。
    var text: String {
        var parts: [String] = []
        parts.append("Pi 扩展包更新未完成（\(packageName)）：\(reason)。")
        parts.append("当前版本：\(oldVersion ?? "未知")；目标版本：\(targetVersion ?? "未知")"
            + (newVersion.map { "；重新检测到的版本：\($0)" } ?? "") + "。")
        parts.append("旧版本文件不会被应用回滚，应用也不声称更新成功；"
            + "请查看日志与诊断结果后手动处理，或稍后重新确认更新。")
        return parts.joined(separator: " ")
    }

    /// 菜单/状态行用的单行摘要。
    var shortText: String {
        "Pi 扩展包更新告警（\(packageName)）：\(reason)（当前 \(oldVersion ?? "未知") → 目标 \(targetVersion ?? "未知")）"
    }
}

/// 持久警告的 UserDefaults 存取（只经 `AppConfiguration` 调用）。
enum PiPackageUpdateWarningStore {
    static func load(from defaults: UserDefaults) -> PiPackageUpdateWarning? {
        guard let kindText = defaults.string(forKey: UpdateSettingKeys.piPackageUpdateWarningKind),
              let kind = PiPackageUpdateWarning.Kind(rawValue: kindText) else { return nil }
        guard let reason = defaults.string(forKey: UpdateSettingKeys.piPackageUpdateWarningReason),
              !reason.isEmpty else { return nil }
        guard let packageName = defaults.string(forKey: UpdateSettingKeys.piPackageUpdateWarningPackage),
              ComponentInstallationDetector.isPackageName(packageName) else { return nil }
        let recordedAt = UpdateIgnoredVersions.timestamp(
            defaults.object(forKey: UpdateSettingKeys.piPackageUpdateWarningRecordedAt)
        ) ?? Date(timeIntervalSince1970: 0)
        return PiPackageUpdateWarning(
            kind: kind,
            packageName: packageName,
            oldVersion: version(defaults, UpdateSettingKeys.piPackageUpdateWarningOldVersion),
            newVersion: version(defaults, UpdateSettingKeys.piPackageUpdateWarningNewVersion),
            targetVersion: version(defaults, UpdateSettingKeys.piPackageUpdateWarningTargetVersion),
            reason: reason,
            recordedAt: recordedAt
        )
    }

    static func save(_ warning: PiPackageUpdateWarning?, to defaults: UserDefaults) {
        guard let warning,
              ComponentInstallationDetector.isPackageName(warning.packageName) else {
            for key in UpdateSettingKeys.allPiPackageUpdateWarningKeys {
                defaults.removeObject(forKey: key)
            }
            return
        }
        defaults.set(warning.kind.rawValue, forKey: UpdateSettingKeys.piPackageUpdateWarningKind)
        defaults.set(warning.packageName, forKey: UpdateSettingKeys.piPackageUpdateWarningPackage)
        defaults.set(warning.reason, forKey: UpdateSettingKeys.piPackageUpdateWarningReason)
        defaults.set(warning.recordedAt.timeIntervalSince1970, forKey: UpdateSettingKeys.piPackageUpdateWarningRecordedAt)
        setVersion(warning.oldVersion, key: UpdateSettingKeys.piPackageUpdateWarningOldVersion, defaults: defaults)
        setVersion(warning.newVersion, key: UpdateSettingKeys.piPackageUpdateWarningNewVersion, defaults: defaults)
        setVersion(warning.targetVersion, key: UpdateSettingKeys.piPackageUpdateWarningTargetVersion, defaults: defaults)
    }

    /// 只接受可解析为语义化版本的字符串；否则写入 nil（删除键）。
    static func setVersion(_ version: String?, key: String, defaults: UserDefaults) {
        guard let version, SemanticVersion(version) != nil else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(version, forKey: key)
    }

    static func version(_ defaults: UserDefaults, _ key: String) -> String? {
        guard let text = defaults.string(forKey: key), SemanticVersion(text) != nil else { return nil }
        return text
    }
}
