import Foundation

// MARK: - Pi CLI 更新与运行进程保护（GitHub #21）
//
// 本文件是 Pi CLI 更新路径的唯一实现。边界：
// - 只调用 Pi 官方自更新命令 `pi update --self`：命令是参数数组
//   （`["update", "--self"]`），不是 shell 字符串；不拼接 npm/pnpm 命令，
//   不调用 `sudo`；
// - 可执行文件路径来自 #16 的 Pi CLI 识别结果，且必须通过参数安全校验；
// - 进程保护优先于一切：**只有** `PiProcessInspection.noProcesses` 才允许自动
//   执行；有运行中的 Pi 进程或状态不确定时一律推迟，并记录原因；
// - 来源硬前置（GitHub #59 / 安全审查 A-1）：目标版本必须来自**本次运行**从
//   白名单主机取得的检查结果；缓存回退只用于提示，不自动执行；
// - 绝不向任何进程发送信号：本文件没有任何 `kill` / `killpg` / 终止调用，
//   连超时也只放弃等待（子进程是用户自己的官方更新命令，不代它做决定）；
// - 执行结果记录退出码、标准输出/错误尾部（经 `LogRedactor` 脱敏）与耗时；
//   执行后用 #16 识别器重新检测版本，版本没有变化或无法解析都算失败；
// - 失败只写入持久警告与日志，不自动重试无上限（一次运行最多尝试一次）。

// MARK: - 设置（GitHub #18 的设置位在 alpha.3 生效，见 GitHub #21）

extension UpdateCheckPreferences {
    /// 启动前自动更新 Pi CLI 的默认值：关闭。
    static let defaultAutoUpdatePiBeforeLaunch = false
    /// 设置位已生效（GitHub #21）：打开后也只有“没有运行中的 Pi 进程 +
    /// 已验证的 npm/pnpm 全局安装 + 已验证且更高的目标版本”时才自动执行。
    static let autoUpdatePiBeforeLaunchIsEffective = true
}

// MARK: - 拒绝原因与推迟原因

/// 不执行自动更新（或连手动命令都给不出）的原因。全部是固定文案，不含路径、
/// 子进程输出或凭据（路径只在展示时单独脱敏拼接）。
enum PiCLIUpdateRefusal: Equatable {
    /// 设置位关闭。
    case settingDisabled
    /// 没有可用的 Pi CLI 识别结果（缺少 #16 的检测结果）。
    case missingInstallation
    /// Pi CLI 识别结果里没有解析出的可执行文件路径。
    case executableUnresolved
    /// 来源不是已验证的 npm/pnpm 全局安装：自动更新不做，只给手动入口。
    case sourceNotVerifiedPackageManager(source: InstallSource, confidence: DetectionConfidence)
    /// 没有可用目标版本（检查结果不是“可更新”或没有版本号）。
    case noTargetVersion
    /// 目标版本未经上游响应验证（confidence != verified）。
    case targetNotVerified
    /// 判定所用的检查结果不是本次运行从白名单主机取得的网络结果（缓存回退或
    /// 没有结果）。缓存文件不是可信输入，因此这条前置条件不允许被绕过。
    case targetNotFromNetwork(origin: UpdateCheckOrigin, cacheWrittenAt: Date?)
    /// 目标版本不是可比较的语义化版本。
    case invalidTargetVersion
    /// 本机版本不低于目标版本。
    case noNewerTargetVersion
    /// 构造出的命令没有通过参数安全校验。
    case unsafeCommand

    var text: String {
        switch self {
        case .settingDisabled:
            return "“启动前自动更新 Pi CLI”设置已关闭"
        case .missingInstallation:
            return "没有可用的 Pi CLI 安装信息"
        case .executableUnresolved:
            return "没有解析出可用于更新的 Pi CLI 可执行文件"
        case .sourceNotVerifiedPackageManager(let source, let confidence):
            return "Pi CLI 来源是 \(source.displayName)（可信度 \(confidence.displayName)）；只有来源为已验证的 npm/pnpm 全局安装才允许自动更新，其它来源只提供手动入口"
        case .noTargetVersion:
            return "没有可用的目标版本"
        case .targetNotVerified:
            return "目标版本未经上游响应验证"
        case .targetNotFromNetwork(let origin, let cacheWrittenAt):
            return origin.autoInstallRefusalText(cacheWrittenAt: cacheWrittenAt)
        case .invalidTargetVersion:
            return "目标版本无法解析为语义化版本"
        case .noNewerTargetVersion:
            return "本机版本不低于目标版本"
        case .unsafeCommand:
            return "构造出的更新命令未通过参数安全校验"
        }
    }
}

/// 推迟自动更新的原因：前置条件都已满足，但进程保护或「已放弃」记录要求这次不执行。
enum PiCLIUpdateDeferral: Equatable {
    /// 有运行中的 Pi 进程：推迟到它们结束后的下一次判定（下次启动或等待状态）。
    case piRunning([PiProcessRecord])
    /// 进程状态不确定：按不安全处理，推迟到下一次判定。
    case processStateUnknown(PiProcessInspectionUnknown)
    /// 同一组件存在未清除的「已放弃」记录（GitHub #62）：推迟到下次启动；手动
    /// 入口不受影响，但必须在确认框里先看到这条记录。
    case abandonedAttemptPending(UpdateAbandonedAttempt)

    var text: String {
        switch self {
        case .piRunning(let records):
            let summary = records.map(\.shortText).joined(separator: "；")
            return "检测到 \(records.count) 个运行中的 Pi 进程（\(summary)）：更新会让正在进行的会话读到被替换的文件，"
                + "因此推迟到它们结束后的下一次判定（下次启动或等待状态）。应用不会结束任何 Pi 进程。"
        case .processStateUnknown(let reason):
            return "无法确定 Pi 进程状态（\(reason.text)）：按不安全处理，推迟到下一次判定。应用不会结束任何进程。"
        case .abandonedAttemptPending(let attempt):
            return UpdateAbandonedAttemptPresenter.automaticRefusalText(attempt)
        }
    }

    var records: [PiProcessRecord] {
        if case .piRunning(let records) = self { return records }
        return []
    }
}

// MARK: - 更新计划

