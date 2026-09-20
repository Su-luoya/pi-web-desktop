/// Verification checks, verification reports and the update verifier.

import CryptoKit
import Darwin
import Foundation

// MARK: - 验证检查模型

/// 更新验证的五条检查。顺序固定，诊断与历史按同一顺序展示。
enum UpdateVerificationCheck: String, CaseIterable, Equatable {
    case executablePresent = "executable-present"
    case realPathReadable = "real-path-readable"
    case versionReached = "version-reached"
    case packageIdentity = "package-identity"
    case healthCheck = "health-check"

    var title: String {
        switch self {
        case .executablePresent: return "可执行文件存在且可执行"
        case .realPathReadable: return "解析后的真实路径可读"
        case .versionReached: return "版本重新检测达到目标"
        case .packageIdentity: return "package.json 名称与期望包名一致"
        case .healthCheck: return "服务启动后健康检查"
        }
    }

    /// 这条检查的能力边界（诊断页与文档共用）。
    var capabilityBoundary: String {
        switch self {
        case .executablePresent, .realPathReadable:
            return "只查询存在性、可执行位与可读性；这两条检查本身不读取文件内容，也不做代码签名验证。"
        case .versionReached:
            return "只比较 #16 识别器重新检测出的版本号；不验证二进制内容，也不证明安装来源。"
        case .packageIdentity:
            return "只读取最近一层 package.json 的 name 字段；不做发布者身份或来源验证。"
        case .healthCheck:
            return "只复用既有服务健康检查；不验证业务功能，也不证明新版本没有回归。"
        }
    }

    /// 本框架明确不做的验证。任何展示“检查完成/通过”的文案都不得暗示这些能力。
    static let notVerifiedCapabilities: [String] = [
        "不做代码签名验证，也不声称能验证官方签名或发布来源。",
        "不验证安装包内容哈希，也不比对上游文件列表；更新前指纹对本地可执行文件记录内容哈希，只用于判断旧文件是否仍是同一份，不证明来源。",
        "不验证新版本的运行时行为；健康检查只覆盖既有探测路径能覆盖的范围。"
    ]
}

enum UpdateVerificationCheckStatus: String, Equatable {
    case passed
    case failed
    /// 能验证到哪一层就写到哪一层：探针缺失、路径缺失或识别结果缺字段时，
    /// 只能记为“未验证”。
    case notChecked

    var displayName: String {
        switch self {
        case .passed: return "通过"
        case .failed: return "失败"
        case .notChecked: return "未验证"
        }
    }
}

/// 单条检查的结果。`detail` 是固定文案 + 已校验的版本号/包名，不含路径、
/// 子进程输出或凭据。
struct UpdateVerificationCheckResult: Equatable {
    var check: UpdateVerificationCheck
    var status: UpdateVerificationCheckStatus
    var detail: String

    var displayLine: String {
        "\(check.title)：\(status.displayName)（\(detail)）"
    }

    /// 用户可见/日志用的“具体事实句”。只描述实际检查到什么，不使用可能被读成
    /// “来源可信”或“安全检查已通过”的结论性措辞。
    var factText: String {
        switch (check, status) {
        case (.executablePresent, .passed):
            return "可执行文件存在且带可执行位"
        case (.realPathReadable, .passed):
            return "解析后的真实路径可读"
        case (.versionReached, .passed):
            return "版本与目标版本一致（\(detail)）"
        case (.packageIdentity, .passed):
            return "身份名称一致（\(detail)）"
        case (.healthCheck, .passed):
            return "健康检查（既有路径）报告服务可用"
        default:
            return "\(check.title)：\(status.displayName)（\(detail)）"
        }
    }
}

/// 服务健康检查的结果。调用方在版本/身份检查完成后传入；没有调用时是
/// `.notRun`，报告会明确写出“未检查”，不会视作通过。
enum UpdateHealthCheckResult: Equatable {
    case notRun
    case passed
    case failed(reason: String)
}

/// 一次更新验证的完整报告。
struct UpdateVerificationReport: Equatable {
    var checks: [UpdateVerificationCheckResult]

    func result(for check: UpdateVerificationCheck) -> UpdateVerificationCheckResult? {
        checks.first { $0.check == check }
    }

    var failedChecks: [UpdateVerificationCheckResult] {
        checks.filter { $0.status == .failed }
    }

    /// 验证是否整体通过：没有任何失败检查，版本检查必须是明确“通过”，
    /// 健康检查不能是失败。文件/身份检查“未验证”时不会因此被当成通过，
    /// 但也不会阻塞——它们只是不提供额外保证（能力边界已写明）。
    var isVerified: Bool {
        guard failedChecks.isEmpty else { return false }
        guard result(for: .versionReached)?.status == .passed else { return false }
        return result(for: .healthCheck)?.status != .failed
    }

    /// 第一条失败检查的可读原因；全部通过/未验证时为 nil。
    var failureReason: String? {
        failedChecks.first.map { "\($0.check.title)失败：\($0.detail)。" }
    }

    var summaryLines: [String] {
        checks.map(\.displayLine)
    }
}

// MARK: - 验证器

