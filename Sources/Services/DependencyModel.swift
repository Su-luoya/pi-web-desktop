/// Dependency value models: install sources, findings and the dependency report.

import Darwin
import Foundation

// MARK: - 诊断模型

/// 安装来源推断结果，取值与 Issue #6 的 `npm-global / homebrew / local-path /
/// unknown` 一一对应。
enum DependencyInstallSource: String, Codable, Equatable {
    case homebrew = "homebrew"
    case npmGlobal = "npm-global"
    case localPath = "local-path"
    /// 由操作系统直接回答的诊断项（默认端口、Pi 配置目录），不是安装来源推断。
    case system = "system"
    case unknown = "unknown"
}

/// 单条依赖诊断。
///
/// `path`、`resolvedPath`、`symlinkTarget` 都已经由 `DependencyPathRedactor`
/// 脱敏：Home 前缀被替换为 `~`，真实用户名不会离开 `DependencyChecker`。
/// `confidence` 描述整条结论的证据强度，取各项证据（状态/版本、安装来源）里
/// 最弱的一项：
/// - `verified`：探针直接确认（版本输出可解析、package.json 可读、可执行文件
///   存在、npm 前缀或 Homebrew Cellar 命中、OS API 返回值）。
/// - `inferred`：只能由候选路径或路径前缀推断（例如可执行文件存在但读不到版本，
///   或安装来源只能按前缀猜测）。
/// - `unknown`：没有可用证据（找不到文件、版本无法解析、来源无法判断）。
struct DependencyFinding: Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        case system
        case node
        case piCLI = "pi"
        case piWeb = "pi-web"
        /// 默认服务端口是否可用；只做提示，不阻塞启动。
        case port = "port"
        /// Pi 配置目录（`~/.pi/agent`）是否存在与可读；只做提示，不读取内容。
        case piConfigDirectory = "pi-config"
    }

    enum Status: String, Codable, Equatable {
        case ok
        case missing
        case outdated
        /// 端口已被其他进程占用；不阻塞启动（已有的 Pi Web 服务会被直接复用）。
        case occupied
        /// 路径存在但不可读。
        case unreadable
        case unknown
    }

    enum Confidence: String, Codable, Equatable {
        case verified
        case inferred
        case unknown

        /// 证据强度排序：unknown < inferred < verified。
        fileprivate var strength: Int {
            switch self {
            case .unknown: return 0
            case .inferred: return 1
            case .verified: return 2
            }
        }

        /// 整条诊断的可信度取各项证据的最小值。
        static func weakest(_ values: [Confidence]) -> Confidence {
            values.min { $0.strength < $1.strength } ?? .unknown
        }
    }

    var kind: Kind
    var status: Status
    var path: String?
    var resolvedPath: String?
    var symlinkTarget: String?
    var version: String?
    var installSource: DependencyInstallSource
    var confidence: Confidence
    /// `InstallCommandManifest` 里对应的修复项；`status == .ok` 时为 nil。
    var remediationID: String?
    /// pi-web 的 package.json 证据；其他类型为 nil。
    var packageName: String?
    var packageVersion: String?
    /// 状态不是 `ok` 时的可读补充原因：既解释“探针超时”（GitHub #85），也解释
    /// “命令无法执行 / 版本输出不可用”（GitHub #89，例如合并后的工具 PATH 里
    /// 找不到 node）。默认 nil，因此旧调用点与旧断言不受影响；只包含静态文案，
    /// 不含路径与凭据。
    var detail: String? = nil
}

/// 整体诊断结果。
struct DependencyReport: Equatable {
    var findings: [DependencyFinding]
    /// 组件安装识别结果（GitHub #16）：路径、包名、版本、来源、可信度与
    /// 建议命令，路径在离开 `DependencyChecker` 前已完成 Home 脱敏。
    /// 默认空数组，因此旧调用点（测试、smoke 夹具）不受影响。
    var components: [ComponentInstallation] = []

    func finding(for kind: DependencyFinding.Kind) -> DependencyFinding? {
        findings.first { $0.kind == kind }
    }

    /// 某一类组件的安装识别结果；没检测到时返回 nil。
    func component(for kind: ComponentKind) -> ComponentInstallation? {
        components.first { $0.kind == kind }
    }

    /// 硬性前置（必需项）的固定顺序：Node.js、Pi CLI、Pi Web。
    /// 路由、门控和路径选择都读这一份清单，不再各自重复。
    static let prerequisiteKinds: [DependencyFinding.Kind] = [.node, .piCLI, .piWeb]