/// 一次 `pi update --self` 的完整计划。
///
/// `arguments` 恒为 `["update", "--self"]`，由构造保证；没有 shell 字符串，
/// 没有 `sudo`，没有额外参数。可执行文件路径来自 #16 的识别结果。
struct PiCLIUpdatePlan: Equatable {
    /// Pi CLI 官方自更新参数：唯一允许的 argv。
    static let requiredArguments = ["update", "--self"]
    /// 可执行文件路径允许的字符集（绝对路径，不含空白与 shell 元字符）。
    static let executablePathAllowedCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@~:"
    )

    var executablePath: String
    var arguments: [String]
    var installedVersion: String
    /// 目标版本：自动路径必须给出（来自已验证的检查结果）；手动路径可以为 nil
    /// （由 Pi 自带更新器决定更新到哪个版本，执行后只比较“版本是否发生变化”）。
    var targetVersion: String?
    var source: InstallSource
    var confidence: DetectionConfidence

    /// 构造计划；任何一项不满足都返回 nil（调用方按 `.unsafeCommand` 处理）。
    static func make(
        executablePath: String?,
        installedVersion: String,
        targetVersion: String?,
        source: InstallSource,
        confidence: DetectionConfidence
    ) -> PiCLIUpdatePlan? {
        guard let executablePath, isSafeExecutablePath(executablePath) else { return nil }
        if let targetVersion {
            guard let target = SemanticVersion(targetVersion), target.description == targetVersion else { return nil }
        }
        guard SemanticVersion(installedVersion) != nil else { return nil }
        let arguments = requiredArguments
        guard arguments == ["update", "--self"] else { return nil }
        return PiCLIUpdatePlan(
            executablePath: executablePath,
            arguments: arguments,
            installedVersion: installedVersion,
            targetVersion: targetVersion,
            source: source,
            confidence: confidence
        )
    }

    /// 绝对路径、无空白、无 shell 元字符、非空段。路径来自 #16，仍要再校验一次。
    static func isSafeExecutablePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count > 1 else { return false }
        guard path.unicodeScalars.allSatisfy({ executablePathAllowedCharacters.contains($0) }) else { return false }
        guard !path.contains("//"), !path.hasSuffix("/") else { return false }
        let base = (path as NSString).lastPathComponent
        return !base.isEmpty && base != "." && base != ".."
    }

    /// 展示用的命令文本（参数已固定，因此拼接没有歧义）；路径由调用方脱敏。
    var commandText: String {
        ([executablePath] + arguments).joined(separator: " ")
    }

    /// 更新前展示的完整信息（日志、诊断、确认框共用）。
    func displayLines(redactingWith redactor: LogRedactor) -> [String] {
        [
            "可执行文件：\(redactor.redact(executablePath))",
            "参数数组：\(arguments.map { "\"\($0)\"" }.joined(separator: ", "))",
            "当前版本：\(installedVersion)",
            "目标版本：\(targetVersion ?? "未知（由 Pi 自带更新器决定）")",
            "来源：\(source.displayName)；可信度：\(confidence.displayName)",
            "命令：\(redactor.redact(commandText))",
            "不使用 shell 字符串、不调用 sudo、不向任何进程发送信号。"
        ]
    }

    /// 手动更新的确认文案。
    func confirmationText(redactingWith redactor: LogRedactor) -> String {
        displayLines(redactingWith: redactor).joined(separator: "\n")
    }
}

// MARK: - 决策

/// 自动更新决策。只有 `.automatic` 会真正执行；`.deferred` 表示“前置条件都满足，
/// 但进程保护要求这次不执行”；两种 `manualOnly`/`unavailable` 情况只展示手动入口。
enum PiCLIUpdateDecision: Equatable {
    case automatic(PiCLIUpdatePlan)
    case deferred(plan: PiCLIUpdatePlan, reason: PiCLIUpdateDeferral)
    case manualOnly(commandText: String?, reason: PiCLIUpdateRefusal)
    case unavailable(reason: PiCLIUpdateRefusal)

    var isAutomatic: Bool {
        if case .automatic = self { return true }
        return false
    }

    var plan: PiCLIUpdatePlan? {
        switch self {
        case .automatic(let plan): return plan
        case .deferred(let plan, _): return plan
        case .manualOnly, .unavailable: return nil
        }
    }

    var deferral: PiCLIUpdateDeferral? {
        if case .deferred(_, let reason) = self { return reason }
        return nil
    }

    /// 决策摘要（已脱敏）。用于日志与诊断页。
    func logLine(redactingWith redactor: LogRedactor) -> String {
        switch self {
        case .automatic(let plan):
            return "Pi CLI 启动前自动更新：允许执行\n"
                + plan.displayLines(redactingWith: redactor).joined(separator: "\n")
        case .deferred(let plan, let reason):
            return "Pi CLI 启动前自动更新：推迟（\(reason.text)）\n"
                + "将执行的命令：\(redactor.redact(plan.commandText))"
        case .manualOnly(let commandText, let reason):
            let base = "Pi CLI 启动前自动更新：不执行（\(reason.text)）"
            guard let commandText else {
                return base + "；没有可用的手动命令"
            }
            return base + "；手动命令：\(redactor.redact(commandText))"
        case .unavailable(let reason):
            return "Pi CLI 启动前自动更新：不执行（\(reason.text)）"
        }
    }

    /// 单行摘要（诊断页/设置页）。
    var statusLine: String {
        switch self {
        case .automatic:
            return "允许自动更新"
        case .deferred:
            return "推迟自动更新"
        case .manualOnly(_, let reason):
            return "只提供手动更新（\(reason.text)）"
        case .unavailable(let reason):
            return "不可用（\(reason.text)）"
        }
    }
}

// MARK: - 决策输入与规划器

