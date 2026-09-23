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

/// Pi CLI update settings, refusal/deferral reasons, plans and decisions.

extension UpdateCheckPreferences {
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
    /// 同一时间只允许一次更新事务：上一次还没有结束（安装之后的版本重检测可能
    /// 仍在进行，或上一个子进程退出尚未确认）。
    case updateAlreadyInProgress

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
        case .updateAlreadyInProgress:
            return "上一次 Pi CLI 更新尚未结束（可能仍在重新检测版本，或上一个子进程退出尚未确认），请稍后再试"
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
    ///
    /// 信任模型（F3，GitHub #121）：应用不固定可执行文件的位置，也不校验它的签名或哈希；
    /// `PATH` 目录本身就是信任边界——能改写 `PATH` 里内容的人，本来也能直接决定跑哪个程序，
    /// 与该用户在该 `PATH` 下亲手执行 `pi-web` 等价。这道校验只负责排除相对路径、`.`/`..`
    /// 段、`//` 与 shell 元字符，避免“在错误的位置、以错误的方式”启动；解析到的路径会写进
    /// `executablePath` 并展示给用户，用户可以在更新前看到到底要跑哪个文件。
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
