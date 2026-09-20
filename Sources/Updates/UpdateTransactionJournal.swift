/// Phase-by-phase transaction journal records.

import Foundation

// MARK: - 事务阶段记录器

/// 一次更新尝试的阶段记录器。协调器在每个阶段调用对应方法；这里只记录结果，
/// 不做任何副作用。`completedPhase` 是最后一个明确成功的阶段。
struct UpdateTransactionJournal {
    struct Configuration: Equatable {
        var component: UpdateTransactionComponent
        var source: InstallSource
        /// 更新前版本（来自 preflight 指纹）。
        var previousVersion: String?
        /// 目标版本；手动路径可以为 nil。
        var targetVersion: String?
        var fingerprint: UpdateArtifactFingerprint
    }

    let configuration: Configuration
    private(set) var phases: [UpdateTransactionPhaseResult] = []
    /// 检查通过后重新检测到的版本（用于历史的“到版本”）。
    private(set) var verifiedVersion: String?

    private let now: () -> Date

    init(configuration: Configuration, now: @escaping () -> Date = Date.init) {
        self.configuration = configuration
        self.now = now
    }

    /// 准备阶段：记录更新前指纹。返回指纹供后续验证使用。
    @discardableResult
    mutating func recordPreflight() -> UpdateArtifactFingerprint {
        record(
            .preflight,
            status: .succeeded,
            reason: "已记录更新前指纹（\(configuration.fingerprint.summaryLine)）；不读取凭据，不做签名验证"
        )
        return configuration.fingerprint
    }

    mutating func recordInstallSucceeded() {
        record(.install, status: .succeeded, reason: "安装命令成功结束（退出码 0）")
    }

    mutating func recordInstallFailed(_ reason: String) {
        record(.install, status: .failed, reason: reason)
    }

    /// 验证阶段：报告里没有任何失败且版本检查通过时记为成功。
    /// `detectedVersion` 是重新检测到的版本（只接受可解析的语义化版本）。
    /// 同一事务里已有一条验证记录时原地更新（例如健康检查结果补齐后重算），
    /// 不会在历史里出现两条 verify。
    @discardableResult
    mutating func recordVerification(_ report: UpdateVerificationReport, detectedVersion: String?) -> Bool {
        let passed = report.isVerified
        if passed, let detectedVersion, let version = SemanticVersion(detectedVersion),
           version.description == detectedVersion {
            verifiedVersion = detectedVersion
        }
        let reason: String
        if passed {
            // 只写“实际检查到什么”的事实句，不使用可能被读成“来源可信”的措辞。
            let facts = report.checks.map(\.factText).joined(separator: "；")
            reason = "检查结果（未做代码签名或来源验证）：" + facts
        } else if let failure = report.failureReason {
            reason = "检查未通过：\(failure)"
        } else {
            reason = "检查未通过"
        }
        let result = UpdateTransactionPhaseResult(
            phase: .verify,
            status: passed ? .succeeded : .failed,
            reason: reason,
            recordedAt: now()
        )
        if let index = phases.firstIndex(where: { $0.phase == .verify }) {
            phases[index] = result
        } else {
            phases.append(result)
        }
        return passed
    }

    mutating func recordCommit(version: String?) {
        verifiedVersion = version ?? verifiedVersion
        record(.commit, status: .succeeded, reason: "已启用新版本 \(version ?? verifiedVersion ?? "未知")；不做自动卸载")
    }

    /// 提交未执行（流程在验证前结束）。
    mutating func recordCommitNotAttempted(reason: String) {
        record(.commit, status: .notAttempted, reason: reason)
    }

    /// 降级阶段（GitHub #106）：`.notNeeded` 记为跳过；只有真的执行了恢复动作
    /// （`degradedToPreviousArtifact`）才算 `.applied`。安装失败、文件未变化只是
    /// 记录结论，无法回滚只是报告，都不能显示成“成功”。
    mutating func recordDegradation(_ plan: UpdateDegradationPlan) {
        let status: UpdateTransactionPhaseStatus
        switch plan.kind {
        case .notNeeded:
            status = .skipped
        case .degradedToPreviousArtifact:
            status = .applied
        case .stillUsingPreviousArtifact, .installFailedKeepingPreviousVersion:
            status = .recordedOnly
        case .cannotAutomaticallyRollback:
            status = .notPossible
        }
        record(.degrade, status: status, reason: plan.reason)
    }

    /// 提交前的降级阶段：没有失败、无需降级。明确记录“跳过”，让历史里
    /// 五个阶段都有明确结果。
    mutating func recordDegradationNotNeeded() {
        record(.degrade, status: .skipped, reason: "版本与目标一致并准备提交，无需降级/回滚")
    }

    /// 最后一个明确成功的阶段。降级是失败后的恢复动作，不算“完成阶段”。
    var completedPhase: UpdateTransactionPhase? {
        let progressPhases: [UpdateTransactionPhase] = [.preflight, .install, .verify, .commit]
        return progressPhases.last { phase in
            phases.contains { $0.phase == phase && $0.status == .succeeded }
        }
    }

    /// 最后一个被记录（有明确结果）的阶段。
    var lastRecordedPhase: UpdateTransactionPhase? {
        phases.last?.phase
    }

    var firstFailureReason: String? {
        phases.first { $0.status == .failed }?.reason
    }

    /// 汇总成一条统一更新历史。
    func historyEntry(
        degradation: UpdateDegradationPlan?,
        advice: UpdateManualAdvice,
        resultingVersion: String? = nil,
        recordedAt: Date? = nil
    ) -> UpdateHistoryEntry {
        UpdateHistoryEntry(
            recordedAt: recordedAt ?? now(),
            component: configuration.component,
            source: configuration.source,
            fromVersion: configuration.previousVersion,
            toVersion: resultingVersion ?? verifiedVersion,
            completedPhase: completedPhase,
            terminationPhase: lastRecordedPhase,
            phases: phases,
            degradationKind: degradation?.kind,
            failureReason: firstFailureReason,
            manualCommandText: degradation?.manualAdvice.commandText ?? advice.commandText,
            manualGuidanceText: degradation?.manualAdvice.guidanceText ?? advice.guidanceText,
            rollbackDescription: degradation.map(UpdateHistoryDescription.rollbackDescription(for:)),
            evidenceLevel: degradation?.evidence?.level ?? configuration.fingerprint.evidenceLevel,
            evidenceNote: degradation?.evidence?.summaryText ?? configuration.fingerprint.evidenceSummaryLine
        )
    }

    private mutating func record(
        _ phase: UpdateTransactionPhase,
        status: UpdateTransactionPhaseStatus,
        reason: String
    ) {
        phases.append(UpdateTransactionPhaseResult(
            phase: phase,
            status: status,
            reason: reason,
            recordedAt: now()
        ))
    }

}
