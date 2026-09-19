import CryptoKit
import Foundation

// MARK: - 更新验证（GitHub #23）
//
// 本文件是 #20（Pi Web）/ #21（Pi CLI）/ #22（Pi 扩展包）三条更新路径共用的
// 验证器。它只回答“实际能验证到的事实”，并把每条检查的结果与能力边界写清楚：
//
//   * 可执行文件存在、可执行、解析后的真实路径可读（文件系统事实）；
//   * 版本能被 #16 识别器重新检测，并且达到目标版本（或相对旧版本发生变化）；
//   * `package.json` 的 `name` 与期望包名一致（防替换攻击）；
//   * 服务启动后的健康检查结果（复用既有健康检查路径，由调用方传入）。
//
// 明确**不**做的验证在 `UpdateVerificationCheck.notVerifiedCapabilities` 里列出：
// 不做代码签名验证、不声称能验证官方签名、不做安装包内容哈希或上游文件比对。
// 没有文件系统探针时，文件层检查记为“未验证”，不会伪装成“通过”。
//
// GitHub #63 起，更新前指纹额外记录 inode、可执行文件内容哈希与 npm 记录的
// `integrity`（有界读取；取不到就标注“未获取”）。这些字段只用于判断“旧文件
// 是否仍然是更新前那一份”，不证明发布时间、发布者或来源可信。

// MARK: - 内容哈希结果

/// 对单个可执行文件做内容哈希的结果。只有 `.hashed` 才是真正的哈希；其余三种
/// 都必须如实标注“未做内容哈希”，不允许退回伪哈希或空字符串冒充。
enum UpdateArtifactContentHashResult: Equatable {
    case hashed(String)
    /// 文件超过大小上限：不读取内容，只保留元数据。
    case aboveSizeLimit
    /// 文件打不开或读取失败。
    case unreadable
    /// 本次运行没有内容哈希能力（例如未注入探针）。
    case unsupported

    var hash: String? {
        if case .hashed(let value) = self { return value }
        return nil
    }
}

// MARK: - 文件系统探针

/// 更新验证读取文件系统事实的唯一入口。
///
/// 生产实现是 `UpdateArtifactProbe.live`（只用 `FileManager`）；unhosted 测试
/// 注入假探针，绝不触碰真实用户目录、不读取真实安装、不执行任何命令。
/// `isAvailable == false` 时所有文件层检查都记为“未验证”，而不是猜一个结论。
struct UpdateArtifactProbe {
    /// 探针可用性。false 表示这次运行没有注入文件系统能力。
    var isAvailable: Bool
    var isExecutableFile: (String) -> Bool
    var isReadableFile: (String) -> Bool
    var resolveRealPath: (String) -> String?
    var fileSize: (String) -> Int?
    var modificationDate: (String) -> Date?
    /// `st_ino`：同一个路径下文件被替换时 inode 通常会变化。取不到时返回 nil。
    var fileInode: (String) -> UInt64? = { _ in nil }
    /// 流式读取可执行文件内容并计算哈希；超过大小上限或读不到时返回对应的
    /// “未做内容哈希”结果，不返回伪造值。
    var contentHash: (String) -> UpdateArtifactContentHashResult = { _ in .unsupported }
    /// npm 记录的完整性（`integrity`）值：只从本机 npm 元数据/锁文件读取，
    /// 不联网、不执行 npm；取不到或值不符合哈希形状时返回 nil。
    var npmIntegrity: (String, String?) -> String? = { _, _ in nil }
    /// 读取指定 `package.json` 的 `name` 字段；读不到或不是合法包名时返回 nil。
    var packageNameAtPackageJSON: (String) -> String?
    /// 从可执行文件路径向上最多 6 层找最近的 `package.json` 并读 `name`。
    var packageNameNear: (String) -> String?

    /// 内容哈希的读取上限（16 MiB）。超过上限不读取内容，只退回元数据证据。
    static let contentHashSizeLimitBytes = 16 * 1024 * 1024

    /// 未注入探针：所有文件层检查记为“未验证”。
    static let disabled = UpdateArtifactProbe(
        isAvailable: false,
        isExecutableFile: { _ in false },
        isReadableFile: { _ in false },
        resolveRealPath: { _ in nil },
        fileSize: { _ in nil },
        modificationDate: { _ in nil },
        fileInode: { _ in nil },
        contentHash: { _ in .unsupported },
        npmIntegrity: { _, _ in nil },
        packageNameAtPackageJSON: { _ in nil },
        packageNameNear: { _ in nil }
    )

