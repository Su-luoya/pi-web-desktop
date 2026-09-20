/// Dependency value models: install sources, findings and the dependency report.

import Darwin
import Foundation

// MARK: - 诊断模型

/// 安装来源推断结果，取值与 Issue #6 的 `npm-global / homebrew / local-path /
/// unknown` 一一对应。
enum DependencyInstallSource: String, Equatable {
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
struct DependencyFinding: Equatable {
    enum Kind: String, Equatable {
        case system
        case node
        case piCLI = "pi"
        case piWeb = "pi-web"
        /// 默认服务端口是否可用；只做提示，不阻塞启动。
        case port = "port"
        /// Pi 配置目录（`~/.pi/agent`）是否存在与可读；只做提示，不读取内容。
        case piConfigDirectory = "pi-config"
    }

    enum Status: String, Equatable {
        case ok
        case missing
        case outdated
        /// 端口已被其他进程占用；不阻塞启动（已有的 Pi Web 服务会被直接复用）。
        case occupied
        /// 路径存在但不可读。
        case unreadable
        case unknown
    }

    enum Confidence: String, Equatable {
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
