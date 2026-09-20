/// Pi CLI update run outcomes and coordinator orchestration.

import Foundation

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
                // B-6：命令失败不证明旧文件没被改动，不写“仍在使用旧版本”这类没有探针支撑的断言。
                reason: "更新失败，没有执行任何回滚动作：\(failure.text)"
            )
        case .versionUnchanged(_, let detectedVersion, let oldVersion, let targetVersion):
            return PiCLIUpdateWarning(
                kind: .versionUnchanged,
                oldVersion: oldVersion,
                newVersion: detectedVersion,
                targetVersion: targetVersion,
                // L-2：重新检测没有给出可用结果时不能既断言“仍在使用更新前的版本”，又说“检测到未知版本”；
                // 前一句需要探针证据。nil 时改为只报“未能确认”。
                reason: detectedVersion.map { detected in
                    "更新后验证失败，仍在使用更新前的版本：更新命令已结束，但重新检测到的版本是 \(detected)，未达到目标版本"
                } ?? "更新后验证失败：更新命令已结束，但重新检测没有给出可用的版本结果，因此无法判断是否达到目标版本"
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

    /// 整轮更新事务是否在进行中：命令执行、重新检测版本与更新历史都算（W3B F2：
    /// 命令进程一结束就放行，事务尾段还能再叠加一次）。标志由协调器自己持有，
    /// 组件之间互不影响（W3B F3）。
    private let transactionLock = NSLock()
    private var transactionInFlight = false

    /// 事务级「更新进行中」：只在 `execute` 的事务期间为真。
    var isRunning: Bool {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        return transactionInFlight
    }

    /// 是否有一次更新正在进行（供 UI 门控：手动入口与菜单项）。既覆盖整轮事务
    /// （执行 + 重检测，W3B F2），也覆盖执行器自己的「已放弃等待、子进程退出
    /// 未确认」窗口。
    var isUpdateInProgress: Bool { isRunning || environment.runner.isRunning }

    private func beginTransaction() {
        transactionLock.lock()
        transactionInFlight = true
        transactionLock.unlock()
    }

    private func endTransaction() {
        transactionLock.lock()
        transactionInFlight = false
        transactionLock.unlock()
    }

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
        completion originalCompletion: @escaping (PiCLIUpdateRunOutcome) -> Void
    ) {
        // 同一时间只允许一次更新事务（W2A A-2/A-4 + W3B F2）：已经有一次命令或
        // 事务尾段在跑时直接返回「未执行」，给出可见文案，而不是排队等第二次回调，
        // 也不启动第二个 `pi update --self`。
        guard !isUpdateInProgress else {
            logOutcome("Pi CLI 更新跳过：\(PiCLIUpdateRefusal.updateAlreadyInProgress.text)")
            environment.deliver {
                originalCompletion(.notAttempted(reason: .updateAlreadyInProgress, commandText: nil))
            }
            return
        }
        // 事务级门控（W3B F2）：包装一次完成回调，事务里的每个结束分支（含执行
        // 器竞态拒绝）都会先解除门控再投递结果。
        beginTransaction()
        let completion: (PiCLIUpdateRunOutcome) -> Void = { [weak self] outcome in
            self?.endTransaction()
            originalCompletion(outcome)
        }
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
            // 与执行器的门控竞争失败：这一次没有启动子进程，不算更新失败，也不写
            // 持久告警（W2A A-1 同型：拒绝必须是可见的「未执行」，不是失败）。
            if result.failure == .alreadyRunning {
                logOutcome("Pi CLI 更新跳过（\(PiCLIUpdateRefusal.updateAlreadyInProgress.text)）。")
                environment.deliver {
                    completion(.notAttempted(reason: .updateAlreadyInProgress, commandText: nil))
                }
                return
            }
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
                        + "目标版本 \(targetText)。本次没有执行任何回滚动作。"
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
                        + UpdateWarningText.oldVersionClaimText(detectedVersion: detectedVersion)
                        + "应用不会自动重试无上限，也不声称更新成功。"
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
