import Foundation

// MARK: - 更新事务（GitHub #23）
//
// 本文件是 #20（Pi Web）/ #21（Pi CLI）/ #22（Pi 扩展包）三条更新路径共用的
// 事务模型：阶段化结果、更新前指纹、有限回滚/降级判定、统一更新历史与用户可见
// 文案。它只做判定与记录，**不执行任何副作用**：
//
//   * 不安装、不卸载、不删除、不改写任何文件；
//   * 不调用 shell、不调用 `sudo`；
//   * 不向任何进程发送信号（不 kill / SIGTERM / SIGKILL）；
//   * 回滚只允许“把调用方指向更新前仍然可用的可执行文件路径/版本”，
//     绝不复制、移动或恢复文件内容。
//
// 真实边界（必须与文档一致）：只有当应用自己保留了更新前的可执行文件路径与
// 版本证据、并且该证据在新版本安装后仍然存在且可用时，才允许自动降级；对
// pnpm / Homebrew / nvm / mise / git checkout / 本地路径 / 未知来源一律不回滚，
// 只报告并给出手动命令文本（只展示，不执行）。

// MARK: - 组件

/// 更新事务的组件标识。`packageName` 只承载已通过 npm 包名校验的扩展包名。
struct UpdateTransactionComponent: Equatable {
    var kind: ComponentKind
    var packageName: String?

    var displayName: String {
        switch kind {
        case .piWeb: return "Pi Web"
        case .piCLI: return "Pi CLI"
        case .piPackage: return packageName.map { "Pi 扩展包 \($0)" } ?? "Pi 扩展包"
        case .desktopApp: return "Pi Web Desktop"
        }
    }

    static let piWeb = UpdateTransactionComponent(kind: .piWeb, packageName: nil)
    static let piCLI = UpdateTransactionComponent(kind: .piCLI, packageName: nil)
    static func piPackage(_ packageName: String?) -> UpdateTransactionComponent {
        UpdateTransactionComponent(kind: .piPackage, packageName: packageName)
    }

    /// 静态清单里的期望包名：Pi Web / Pi CLI 固定；扩展包只有自身包名。
    var expectedPackageName: String? {
        switch kind {
        case .piWeb: return InstallCommandManifest.piWebPackageName
        case .piCLI: return InstallCommandManifest.piCLIPackageName
        case .piPackage: return packageName
        case .desktopApp: return nil
        }
    }
}

// MARK: - 事务阶段

/// 事务阶段：准备 → 执行 → 验证 → 启用/提交 → 失败降级。
enum UpdateTransactionPhase: String, CaseIterable, Equatable {
    case preflight
    case install
    case verify
    case commit
    case degrade

    var title: String {
        switch self {
        case .preflight: return "准备"
        case .install: return "执行安装"
        case .verify: return "验证"
        case .commit: return "启用/提交"
        case .degrade: return "失败降级"
        }
    }
}

enum UpdateTransactionPhaseStatus: String, Equatable {
    case succeeded
    case failed
    case skipped
    case notAttempted

    var displayName: String {
        switch self {
        case .succeeded: return "成功"
        case .failed: return "失败"
        case .skipped: return "跳过"
        case .notAttempted: return "未执行"
        }
    }
}

/// 单阶段结果：阶段、状态、可读原因与时间。`reason` 必须由固定文案 + 已校验的
/// 版本号/包名组成，不含路径、子进程输出或凭据。
struct UpdateTransactionPhaseResult: Equatable {
    var phase: UpdateTransactionPhase
    var status: UpdateTransactionPhaseStatus
    var reason: String
    var recordedAt: Date

    var displayLine: String {
        "\(phase.title)：\(status.displayName)（\(reason)）"
    }
}

// MARK: - 更新前指纹

/// 更新前指纹使用的证据等级（GitHub #63）。`rawValue` 直接进历史记录，
/// 历史展示与降级文案都据此说明“到底校验到了哪一层”。
enum UpdateArtifactEvidenceLevel: String, Equatable, CaseIterable {
    /// 只记录路径/版本/包名/size/mtime 等元数据，没有 inode 也没有内容哈希。
    case pathOnly
    /// 记录了 inode（+ 元数据），仍然没有内容哈希。
    case inode
    /// 记录了可执行文件内容哈希（+ inode）。
    case contentHash

    var text: String {
        switch self {
        case .pathOnly: return "仅路径与元数据（未做内容哈希）"
        case .inode: return "inode + 元数据（未做内容哈希）"
        case .contentHash: return "inode + 内容哈希"
        }
    }
}

/// 没有内容哈希时的固定原因。取不到就如实标注“未做内容哈希”，绝不伪造哈希。
enum UpdateContentHashUnavailableReason: String, Equatable {
    case aboveSizeLimit
    case unreadable
    case unsupported
    case probeUnavailable
    case noPath

