/// Persisted update history entries, store and presenter text.

import Foundation

/// 历史/诊断里回滚结果的准确描述（不含路径）。
enum UpdateHistoryDescription {
    static func rollbackDescription(for plan: UpdateDegradationPlan) -> String {
        switch plan.kind {
        case .notNeeded:
            return "无需降级"
        case .installFailedKeepingPreviousVersion:
            return "安装失败，未尝试回滚（命令失败不证明旧文件未被改动，因此不断言系统状态未改变）"
        case .stillUsingPreviousArtifact:
            return "验证失败，当前仍是更新前的文件，未尝试回滚"
        case .degradedToPreviousArtifact:
            var text = "验证失败，已降级到更新前记录的可用可执行文件（版本 \(plan.restoredVersion ?? "未知")）；这只是把调用方指回更新前记录的路径，不复制、不移动、不恢复文件内容"
            if let evidence = plan.evidence {
                text += "；\(evidence.contentVerificationClause)；证据等级 \(evidence.level.rawValue)（\(evidence.summaryText)）"
            } else {
                text += "；不校验旧文件内容（没有可用的证据核对记录）"
            }
            return text
        case .cannotAutomaticallyRollback:
            return "验证失败，无法自动回滚（\(plan.rollbackEligibility.text)）"
        }
    }
}

// MARK: - 更新历史

/// 一条更新历史。字段全部是固定枚举、已校验的版本号/包名与固定原因文案：
/// 不含绝对路径、环境变量值、凭据或子进程输出。
struct UpdateHistoryEntry: Equatable {
    var recordedAt: Date
    var component: UpdateTransactionComponent
    var source: InstallSource
    var fromVersion: String?
    var toVersion: String?
    /// 最后一个明确成功的阶段（诊断页展示“完成阶段”）。
    var completedPhase: UpdateTransactionPhase?
    /// 最后一个有结果的阶段（失败时用于说明停在哪一步）。
    var terminationPhase: UpdateTransactionPhase?
    var phases: [UpdateTransactionPhaseResult]
    var degradationKind: UpdateDegradationKind?
    var failureReason: String?
    /// 手动命令文本（静态清单；只展示，不执行）。
    var manualCommandText: String?
    var manualGuidanceText: String?
    var rollbackDescription: String?
    /// 本次更新使用的指纹/降级证据等级（GitHub #63）。
    var evidenceLevel: UpdateArtifactEvidenceLevel?
    /// 证据等级的具体说明（含“未做内容哈希”与 npm “未获取”标注）。
    var evidenceNote: String?

    /// 是否是一次成功更新（提交阶段成功且没有失败阶段）。
    var isSuccessful: Bool {
        completedPhase == .commit && !phases.contains { $0.status == .failed }
    }
}

/// 更新历史的 UserDefaults 存取。
///
/// 单键 JSON 编码；条数有上限（最新在前）；读取时逐条校验并丢弃不可信字段
/// （未知枚举、非法版本号/包名、超长文本），因此手工写入的任意内容不会进入
/// 诊断展示。
enum UpdateHistoryStore {
    /// 保留的历史条数上限。
    static let maximumEntries = 20
    /// 单条文本字段的长度上限（防止把不受控内容写进历史）。
    static let maximumTextFieldLength = 300

    static func load(from defaults: UserDefaults) -> [UpdateHistoryEntry] {
        guard let data = defaults.data(forKey: UpdateSettingKeys.updateHistory),
              let entries = decode(data) else { return [] }
        return entries
    }

    static func record(_ entry: UpdateHistoryEntry, to defaults: UserDefaults) {
        var entries = load(from: defaults)
        entries.insert(sanitize(entry), at: 0)
        entries = Array(entries.prefix(maximumEntries))
        guard let data = encode(entries) else { return }
        defaults.set(data, forKey: UpdateSettingKeys.updateHistory)
    }

    static func clear(from defaults: UserDefaults) {
        defaults.removeObject(forKey: UpdateSettingKeys.updateHistory)
    }

    static func encode(_ entries: [UpdateHistoryEntry]) -> Data? {
        try? JSONEncoder().encode(entries.map(StoredEntry.init(entry:)))
    }

    static func decode(_ data: Data) -> [UpdateHistoryEntry]? {
        guard let stored = try? JSONDecoder().decode([StoredEntry].self, from: data) else { return nil }
        return stored.compactMap { $0.entry() }.map(sanitize).prefix(maximumEntries).map { $0 }
    }

    /// 去掉不受控内容：截断长文本、丢掉无法校验的包名与版本。
    static func sanitize(_ entry: UpdateHistoryEntry) -> UpdateHistoryEntry {
        var copy = entry
        if let packageName = copy.component.packageName,
           !ComponentInstallationDetector.isPackageName(packageName) {
            copy.component.packageName = nil
        }
        copy.fromVersion = validVersion(copy.fromVersion)
        copy.toVersion = validVersion(copy.toVersion)
        copy.failureReason = clipped(copy.failureReason)
        copy.manualCommandText = clipped(copy.manualCommandText)
        copy.manualGuidanceText = clipped(copy.manualGuidanceText)
        copy.rollbackDescription = clipped(copy.rollbackDescription)
        copy.evidenceNote = clipped(copy.evidenceNote)
        copy.phases = copy.phases.map { phase in
            var phaseCopy = phase
            phaseCopy.reason = clipped(phaseCopy.reason) ?? "（原因已省略）"
            return phaseCopy
        }
        return copy
    }

    static func validVersion(_ text: String?) -> String? {
        guard let text, let version = SemanticVersion(text), version.description == text else { return nil }
        return text
    }