    /// 未通过的必需项：报告里没有该条目，或状态不是 `.ok`。
    /// 缺项也算未通过：`DependencyReport(findings: [])` 必须进入诊断页，
    /// 不能因为 `blockingFindings` 为空就被当成就绪。
    var unsatisfiedPrerequisiteKinds: [DependencyFinding.Kind] {
        Self.prerequisiteKinds.filter { kind in
            guard let finding = finding(for: kind) else { return true }
            return finding.status != .ok
        }
    }

    /// 阻塞服务启动的诊断项（只包含报告里存在的条目）：Node.js 状态不是 `ok`
    /// （缺失/过旧/无法确定），以及 Pi CLI / Pi Web 状态不是 `ok`（缺失或版本
    /// 无法解析）。系统项、默认端口占用和 Pi 配置目录只做提示，不阻塞启动。
    /// 报告里缺少必需条目时这里不会出现对应项，因此门控不能只用它判定
    /// （见 `unsatisfiedPrerequisiteKinds`）。
    var blockingFindings: [DependencyFinding] {
        findings.filter { finding in
            switch finding.kind {
            case .system, .port, .piConfigDirectory:
                return false
            case .node, .piCLI, .piWeb:
                return finding.status != .ok
            }
        }
    }

    /// 三条硬性前置都存在且状态都是 `.ok` 时才为 true。
    /// 缺少任一条目（例如空报告）或状态为 `.unknown` 都为 false：版本无法解析
    /// 意味着无法核对身份，不能放行启动。
    var canStartService: Bool {
        unsatisfiedPrerequisiteKinds.isEmpty
    }
}

// MARK: - 启动门控快路径缓存（GitHub #169）

/// 缓存里的组件识别结果：字段与 `ComponentInstallation` 一一对应。
///
/// 之所以要这份快照：`ComponentInstallation` 的定义在更新检查模块里，而缓存
/// JSON 需要一份显式 schema。枚举字段一律以 `rawValue` 形式存储，读取时任何
/// 取值无法识别都返回 nil，调用方按“缓存不可用”处理——宁可多跑一次完整检查，
/// 也不能用一份读不懂的旧报告放行启动。
struct DependencyGateCachedComponent: Codable, Equatable {
    var kind: String
    var packageName: String?
    var version: String?
    var executablePath: String?
    var resolvedPath: String?
    var symlinkChain: [String]
    var packageJSONPath: String?
    var source: String
    var confidence: String
    var evidence: [String]
    var suggestedCommand: String?

    init(_ installation: ComponentInstallation) {
        kind = installation.kind.rawValue
        packageName = installation.packageName
        version = installation.version
        executablePath = installation.executablePath
        resolvedPath = installation.resolvedPath
        symlinkChain = installation.symlinkChain
        packageJSONPath = installation.packageJSONPath
        source = installation.source.rawValue
        confidence = installation.confidence.rawValue
        evidence = installation.evidence
        suggestedCommand = installation.suggestedCommand
    }

    /// 还原成 `ComponentInstallation`；枚举取值无法识别时返回 nil。
    func installation() -> ComponentInstallation? {
        guard let kind = ComponentKind(rawValue: kind),
              let source = InstallSource(rawValue: source),
              let confidence = DetectionConfidence(rawValue: confidence)
        else { return nil }
        return ComponentInstallation(
            kind: kind,
            packageName: packageName,
            version: version,
            executablePath: executablePath,
            resolvedPath: resolvedPath,
            symlinkChain: symlinkChain,
            packageJSONPath: packageJSONPath,
            source: source,
            confidence: confidence,
            evidence: evidence,
            suggestedCommand: suggestedCommand
        )
    }
}

/// 缓存失效指纹：任一输入变化都让缓存失效。
///
/// 只包含启动时不必执行命令就能读到的本地输入：应用版本、配置的 pi-web 路径、
/// 工作目录、服务地址与工具 PATH 摘要。工具 PATH 的原文（进程 PATH、登录 shell
/// 路径、主目录）不写进缓存文件，也不写进日志，只留摘要。
struct DependencyGateFingerprint: Codable, Equatable {
    var appVersion: String
    var piWebPath: String
    var workspacePath: String
    var hostname: String
    var port: Int
    var toolPathDigest: String
}