    /// 完整说明（用户可见/日志），固定写明“未做内容哈希”。
    var text: String {
        switch self {
        case .aboveSizeLimit:
            return "未做内容哈希（文件超过大小上限 \(UpdateArtifactProbe.contentHashSizeLimitBytes) 字节）"
        case .unreadable: return "未做内容哈希（文件不可读）"
        case .unsupported: return "未做内容哈希（本机没有内容哈希能力）"
        case .probeUnavailable: return "未做内容哈希（本次运行没有文件系统探针）"
        case .noPath: return "未做内容哈希（没有可执行文件路径）"
        }
    }

    /// 摘要里的短原因。
    var shortText: String {
        switch self {
        case .aboveSizeLimit: return "超过大小上限"
        case .unreadable: return "文件不可读"
        case .unsupported: return "没有内容哈希能力"
        case .probeUnavailable: return "没有文件系统探针"
        case .noPath: return "没有可执行文件路径"
        }
    }
}

/// 更新前记录的可执行文件指纹（GitHub #23 第 1 项，GitHub #63 加强）。
///
/// 只记录可验证到的事实：可执行文件路径、真实路径、版本、`package.json` 名称，
/// 文件大小与 mtime，inode，可执行文件内容哈希，以及 npm 记录的 `integrity`。
/// 取不到哈希时 `contentHash` 为 nil 并带固定的“未做内容哈希”原因；取不到 npm
/// 完整性时 `npmIntegrity` 为 nil（展示为“未获取”）。**不**包含代码签名状态，
/// 也**不**声称这些字段能验证官方签名或来源可信。
struct UpdateArtifactFingerprint: Equatable {
    var executablePath: String?
    var resolvedPath: String?
    var version: String?
    var packageName: String?
    var fileSize: Int?
    var modifiedAt: Date?
    /// `st_ino`。nil 表示没有记录（或读取失败）。
    var fileInode: UInt64?
    /// 可执行文件内容哈希；nil 表示“未做内容哈希”，原因见 `contentHashUnavailableReason`。
    var contentHash: String?
    /// 未做内容哈希的固定原因；`contentHash != nil` 时必须为 nil。
    var contentHashUnavailableReason: UpdateContentHashUnavailableReason?
    /// npm 记录的完整性（`integrity`）；nil 表示“未获取”，不是空字符串。
    var npmIntegrity: String?

    /// 用于回滚/降级的候选路径：优先真实路径，其次调用方给出的可执行文件路径。
    var evidencePath: String? {
        resolvedPath ?? executablePath
    }

    var hasVersionEvidence: Bool { version != nil }

    /// 这份指纹实际用到的证据等级。
    var evidenceLevel: UpdateArtifactEvidenceLevel {
        if contentHash != nil { return .contentHash }
        return fileInode != nil ? .inode : .pathOnly
    }

    /// 内容哈希证据的固定说明（含“未做内容哈希”原因）。
    var contentHashEvidenceText: String {
        if let contentHash { return "已记录内容哈希（\(String(contentHash.prefix(14)))…）" }
        return contentHashUnavailableReason?.text ?? "未做内容哈希"
    }

    /// npm 完整性证据的固定说明：取不到时明确写“未获取”。
    var npmIntegrityEvidenceText: String {
        if let npmIntegrity { return "npm 完整性已记录（\(String(npmIntegrity.prefix(12)))…）" }
        return "npm 完整性未获取"
    }

    /// 历史记录用的一行证据说明（含“未做内容哈希”与 npm “未获取”标注）。
    var evidenceSummaryLine: String {
        var parts = [
            "证据等级 \(evidenceLevel.rawValue)（\(evidenceLevel.text)）",
            contentHashEvidenceText,
            npmIntegrityEvidenceText
        ]
        if let fileInode { parts.append("inode \(fileInode)") }
        if let fileSize { parts.append("大小 \(fileSize) 字节") }
        return parts.joined(separator: "；")
    }

    /// 从 #16 的识别结果采集指纹。`probe` 不可用时只记录识别结果里的字段，
    /// 不猜文件大小与 mtime。
    static func capture(installation: ComponentInstallation?, probe: UpdateArtifactProbe) -> UpdateArtifactFingerprint {
        capture(
            executablePath: installation?.executablePath,
            resolvedPath: installation?.resolvedPath,
            version: installation?.version,
            packageName: installation?.packageName,
            probe: probe
        )
    }

