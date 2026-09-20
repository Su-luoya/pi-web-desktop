/// Pre-update artifact fingerprint and its evidence levels.

import Foundation

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
                // GitHub #124：把这次记录的版本一并交给探针，让锁文件里的
                // 版本比对相对已记录证据，而不是探针自己重新推导。
                integrity = probe.npmIntegrity(path, packageName, version).flatMap { value in
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
