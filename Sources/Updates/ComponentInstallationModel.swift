import Foundation

// MARK: - 组件安装模型（GitHub #16）

/// 被识别的组件种类。
///
/// `desktopApp` 是应用自身，`piCLI` / `piWeb` 是两个独立的上游包，
/// `piPackage` 是 Pi CLI 管理的扩展包（`pi list` 报告的那些）。#17/#18 的
/// 更新计划直接以这个模型为输入。

/// Component install model: kinds, install sources, confidence and installation facts.

enum ComponentKind: String, Equatable, CaseIterable {
    case desktopApp = "desktop-app"
    case piCLI = "pi"
    case piWeb = "pi-web"
    case piPackage = "pi-package"

    var displayName: String {
        switch self {
        case .desktopApp: return "Pi Web Desktop"
        case .piCLI: return "Pi CLI"
        case .piWeb: return "Pi Web"
        case .piPackage: return "Pi 扩展包"
        }
    }
}

/// 安装来源。
///
/// 这是“能不能用包管理器更新、用什么命令更新”的唯一判据：#16 明确要求不得
/// 仅凭路径前缀（例如 `/opt/homebrew/bin`）下结论，也不得统一给出
/// `npm install -g`。判定规则见 `ComponentSourceResolver`。
enum InstallSource: String, Equatable, CaseIterable {
    case npmGlobal = "npm-global"
    case pnpmGlobal = "pnpm-global"
    case homebrew
    /// nvm 管理的 Node 版本目录（`versions/node/<版本>/…`）。
    case nvm
    /// mise 管理的 Node 安装目录（`installs/<工具>/<版本>/…`）。
    case mise
    /// 官方安装器 / 发布产物（例如 Applications 目录下的应用包）。
    case officialInstaller = "official-installer"
    /// 包目录内有 `.git` 的源码检出。
    case gitCheckout = "git-checkout"
    /// 本地路径：Home 下的自定义目录、手工放置的可执行文件。
    case localPath = "local-path"
    case unknown

    var displayName: String {
        switch self {
        case .npmGlobal: return "npm 全局"
        case .pnpmGlobal: return "pnpm 全局"
        case .homebrew: return "Homebrew"
        case .nvm: return "nvm"
        case .mise: return "mise"
        case .officialInstaller: return "官方安装器"
        case .gitCheckout: return "git checkout"
        case .localPath: return "本地路径"
        case .unknown: return "未知"
        }
    }

    /// 只有 npm/pnpm 全局来源才允许给出对应包管理器的更新命令。其它来源
    /// （Homebrew、nvm/mise、git checkout、本地路径、未知）一律只给指引或
    /// “请按来源文档更新”，避免把包管理器命令用在它管不到的安装上。
    var isPackageManagerManaged: Bool {
        self == .npmGlobal || self == .pnpmGlobal
    }
}

/// 判定可信度。语义与 #6 的 `DependencyFinding.Confidence` 一致，独立成类型是
/// 为了让组件模型不依赖诊断报告：
/// - `verified`：探针直接确认（命令输出、package.json、Cellar/opt 结构、
///   npm/pnpm 全局 root 命中、包目录内 `.git`、可执行位 + 可执行文件存在）。
/// - `inferred`：只能由弱证据推断（例如 Home 下的本地路径、Applications
///   目录下的应用包、包名与 package.json 不一致）。
/// - `unknown`：证据不足（找不到可执行文件、版本无法解析、来源无法判定）。
enum DetectionConfidence: String, Equatable, CaseIterable {
    case verified
    case inferred
    case unknown

    var displayName: String {
        switch self {
        case .verified: return "已验证"
        case .inferred: return "推断"
        case .unknown: return "未知"
        }
    }

    /// 证据强度排序：unknown < inferred < verified。
    var strength: Int {
        switch self {
        case .unknown: return 0
        case .inferred: return 1
        case .verified: return 2
        }
    }

    /// 整条结论取各项证据里最弱的一项。
    static func weakest(_ values: [DetectionConfidence]) -> DetectionConfidence {
        values.min { $0.strength < $1.strength } ?? .unknown
    }
}

/// 单个组件的安装事实。
///
/// 模型只包含“事实 + 判定 + 证据”，不含任何执行能力：它不安装、不升级、不写
/// 文件。#17/#18 负责计划与用户确认，执行不在本模型里。
struct ComponentInstallation: Equatable {
    var kind: ComponentKind
    /// package.json（或 `pi list`）报告的包名；识别不出时为 nil。
    var packageName: String?
    /// 解析出的版本；没有任何证据时为 nil（不要用别的版本填充）。
    var version: String?
    /// 调用方给出的可执行文件路径（可能是符号链接）。
    var executablePath: String?
    /// 完整解析符号链接后的真实路径；链悬空或无法解析时为 nil。
    var resolvedPath: String?
    /// 完整符号链接链，从 `executablePath` 到链尾（含每一跳）。
    var symlinkChain: [String]
    /// 最近一层 package.json 的路径。
    var packageJSONPath: String?
    var source: InstallSource
    var confidence: DetectionConfidence
    /// 判定依据；非 `verified` 时必然有一条“未验证原因：…”。
    var evidence: [String]
    /// 只来自 `InstallCommandManifest` 的静态命令；nil 表示“只展示指引、
    /// 不给出任何更新命令”（来源不是已验证的 npm/pnpm 全局或没有对应条目）。
    var suggestedCommand: String?

    /// 诊断导出与状态页共用的一行摘要：路径、包名、版本、来源、可信度、建议命令。
    /// 缺值用占位符，不省略字段。
    var summaryLine: String {
        let packageText: String
        if let name = packageName, let version {
            packageText = "\(name)@\(version)"
        } else if let name = packageName {
            packageText = name
        } else if let version {
            packageText = version
        } else {
            packageText = "未找到"
        }
        let commandText = suggestedCommand ?? "无（请按来源文档更新）"
        return "\(kind.displayName)（\(kind.rawValue)）：路径 \(executablePath ?? "未找到")"
            + "；包名 \(packageText)"
            + "；来源 \(source.displayName)"
            + "；可信度 \(confidence.displayName)"
            + "；建议命令 \(commandText)"
    }

    /// 按 Home 前缀脱敏的副本。
    ///
    /// 只改用于展示的路径字段与证据文本；`source`、`confidence`、`version` 等
    /// 判定结果保持不变。脱敏在诊断报告离开 `DependencyChecker` 之前完成，
    /// 与 #6 的约定一致。
    func redacted(using redactor: DependencyPathRedactor) -> ComponentInstallation {
        var copy = self
        copy.executablePath = executablePath.map { redactor.redact($0) }
        copy.resolvedPath = resolvedPath.map { redactor.redact($0) }
        copy.symlinkChain = symlinkChain.map { redactor.redact($0) }
        copy.packageJSONPath = packageJSONPath.map { redactor.redact($0) }
        // 证据行里的路径不一定在行首（例如 `npm root -g → ` 后面紧跟用户主目录前缀），
        // 所以这里替换所有出现的 Home 前缀，而不只是行首；写注释时不要写出该前缀的字面量，
        // 否则仓库自己的 personal-data 门禁会把这条注释当成命中的样例。
        copy.evidence = evidence.map { redactor.redactingAllOccurrences(in: $0) }
        return copy
    }
}