/// 决策所需的全部输入（纯值类型，测试可直接构造）。
struct PiCLIUpdatePlanningInput: Equatable {
    var preferences: UpdateCheckPreferences
    /// #16 的 Pi CLI 识别结果。
    var installation: ComponentInstallation?
    /// #17/#18 检查器给出的上游版本。
    var targetVersion: String?
    /// 检查结论；只有 `.updateAvailable` 才算有可用目标版本。
    var targetStatus: UpdateCheckStatus = .unknown
    /// 检查结论的可信度；只有 `.verified` 才允许自动执行。
    var targetConfidence: DetectionConfidence = .unknown
    /// 检查结论的来源；只有 `.network`（本次运行刚从白名单主机取得）才允许
    /// 自动执行。默认值是最安全的一档，漏传时不会退化成“允许自动更新”。
    var targetOrigin: UpdateCheckOrigin = .unavailable
    /// 来源为缓存回退时的缓存写入时间（仅用于展示与拒绝原因）。
    var targetCacheWrittenAt: Date? = nil
    /// Pi 进程检查结果。默认值是“枚举失败”，即不安全：漏传时不会退化成允许自动更新。
    var processes: PiProcessInspection = .unknown(.enumerationFailed)
    /// 同一组件未清除的「已放弃」记录（GitHub #62）。有值时不允许自动执行
    /// （推迟到下次启动）；手动入口仍然可用但必须先看到这条记录。
    /// 默认 nil，旧调用点保持不变。
    var abandonedAttempt: UpdateAbandonedAttempt? = nil
}

/// 前置条件与命令构造的纯逻辑（GitHub #21 第 3 项）。
enum PiCLIUpdatePlanner {
    /// 手动入口展示的命令文本：`<pi 路径> update --self`。路径必须通过安全校验；
    /// 否则返回 nil（界面显示“没有可用的手动命令”）。
    static func manualCommandText(executablePath: String?) -> String? {
        guard let plan = PiCLIUpdatePlan.make(
            executablePath: executablePath,
            installedVersion: "0.0.0",
            targetVersion: nil,
            source: .unknown,
            confidence: .unknown
        ) else { return nil }
        return plan.commandText
    }

    /// 手动更新的计划：只要求 #16 已经解析出可执行文件并通过命令安全校验。
    /// 不要求来源可信度，也不看进程状态：确认框会把进程信息与风险一起展示给
    /// 用户，由用户显式确认。目标版本可以缺失。
    static func manualPlan(
        installation: ComponentInstallation?,
        targetVersion: String?
    ) -> PiCLIUpdatePlan? {
        guard let installation, installation.kind == .piCLI else { return nil }
        guard let installedVersion = installation.version else { return nil }
        return PiCLIUpdatePlan.make(
            executablePath: installation.executablePath,
            installedVersion: installedVersion,
            targetVersion: targetVersion.flatMap { SemanticVersion($0)?.description },
            source: installation.source,
            confidence: installation.confidence
        )
    }

    /// 决策。前置条件的顺序是“设置 → 安装信息 → 来源 → 目标版本 → 命令安全”，
    /// 最后才是进程保护：进程保护只会让已经就绪的更新**推迟**，不会掩盖上面
    /// 任何一条不满足的事实。
    static func decide(_ input: PiCLIUpdatePlanningInput) -> PiCLIUpdateDecision {
        let commandText = manualCommandText(executablePath: input.installation?.executablePath)
        guard input.preferences.autoUpdatePiBeforeLaunch else {
            return .manualOnly(commandText: commandText, reason: .settingDisabled)
        }
        guard let installation = input.installation, installation.kind == .piCLI else {
            return .unavailable(reason: .missingInstallation)
        }
        guard let executablePath = installation.executablePath, !executablePath.isEmpty else {
            return .unavailable(reason: .executableUnresolved)
        }
        guard installation.source.isPackageManagerManaged, installation.confidence == .verified else {
            return .manualOnly(
                commandText: commandText,
                reason: .sourceNotVerifiedPackageManager(
                    source: installation.source,
                    confidence: installation.confidence
                )
            )
        }
        guard input.targetStatus == .updateAvailable,
              let targetVersion = input.targetVersion,
              !targetVersion.isEmpty else {
            return .manualOnly(commandText: commandText, reason: .noTargetVersion)
        }
        guard input.targetConfidence == .verified else {
            return .manualOnly(commandText: commandText, reason: .targetNotVerified)
        }
        // 硬前置（GitHub #59 / alpha.3 安全审查 A-1）：判定所用的检查结果必须是
        // 本次运行刚从白名单主机取得的响应。缓存回退或没有结果一律不自动执行，
        // 只保留手动入口；缓存文件不是可信输入（同一用户可改写）。
        guard input.targetOrigin.isEligibleForAutomaticInstall else {
            return .manualOnly(
                commandText: commandText,
                reason: .targetNotFromNetwork(origin: input.targetOrigin, cacheWrittenAt: input.targetCacheWrittenAt)
            )
        }
        guard let target = SemanticVersion(targetVersion) else {
            return .manualOnly(commandText: commandText, reason: .invalidTargetVersion)
        }
        guard let installedVersion = installation.version,
              let installed = SemanticVersion(installedVersion),
              installed < target else {
            return .manualOnly(commandText: commandText, reason: .noNewerTargetVersion)
        }
        guard let plan = PiCLIUpdatePlan.make(
            executablePath: executablePath,
            installedVersion: installedVersion,
            targetVersion: targetVersion,
            source: installation.source,
            confidence: installation.confidence
        ) else {
            return .unavailable(reason: .unsafeCommand)
        }
        // 「已放弃」记录硬前置（GitHub #62 / alpha.3 安全审查 A-6、A-7）：同一组件
        // 存在未清除的记录时不允许自动执行，推迟到下次启动。进程保护只在这一条
        // 满足之后才参与判定；手动入口单独经 `manualPlan` 走。
        if let attempt = input.abandonedAttempt {
            return .deferred(plan: plan, reason: .abandonedAttemptPending(attempt))
        }
        // 进程保护：唯一允许自动执行的情况是“确认没有任何 Pi 进程”。
        switch input.processes {
        case .noProcesses:
            return .automatic(plan)
        case .runningProcesses(let records):
            return .deferred(plan: plan, reason: .piRunning(records))
        case .unknown(let reason):
            return .deferred(plan: plan, reason: .processStateUnknown(reason))
        }
    }

    /// 重新检测的版本是否确认更新成功。
    ///
    /// 有目标版本时要求“达到或超过目标版本”；没有目标版本（手动路径）时只要
    /// 版本发生变化就算成功；版本不可解析一律算失败。
    static func updateVerified(detected: String?, old: String, target: String?) -> Bool {
        UpdateVerifier.versionReached(detected: detected, old: old, target: target)
    }

