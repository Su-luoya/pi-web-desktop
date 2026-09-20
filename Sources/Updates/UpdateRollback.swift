/// Rollback eligibility, degradation planning and user-facing warning text.

import Foundation

// MARK: - 手动建议（只展示，不执行）

/// 来源对应的手动更新建议。文本全部来自 `InstallCommandManifest` 的静态清单，
/// 不含本机路径、不根据包名动态拼接，也绝不会被应用执行。
struct UpdateManualAdvice: Equatable {
    var source: InstallSource
    /// 可复制的手动命令；nil 表示该来源没有可给出的静态命令。
    var commandText: String?
    /// 指引说明（来源文档 / 注意事项）。
    var guidanceText: String

    /// 用户可见的提示句：先给命令文本（若有），再给指引。
    var summarySentence: String {
        if let commandText {
            return "可手动执行（只展示，应用不会执行）：\(commandText)。\(guidanceText)"
        }
        return guidanceText
    }
}

enum UpdateManualAdviceBuilder {
    /// 按“组件种类 + 来源”取静态更新指引。
    static func advice(component: UpdateTransactionComponent, source: InstallSource) -> UpdateManualAdvice {
        guard let entry = InstallCommandManifest.updateGuidance(for: component.kind, source: source) else {
            return UpdateManualAdvice(
                source: source,
                commandText: nil,
                guidanceText: "没有适用于该来源的静态更新命令；请按来源文档手动更新后重新检测。"
            )
        }
        return UpdateManualAdvice(
            source: source,
            commandText: entry.command,
            guidanceText: entry.note
        )
    }
}

// MARK: - 有限回滚 / 降级

/// 回滚资格判定结果。只有 `eligibleRetainedEvidence` 才允许自动降级。
enum UpdateRollbackEligibility: String, Equatable {
    /// 来源是 npm 全局，且应用保留的更新前证据仍然存在并可用。
    case eligibleRetainedEvidence
    /// 来源不是 npm 全局：永不尝试回滚。
    case sourceDoesNotSupportRollback
    /// 应用没有保留更新前的可执行文件路径/版本证据。
    case missingEvidence
    /// 证据已被覆盖、删除或不可执行（例如 npm 全局安装覆盖了同一个路径）。
    case evidenceChangedOrMissing
    /// 本次运行没有可用的文件系统探针（GitHub #106）：没法核对证据，因此既
    /// 不回滚，也不断言证据被改动。
    case probeUnavailable
    /// 路径与指纹一致：仍然就是更新前的文件，不需要回滚。
    case alreadyOnPreviousArtifact
    /// 安装命令失败，但没有核对过旧文件是否被改动（B-6）：既不断言“仍在更新前的
    /// 文件上”，也不断言“系统状态未改变”，只是不执行回滚动作。
    case stateNotVerified

    var text: String {
        switch self {
        case .eligibleRetainedEvidence: return "保留了可用的更新前证据"
        case .sourceDoesNotSupportRollback: return "该来源不支持自动回滚"
        case .missingEvidence: return "没有保留更新前的路径/版本证据"
        case .evidenceChangedOrMissing: return "更新前的证据已被覆盖、删除或不可执行"
        case .probeUnavailable: return "本次运行没有可用的文件系统探针，无法核对更新前的证据"
        case .alreadyOnPreviousArtifact: return "当前仍在更新前的文件上"
        case .stateNotVerified: return "安装命令失败后没有核对过旧文件，无法断言仍在更新前的文件上"
        }
    }
}

/// 降级结果类别。用户可见文案与诊断展示依据这个枚举区分。
enum UpdateDegradationKind: String, Equatable {
    /// 本次尝试成功，不需要降级。
    case notNeeded
    /// 安装阶段失败：没有执行任何回滚动作，也不断言旧文件未被改动。
    case installFailedKeepingPreviousVersion
    /// 验证失败，但当前文件仍是更新前的版本（版本未变化）。
    case stillUsingPreviousArtifact
    /// 验证失败，已把调用方指回更新前仍然可用的可执行文件。
    case degradedToPreviousArtifact
    /// 验证失败，无法自动回滚：只报告 + 手动提示。
    case cannotAutomaticallyRollback

    var displayName: String {
        switch self {
        case .notNeeded: return "无需降级"
        case .installFailedKeepingPreviousVersion: return "更新失败，没有执行任何回滚动作"
        case .stillUsingPreviousArtifact: return "更新后验证失败，仍在使用更新前的版本"
        case .degradedToPreviousArtifact: return "更新后验证失败，已降级"
        case .cannotAutomaticallyRollback: return "更新后验证失败，无法自动回滚"
        }
    }