    /// 截断到上限并去除控制字符；空串视为 nil。
    static func clipped(_ text: String?) -> String? {
        guard let text else { return nil }
        let filtered = text.unicodeScalars.filter { scalar in
            !(scalar.value < 0x20 || scalar.value == 0x7F)
        }
        let value = String(String.UnicodeScalarView(filtered))
        let clipped = String(value.prefix(maximumTextFieldLength))
        return clipped.isEmpty ? nil : clipped
    }

    /// JSON 存储形状：显式字段，避免把任意 Enum 原始值直接落盘。
    private struct StoredEntry: Codable {
        var recordedAt: Double
        var componentKind: String
        var packageName: String?
        var source: String
        var fromVersion: String?
        var toVersion: String?
        var completedPhase: String?
        var terminationPhase: String?
        var phases: [StoredPhase]
        var degradationKind: String?
        var failureReason: String?
        var manualCommandText: String?
        var manualGuidanceText: String?
        var rollbackDescription: String?
        var evidenceLevel: String?
        var evidenceNote: String?

        init(entry: UpdateHistoryEntry) {
            recordedAt = entry.recordedAt.timeIntervalSince1970
            componentKind = entry.component.kind.rawValue
            packageName = entry.component.packageName
            source = entry.source.rawValue
            fromVersion = entry.fromVersion
            toVersion = entry.toVersion
            completedPhase = entry.completedPhase?.rawValue
            terminationPhase = entry.terminationPhase?.rawValue
            phases = entry.phases.map(StoredPhase.init(phase:))
            degradationKind = entry.degradationKind?.rawValue
            failureReason = entry.failureReason
            manualCommandText = entry.manualCommandText
            manualGuidanceText = entry.manualGuidanceText
            rollbackDescription = entry.rollbackDescription
            evidenceLevel = entry.evidenceLevel?.rawValue
            evidenceNote = entry.evidenceNote
        }

        func entry() -> UpdateHistoryEntry? {
            guard let kind = ComponentKind(rawValue: componentKind) else { return nil }
            guard let source = InstallSource(rawValue: source) else { return nil }
            return UpdateHistoryEntry(
                recordedAt: Date(timeIntervalSince1970: recordedAt),
                component: UpdateTransactionComponent(kind: kind, packageName: packageName),
                source: source,
                fromVersion: fromVersion,
                toVersion: toVersion,
                completedPhase: completedPhase.flatMap(UpdateTransactionPhase.init(rawValue:)),
                terminationPhase: terminationPhase.flatMap(UpdateTransactionPhase.init(rawValue:)),
                phases: phases.compactMap { $0.makePhase() },
                degradationKind: degradationKind.flatMap(UpdateDegradationKind.init(rawValue:)),
                failureReason: failureReason,
                manualCommandText: manualCommandText,
                manualGuidanceText: manualGuidanceText,
                rollbackDescription: rollbackDescription,
                evidenceLevel: evidenceLevel.flatMap(UpdateArtifactEvidenceLevel.init(rawValue:)),
                evidenceNote: evidenceNote
            )
        }
    }

    private struct StoredPhase: Codable {
        var phase: String
        var status: String
        var reason: String
        var recordedAt: Double

        init(phase: UpdateTransactionPhaseResult) {
            self.phase = phase.phase.rawValue
            self.status = phase.status.rawValue
            self.reason = phase.reason
            self.recordedAt = phase.recordedAt.timeIntervalSince1970
        }

        func makePhase() -> UpdateTransactionPhaseResult? {
            guard let phase = UpdateTransactionPhase(rawValue: phase),
                  let status = UpdateTransactionPhaseStatus(rawValue: status) else { return nil }
            return UpdateTransactionPhaseResult(
                phase: phase,
                status: status,
                reason: reason,
                recordedAt: Date(timeIntervalSince1970: recordedAt)
            )
        }
    }
}

// MARK: - 历史展示

/// 诊断页的最近更新展示（纯函数）。只展示阶段结果、失败原因与建议动作；
/// 手动命令文本只展示、绝不执行。
enum UpdateHistoryPresenter {
    static func lines(for entry: UpdateHistoryEntry?) -> [String] {
        guard let entry else {
            return ["最近一次更新：本次运行还没有更新记录。"]
        }
        var lines: [String] = []
        lines.append("最近一次更新：\(entry.component.displayName)；来源 \(entry.source.displayName)；"
            + "\(entry.fromVersion ?? "未知") → \(entry.toVersion ?? "未知")")
        lines.append("完成阶段：\(entry.completedPhase?.title ?? "无")"
            + (entry.terminationPhase.map { "；最后记录阶段：\($0.title)" } ?? "")
            + "；结果：\(entry.isSuccessful ? "成功" : "未完成")")
        for phase in entry.phases {
            lines.append("· \(phase.displayLine)")
        }
        if let failure = entry.failureReason {
            lines.append("失败原因：\(failure)")
        }
        if let rollback = entry.rollbackDescription {
            lines.append("降级/回滚：\(rollback)")
        }
        if let level = entry.evidenceLevel {
            lines.append("降级证据等级：\(level.rawValue)（\(level.text)）")
        }
        if let note = entry.evidenceNote {
            lines.append("证据说明：\(note)")
        }
        lines.append("建议动作：" + adviceText(for: entry))
        return lines
    }

    static func adviceText(for entry: UpdateHistoryEntry) -> String {
        if entry.isSuccessful {
            return "无需操作。"
        }
        if let command = entry.manualCommandText {
            return "可复制以下命令手动处理（应用只展示，不执行）：\(command)"
                + (entry.manualGuidanceText.map { "；\($0)" } ?? "")
        }
        if let guidance = entry.manualGuidanceText {
            return guidance + "（应用只展示，不执行任何命令）"
        }
        return "没有可给出的静态命令；请按来源文档手动处理。"
    }
}