    /// 兼容旧调用名：重新检测的版本是否达到目标版本。
    static func versionReached(detected: String?, target: String) -> Bool {
        updateVerified(detected: detected, old: target, target: target)
    }
}

// MARK: - 命令执行

/// 命令失败类别。固定枚举，不含子进程输出或路径。
enum PiCLIUpdateCommandFailure: String, Equatable {
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
struct PiCLIUpdateCommandResult: Equatable {
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
    var failure: PiCLIUpdateCommandFailure? {
        if abandoned { return .abandoned }
        if timedOut { return .timedOut }
        if launchFailed { return .launchFailed }
        guard let exitCode else { return .launchFailed }
        return exitCode == 0 ? nil : .nonZeroExit
    }

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

/// 更新命令执行器的注入点。生产实现是 `ProcessPiCLIUpdateCommand`。
///
/// 接口里没有任何发送信号、终止或修改进程的方法：超时与退出只“放弃等待”，
/// 子进程继续按自己的方式结束。测试注入记录调用的替身，绝不执行真实 `pi`。
protocol PiCLIUpdateRunning: AnyObject {
    /// 以参数数组执行计划里的命令。`completion` 可能在任何队列上被调用。
    func run(
        _ plan: PiCLIUpdatePlan,
        timeout: TimeInterval,
        completion: @escaping (PiCLIUpdateCommandResult) -> Void
    )
    /// 放弃等待进行中的命令。**不发送任何信号**，也不终止子进程。
    func abandon()
}

/// 生产执行器：`Process` + 固定参数数组，没有 shell、没有 `sudo`、没有信号。
///
/// - 可执行文件与 argv 只来自 `PiCLIUpdatePlan`（`["update", "--self"]`）；
/// - 环境变量白名单化（与 #20 的 npm 路径同一组键）：不把无关凭据、
///   `npm_config_*`、代理变量透传给子进程；PATH 前置 `pi` 所在目录并补上系统目录，
///   因为 npm 安装的 `pi` 是 `#!/usr/bin/env node` 脚本；
/// - stdout/stderr 分别合并进有界尾部片段，只用于诊断；
/// - 超时或 `abandon()` 只标记结果并停止等待：本类型不调用任何信号或终止 API。
final class ProcessPiCLIUpdateCommand: PiCLIUpdateRunning {
    /// 保留的子进程输出上限（每条流，字符）。
    static let outputTailLimit = 2000
    /// 进程结束后等两条管道读到 EOF 的宽限时间（有界；超时后照常结束）。
    /// `readabilityHandler` 是异步投递的，不等就可能丢掉最后一段输出（正是失败
    /// 原因所在）；但也不能无限等（子进程可能留下持有写端的孩子）。
    static let pipeDrainGrace: TimeInterval = 0.5

    private let stateQueue = DispatchQueue(label: "io.github.su-luoya.pi-web-desktop.pi-cli-update-command")
    private let clock: () -> Date
    private let baseEnvironment: [String: String]
    private let redact: (String) -> String
    private let recordAbandonedAttempt: (UpdateAbandonedAttempt) -> Void

    private var process: Process?
    private var plan: PiCLIUpdatePlan?
    private var timeout: TimeInterval = 0
    private var timer: DispatchSourceTimer?
    private var drainTimer: DispatchSourceTimer?
    private var completion: ((PiCLIUpdateCommandResult) -> Void)?
    private var finished = false
    private var timedOut = false
    private var abandoned = false
    private var startedAt: Date?
    private var stdoutTail = ""
    private var stderrTail = ""
    private var stdoutDrained = false
    private var stderrDrained = false
    /// 本次命令是否已经写过「已放弃」记录（至多一条）。
    private var didRecordAbandonedAttempt = false
    /// 进程已经结束、但还在等管道读完时的暂存结果。
    private var pendingFinish: (exitCode: Int32?, launchFailed: Bool)?

    init(
        clock: @escaping () -> Date = { Date() },
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        redact: @escaping (String) -> String = { LogRedactor().redact($0) },
        recordAbandonedAttempt: @escaping (UpdateAbandonedAttempt) -> Void = { _ in }
    ) {
        self.clock = clock
        self.baseEnvironment = baseEnvironment
        self.redact = redact
        self.recordAbandonedAttempt = recordAbandonedAttempt
    }

    func run(
        _ plan: PiCLIUpdatePlan,
        timeout: TimeInterval,
        completion: @escaping (PiCLIUpdateCommandResult) -> Void
    ) {
        stateQueue.async { [weak self] in
            self?.startLocked(plan, timeout: timeout, completion: completion)
        }
    }

    func abandon() {
        stateQueue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.abandoned = true
            self.recordAbandonedAttemptLocked(reason: .abandonedWaiting)
            self.finishLocked(exitCode: nil)
        }
    }

    // MARK: - 内部（全部在 stateQueue 上执行）

    private func startLocked(
        _ plan: PiCLIUpdatePlan,
        timeout: TimeInterval,
        completion: @escaping (PiCLIUpdateCommandResult) -> Void
    ) {
        guard !finished else { return }
        self.completion = completion
        self.plan = plan
        self.timeout = timeout
        self.startedAt = clock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.environment = PiCLIUpdateEnvironment.environment(
            base: baseEnvironment,
            executablePath: plan.executablePath
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
            // 超时只放弃等待：不发送信号、不终止子进程；同时写一条「已放弃」记录。
            self.timedOut = true
            self.recordAbandonedAttemptLocked(reason: .timedOut)
            self.finishLocked(exitCode: nil)
        }
        timer.resume()
        self.timer = timer
    }