/// 稳定的字符串摘要（FNV-1a 64 位）：只用于判断输入是否变化，不是安全用途。
enum DependencyGateCacheDigest {
    static func digest(_ parts: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for part in parts {
            for byte in part.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            // 分隔符：`["ab", "c"]` 与 `["a", "bc"]` 不能算出同一个摘要。
            hash ^= 0x1f
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// 快路径缓存的有效期策略。
struct DependencyGateCachePolicy: Equatable {
    /// 缓存年龄上限：7 天。命中快路径后仍会跑一次完整复查，缓存只影响首屏速度、
    /// 不影响结论，所以这个值可以取得比较宽松。
    var maximumAge: TimeInterval = 7 * 24 * 60 * 60

    static let standard = DependencyGateCachePolicy()
}

/// 缓存不可用的原因。每一条都会写进启动日志，用于回答“这次为什么没走快路径”。
enum DependencyGateCacheInvalidReason: String, Equatable {
    case missingOrUnreadable
    case schemaMismatch
    case expired
    case fingerprintChanged
    case canStartServiceIsFalse
    case reportUnreadable

    var logText: String {
        switch self {
        case .missingOrUnreadable: return "缓存缺失或不可解析"
        case .schemaMismatch: return "缓存 schema 版本不符"
        case .expired: return "缓存已过期"
        case .fingerprintChanged: return "启动输入指纹已变化"
        case .canStartServiceIsFalse: return "上次检查的结论为不可启动"
        case .reportUnreadable: return "缓存内容无法还原"
        }
    }
}

/// 快路径判定结果。
enum DependencyGateCacheVerdict: Equatable {
    case valid(DependencyReport)
    case invalid(DependencyGateCacheInvalidReason)
}

/// 上一次完整检查的结论 + 失效指纹，存在支持目录下的独立 JSON 文件里
/// （`AppConfiguration.dependencyGateCacheURL`）。不写用户偏好设置、不进仓库；
/// 删掉它只影响下一次启动是否走快路径。
struct DependencyGateCache: Codable, Equatable {
    /// 缓存 schema 版本：字段含义变化时必须 +1，旧缓存随即失效。
    static let schemaVersion = 1

    var schemaVersion: Int
    var writtenAt: Date
    /// 上次检查的结论。不可启动的结论也会写入，但读取端一律拒绝
    /// （见 `DependencyGateFastPath.decide`）：这样“上次不可启动”是一条真实生效
    /// 的失效规则，而不是靠“不写缓存”回避。
    var canStartService: Bool
    var fingerprint: DependencyGateFingerprint
    var findings: [DependencyFinding]
    var components: [DependencyGateCachedComponent]

    init(report: DependencyReport, fingerprint: DependencyGateFingerprint, writtenAt: Date) {
        schemaVersion = Self.schemaVersion
        self.writtenAt = writtenAt
        canStartService = report.canStartService
        self.fingerprint = fingerprint
        findings = report.findings
        components = report.components.map(DependencyGateCachedComponent.init)
    }

    /// 还原报告：`canStartService` 按 findings 重新计算（不单独信任缓存里的布尔
    /// 值）；组件无法识别时返回 nil。
    func report() -> DependencyReport? {
        var installations: [ComponentInstallation] = []
        installations.reserveCapacity(components.count)
        for component in components {
            guard let installation = component.installation() else { return nil }
            installations.append(installation)
        }
        return DependencyReport(findings: findings, components: installations)
    }
}

/// 缓存快路径的纯判定逻辑：不碰文件系统、不依赖 AppKit，因此每一条失效规则都能
/// 在单元测试里覆盖。
enum DependencyGateFastPath {
    /// 判定缓存是否可信。顺序即优先级，返回的 reason 就是日志里写出的原因。
    static func decide(
        cache: DependencyGateCache?,
        fingerprint: DependencyGateFingerprint,
        policy: DependencyGateCachePolicy = .standard,
        now: Date
    ) -> DependencyGateCacheVerdict {
        guard let cache else { return .invalid(.missingOrUnreadable) }
        guard cache.schemaVersion == DependencyGateCache.schemaVersion else {
            return .invalid(.schemaMismatch)
        }
        // 年龄不在 [0, maximumAge] 内都失效：时钟回拨产生的“未来缓存”同样不可信。
        let age = now.timeIntervalSince(cache.writtenAt)
        guard age >= 0, age <= policy.maximumAge else { return .invalid(.expired) }
        guard cache.fingerprint == fingerprint else { return .invalid(.fingerprintChanged) }
        // 上次结论为不可启动时永远重跑完整检查：不放行“有问题的环境”。
        guard cache.canStartService else { return .invalid(.canStartServiceIsFalse) }
        guard let report = cache.report() else { return .invalid(.reportUnreadable) }
        // 最终依据是 findings 重新算出来的结论：缓存里的布尔值不能单独放行。
        guard report.canStartService else { return .invalid(.canStartServiceIsFalse) }
        return .valid(report)
    }

    /// 快路径之后的收敛判据（GitHub #169 的安全关键路径）：后台复查只要不同意
    /// “可以启动”，或路由不再是主窗口，就必须收敛到真实状态。抽成纯函数是为了让
    /// 这条判据本身可被单测覆盖，而不是藏在 `AppDelegate` 的 `if case` 里。
    static func requiresConvergence(canStartService: Bool, routeIsMainWindow: Bool) -> Bool {
        !(routeIsMainWindow && canStartService)
    }
}
