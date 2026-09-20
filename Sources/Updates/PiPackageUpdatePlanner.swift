/// Pure per-package update decision logic and plan sets.

import Foundation

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
    /// 计划就绪，但同一包存在未清除的「已放弃」记录：不允许自动/常规执行。
    /// 确认框必须先展示这条记录，用户显式确认后才执行一次（GitHub #62）。
    case awaitingAbandonedConfirmation(plan: PiPackageUpdatePlan, attempt: UpdateAbandonedAttempt)
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
        case .awaitingAbandonedConfirmation(let plan, _):
            return plan.packageName
        }
    }

    /// 可以执行的计划（已经通过全部前置条件与进程保护）。
    var executablePlan: PiPackageUpdatePlan? {
        if case .awaitingConfirmation(let plan) = self { return plan }
        return nil
    }

    /// 需要“先看到「已放弃」记录再确认”的计划；未显式确认前不执行。
    var abandonedConfirmationPlan: PiPackageUpdatePlan? {
        if case .awaitingAbandonedConfirmation(let plan, _) = self { return plan }
        return nil
    }

    /// 任何计划（包含被进程保护或「已放弃」记录拒绝的），用于展示与诊断。
    var anyPlan: PiPackageUpdatePlan? {
        switch self {
        case .awaitingConfirmation(let plan): return plan
        case .awaitingAbandonedConfirmation(let plan, _): return plan
        case .executeBlocked(let plan, _): return plan
        default: return nil
        }
    }

    var refusalReason: PiPackageUpdateRefusal? {
        switch self {
        case .executeBlocked(_, let reason), .manualOnly(_, let reason), .unavailable(_, let reason):
            return reason
        case .awaitingAbandonedConfirmation(_, let attempt):
            return .abandonedAttemptPending(attempt)
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
        case .awaitingAbandonedConfirmation(let plan, let attempt):
            return "Pi 扩展包更新（\(plan.packageName)）：存在未清除的「已放弃」记录，需要用户看完记录后确认（允许自动执行：否）\n"
                + UpdateAbandonedAttemptPresenter.lines(for: attempt).joined(separator: "\n")
                + "\n" + plan.displayLines(redactingWith: redactor).joined(separator: "\n")
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
    /// 本次判定用到的「已放弃」记录（GitHub #62），用于确认框/诊断展示。
    var abandonedAttempts: [UpdateAbandonedAttempt] = []

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

    /// 需要“先看到「已放弃」记录再确认”的计划；与可执行计划一样需要显式确认，
    /// 但确认框必须先展示记录（GitHub #62）。
    var abandonedConfirmationPlans: [PiPackageUpdatePlan] {
        decisions.compactMap(\.abandonedConfirmationPlan)
    }

    /// 全部需要用户确认的计划（常规确认 + 先看「已放弃」记录的确认）。
    var confirmationPlans: [PiPackageUpdatePlan] {
        executablePlans + abandonedConfirmationPlans
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
    /// 顺序：策略 → 包名 → 检查结论 → 目标版本 → 来源 → 命令安全 → 进程保护
    /// →「已放弃」记录。后两项只让“已经就绪的计划”变成需要确认/拒绝的状态，
    /// 不会掩盖其它拒绝原因。
    ///
    /// 进程保护先于「已放弃」记录（GitHub #107 / W2B B-12）：检测到运行中的 Pi
    /// 进程时执行阶段必然拒绝，先要求用户确认「已放弃」记录只会让人确认一个注定
    /// 失败的操作；先给出进程状态，等进程退出后同一条记录仍会要求确认。
    static func decide(
        _ candidate: PiPackageCandidate,
        check: PiPackageCheckOutcome?,
        policy: PiPackageUpdatePolicy,
        processes: PiProcessInspection,
        piExecutablePath: String?,
        abandonedAttempt: UpdateAbandonedAttempt? = nil
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
        // 硬前置（GitHub #59 / alpha.3 安全审查 A-1）：可点的执行入口只对本次
        // 运行刚从白名单主机取得的结果开放。“检查并通知”不受影响，仍然只提示；
        // 缓存回退与没有结果连执行入口都不提供，只保留手动命令文本。
        guard check.origin.isEligibleForAutomaticInstall else {
            return .manualOnly(
                notice(for: candidate, check: check, piExecutablePath: piExecutablePath),
                reason: .targetNotFromNetwork(origin: check.origin, cacheWrittenAt: check.cacheWrittenAt)
            )
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
        // GitHub #107（W2B B-12）：这一判定在「已放弃」记录之前——被进程挡住的
        // 计划不该再要求用户确认一条记录（执行前的复查同样以进程态优先）。
        switch processes {
        case .noProcesses:
            break
        case .runningProcesses(let records):
            return .executeBlocked(plan: plan, reason: .piRunning(records))
        case .unknown(let reason):
            return .executeBlocked(plan: plan, reason: .processStateUnknown(reason))
        }
        // 「已放弃」记录硬前置（GitHub #62 / alpha.3 安全审查 A-6、A-7）：同一包
        // 存在未清除的记录时不允许自动/常规执行；确认框必须先展示这条记录，
        // 用户在看过之后显式确认才执行一次。
        if let abandonedAttempt {
            return .awaitingAbandonedConfirmation(plan: plan, attempt: abandonedAttempt)
        }
        return .awaitingConfirmation(plan)
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
                piExecutablePath: input.piExecutablePath,
                abandonedAttempt: UpdateAbandonedAttemptGate.blockingAttempt(
                    for: UpdateTransactionComponent.piPackage(candidate.packageName),
                    in: input.abandonedAttempts
                )
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
            extraRefusals: orphanChecks,
            abandonedAttempts: input.abandonedAttempts
        )
    }

    /// 带策略门控的规划：策略为“关闭”（或不属于扩展包允许集合）时**不调用**
    /// `check`，因此关闭策略下检查次数恒为 0。
    static func plan(
        policy: UpdateCheckPolicy,
        packages: [PiPackageCandidate],
        processes: PiProcessInspection = .unknown(.enumerationFailed),
        piExecutablePath: String?,
        abandonedAttempts: [UpdateAbandonedAttempt] = [],
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
            piExecutablePath: piExecutablePath,
            abandonedAttempts: abandonedAttempts
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
        UpdateVerifier.versionReached(detected: detected, old: old, target: target)
    }
}