    /// 是否产生了自动降级动作（把调用方指向更新前的可用路径）。
    var performedAutomaticDegradation: Bool { self == .degradedToPreviousArtifact }
}

/// 降级前重新核对的证据（GitHub #63）。这些字段都是“实际核对到的事实”，
/// 不包含“来源可信”或“已确认安全”类结论。
struct UpdateRollbackEvidence: Equatable {
    var level: UpdateArtifactEvidenceLevel
    var identityVerified: Bool
    var inodeVerified: Bool
    var contentHashVerified: Bool
    /// 未做内容哈希的原因（`contentHashVerified == false` 时非 nil）。
    var contentHashUnavailableReason: UpdateContentHashUnavailableReason?
    /// npm 完整性证据的固定说明（“已记录”/“未获取”）。
    var npmIntegrityEvidenceText: String

    /// 用户可见事实句：明确写出证据等级、核对过的字段，以及未做内容哈希的原因。
    var summaryText: String {
        var parts: [String] = ["证据等级 \(level.rawValue)"]
        if identityVerified { parts.append("身份名称一致") }
        if inodeVerified { parts.append("inode 一致") }
        if contentHashVerified {
            parts.append("内容哈希一致")
        } else {
            parts.append(contentHashUnavailableReason?.text ?? "未做内容哈希")
        }
        parts.append(npmIntegrityEvidenceText)
        return parts.joined(separator: "；")
    }

    /// “已降级”文案里必须写明的句子：证据等级不是 `contentHash` 时，明确写出
    /// “不校验旧文件内容”。
    var contentVerificationClause: String {
        contentHashVerified
            ? "降级前已重新核对旧文件内容哈希与身份名称一致"
            : "不校验旧文件内容（\(contentHashUnavailableReason?.text ?? "未做内容哈希")）"
    }
}

/// 证据核对失败的原因（固定文案；不含路径，也不回显实际包名）。
enum UpdateRollbackEvidenceIssue: Equatable {
    case missingExpectedName
    case identityUnreadable
    case identityMismatch
    case inodeUnreadable
    case inodeMismatch
    case contentHashUnreadable
    case contentHashMismatch

    var text: String {
        switch self {
        case .missingExpectedName:
            return "更新前指纹没有记录可比的包名，无法确认旧文件身份"
        case .identityUnreadable:
            return "读不到旧文件所在包的 package.json 名称，无法确认旧文件身份"
        case .identityMismatch:
            return "旧文件所在包的 package.json 名称与更新前记录不一致"
        case .inodeUnreadable:
            return "读不到旧文件的 inode，无法确认仍是同一个文件"
        case .inodeMismatch:
            return "旧文件的 inode 与更新前记录不一致"
        case .contentHashUnreadable:
            return "无法重新计算旧文件的内容哈希，无法确认旧文件内容一致"
        case .contentHashMismatch:
            return "旧文件的内容哈希与更新前记录不一致"
        }
    }
}

/// 一次降级/回滚判定。`restoredExecutablePath` 只在
/// `kind == .degradedToPreviousArtifact` 时非 nil：它是调用方应当继续使用的
/// 更新前可执行文件路径。
struct UpdateDegradationPlan: Equatable {
    var kind: UpdateDegradationKind
    /// 可读原因（固定文案；不含路径）。
    var reason: String
    var rollbackEligibility: UpdateRollbackEligibility
    var previousVersion: String?
    var previousExecutablePath: String?
    var restoredExecutablePath: String?
    var restoredVersion: String?
    var manualAdvice: UpdateManualAdvice
    /// 用户可见的持久警告文案（明确区分“仍在使用旧版本 / 已降级 / 无法自动回滚”）。
    var warningText: String
    /// 降级前实际核对到的证据；没有做核对（不需降级/安装失败/证据缺失）时为 nil。
    var evidence: UpdateRollbackEvidence?

    var performedAutomaticDegradation: Bool { kind.performedAutomaticDegradation }
}