    /// 写一条「已放弃」记录（GitHub #62）：组件、脱敏命令摘要、开始时间、超时值、
    /// 结束时间未知（`finishedAt == nil`）与实际动作“没有发送任何信号”。
    private func recordAbandonedAttemptLocked(reason: UpdateAbandonedAttempt.Reason) {
        guard !didRecordAbandonedAttempt, let plan else { return }
        didRecordAbandonedAttempt = true
        let recordedAt = clock()
        recordAbandonedAttempt(UpdateAbandonedAttempt(
            componentKind: .piCLI,
            packageName: nil,
            reason: reason,
            commandSummary: UpdateAbandonedAttempt.makeCommandSummary(
                executablePath: plan.executablePath,
                arguments: plan.arguments,
                redactingWith: redact
            ),
            startedAt: startedAt ?? recordedAt,
            timeout: timeout,
            finishedAt: nil,
            source: plan.source,
            recordedAt: recordedAt,
            childProcessAction: .waitedWithoutSignals,
            derivedProcessesConfirmedEnded: nil
        ))
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

    private static func bounded(_ text: String, limit: Int = ProcessPiCLIUpdateCommand.outputTailLimit) -> String {
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
        drainTimer = timer
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
        let result = PiCLIUpdateCommandResult(
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

/// 子进程环境变量白名单：与 #20 的 npm 路径使用同一组允许键与兜底 PATH。
enum PiCLIUpdateEnvironment {
    static func environment(base: [String: String], executablePath: String) -> [String: String] {
        var result = PiWebUpdateEnvironment.sanitized(base)
        // PATH 合并复用 `ToolPathBuilder`（GitHub #89）：pi 自己所在目录排在最前，
        // 其余目录（登录 shell PATH、已知目录、node 目录、npm prefix/bin）由构建器
        // 给出；白名单与“只增路径、不增变量”的语义保持不变。
        let builder = ToolPathBuilder(
            appEnvironment: result,
            homeDirectory: result["HOME"] ?? ""
        )
        result["PATH"] = builder.path(prioritizing: [
            (executablePath as NSString).deletingLastPathComponent
        ])
        return result
    }

    /// 只用于展示/日志：按键排序的键名，不含值。
    static func keyDescription(_ environment: [String: String]) -> String {
        PiWebUpdateEnvironment.keyDescription(environment)
    }
}

// MARK: - 重新检测辅助

/// 执行后的聚焦版本重检测：复用 #16 识别器，只识别 Pi CLI 一个组件。
enum PiCLIUpdateRedetection {
    static func request(piPath: String?) -> ComponentInstallationDetector.ComponentDetectionRequest {
        var candidates: [String] = []
        if let piPath, !piPath.isEmpty {
            candidates.append(piPath)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi"
        ])
        return ComponentInstallationDetector.ComponentDetectionRequest(
            kind: .piCLI,
            packageName: InstallCommandManifest.piCLIPackageName,
            executableNames: ["pi"],
            candidates: candidates,
            knownVersion: nil,
            runsVersionCommand: true,
            isApplicationBundle: false,
            probesShellPath: true
        )
    }

    static func detect(
        piPath: String?,
        commandRunner: CommandRunning,
        fileSystem: DependencyFileSystemProbing = SystemDependencyFileSystemProbe(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String? = nil
    ) -> ComponentInstallation {
        let detector = ComponentInstallationDetector(
            commandRunner: commandRunner,
            fileSystem: fileSystem,
            environment: environment,
            homeDirectory: homeDirectory
        )
        return detector.detect(request(piPath: piPath))
    }
}

// MARK: - 编排

/// 一次 Pi CLI 更新尝试的结果。
enum PiCLIUpdateRunOutcome: Equatable {
    /// 没有尝试执行：设置关闭、前置条件不满足或来源只能手动更新。
    case notAttempted(reason: PiCLIUpdateRefusal, commandText: String?)
    /// 进程保护要求推迟（含执行前的最后一次复查）。
    case deferred(reason: PiCLIUpdateDeferral)
    /// 命令失败（非零退出 / 超时 / 启动失败 / 放弃等待）：旧版本保持原样。
    case commandFailed(
        plan: PiCLIUpdatePlan,
        failure: PiCLIUpdateCommandFailure,
        oldVersion: String,
        targetVersion: String?,
        outputTail: String?
    )
    /// 命令退出码 0，但重新检测的版本没有达到目标版本（未变化或不可解析）。
    case versionUnchanged(plan: PiCLIUpdatePlan, detectedVersion: String?, oldVersion: String, targetVersion: String?)
    /// 版本已经更新。
    case succeeded(plan: PiCLIUpdatePlan, oldVersion: String, newVersion: String)

    var isSucceeded: Bool {
        if case .succeeded = self { return true }
        return false
    }

    /// 失败路径的持久警告记录；成功、推迟与未尝试返回 nil。
    var warning: PiCLIUpdateWarning? {
        switch self {
        case .notAttempted, .deferred, .succeeded:
            return nil
        case .commandFailed(let plan, let failure, let oldVersion, let targetVersion, _):
            return PiCLIUpdateWarning(
                kind: .commandFailed,
                oldVersion: oldVersion,
                newVersion: plan.installedVersion,
                targetVersion: targetVersion,
                reason: "更新失败，仍在使用旧版本：\(failure.text)"
            )
        case .versionUnchanged(_, let detectedVersion, let oldVersion, let targetVersion):
            return PiCLIUpdateWarning(
                kind: .versionUnchanged,
                oldVersion: oldVersion,
                newVersion: detectedVersion,
                targetVersion: targetVersion,
                reason: "更新后验证失败，仍在使用更新前的版本：更新命令已结束，但重新检测到的版本是 \(detectedVersion ?? "未知")，未达到目标版本"
            )
        }
    }
}

/// 决策 →（执行前的最后一次进程复查）→ 执行 → 重新检测版本的顺序编排。
///
/// 全部副作用都注入（进程检查、命令执行器、版本重检测、日志、投递队列、时钟），
/// 因此 unhosted 测试可以用同步替身断言每一步，不枚举真实进程、不执行真实 `pi`、
/// 不访问网络。
final class PiCLIUpdateCoordinator {
    struct Environment {
        /// 进程检查器（生产：`PiProcessInspector`；测试：假进程表）。
        var inspectProcesses: () -> PiProcessInspection
        /// 命令执行器（生产：`ProcessPiCLIUpdateCommand`；测试：记录替身）。
        var runner: PiCLIUpdateRunning
        /// 重新检测 Pi CLI 版本（复用 #16 识别器）。
        var detectInstallation: () -> ComponentInstallation?
        /// 统一脱敏器（与日志/诊断共用同一个实例）。
        var redactor: LogRedactor
        /// 日志入口；每条消息写入前都必须经过 `redactor`。
        var log: (String) -> Void
        /// 结果投递队列（生产：主队列；测试：立即执行）。
        var deliver: (@escaping () -> Void) -> Void
        /// 命令超时（秒）。超时按失败处理，但不发送任何信号。
        var timeout: TimeInterval
        /// 共享更新事务（GitHub #23）：文件系统探针、统一历史与降级应用。
        var transaction: UpdateTransactionEnvironment
        /// 该组件成功完成一次更新后清除它的「已放弃」记录（GitHub #62）。
        /// 默认什么都不做（旧调用点保持不变）。
        var clearAbandonedAttempt: (UpdateTransactionComponent) -> Void

        init(
            inspectProcesses: @escaping () -> PiProcessInspection,
            runner: PiCLIUpdateRunning,
            detectInstallation: @escaping () -> ComponentInstallation?,
            redactor: LogRedactor,
            log: @escaping (String) -> Void,
            deliver: @escaping (@escaping () -> Void) -> Void,
            timeout: TimeInterval = PiCLIUpdateCoordinator.defaultTimeout,
            transaction: UpdateTransactionEnvironment = .disabled,
            clearAbandonedAttempt: @escaping (UpdateTransactionComponent) -> Void = { _ in }
        ) {
            self.inspectProcesses = inspectProcesses
            self.runner = runner
            self.detectInstallation = detectInstallation
            self.redactor = redactor
            self.log = log
            self.deliver = deliver
            self.timeout = timeout
            self.transaction = transaction
            self.clearAbandonedAttempt = clearAbandonedAttempt
        }
    }

    /// 默认命令超时：10 分钟。有界，但超时不会终止子进程。
    static let defaultTimeout: TimeInterval = 600

    private let environment: Environment

    init(environment: Environment) {
        self.environment = environment
    }

    /// 执行一次 Pi CLI 更新。只在决策为 `.automatic` 时才会调用执行器；执行前
    /// 再检查一次进程状态，任何非 `noProcesses` 的结果都会让本次执行被推迟。
    func run(_ input: PiCLIUpdatePlanningInput, completion: @escaping (PiCLIUpdateRunOutcome) -> Void) {
        let decision = PiCLIUpdatePlanner.decide(input)
        environment.log(environment.redactor.redact(decision.logLine(redactingWith: environment.redactor)))
        switch decision {
        case .manualOnly(let commandText, let reason):
            environment.deliver { completion(.notAttempted(reason: reason, commandText: commandText)) }
        case .unavailable(let reason):
            environment.deliver { completion(.notAttempted(reason: reason, commandText: nil)) }
        case .deferred(_, let reason):
            environment.deliver { completion(.deferred(reason: reason)) }
        case .automatic(let plan):
            runAutomatic(plan: plan, installation: input.installation, completion: completion)
        }
    }

    /// 手动路径：用户已经在确认框里看到计划、进程信息与风险说明并显式确认，
    /// 因此这里直接执行（不再做进程门控，也不会停止任何进程），执行结果同样
    /// 重新检测版本。
    func runManual(_ plan: PiCLIUpdatePlan, completion: @escaping (PiCLIUpdateRunOutcome) -> Void) {
        environment.log(environment.redactor.redact(
            "Pi CLI 手动更新：已确认执行\n"
                + plan.displayLines(redactingWith: environment.redactor).joined(separator: "\n")
        ))
        execute(plan: plan, installation: nil, completion: completion)
    }

    /// 自动路径的执行前复查 + 执行：决策与执行之间可能有新的 Pi 进程启动。
    private func runAutomatic(
        plan: PiCLIUpdatePlan,
        installation: ComponentInstallation?,
        completion: @escaping (PiCLIUpdateRunOutcome) -> Void
    ) {
        switch environment.inspectProcesses() {
        case .noProcesses:
            break
        case .runningProcesses(let records):
            let reason = PiCLIUpdateDeferral.piRunning(records)
            logOutcome("Pi CLI 自动更新：执行前复查发现运行中的 Pi 进程，已推迟（\(reason.text)）")
            environment.deliver { completion(.deferred(reason: reason)) }
            return
        case .unknown(let reason):
            let deferral = PiCLIUpdateDeferral.processStateUnknown(reason)
            logOutcome("Pi CLI 自动更新：执行前复查无法确定进程状态，已推迟（\(deferral.text)）")
            environment.deliver { completion(.deferred(reason: deferral)) }
            return
        }
        execute(plan: plan, installation: installation, completion: completion)
    }

    private func execute(
        plan: PiCLIUpdatePlan,
        installation: ComponentInstallation?,
        completion: @escaping (PiCLIUpdateRunOutcome) -> Void
    ) {
        // 共享事务（GitHub #23）：准备阶段记录更新前指纹，执行/验证/提交/降级
        // 四个阶段的结果都进入同一份更新历史。
        let component = UpdateTransactionComponent.piCLI
        let advice = UpdateManualAdviceBuilder.advice(component: component, source: plan.source)
        var journal = UpdateTransactionJournal(
            configuration: UpdateTransactionJournal.Configuration(
                component: component,
                source: plan.source,
                previousVersion: plan.installedVersion,
                targetVersion: plan.targetVersion,
                fingerprint: UpdateArtifactFingerprint.capture(
                    executablePath: installation?.executablePath ?? plan.executablePath,
                    resolvedPath: installation?.resolvedPath,
                    version: installation?.version ?? plan.installedVersion,
                    packageName: installation?.packageName ?? component.expectedPackageName,
                    probe: environment.transaction.probe
                )
            ),
            now: environment.transaction.now
        )
        journal.recordPreflight()
        environment.runner.run(plan, timeout: environment.timeout) { [weak self] result in
            guard let self else { return }
            let targetText = plan.targetVersion ?? "未知"
            if let failure = result.failure {
                let degradation = UpdateDegradationPlanner.installFailure(
                    component: component,
                    source: plan.source,
                    fingerprint: journal.configuration.fingerprint,
                    targetVersion: plan.targetVersion,
                    failureReason: failure.text
                )
                journal.recordInstallFailed(failure.text)
                journal.recordCommitNotAttempted(reason: "执行阶段失败，未启用新版本")
                journal.recordDegradation(degradation)
                self.recordTransaction(
                    journal,
                    degradation: degradation,
                    advice: advice,
                    resultingVersion: nil
                )
                self.logOutcome(
                    "Pi CLI 更新失败（\(failure.text)）：退出码 \(result.exitCode.map(String.init) ?? "无")，"
                        + "耗时 \(Self.durationText(result.duration))，当前版本 \(plan.installedVersion)，"
                        + "目标版本 \(targetText)。旧版本保持不变。"
                )
                let tail = Self.outputTailText(result, redactingWith: self.environment.redactor)
                if let tail {
                    self.logOutcome("Pi CLI 更新命令输出片段（已脱敏）：\(tail)")
                }
                let outcome = PiCLIUpdateRunOutcome.commandFailed(
                    plan: plan,
                    failure: failure,
                    oldVersion: plan.installedVersion,
                    targetVersion: plan.targetVersion,
                    outputTail: tail
                )
                self.environment.deliver { completion(outcome) }
                return
            }

            journal.recordInstallSucceeded()
            let detected = self.environment.detectInstallation()
            let detectedVersion = detected?.version
            let verificationInput = UpdateVerificationInput(
                component: .piCLI,
                packageName: component.expectedPackageName,
                previousVersion: plan.installedVersion,
                targetVersion: plan.targetVersion,
                detectedVersion: detectedVersion,
                detectedPackageName: detected?.packageName,
                detectedExecutablePath: detected?.executablePath,
                detectedResolvedPath: detected?.resolvedPath,
                detectedPackageJSONPath: detected?.packageJSONPath,
                fingerprint: journal.configuration.fingerprint
            )
            let report = UpdateVerifier.verify(
                verificationInput,
                probe: self.environment.transaction.probe
            )
            guard journal.recordVerification(report, detectedVersion: detectedVersion) else {
                let degradation = UpdateDegradationPlanner.verificationFailure(
                    component: component,
                    source: plan.source,
                    fingerprint: journal.configuration.fingerprint,
                    newVersion: detectedVersion,
                    newResolvedPath: detected?.resolvedPath ?? detected?.executablePath,
                    failureReason: report.failureReason ?? "验证未通过",
                    probe: self.environment.transaction.probe
                )
                journal.recordCommitNotAttempted(reason: "验证阶段失败，未启用新版本")
                journal.recordDegradation(degradation)
                self.environment.transaction.applyDegradation(degradation)
                self.recordTransaction(
                    journal,
                    degradation: degradation,
                    advice: advice,
                    resultingVersion: detectedVersion
                )
                self.logOutcome(
                    "Pi CLI 更新未通过版本验证：命令退出码 0，但重新检测到的版本是 "
                        + "\(detectedVersion ?? "未知")，目标版本 \(targetText)。"
                        + "旧版本语义保持不变；应用不会自动重试无上限，也不声称更新成功。"
                )
                let outcome = PiCLIUpdateRunOutcome.versionUnchanged(
                    plan: plan,
                    detectedVersion: detectedVersion,
                    oldVersion: plan.installedVersion,
                    targetVersion: plan.targetVersion
                )
                self.environment.deliver { completion(outcome) }
                return
            }

            let newVersion = detectedVersion ?? plan.targetVersion ?? plan.installedVersion
            journal.recordDegradationNotNeeded()
            journal.recordCommit(version: newVersion)
            self.recordTransaction(
                journal,
                degradation: nil,
                advice: advice,
                resultingVersion: newVersion
            )
            // 该组件成功完成了一次更新：清除它的「已放弃」记录（GitHub #62）。
            self.environment.clearAbandonedAttempt(component)
            self.logOutcome("Pi CLI 更新完成：\(plan.installedVersion) → \(newVersion)，耗时 \(Self.durationText(result.duration))。")
            let outcome = PiCLIUpdateRunOutcome.succeeded(
                plan: plan,
                oldVersion: plan.installedVersion,
                newVersion: newVersion
            )
            self.environment.deliver { completion(outcome) }
        }
    }

    /// 记录统一更新历史（GitHub #23）并写一条脱敏日志。
    private func recordTransaction(
        _ journal: UpdateTransactionJournal,
        degradation: UpdateDegradationPlan?,
        advice: UpdateManualAdvice,
        resultingVersion: String?
    ) {
        let entry = journal.historyEntry(
            degradation: degradation,
            advice: advice,
            resultingVersion: resultingVersion
        )
        environment.transaction.recordHistory(entry)
        logOutcome("更新历史：\(UpdateHistoryPresenter.lines(for: entry).joined(separator: " "))")
    }

    private func logOutcome(_ message: String) {
        environment.log(environment.redactor.redact(message))
    }

    /// 标准输出/错误尾部：合并、脱敏、折叠空白；没有输出时返回 nil。
    static func outputTailText(_ result: PiCLIUpdateCommandResult, redactingWith redactor: LogRedactor) -> String? {
        var parts: [String] = []
        if let stdout = result.stdoutTail, !stdout.isEmpty { parts.append("标准输出：\(stdout)") }
        if let stderr = result.stderrTail, !stderr.isEmpty { parts.append("标准错误：\(stderr)") }
        guard !parts.isEmpty else { return nil }
        let joined = redactor.redact(parts.joined(separator: "\n"))
        let collapsed = joined.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    static func durationText(_ duration: TimeInterval) -> String {
        String(format: "%.1f 秒", max(0, duration))
    }
}

// MARK: - 手动更新的确认文案

/// 手动更新确认框的纯文本构造（诊断页与确认框共用；不含任何未脱敏内容）。
enum PiCLIManualUpdateConfirmation {
    static func text(
        plan: PiCLIUpdatePlan?,
        commandText: String?,
        inspection: PiProcessInspection,
        abandonedAttempt: UpdateAbandonedAttempt? = nil,
        redactingWith redactor: LogRedactor
    ) -> String {
        var lines: [String] = []
        if let plan {
            lines.append(contentsOf: plan.displayLines(redactingWith: redactor))
        } else if let commandText {
            lines.append("将执行的命令：\(redactor.redact(commandText))")
        } else {
            lines.append("没有可用的 Pi CLI 更新命令。")
        }
        if let abandonedAttempt {
            lines.append("")
            lines.append(UpdateAbandonedAttemptPresenter.confirmationBlock(for: abandonedAttempt))
        }
        lines.append("")
        lines.append("当前 Pi 进程状态：\(inspection.statusText)")
        for record in inspection.records {
            lines.append(contentsOf: record.displayLines)
            lines.append("")
        }
        lines.append("风险说明：更新会替换 Pi CLI 的可执行文件。")
        lines.append("· 正在进行或稍后恢复的 Pi 会话可能读到更新后的文件，行为可能与会话开始时不同；")
        lines.append("· 应用不会结束、暂停或接管任何 Pi 进程与会话，也不会向它们发送任何信号；")
        lines.append("· 更新是否成功取决于上游命令本身，应用只负责执行并重新检测版本，不保证成功，也不做回滚。")
        return lines.joined(separator: "\n")
    }
}

// MARK: - 状态展示

/// 诊断页/设置页用的状态文本（纯函数；输入都是已经脱敏的值）。
/// `inspection` 为 nil 表示本次运行还没有做过进程检查（smoke 启动不会枚举真实
/// 进程），此时只展示设置与手动入口，不展示决策结果。
enum PiCLIUpdateStatusPresenter {
    static func lines(
        preferences: UpdateCheckPreferences,
        inspection: PiProcessInspection?,
        decision: PiCLIUpdateDecision?,
        warning: PiCLIUpdateWarning?
    ) -> [String] {
        var lines: [String] = []
        lines.append("Pi CLI 进程保护：\(inspection?.statusText ?? "尚未检查（本次运行还没有枚举本机进程）")")
        lines.append(
            "Pi CLI 启动前自动更新："
                + (preferences.autoUpdatePiBeforeLaunch ? "已开启" : "已关闭")
                + (decision.map { "；本次决策：\($0.statusLine)" } ?? "")
        )
        if let deferral = decision?.deferral {
            lines.append("推迟原因：\(deferral.text)")
        }
        if let warning {
            lines.append(warning.text)
        }
        lines.append("手动更新入口：菜单“服务 → 更新检查设置 → 立即更新 Pi CLI…”（执行前显示进程信息并要求确认）")
        return lines
    }
}

// MARK: - 持久警告

/// 一次失败的 Pi CLI 更新的持久记录。
///
/// 只保存类别、旧/新/目标版本、固定原因文案与时间：不含路径、环境变量值、
/// 凭据或子进程输出。警告在界面与诊断文本里持续显示，直到下一次成功更新。
struct PiCLIUpdateWarning: Equatable {
    enum Kind: String, Equatable {
        case commandFailed
        case versionUnchanged
    }

    var kind: Kind
    var oldVersion: String?
    var newVersion: String?
    var targetVersion: String?
    var reason: String
    var recordedAt: Date

    init(
        kind: Kind,
        oldVersion: String? = nil,
        newVersion: String? = nil,
        targetVersion: String? = nil,
        reason: String,
        recordedAt: Date = Date()
    ) {
        self.kind = kind
        self.oldVersion = oldVersion
        self.newVersion = newVersion
        self.targetVersion = targetVersion
        self.reason = reason
        self.recordedAt = recordedAt
    }

    /// 用户可见的持久警告：明确说明旧版本语义保持不变、没有回滚这回事。
    var text: String {
        var parts: [String] = []
        parts.append("Pi CLI 更新未完成：\(reason)。")
        parts.append("当前版本：\(oldVersion ?? "未知")；目标版本：\(targetVersion ?? "未知")"
            + (newVersion.map { "；重新检测到的版本：\($0)" } ?? "") + "。")
        parts.append("旧版本语义保持不变：应用不会自动回滚已替换的文件，也不声称更新成功；"
            + "请查看日志与诊断结果后手动处理。")
        return parts.joined(separator: " ")
    }

    /// 菜单/状态行用的单行摘要。
    var shortText: String {
        "Pi CLI 更新告警：\(reason)（当前 \(oldVersion ?? "未知") → 目标 \(targetVersion ?? "未知")）"
    }
}

/// 持久警告的 UserDefaults 存取（只经 `AppConfiguration` 调用）。
enum PiCLIUpdateWarningStore {
    static func load(from defaults: UserDefaults) -> PiCLIUpdateWarning? {
        guard let kindText = defaults.string(forKey: UpdateSettingKeys.piCLIUpdateWarningKind),
              let kind = PiCLIUpdateWarning.Kind(rawValue: kindText) else { return nil }
        guard let reason = defaults.string(forKey: UpdateSettingKeys.piCLIUpdateWarningReason),
              !reason.isEmpty else { return nil }
        let recordedAt = UpdateIgnoredVersions.timestamp(
            defaults.object(forKey: UpdateSettingKeys.piCLIUpdateWarningRecordedAt)
        ) ?? Date(timeIntervalSince1970: 0)
        return PiCLIUpdateWarning(
            kind: kind,
            oldVersion: version(defaults, UpdateSettingKeys.piCLIUpdateWarningOldVersion),
            newVersion: version(defaults, UpdateSettingKeys.piCLIUpdateWarningNewVersion),
            targetVersion: version(defaults, UpdateSettingKeys.piCLIUpdateWarningTargetVersion),
            reason: reason,
            recordedAt: recordedAt
        )
    }

    static func save(_ warning: PiCLIUpdateWarning?, to defaults: UserDefaults) {
        guard let warning else {
            for key in UpdateSettingKeys.allPiCLIUpdateWarningKeys {
                defaults.removeObject(forKey: key)
            }
            return
        }
        defaults.set(warning.kind.rawValue, forKey: UpdateSettingKeys.piCLIUpdateWarningKind)
        defaults.set(warning.reason, forKey: UpdateSettingKeys.piCLIUpdateWarningReason)
        defaults.set(warning.recordedAt.timeIntervalSince1970, forKey: UpdateSettingKeys.piCLIUpdateWarningRecordedAt)
        setVersion(warning.oldVersion, key: UpdateSettingKeys.piCLIUpdateWarningOldVersion, defaults: defaults)
        setVersion(warning.newVersion, key: UpdateSettingKeys.piCLIUpdateWarningNewVersion, defaults: defaults)
        setVersion(warning.targetVersion, key: UpdateSettingKeys.piCLIUpdateWarningTargetVersion, defaults: defaults)
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