    /// 直接用已知字段采集指纹（手动路径没有 #16 识别结果时使用）。
    static func capture(
        executablePath: String?,
        resolvedPath: String? = nil,
        version: String?,
        packageName: String?,
        probe: UpdateArtifactProbe
    ) -> UpdateArtifactFingerprint {
        let path = resolvedPath ?? executablePath
        var size: Int?
        var modified: Date?
        var inode: UInt64?
        var contentHash: String?
        var contentHashReason: UpdateContentHashUnavailableReason?
        var integrity: String?
        if let path {
            if probe.isAvailable {
                size = probe.fileSize(path)
                modified = probe.modificationDate(path)
                inode = probe.fileInode(path)
                let hashResult = probe.contentHash(path)
                contentHash = hashResult.hash
                if contentHash == nil {
                    switch hashResult {
                    case .aboveSizeLimit: contentHashReason = .aboveSizeLimit
                    case .unreadable: contentHashReason = .unreadable
                    case .unsupported: contentHashReason = .unsupported
                    case .hashed: contentHashReason = nil
                    }
                }
                // 只接受形状合法的完整性值；其它一律按“未获取”处理。
                integrity = probe.npmIntegrity(path, packageName).flatMap { value in
                    UpdateArtifactProbe.isIntegrityValue(value) ? value : nil
                }
            } else {
                contentHashReason = .probeUnavailable
            }
        } else {
            contentHashReason = .noPath
        }
        return UpdateArtifactFingerprint(
            executablePath: executablePath,
            resolvedPath: resolvedPath,
            version: version,
            packageName: packageName,
            fileSize: size,
            modifiedAt: modified,
            fileInode: inode,
            contentHash: contentHash,
            contentHashUnavailableReason: contentHashReason,
            npmIntegrity: integrity
        )
    }

    /// 没有可执行文件路径的组件（例如 Pi 扩展包）只记录版本与包名。
    static func versionOnly(version: String?, packageName: String?) -> UpdateArtifactFingerprint {
        UpdateArtifactFingerprint(
            executablePath: nil,
            resolvedPath: nil,
            version: version,
            packageName: packageName,
            fileSize: nil,
            modifiedAt: nil,
            contentHashUnavailableReason: .noPath
        )
    }

    /// 诊断/日志可安全展示的一行摘要：不含路径，并明确写出证据等级、是否做了
    /// 内容哈希以及 npm 完整性是“已记录”还是“未获取”。
    var summaryLine: String {
        [
            "版本 \(version ?? "未知")",
            "包名 \(packageName ?? "未知")",
            fileSize.map { "大小 \($0) 字节" } ?? "大小 未知",
            modifiedAt.map { "mtime \(Int($0.timeIntervalSince1970))" } ?? "mtime 未知",
            "inode \(fileInode.map(String.init) ?? "未知")",
            contentHashEvidenceText,
            npmIntegrityEvidenceText
        ].joined(separator: "；")
    }
}

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
        case .alreadyOnPreviousArtifact: return "当前仍在更新前的文件上"
        case .stateNotVerified: return "安装命令失败后没有核对过旧文件，无法断言仍在更新前的文件上"
        }
    }
}

/// 降级结果类别。用户可见文案与诊断展示依据这个枚举区分。
enum UpdateDegradationKind: String, Equatable {
    /// 本次尝试成功，不需要降级。
    case notNeeded
    /// 安装阶段失败：系统状态未改变，仍在使用旧版本。
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
        case .installFailedKeepingPreviousVersion: return "更新失败，仍在使用旧版本"
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
                eligibility: .evidenceChangedOrMissing,
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

    /// 降级阶段：`.notNeeded` 记为跳过，其余记为成功/失败结果。
    mutating func recordDegradation(_ plan: UpdateDegradationPlan) {
        let status: UpdateTransactionPhaseStatus
        switch plan.kind {
        case .notNeeded:
            status = .skipped
        case .degradedToPreviousArtifact, .stillUsingPreviousArtifact,
             .cannotAutomaticallyRollback, .installFailedKeepingPreviousVersion:
            status = .succeeded
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

// MARK: - 协调器注入的事务环境

/// #20/#21/#22 三个协调器共用的更新事务注入。
///
/// 默认值是“无探针、不记历史、不应用降级”：已有测试与未接入场景的行为保持
/// 不变。生产路径显式注入 `.live` 探针、历史写入与降级应用。
struct UpdateTransactionEnvironment {
    /// 文件系统探针。
    var probe: UpdateArtifactProbe
    /// 历史写入（生产：UserDefaults；测试：内存数组）。
    var recordHistory: (UpdateHistoryEntry) -> Void
    /// 应用降级结果：把服务/重检测指向更新前仍然可用的可执行文件。
    /// 只允许改调用方自己的配置，不做文件操作、不发信号、不执行命令。
    var applyDegradation: (UpdateDegradationPlan) -> Void
    /// 时钟（测试注入固定时间）。
    var now: () -> Date

    static let disabled = UpdateTransactionEnvironment(
        probe: .disabled,
        recordHistory: { _ in },
        applyDegradation: { _ in },
        now: Date.init
    )
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
