/// Pi package run outcomes, batch records and coordinator orchestration.

import Foundation

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
    /// 命令失败（非零退出 / 超时 / 启动失败 / 放弃等待）：不断言文件状态，只记命令事实与「没有回滚动作」。
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
                // B-6：命令失败不证明旧文件没被改动，不写“仍在使用旧版本”这类没有探针支撑的断言。
                reason: "更新失败，没有执行任何回滚动作：\(failure.text)"
            )
        case .versionUnchanged(let plan, let detectedVersion, _):
            return PiPackageUpdateWarning(
                kind: .versionUnchanged,
                packageName: plan.packageName,
                oldVersion: plan.installedVersion,
                newVersion: detectedVersion,
                targetVersion: plan.targetVersion,
                // L-2：与 CLI / Pi Web 同一处理：nil 时不作版本状态断言。
                reason: detectedVersion.map { detected in
                    "更新后验证失败，仍在使用更新前的版本：更新命令已结束，但重新检测到的版本是 \(detected)，未达到目标版本"
                } ?? "更新后验证失败：更新命令已结束，但重新检测没有给出可用的版本结果，因此无法判断是否达到目标版本"
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
                + "当前版本 \(plan.installedVersion)，目标版本 \(plan.targetVersion ?? "未知")。本次没有执行任何回滚动作。"
        case .versionUnchanged(let plan, let detected, let record):
            return "Pi 扩展包更新（\(plan.packageName)）未通过版本验证：命令退出码 0、耗时 \(record.durationText)，"
                + "但重新检测到的版本是 \(detected ?? "未知")，目标版本 \(plan.targetVersion ?? "未知")。"
                + UpdateWarningText.oldVersionClaimText(detectedVersion: detected)
                + "应用不会自动重试无上限，也不声称更新成功。"
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
        /// 共享更新事务（GitHub #23）：文件系统探针、统一历史与降级应用。
        var transaction: UpdateTransactionEnvironment
        /// 该组件成功完成一次更新后清除它的「已放弃」记录（GitHub #62）。
        /// 默认什么都不做（旧调用点保持不变）。
        var clearAbandonedAttempt: (UpdateTransactionComponent) -> Void

        init(
            inspectProcesses: @escaping () -> PiProcessInspection,
            runner: PiPackageUpdateRunning,
            detectPackageVersion: @escaping (String) -> String?,
            redactor: LogRedactor,
            log: @escaping (String) -> Void,
            deliver: @escaping (@escaping () -> Void) -> Void,
            timeout: TimeInterval = PiPackageUpdateCoordinator.defaultTimeout,
            transaction: UpdateTransactionEnvironment = .disabled,
            clearAbandonedAttempt: @escaping (UpdateTransactionComponent) -> Void = { _ in }
        ) {
            self.inspectProcesses = inspectProcesses
            self.runner = runner
            self.detectPackageVersion = detectPackageVersion
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
        // 共享事务（GitHub #23）：准备阶段记录指纹。扩展包没有独立可执行文件，
        // 只记录包名与版本（能验证到哪一层就写到哪一层），因此回滚证据不足时
        // 降级判定会如实给出“无法自动回滚”。
        let component = UpdateTransactionComponent.piPackage(plan.packageName)
        let advice = UpdateManualAdviceBuilder.advice(component: component, source: plan.source)
        var journal = UpdateTransactionJournal(
            configuration: UpdateTransactionJournal.Configuration(
                component: component,
                source: plan.source,
                previousVersion: plan.installedVersion,
                targetVersion: plan.targetVersion,
                fingerprint: UpdateArtifactFingerprint.versionOnly(
                    version: plan.installedVersion,
                    packageName: plan.packageName
                )
            ),
            now: environment.transaction.now
        )
        journal.recordPreflight()
        environment.runner.run(plan, timeout: environment.timeout) { [weak self] result in
            guard let self else { return }
            // B-1：执行器拒绝执行时（同一实例上还有一次运行没结束）也必须回调。
            // 这里如实记录「未执行」：不写安装失败，也不断言旧版本是否还在原位。
            if result.notAttempted {
                let reason = result.awaitingAbandonedChildExit
                    ? PiPackageUpdateRefusal.executorBusyAwaitingAbandonedChildExit
                    : PiPackageUpdateRefusal.executorBusy
                self.logOutcome(
                    "Pi 扩展包更新（\(plan.packageName)）：未执行（\(reason.text)）；"
                        + "当前版本 \(plan.installedVersion)，目标版本 \(plan.targetVersion ?? "未知")。"
                )
                completion(.notAttempted(packageName: plan.packageName, reason: reason))
                return
            }
            let record = PiPackageUpdateCommandRecord(
                exitCode: result.exitCode,
                duration: result.duration,
                failure: result.failure
            )
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
                // GitHub #107（W2B B-13）：与验证失败分支走同一条降级应用路径。
                // 扩展包没有可重新指向的可执行文件，生产注入的 applyDegradation
                // 对这个 kind 是 no-op（只改配置/重检测路径的组件才有实际动作），
                // 但仍要调用：三条失败路径的降级语义必须一致，测试替身按调用断言。
                self.environment.transaction.applyDegradation(degradation)
                let tail = Self.outputTailText(result, redactingWith: self.environment.redactor)
                self.recordTransaction(
                    journal,
                    degradation: degradation,
                    advice: advice,
                    resultingVersion: nil
                )
                self.logOutcome(
                    "Pi 扩展包更新（\(plan.packageName)）失败：\(failure.text)；退出码 "
                        + "\(result.exitCode.map(String.init) ?? "无")，耗时 \(record.durationText)，"
                        + "当前版本 \(plan.installedVersion)，目标版本 \(plan.targetVersion ?? "未知")。"
                        + "应用不声称更新成功，也未核对更新前的文件是否被改动。"
                )
                if let tail {
                    self.logOutcome("Pi 扩展包更新命令输出片段（已脱敏）：\(tail)")
                }
                completion(.commandFailed(plan: plan, failure: failure, record: record, outputTail: tail))
                return
            }
            journal.recordInstallSucceeded()
            let detected = self.environment.detectPackageVersion(plan.packageName)
            let verificationInput = UpdateVerificationInput(
                component: .piPackage,
                packageName: plan.packageName,
                previousVersion: plan.installedVersion,
                targetVersion: plan.targetVersion,
                detectedVersion: detected,
                // B-3：不能用计划里的期望包名冒充「检测到的包名」——那会让身份检查
                // 同义反复地恒真，却把未验证的结论写进历史。传 nil，如实记为「未验证」。
                detectedPackageName: nil,
                detectedExecutablePath: nil,
                detectedResolvedPath: nil,
                detectedPackageJSONPath: nil,
                fingerprint: journal.configuration.fingerprint
            )
            let report = UpdateVerifier.verify(
                verificationInput,
                probe: self.environment.transaction.probe
            )
            guard journal.recordVerification(report, detectedVersion: detected) else {
                let degradation = UpdateDegradationPlanner.verificationFailure(
                    component: component,
                    source: plan.source,
                    fingerprint: journal.configuration.fingerprint,
                    newVersion: detected,
                    newResolvedPath: nil,
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
                    resultingVersion: detected
                )
                self.logOutcome(
                    "Pi 扩展包更新（\(plan.packageName)）未通过版本验证：命令退出码 0，但重新检测到的版本是 "
                        + "\(detected ?? "未知")，目标版本 \(plan.targetVersion ?? "未知")。"
                        + UpdateWarningText.oldVersionClaimText(detectedVersion: detected)
                        + "应用不会自动重试无上限，也不声称更新成功。"
                )
                completion(.versionUnchanged(plan: plan, detectedVersion: detected, record: record))
                return
            }
            let newVersion = detected ?? plan.targetVersion ?? plan.installedVersion
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
            self.logOutcome(
                "Pi 扩展包更新（\(plan.packageName)）完成：\(plan.installedVersion) → \(newVersion)，耗时 \(record.durationText)。"
            )
            completion(.succeeded(plan: plan, newVersion: newVersion, record: record))
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
    /// `abandonedAttempts` 是该批计划涉及的「已放弃」记录（GitHub #62）：
    /// 确认前必须先展示，确认后才执行一次。
    static func text(
        plans: [PiPackageUpdatePlan],
        inspection: PiProcessInspection,
        abandonedAttempts: [UpdateAbandonedAttempt] = [],
        redactingWith redactor: LogRedactor
    ) -> String {
        var lines: [String] = []
        lines.append("共 \(plans.count) 个扩展包待更新。执行前会再次检查 Pi 进程；"
            + "检测到运行中的 Pi 进程或状态不确定时不会执行。")
        for attempt in abandonedAttempts {
            lines.append("")
            lines.append(UpdateAbandonedAttemptPresenter.confirmationBlock(for: attempt))
        }
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