/// 更新验证的输入。全部是值类型，unhosted 测试可直接构造。
struct UpdateVerificationInput: Equatable {
    /// 被验证的组件（Pi Web / Pi CLI / Pi 扩展包）。
    var component: ComponentKind
    /// 包名（扩展包必填；Pi Web / Pi CLI 用静态清单包名）。
    var packageName: String?
    /// 更新前的版本（来自 preflight 指纹）。
    var previousVersion: String?
    /// 目标版本；没有目标版本（手动路径）时只要求“版本发生变化”。
    var targetVersion: String?
    /// #16 识别器重新检测到的版本；nil 表示没有证据。
    var detectedVersion: String?
    /// 重新检测到的包名；nil 表示识别结果没有包名。
    var detectedPackageName: String?
    /// 重新检测到的可执行文件路径。
    var detectedExecutablePath: String?
    /// 重新检测到的真实路径。
    var detectedResolvedPath: String?
    /// 重新检测到的 `package.json` 路径。
    var detectedPackageJSONPath: String?
    /// 更新前记录的指纹。
    var fingerprint: UpdateArtifactFingerprint
}

/// 三条更新路径共用的验证器（纯函数；副作用只有注入的探针读取）。
enum UpdateVerifier {
    /// 版本检查的唯一实现：#20/#21/#22 都调用它，避免三份语义漂移。
    ///
    /// - 有目标版本：重新检测的版本必须“达到或超过”目标版本；
    /// - 没有目标版本（手动路径）：版本必须相对旧版本发生变化；
    /// - 版本无法解析或检测不到：失败。
    static func versionReached(detected: String?, old: String, target: String?) -> Bool {
        guard let detected, let detectedVersion = SemanticVersion(detected) else { return false }
        if let target {
            guard let targetVersion = SemanticVersion(target) else { return false }
            return detectedVersion >= targetVersion
        }
        guard let oldVersion = SemanticVersion(old) else { return false }
        return detectedVersion != oldVersion
    }

    /// 执行文件层、版本层与身份层验证；健康检查记为“未运行”，由调用方在
    /// 服务启动后用 `report(_:healthCheck:)` 补齐。
    static func verify(_ input: UpdateVerificationInput, probe: UpdateArtifactProbe) -> UpdateVerificationReport {
        var checks: [UpdateVerificationCheckResult] = []
        let artifactPath = input.detectedExecutablePath ?? input.fingerprint.resolvedPath
            ?? input.fingerprint.executablePath
        checks.append(executableCheck(path: artifactPath, probe: probe))
        checks.append(realPathCheck(path: artifactPath, resolved: input.detectedResolvedPath, probe: probe))
        checks.append(versionCheck(
            detected: input.detectedVersion,
            previous: input.previousVersion,
            target: input.targetVersion
        ))
        // B-3：只有带路径证据的指纹里的包名才算「检测到的名称」；没有路径证据时
        // 它只是计划里的期望值，用它核对身份等于同义反复（恒真）。
        checks.append(identityCheck(
            expected: input.packageName,
            detected: input.detectedPackageName,
            fingerprintName: input.fingerprint.evidencePath == nil ? nil : input.fingerprint.packageName,
            packageJSONPath: input.detectedPackageJSONPath,
            executablePath: artifactPath,
            probe: probe
        ))
        checks.append(UpdateVerificationCheckResult(
            check: .healthCheck,
            status: .notChecked,
            detail: "尚未启动服务；健康检查未运行"
        ))
        return UpdateVerificationReport(checks: checks)
    }

    /// 用健康检查结果替换报告里的健康检查行。
    static func report(
        _ report: UpdateVerificationReport,
        healthCheck: UpdateHealthCheckResult
    ) -> UpdateVerificationReport {
        let replacement: UpdateVerificationCheckResult
        switch healthCheck {
        case .notRun:
            replacement = UpdateVerificationCheckResult(
                check: .healthCheck,
                status: .notChecked,
                detail: "健康检查未运行"
            )
        case .passed:
            replacement = UpdateVerificationCheckResult(
                check: .healthCheck,
                status: .passed,
                detail: "既有健康检查路径报告服务可用"
            )
        case .failed(let reason):
            replacement = UpdateVerificationCheckResult(
                check: .healthCheck,
                status: .failed,
                detail: reason
            )
        }
        var checks = report.checks.filter { $0.check != .healthCheck }
        checks.append(replacement)
        // 保持固定顺序展示。
        checks.sort { lhs, rhs in
            let order = UpdateVerificationCheck.allCases
            return (order.firstIndex(of: lhs.check) ?? 0) < (order.firstIndex(of: rhs.check) ?? 0)
        }
        return UpdateVerificationReport(checks: checks)
    }

    // MARK: - 单条检查