/// 降级判定器（纯函数）。判定依据只有：来源、更新前指纹、重新检测到的路径与
/// 版本，以及注入的文件系统探针。
enum UpdateDegradationPlanner {
    /// 安装阶段失败：不执行任何回滚动作。命令失败不证明旧文件没被改动（可能已经
    /// 写入了部分内容），因此既不声称“系统状态未改变”，也不声称“仍在旧版本上”。
    static func installFailure(
        component: UpdateTransactionComponent,
        source: InstallSource,
        fingerprint: UpdateArtifactFingerprint,
        targetVersion: String?,
        failureReason: String
    ) -> UpdateDegradationPlan {
        let advice = UpdateManualAdviceBuilder.advice(component: component, source: source)
        let previous = fingerprint.version
        let warning = UpdateWarningText.installFailed(
            component: component,
            previousVersion: previous,
            targetVersion: targetVersion,
            failureReason: failureReason
        )
        return UpdateDegradationPlan(
            kind: .installFailedKeepingPreviousVersion,
            reason: "安装命令失败（\(failureReason)）；本次没有执行任何回滚动作",
            rollbackEligibility: source == .npmGlobal ? .stateNotVerified : .sourceDoesNotSupportRollback,
            previousVersion: previous,
            previousExecutablePath: fingerprint.evidencePath,
            restoredExecutablePath: nil,
            restoredVersion: nil,
            manualAdvice: advice,
            warningText: warning,
            evidence: nil
        )
    }

    /// 在新版本安装后重新核对旧路径的证据（GitHub #63）：身份名称、inode、
    /// 内容哈希。全部读得到且一致才返回证据；任一不满足或读不到都返回固定
    /// 原因，调用方必须按“无法自动回滚”处理。
    ///
    /// 明示的等价规则：内容哈希是比 size/mtime 更强的证据——指纹记录了内容哈希
    /// 时以哈希为准（哈希已覆盖文件内容），但 inode 与身份仍必须一致；指纹没有
    /// 记录内容哈希（超限/不可读）时，退回 size/mtime 元数据检查，并在证据与
    /// 文案里明确写出“未做内容哈希”。
    static func evaluateRollbackEvidence(
        fingerprint: UpdateArtifactFingerprint,
        expectedPackageName: String?,
        previousPath: String,
        probe: UpdateArtifactProbe
    ) -> (evidence: UpdateRollbackEvidence?, issue: UpdateRollbackEvidenceIssue?) {
        let expected = fingerprint.packageName ?? expectedPackageName
        guard let expected, !expected.isEmpty else { return (nil, .missingExpectedName) }
        guard let actual = probe.packageNameNear(previousPath) else { return (nil, .identityUnreadable) }
        guard actual == expected else { return (nil, .identityMismatch) }

        var inodeVerified = false
        if let recordedInode = fingerprint.fileInode {
            guard let currentInode = probe.fileInode(previousPath) else { return (nil, .inodeUnreadable) }
            guard currentInode == recordedInode else { return (nil, .inodeMismatch) }
            inodeVerified = true
        }

        var contentHashVerified = false
        var contentHashUnavailableReason: UpdateContentHashUnavailableReason?
        if let recordedHash = fingerprint.contentHash {
            let result = probe.contentHash(previousPath)
            guard let currentHash = result.hash else { return (nil, .contentHashUnreadable) }
            guard currentHash == recordedHash else { return (nil, .contentHashMismatch) }
            contentHashVerified = true
        } else {
            contentHashUnavailableReason = fingerprint.contentHashUnavailableReason ?? .unsupported
        }

        let level: UpdateArtifactEvidenceLevel = contentHashVerified
            ? .contentHash
            : (inodeVerified ? .inode : .pathOnly)
        return (UpdateRollbackEvidence(
            level: level,
            identityVerified: true,
            inodeVerified: inodeVerified,
            contentHashVerified: contentHashVerified,
            contentHashUnavailableReason: contentHashUnavailableReason,
            npmIntegrityEvidenceText: fingerprint.npmIntegrityEvidenceText
        ), nil)
    }