    /// 生产探针：只使用 `FileManager`，不联网、不执行子进程、不发送信号。
    static let live = UpdateArtifactProbe(
        isAvailable: true,
        isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) },
        isReadableFile: { FileManager.default.isReadableFile(atPath: $0) },
        resolveRealPath: { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        },
        fileSize: { path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else { return nil }
            return size.intValue
        },
        modificationDate: { path in
            (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        },
        fileInode: { path in
            guard let number = (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber]
                    as? NSNumber else { return nil }
            return number.uint64Value
        },
        contentHash: { path in
            UpdateArtifactProbe.readContentHash(atPath: path)
        },
        npmIntegrity: { path, packageName in
            UpdateArtifactProbe.readNpmIntegrity(executablePath: path, packageName: packageName)
        },
        packageNameAtPackageJSON: { path in
            UpdateArtifactProbe.readPackageName(atPackageJSONPath: path)
        },
        packageNameNear: { path in
            UpdateArtifactProbe.readPackageName(near: path)
        }
    )

    /// 流式计算 SHA-256（分块 64 KiB，上限 `contentHashSizeLimitBytes`）。
    /// 只读文件内容；不做任何写入、不执行命令、不联网。
    static func readContentHash(atPath path: String) -> UpdateArtifactContentHashResult {
        guard let size = fileSize(atPath: path) else { return .unreadable }
        if size > contentHashSizeLimitBytes { return .aboveSizeLimit }
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unreadable }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while true {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: 64 * 1024), !read.isEmpty else { break }
                chunk = read
            } catch {
                return .unreadable
            }
            total += chunk.count
            if total > contentHashSizeLimitBytes { return .aboveSizeLimit }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .hashed("sha256:" + digest)
    }

    /// 文件大小（字节）。只读属性，不跟随写入。
    static func fileSize(atPath path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    /// 读取 `package.json` 的 `name`。有界读取（上限 512 KiB），解析失败返回 nil。
    static func readPackageName(atPackageJSONPath path: String) -> String? {
        guard path.hasSuffix("package.json") else { return nil }
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        guard data.count <= 512 * 1024 else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String,
              ComponentInstallationDetector.isPackageName(name) else { return nil }
        return name
    }

    /// npm 记录的完整性值形状校验：`<算法>-<base64 形状>`，长度有上限。
    /// 不符合形状的值一律当作“未获取”，不写进指纹。
    static func isIntegrityValue(_ value: String) -> Bool {
        guard value.count <= 200 else { return false }
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let algorithms = ["sha1", "sha256", "sha384", "sha512", "md5"]
        guard algorithms.contains(String(parts[0])) else { return false }
        let payload = parts[1]
        guard !payload.isEmpty else { return false }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        return payload.allSatisfy { allowed.contains($0) }
    }

    /// 读取 npm 记录的完整性（`integrity`）值，作为降级的附加证据。
    ///
    /// 只读本机文件：从可执行文件目录向上最多 6 层查找 `package-lock.json`、
    /// `.package-lock.json` 与 `node_modules/.package-lock.json`（npm 7+ 的隐藏
    /// 锁文件），在 `packages` / `dependencies` 里找与包名匹配的条目并读 `integrity`。
    /// 取值有界（单个锁文件上限 4 MiB）、值经过形状校验；不联网、不执行 npm、
    /// 不读取 npm 凭据。取不到时返回 nil，调用方必须标注“未获取”。
    static func readNpmIntegrity(executablePath: String, packageName: String?) -> String? {
        guard executablePath.hasPrefix("/") else { return nil }
        let expectedName = packageName ?? readPackageName(near: executablePath)
        guard let expectedName, !expectedName.isEmpty else { return nil }
        var directory = (executablePath as NSString).deletingLastPathComponent
        var depth = 0
        while !directory.isEmpty, directory != "/", depth < 6 {
            for candidate in [
                (directory as NSString).appendingPathComponent("package-lock.json"),
                (directory as NSString).appendingPathComponent(".package-lock.json"),
                (directory as NSString).appendingPathComponent("node_modules/.package-lock.json")
            ] {
                if let integrity = readIntegrityValue(atLockfilePath: candidate, packageName: expectedName) {
                    return integrity
                }
            }
            directory = (directory as NSString).deletingLastPathComponent
            depth += 1
        }
        return nil
    }

    /// 从单个锁文件里取指定包名的 `integrity`。有界读取；解析失败返回 nil。
    static func readIntegrityValue(atLockfilePath path: String, packageName: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        guard data.count <= 4 * 1024 * 1024 else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let packages = object["packages"] as? [String: Any] {
            for (key, value) in packages {
                guard let entry = value as? [String: Any],
                      let integrity = entry["integrity"] as? String,
                      isIntegrityValue(integrity) else { continue }
                let suffix = key.components(separatedBy: "node_modules/").last ?? key
                if suffix == packageName { return integrity }
            }
        }
        if let dependencies = object["dependencies"] as? [String: Any],
           let entry = dependencies[packageName] as? [String: Any],
           let integrity = entry["integrity"] as? String,
           isIntegrityValue(integrity) {
            return integrity
        }
        return nil
    }

    /// 从 `path` 向上最多 6 层找最近的 `package.json` 并读 `name`。
    /// 只做有界目录向上遍历，不递归、不列目录内容。
    static func readPackageName(near path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var directory = (path as NSString).deletingLastPathComponent
        var depth = 0
        while !directory.isEmpty, directory != "/", depth < 6 {
            let candidate = (directory as NSString).appendingPathComponent("package.json")
            if let name = readPackageName(atPackageJSONPath: candidate) {
                return name
            }
            directory = (directory as NSString).deletingLastPathComponent
            depth += 1
        }
        return nil
    }
}

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
        if let target, let targetVersion = SemanticVersion(target) {
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
        checks.append(identityCheck(
            expected: input.packageName,
            detected: input.detectedPackageName,
            fingerprintName: input.fingerprint.packageName,
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