    static func executableCheck(path: String?, probe: UpdateArtifactProbe) -> UpdateVerificationCheckResult {
        guard let path, !path.isEmpty else {
            return UpdateVerificationCheckResult(
                check: .executablePresent,
                status: .notChecked,
                detail: "没有可用的可执行文件路径"
            )
        }
        guard probe.isAvailable else {
            return UpdateVerificationCheckResult(
                check: .executablePresent,
                status: .notChecked,
                detail: "本次运行没有注入文件系统探针"
            )
        }
        if probe.isExecutableFile(path) {
            return UpdateVerificationCheckResult(
                check: .executablePresent,
                status: .passed,
                detail: "路径存在且带可执行位"
            )
        }
        return UpdateVerificationCheckResult(
            check: .executablePresent,
            status: .failed,
            detail: "路径不存在或没有可执行位"
        )
    }

    static func realPathCheck(
        path: String?,
        resolved: String?,
        probe: UpdateArtifactProbe
    ) -> UpdateVerificationCheckResult {
        guard let path, !path.isEmpty else {
            return UpdateVerificationCheckResult(
                check: .realPathReadable,
                status: .notChecked,
                detail: "没有可用的可执行文件路径"
            )
        }
        guard probe.isAvailable else {
            return UpdateVerificationCheckResult(
                check: .realPathReadable,
                status: .notChecked,
                detail: "本次运行没有注入文件系统探针"
            )
        }
        guard let real = resolved ?? probe.resolveRealPath(path), !real.isEmpty else {
            return UpdateVerificationCheckResult(
                check: .realPathReadable,
                status: .failed,
                detail: "无法解析出真实路径（符号链接可能悬空）"
            )
        }
        if probe.isReadableFile(real) {
            return UpdateVerificationCheckResult(
                check: .realPathReadable,
                status: .passed,
                detail: "解析后的真实路径可读"
            )
        }
        return UpdateVerificationCheckResult(
            check: .realPathReadable,
            status: .failed,
            detail: "解析后的真实路径不可读"
        )
    }

    static func versionCheck(detected: String?, previous: String?, target: String?) -> UpdateVerificationCheckResult {
        let previousText = previous ?? "未知"
        let targetText = target ?? "由上游更新命令决定"
        if let target, SemanticVersion(target) == nil {
            return UpdateVerificationCheckResult(
                check: .versionReached,
                status: .failed,
                detail: "目标版本不可解析"
            )
        }
        guard let detected, SemanticVersion(detected) != nil else {
            return UpdateVerificationCheckResult(
                check: .versionReached,
                status: .failed,
                detail: "重新检测不到可解析的版本（更新前 \(previousText)，目标 \(targetText)）"
            )
        }
        guard let previous else {
            // 没有更新前版本证据时，只有“重新检测到目标版本”才算通过。
            guard let target, let detectedVersion = SemanticVersion(detected),
                  let targetVersion = SemanticVersion(target) else {
                return UpdateVerificationCheckResult(
                    check: .versionReached,
                    status: .notChecked,
                    detail: "缺少更新前版本与目标版本，无法判定版本是否达到目标"
                )
            }
            let passed = detectedVersion >= targetVersion
            return UpdateVerificationCheckResult(
                check: .versionReached,
                status: passed ? .passed : .failed,
                detail: "重新检测到 \(detected)，目标 \(target)"
            )
        }
        let passed = versionReached(detected: detected, old: previous, target: target)
        let ruleText = target == nil ? "版本需相对更新前发生变化" : "版本需达到目标"
        return UpdateVerificationCheckResult(
            check: .versionReached,
            status: passed ? .passed : .failed,
            detail: "重新检测到 \(detected)（更新前 \(previous)；\(ruleText)）"
        )
    }

    /// 身份层检查。`fingerprintName` 必须是**实际观测到**的包名（例如指纹来自
    /// 真实文件路径）；调用方不得把计划里的期望包名当作检测值传进来，否则
    /// “身份名称一致”会恒真，历史里就会留下一条未经验证的结论。
    static func identityCheck(
        expected: String?,
        detected: String?,
        fingerprintName: String?,
        packageJSONPath: String?,
        executablePath: String?,
        probe: UpdateArtifactProbe
    ) -> UpdateVerificationCheckResult {
        guard let expected, !expected.isEmpty else {
            return UpdateVerificationCheckResult(
                check: .packageIdentity,
                status: .notChecked,
                detail: "没有期望包名，无法核对身份"
            )
        }
        var actual = detected ?? fingerprintName
        if actual == nil, probe.isAvailable {
            if let packageJSONPath, !packageJSONPath.isEmpty {
                actual = probe.packageNameAtPackageJSON(packageJSONPath)
            }
            if actual == nil, let executablePath, !executablePath.isEmpty {
                actual = probe.packageNameNear(executablePath)
            }
        }
        guard let actual else {
            return UpdateVerificationCheckResult(
                check: .packageIdentity,
                status: .notChecked,
                detail: "识别结果与文件系统都没有包名证据，无法核对身份"
            )
        }
        if actual == expected {
            return UpdateVerificationCheckResult(
                check: .packageIdentity,
                status: .passed,
                detail: "包名与期望一致"
            )
        }
        return UpdateVerificationCheckResult(
            check: .packageIdentity,
            status: .failed,
            // 不写出实际名称：名字可能来自被替换的包，避免把不受控文本写进日志/历史。
            detail: "识别到的包名与期望包名不一致（期望 \(expected)）"
        )
    }
}