    /// 验证阶段失败：按有限回滚边界决定“仍在使用旧版本 / 已降级 / 无法自动回滚”。
    static func verificationFailure(
        component: UpdateTransactionComponent,
        source: InstallSource,
        fingerprint: UpdateArtifactFingerprint,
        newVersion: String?,
        newResolvedPath: String?,
        failureReason: String,
        probe: UpdateArtifactProbe
    ) -> UpdateDegradationPlan {
        let advice = UpdateManualAdviceBuilder.advice(component: component, source: source)
        let previousVersion = fingerprint.version
        let previousPath = fingerprint.evidencePath

        func plan(kind: UpdateDegradationKind, eligibility: UpdateRollbackEligibility, reason: String,
                  evidence: UpdateRollbackEvidence? = nil,
                  restoredPath: String? = nil, restoredVersion: String? = nil) -> UpdateDegradationPlan {
            let warning = UpdateWarningText.verificationFailed(
                component: component,
                previousVersion: previousVersion,
                newVersion: newVersion,
                kind: kind,
                reason: reason,
                advice: advice,
                evidence: evidence
            )
            return UpdateDegradationPlan(
                kind: kind,
                reason: reason,
                rollbackEligibility: eligibility,
                previousVersion: previousVersion,
                previousExecutablePath: previousPath,
                restoredExecutablePath: restoredPath,
                restoredVersion: restoredVersion,
                manualAdvice: advice,
                warningText: warning,
                evidence: evidence
            )
        }

        // 版本未变化：文件仍是更新前的版本，直接如实报告，不做任何“回滚动作”。
        if let previousVersion, let newVersion, previousVersion == newVersion {
            return plan(
                kind: .stillUsingPreviousArtifact,
                eligibility: .alreadyOnPreviousArtifact,
                reason: "验证失败（\(failureReason)）；重新检测到的版本与更新前相同（\(previousVersion)），文件未被替换"
            )
        }

        // 真实边界 1：非 npm 全局来源一律不回滚。
        guard source == .npmGlobal else {
            return plan(
                kind: .cannotAutomaticallyRollback,
                eligibility: .sourceDoesNotSupportRollback,
                reason: "验证失败（\(failureReason)）；来源为 \(source.displayName)，应用只对 npm 全局安装保留回滚证据，该来源从不尝试回滚"
            )
        }

        // 真实边界 2：没有保留更新前的路径与版本证据。
        guard let previousVersion, let previousPath else {
            return plan(
                kind: .cannotAutomaticallyRollback,
                eligibility: .missingEvidence,
                reason: "验证失败（\(failureReason)）；应用没有保留更新前的可执行文件路径与版本证据，无法回滚"
            )
        }

        // 真实边界 3：探针可用，且旧路径仍然存在并带可执行位。
        guard probe.isAvailable else {
            return plan(
                kind: .cannotAutomaticallyRollback,
                eligibility: .probeUnavailable,
                reason: "验证失败（\(failureReason)）；本次运行没有可用的文件系统探针，无法确认更新前的证据仍然可用，因此不回滚"
            )
        }
        guard probe.isExecutableFile(previousPath) else {
            return plan(
                kind: .cannotAutomaticallyRollback,
                eligibility: .evidenceChangedOrMissing,
                reason: "验证失败（\(failureReason)）；更新前的可执行文件已被覆盖、删除或不再可执行，无法回滚"
            )
        }

        // 真实边界 4（GitHub #63）：身份名称、inode 与内容哈希必须与更新前记录
        // 一致；任一读不到或不一致都只能报告“无法自动回滚”，不得声称“已降级”。
        let (evidence, issue) = evaluateRollbackEvidence(
            fingerprint: fingerprint,
            expectedPackageName: component.expectedPackageName,
            previousPath: previousPath,
            probe: probe
        )
        guard let evidence else {
            return plan(
                kind: .cannotAutomaticallyRollback,
                eligibility: .evidenceChangedOrMissing,
                reason: "验证失败（\(failureReason)）；更新前证据重新核对未通过（\(issue?.text ?? "证据不可用")），不能确认旧文件仍是更新前那份，无法回滚"
            )
        }

        // 没有内容哈希（超限/不可读）时退回 size/mtime 元数据检查，并在证据与
        // 文案里写明“未做内容哈希”。内容哈希一致时不再要求 size/mtime 相同：
        // 哈希是更强的证据（上面明示的等价规则）。
        if !evidence.contentHashVerified {
            // B-7：没有内容哈希时只能用 size/mtime 兜底；没记录的字段一律算未验证
            // （不能默认通过），两者都没记录时就没有任何可核对的元数据。
            guard fingerprint.fileSize != nil || fingerprint.modifiedAt != nil else {
                return plan(
                    kind: .cannotAutomaticallyRollback,
                    eligibility: .evidenceChangedOrMissing,
                    reason: "验证失败（\(failureReason)）；更新前的指纹没有内容哈希，也没有记录大小与 mtime，没有可核对的元数据，无法回滚"
                )
            }
            let sizeMatches = fingerprint.fileSize.map { probe.fileSize(previousPath) == $0 } ?? false
            let mtimeMatches = fingerprint.modifiedAt.map { probe.modificationDate(previousPath) == $0 } ?? false
            guard sizeMatches, mtimeMatches else {
                return plan(
                    kind: .cannotAutomaticallyRollback,
                    eligibility: .evidenceChangedOrMissing,
                    reason: "验证失败（\(failureReason)）；更新前的可执行文件已被覆盖或替换（大小/mtime 与指纹不一致，且未做内容哈希，只能用元数据比对），无法回滚"
                )
            }
        }

        // 路径未变且证据一致：文件仍是更新前的版本。
        if newResolvedPath == nil || newResolvedPath == previousPath {
            return plan(
                kind: .stillUsingPreviousArtifact,
                eligibility: .alreadyOnPreviousArtifact,
                reason: "验证失败（\(failureReason)）；更新前的可执行文件仍在原位且证据等级 \(evidence.level.rawValue) 的指纹一致，仍在使用更新前的版本",
                evidence: evidence
            )
        }

        // 真正的有限降级：更新前路径与当前路径不同，且旧路径的证据已重新核对。
        return plan(
            kind: .degradedToPreviousArtifact,
            eligibility: .eligibleRetainedEvidence,
            reason: "验证失败（\(failureReason)）；已把调用方指回更新前记录的路径（\(evidence.summaryText)）",
            evidence: evidence,
            restoredPath: previousPath,
            restoredVersion: previousVersion
        )
    }
}

// MARK: - 用户可见警告文案

/// 用户可见的持久警告文案。明确区分：
///   * “更新失败，没有执行任何回滚动作”（install 阶段失败）；
///   * “更新后验证失败，已降级 / 仍在旧版本 / 无法自动回滚”。
enum UpdateWarningText {
    static func installFailed(
        component: UpdateTransactionComponent,
        previousVersion: String?,
        targetVersion: String?,
        failureReason: String
    ) -> String {
        "\(component.displayName)更新失败，没有执行任何回滚动作"
            + "（更新前版本 \(previousVersion ?? "未知")，目标版本 \(targetVersion ?? "未知")；原因：\(failureReason)）。"
            + "应用不声称更新成功，也未核对更新前的文件是否被改动。"
    }

    /// L-1（GitHub #127）：日志行与持久警告共用同一套三态措辞——只有重新检测拿到版本证据时
    /// 才写「仍在使用更新前的版本」，拿不到版本时不得断言旧文件仍在原位。
    static func oldVersionClaimText(detectedVersion: String?) -> String {
        if let detectedVersion {
            return "仍在使用更新前的版本 \(detectedVersion)；"
        }
        return "重新检测没有给出可用的版本结果，无法判断更新前的文件是否仍在原位；"
    }

    static func verificationFailed(
        component: UpdateTransactionComponent,
        previousVersion: String?,
        newVersion: String?,
        kind: UpdateDegradationKind,
        reason: String,
        advice: UpdateManualAdvice,
        evidence: UpdateRollbackEvidence? = nil
    ) -> String {
        let head: String
        switch kind {
        case .stillUsingPreviousArtifact:
            head = "\(component.displayName)更新后验证失败，仍在使用更新前的版本 \(previousVersion ?? "未知")"
        case .degradedToPreviousArtifact:
            head = "\(component.displayName)更新后验证失败，已降级到更新前记录的版本 \(previousVersion ?? "未知")"
        case .cannotAutomaticallyRollback:
            head = "\(component.displayName)更新后验证失败，无法自动回滚"
        case .installFailedKeepingPreviousVersion, .notNeeded:
            head = "\(component.displayName)更新后验证失败"
        }
        var parts = [head + "（检测到版本 \(newVersion ?? "未知")）。"]
        parts.append(reason + "。")
        switch kind {
        case .degradedToPreviousArtifact:
            // 必须写明：这只是把调用方指回更新前记录的路径；证据等级不是
            // contentHash 时还必须写明“不校验旧文件内容”。
            parts.append("这只是把调用方指回更新前记录的路径。")
            if let evidence {
                parts.append("\(evidence.contentVerificationClause)（\(evidence.summaryText)）。")
            } else {
                parts.append("不校验旧文件内容（没有可用的证据核对记录）。")
            }
            parts.append("应用不复制、不移动、不恢复文件内容，也不卸载新版本，也不会自动回滚之后的更改。")
        case .cannotAutomaticallyRollback:
            parts.append("请按下面的手动方式处理：")
        default:
            parts.append("应用不会自动回滚已替换的文件，也不声称更新成功。")
        }
        parts.append(advice.summarySentence)
        return parts.joined(separator: " ")
    }
}
