import Foundation

// MARK: - 组件安装模型（GitHub #16）

/// 被识别的组件种类。
///
/// `desktopApp` 是应用自身，`piCLI` / `piWeb` 是两个独立的上游包，
/// `piPackage` 是 Pi CLI 管理的扩展包（`pi list` 报告的那些）。#17/#18 的
/// 更新计划直接以这个模型为输入。
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

extension DependencyPathRedactor {
    /// 替换字符串里所有处于路径边界的 Home 前缀（Home 本身、`<home>/…`），
    /// 不误伤 `<home>-other` 这种同前缀目录。用于证据行里的路径脱敏。
    func redactingAllOccurrences(in text: String) -> String {
        guard !homeDirectory.isEmpty, homeDirectory != "/" else { return text }
        guard text.contains(homeDirectory) else { return text }
        var result = ""
        var remainder = Substring(text)
        while let range = remainder.range(of: homeDirectory) {
            let after = remainder[range.upperBound...]
            let isBoundary = after.isEmpty || after.first == "/"
            result += remainder[..<range.lowerBound]
            result += isBoundary ? "~" : homeDirectory
            remainder = after
        }
        result += remainder
        return result
    }
}

// MARK: - 应用自身安装形态

/// 应用自身的只读安装信息（`desktopApp` 组件）。
///
/// 默认是 `.none`：unhosted 测试、smoke 和 `--version` 之外的调用都不会读到
/// 真实 bundle 路径。app target 的 `AppDelegate` 显式传入 `.current`。
struct ApplicationInstallationProbe: Equatable {
    var bundlePath: String?
    var version: String?
    var bundleIdentifier: String?

    static let none = ApplicationInstallationProbe(bundlePath: nil, version: nil, bundleIdentifier: nil)

    /// 运行中的应用自己。版本只从 Info.plist 读取，不在源码里写版本字面值。
    static var current: ApplicationInstallationProbe {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ApplicationInstallationProbe(
            bundlePath: Bundle.main.bundleURL.path,
            version: (version?.isEmpty == false) ? version : nil,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }
}

// MARK: - 来源判定（纯规则）

/// 来源判定的输入：只包含已经收集到的证据。
///
/// `resolve` 因此是纯函数：不执行命令、不读盘，规则可以直接用构造出来的证据
/// 断言（包括“仅凭路径前缀不能判定”的反例）。
struct ComponentSourceEvidence: Equatable {
    var kind: ComponentKind
    var executablePath: String?
    var resolvedPath: String?
    var symlinkChain: [String] = []
    /// 最近一层 package.json 所在目录。
    var packageDirectory: String?
    /// 包目录（或向上）里 `.git` 的路径；nil 表示没有 git 证据。
    var gitEvidencePath: String?
    /// `npm root -g`（或 `npm prefix -g` + `lib/node_modules`）解析出的全局 root。
    var npmRoot: String?
    var npmRootEvidence: String?
    /// `pnpm root -g` 解析出的全局 root。
    var pnpmRoot: String?
    var pnpmRootEvidence: String?
    var environment: [String: String] = [:]
    var homeDirectory: String = ""
}

/// 来源判定结论。
struct ComponentSourceVerdict: Equatable {
    var source: InstallSource
    var confidence: DetectionConfidence
    var evidence: [String]
}

/// 证据组合 → 安装来源的纯规则（GitHub #16）。
///
/// 判定优先级（每条都以“证据组合”为前提，不使用单一前缀）：
/// 1. Homebrew：**Cellar/opt 结构**（`Cellar/<formula>/<版本>/…` 或
///    `<homebrew 根>/opt/<formula>/…`）。仅在 `/opt/homebrew/bin` 下不算。
/// 2. nvm：`versions/node/<版本>` 路径段 + `.nvm` 目录或 `NVM_DIR`/`NVM_BIN`
///    环境标记；只有路径段没有标记不算。
/// 3. mise：`installs/<工具>/<版本>` 路径段 + `mise` 目录或 `MISE_*` 环境标记。
/// 4. pnpm 全局：真实路径在 `pnpm root -g` 报告的 root 之下。
/// 5. npm 全局：真实路径在 `npm root -g`（或 `npm prefix -g` +
///    `lib/node_modules`）报告的 root 之下。
/// 6. git checkout：包目录（或向上）里存在 `.git`。
/// 7. 官方安装器（仅 `desktopApp`）：`.app` 包且位于 Applications 目录。
/// 8. 弱证据：`~/.npm-global`、`/lib/node_modules`、`/pnpm/global/` 路径段 →
///    包管理器来源但只能算 `inferred`。
/// 9. 本地路径：真实路径在 Home 下且没有其它证据 → `localPath`，`inferred`。
/// 10. 其余一律 `unknown`：证据不足时绝不猜测，`evidence` 里写明“为什么不是
///     verified”（例如只命中 Homebrew 前缀但没有 Cellar/opt 结构）。
enum ComponentSourceResolver {
    static func resolve(_ input: ComponentSourceEvidence) -> ComponentSourceVerdict {
        let resolved = normalized(input.resolvedPath ?? input.executablePath)
        let executable = normalized(input.executablePath)
        let chain = input.symlinkChain.map(normalized)
        let home = normalized(input.homeDirectory)
        let paths = [executable, resolved].compactMap { $0 } + chain

        var notes: [String] = []

        // 1. Homebrew：Cellar/opt 结构本身就是 formula 证据。
        if let layout = homebrewLayout(in: paths) {
            notes.append(
                "Homebrew 证据：\(layout.root)/\(layout.kind)/\(layout.formula)"
                    + "（Cellar/opt 结构，不是仅凭路径前缀）"
            )
            return ComponentSourceVerdict(source: .homebrew, confidence: .verified, evidence: notes)
        }

        // 2. nvm
        if let marker = nodeVersionManagerMarker(
            paths: paths,
            environment: input.environment,
            directoryName: ".nvm",
            environmentKeys: ["NVM_DIR", "NVM_BIN"]
        ) {
            notes.append("nvm 证据：\(marker)")
            return ComponentSourceVerdict(source: .nvm, confidence: .verified, evidence: notes)
        }

        // 3. mise
        if let marker = miseMarker(paths: paths, environment: input.environment) {
            notes.append("mise 证据：\(marker)")
            return ComponentSourceVerdict(source: .mise, confidence: .verified, evidence: notes)
        }

        // 4. pnpm 全局（命令报告的 root 命中）
        if let pnpmRoot = input.pnpmRoot.map(normalized), !pnpmRoot.isEmpty,
           contains(resolved, under: pnpmRoot) {
            notes.append("pnpm 全局 root：\(input.pnpmRootEvidence ?? pnpmRoot)；真实路径 \(resolved) 在其下")
            return ComponentSourceVerdict(source: .pnpmGlobal, confidence: .verified, evidence: notes)
        }

        // 5. npm 全局（命令报告的 root 命中）
        if let npmRoot = input.npmRoot.map(normalized), !npmRoot.isEmpty,
           contains(resolved, under: npmRoot) {
            notes.append("npm 全局 root：\(input.npmRootEvidence ?? npmRoot)；真实路径 \(resolved) 在其下")
            return ComponentSourceVerdict(source: .npmGlobal, confidence: .verified, evidence: notes)
        }

        // 链接路径在包管理器 root 内、真实路径不在：npm link / 本地覆盖。记录矛盾，
        // 并按真实路径继续判定，不把“链接位置”当成安装来源。
        if let npmRoot = input.npmRoot.map(normalized), !npmRoot.isEmpty,
           contains(executable, under: npmRoot), !contains(resolved, under: npmRoot) {
            notes.append("链接路径 \(executable) 在 npm 全局 root \(npmRoot) 内，但真实路径是 \(resolved)：疑似 npm link 或本地覆盖，因此不按 npm 全局判定")
        }
        if let pnpmRoot = input.pnpmRoot.map(normalized), !pnpmRoot.isEmpty,
           contains(executable, under: pnpmRoot), !contains(resolved, under: pnpmRoot) {
            notes.append("链接路径 \(executable) 在 pnpm 全局 root \(pnpmRoot) 内，但真实路径是 \(resolved)：疑似 pnpm link 或本地覆盖，因此不按 pnpm 全局判定")
        }

        // 6. git checkout：包目录（或向上）里的 `.git`。
        if let gitPath = input.gitEvidencePath {
            notes.append("git checkout 证据：包目录内存在 \(gitPath)")
            return ComponentSourceVerdict(source: .gitCheckout, confidence: .verified, evidence: notes)
        }

        // 7. 官方安装器（仅应用自身）：`.app` 包且位于 Applications 目录。
        if input.kind == .desktopApp, isUnderApplicationsDirectory(resolved) {
            notes.append("应用形态：\(resolved) 是 .app 包且位于 Applications 目录")
            notes.append(unverifiedReason("只能确认是应用包与安装目录，无法确认具体安装方式（官方安装器/拖拽/其它）"))
            return ComponentSourceVerdict(source: .officialInstaller, confidence: .inferred, evidence: notes)
        }

        // 8. 弱证据：包管理器常见目录形态，但命令没有给出对应 root。
        if !home.isEmpty, contains(resolved, under: home + "/.npm-global") {
            notes.append("弱证据：真实路径在 ~/.npm-global 下（npm 的用户级前缀常见位置）")
            notes.append(unverifiedReason("npm root -g / npm prefix -g 没有给出对应 root，只能按目录形态推断"))
            return ComponentSourceVerdict(source: .npmGlobal, confidence: .inferred, evidence: notes)
        }
        if resolved.contains("/lib/node_modules/") {
            notes.append("弱证据：真实路径包含 /lib/node_modules/（npm 全局安装的目录形态）")
            notes.append(unverifiedReason("npm root -g / npm prefix -g 没有给出覆盖该路径的 root，只能按目录形态推断"))
            return ComponentSourceVerdict(source: .npmGlobal, confidence: .inferred, evidence: notes)
        }
        if resolved.contains("/pnpm/global/") {
            notes.append("弱证据：真实路径包含 pnpm 全局目录形态（/pnpm/global/）")
            notes.append(unverifiedReason("pnpm root -g 没有给出覆盖该路径的 root，只能按目录形态推断"))
            return ComponentSourceVerdict(source: .pnpmGlobal, confidence: .inferred, evidence: notes)
        }

        // 9. Homebrew 前缀反例：只有前缀，没有 Cellar/opt 结构。
        if isHomebrewPrefix(resolved) || isHomebrewPrefix(executable) {
            notes.append("路径位于 Homebrew 前缀（\(homebrewPrefixDescription(for: resolved) ?? homebrewPrefixDescription(for: executable) ?? "未知")）但没有 Cellar/opt 结构或 formula 证据：仅凭前缀不判定为 Homebrew")
        }

        // 真实路径无法确定（符号链接链悬空）：只能 unknown，不拿链接路径当地址。
        if input.resolvedPath == nil, input.executablePath != nil {
            notes.append("可执行文件的符号链接链悬空：真实路径无法确定")
        }

        // 10. 本地路径：真实路径在 Home 下、文件存在且没有其它证据。
        let resolvedPath = normalized(input.resolvedPath)
        if !home.isEmpty, !resolvedPath.isEmpty, contains(resolvedPath, under: home) {
            notes.append("弱证据：真实路径 \(resolved) 在 Home 目录下，且没有包管理器 / git / 版本管理器证据")
            notes.append(unverifiedReason("本地路径不能说明安装方式，只能判定为 localPath"))
            return ComponentSourceVerdict(source: .localPath, confidence: .inferred, evidence: notes)
        }

        // 11. 证据不足：不要猜。
        if resolved.isEmpty || resolved == "~" {
            notes.append("没有可判定的路径：没有找到可执行文件或应用包")
        } else {
            notes.append("证据组合：未命中 Homebrew Cellar/opt、nvm/mise 路径段、npm/pnpm 全局 root，包目录内也没有 .git")
        }
        notes.append(unverifiedReason("证据不足，判定为 unknown"))
        return ComponentSourceVerdict(source: .unknown, confidence: .unknown, evidence: notes)
    }

    // MARK: - 规则辅助

    private static func unverifiedReason(_ text: String) -> String {
        "未验证原因：\(text)"
    }

    private static func normalized(_ path: String?) -> String {
        var value = path ?? ""
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    /// 路径是否等于 root 或位于 root 之下（按路径段，避免 `/a/bc` 命中 `/a/b`）。
    private static func contains(_ path: String, under root: String) -> Bool {
        guard !path.isEmpty, !root.isEmpty, root != "~" else { return false }
        return path == root || path.hasPrefix(root + "/")
    }

    private struct HomebrewLayout: Equatable {
        var root: String
        var kind: String
        var formula: String
    }

    /// 识别 `Cellar/<formula>/<版本>/…` 与 `<Homebrew 根>/opt/<formula>/…`。
    private static func homebrewLayout(in paths: [String]) -> HomebrewLayout? {
        for path in paths where !path.isEmpty {
            let components = (path as NSString).pathComponents
            for index in components.indices {
                let component = components[index]
                guard component == "Cellar" || component == "opt" else { continue }
                let root = NSString.path(withComponents: Array(components[0..<index]))
                guard isHomebrewRoot(root), index + 1 < components.count else { continue }
                let formula = components[index + 1]
                guard !formula.isEmpty, !formula.hasPrefix(".") else { continue }
                if component == "Cellar" {
                    // Cellar 结构必须带版本段；裸 `Cellar/<formula>` 不作为证据。
                    guard index + 2 < components.count,
                          SemanticVersion(components[index + 2]) != nil else { continue }
                }
                return HomebrewLayout(root: root, kind: component, formula: formula)
            }
        }
        return nil
    }

    private static func isHomebrewRoot(_ root: String) -> Bool {
        root == "/opt/homebrew" || root == "/usr/local" || root.lowercased().hasSuffix("/homebrew")
    }

    /// 只用于反例说明：路径是否位于一个 Homebrew 前缀下（不作为来源证据）。
    private static func isHomebrewPrefix(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/")
    }

    private static func homebrewPrefixDescription(for path: String) -> String? {
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/opt/homebrew/") { return "/opt/homebrew" }
        if path.hasPrefix("/usr/local/") { return "/usr/local" }
        return nil
    }

    /// nvm：`versions/node/<版本>` 路径段 + `.nvm` 目录或 `NVM_DIR`/`NVM_BIN` 标记。
    private static func nodeVersionManagerMarker(
        paths: [String],
        environment: [String: String],
        directoryName: String,
        environmentKeys: [String]
    ) -> String? {
        let markers = environmentKeys.compactMap { key -> String? in
            guard let value = environment[key] else { return nil }
            let trimmed = normalized(value)
            return trimmed.isEmpty ? nil : trimmed
        }
        for path in paths where !path.isEmpty {
            guard let segment = nodeVersionSegment(in: path) else { continue }
            let components = (path as NSString).pathComponents
            if components.contains(directoryName) {
                let markerText = markers.isEmpty ? "没有环境标记" : "环境标记 \(environmentKeys.joined(separator: "/")) 已设置"
                return "路径段 \(segment) 位于 \(directoryName) 目录；\(markerText)"
            }
            if markers.contains(where: { contains(path, under: $0) }) {
                return "路径在 \(environmentKeys.joined(separator: "/")) 标记的目录内；路径段 \(segment)"
            }
        }
        return nil
    }

    private static func nodeVersionSegment(in path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard components.count >= 3 else { return nil }
        for index in 0..<(components.count - 2) {
            if components[index] == "versions", components[index + 1] == "node",
               !components[index + 2].isEmpty, components[index + 2] != "/" {
                return "versions/node/\(components[index + 2])"
            }
        }
        return nil
    }

    /// mise：`installs/<工具>/<版本>` 路径段 + `mise` 目录或 `MISE_*` 标记。
    private static func miseMarker(paths: [String], environment: [String: String]) -> String? {
        let markers = ["MISE_DATA_DIR", "MISE_INSTALLS_DIR", "MISE_SHIMS_DIR"].compactMap { key -> String? in
            guard let value = environment[key] else { return nil }
            let trimmed = normalized(value)
            return trimmed.isEmpty ? nil : trimmed
        }
        for path in paths where !path.isEmpty {
            guard let segment = miseInstallSegment(in: path) else { continue }
            let components = (path as NSString).pathComponents
            if components.contains("mise") {
                return "路径段 \(segment) 位于 mise 目录"
            }
            if markers.contains(where: { contains(path, under: $0) }) {
                return "路径段 \(segment)；命中的 MISE_* 环境标记：\(markers.joined(separator: ", "))"
            }
        }
        return nil
    }

    private static func miseInstallSegment(in path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard components.count >= 4 else { return nil }
        for index in 0..<(components.count - 3) {
            if components[index] == "installs",
               !components[index + 1].isEmpty, components[index + 1] != "/",
               SemanticVersion(components[index + 2]) != nil {
                return "installs/\(components[index + 1])/\(components[index + 2])"
            }
        }
        return nil
    }

    /// `.app` 包且位于 Applications 目录（用户、系统或任意层级下的 Applications）。
    private static func isUnderApplicationsDirectory(_ path: String) -> Bool {
        guard !path.isEmpty, (path as NSString).pathExtension == "app" else { return false }
        return (path as NSString).pathComponents.contains("Applications")
    }
}

// MARK: - 识别器

/// 组件安装识别器（GitHub #16）。
///
/// 只做只读探测：命令只执行 `--version`、`npm root -g`、`npm prefix -g`、
/// `pnpm root -g`、`pi list` 和 `command -v <编译期字面量>`；磁盘只经
/// `DependencyFileSystemProbing`（#6 的同一组探针）读取。它不安装、不升级、
/// 不联网、不写文件、不调用 `sudo`，也不读取 Pi 认证内容。
struct ComponentInstallationDetector {
    static let shellPath = "/bin/zsh"
    static let runnerPath = "/usr/bin/env"
    /// package.json 与 `.git` 向上查找的最大层数。
    static let packageSearchDepth = 6
    /// 符号链接链的最大跳数；超过即判定为无法解析，不无限循环。
    static let maximumSymlinkHops = 16

    private let commandRunner: CommandRunning
    private let fileSystem: DependencyFileSystemProbing
    private let environment: [String: String]
    private let homeDirectory: String
    /// 调用方已经解析出来的 `npm prefix -g`（#6 的诊断已执行过一次）；
    /// nil 表示本类型在需要时自行查询。
    private let knownNPMPrefix: String?
    /// 命令探测的子进程环境（GitHub #89）：由 `ToolPathProvider` 构建，含登录
    /// shell / 已知目录 / node 目录的 PATH。nil 表示按 runner 自己的选择执行。
    private let commandEnvironment: [String: String]?

    init(
        commandRunner: CommandRunning = SystemCommandRunner(),
        fileSystem: DependencyFileSystemProbing = SystemDependencyFileSystemProbe(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String? = nil,
        knownNPMPrefix: String? = nil,
        commandEnvironment: [String: String]? = nil
    ) {
        self.commandRunner = commandRunner
        self.fileSystem = fileSystem
        self.environment = environment
        self.homeDirectory = Self.normalizedDirectory(homeDirectory ?? fileSystem.homeDirectoryPath())
        self.knownNPMPrefix = knownNPMPrefix
        self.commandEnvironment = commandEnvironment
    }

    // MARK: - 请求

    /// 一个组件的检测请求。候选路径与可执行名都由调用方以编译期字面量给出，
    /// 识别器不会把用户输入拼进任何命令。
    struct ComponentDetectionRequest: Equatable {
        var kind: ComponentKind
        /// 期望的包名（用于和 package.json `name` 交叉验证）；nil 表示不核对。
        var packageName: String?
        /// `command -v` 回退与 package.json `bin` 交叉验证用的可执行名。
        var executableNames: [String] = []
        /// 默认候选路径；存在性与可执行位由文件系统探针回答。
        var candidates: [String] = []
        /// 已由调用方解析的版本（#6 的 finding 或 Info.plist）；非 nil 时本识别器
        /// 不再执行 `--version`。nil 表示按命令输出 / package.json 解析。
        var knownVersion: String?
        /// 是否执行 `<path> --version`；应用 bundle 没有该开关，传 false。
        var runsVersionCommand: Bool = true
        /// 路径是 `.app` 包（应用自身）：存在性按目录判断，来源按应用形态判定。
        var isApplicationBundle: Bool = false
        /// 候选路径都不存在时是否用登录 shell 的 `command -v` 再找一次。
        /// `DependencyChecker` 已经自己解析过可执行文件，传 false 避免重复执行。
        var probesShellPath: Bool = true
    }

    /// `pi list` 的一行解析结果。
    struct PiPackageEntry: Equatable {
        var name: String
        var version: String?
    }

    // MARK: - 入口

    /// 检测单个组件。
    func detect(_ request: ComponentDetectionRequest) -> ComponentInstallation {
        detect(request, roots: packageManagerRoots())
    }

    /// 批量检测：npm/pnpm 全局 root 只查询一次，多个组件共用同一组证据。
    func detectAll(_ requests: [ComponentDetectionRequest]) -> [ComponentInstallation] {
        let roots = packageManagerRoots()
        return requests.map { detect($0, roots: roots) }
    }

    /// `pi list` 报告的 Pi 扩展包。
    ///
    /// 命令失败或输出不可解析时返回一个 `unknown` 的 `piPackage` 条目（不崩溃、
    /// 不猜测包名与版本）。没有 pi 可执行文件时返回空数组：没有证据就不生成条目。
    func detectPiPackages(piExecutablePath: String?) -> [ComponentInstallation] {
        guard let piExecutablePath, fileSystem.isExecutableFile(atPath: piExecutablePath) else {
            return []
        }
        guard let output = commandRunner.run([piExecutablePath, "list"], environment: commandEnvironment) else {
            return [Self.unknownPiPackage(evidence: [
                "`pi list` 执行失败（无输出或非零退出；命令无法执行时先确认合并后的工具 PATH 里能找到 node）",
                "未验证原因：没有可解析的包列表，降级为 unknown（不猜测包名与版本）"
            ])]
        }
        let parsed = Self.parsePiList(output)
        guard !parsed.isEmpty else {
            return [Self.unknownPiPackage(evidence: [
                "`pi list` 输出了 \(Self.lineCount(of: output)) 行，但没有可解析的“包名@版本”行",
                "未验证原因：输出形态不符合 `包名@版本` / `包名 版本`，降级为 unknown（不猜测包名与版本）"
            ])]
        }
        let roots = packageManagerRoots()
        return parsed.map { piPackageInstallation(entry: $0, roots: roots) }
    }

    // MARK: - 单组件检测

    private func detect(
        _ request: ComponentDetectionRequest,
        roots: PackageManagerRoots
    ) -> ComponentInstallation {
        var evidence: [String] = []

        // 1. 可执行文件 / 应用包：存在性、可执行位与完整符号链接链。
        let probe: ExecutableProbe
        if request.isApplicationBundle, let bundlePath = request.candidates.first {
            probe = makeApplicationProbe(path: bundlePath)
        } else {
            probe = probeExecutable(
                candidates: request.candidates,
                names: request.executableNames,
                probesShellPath: request.probesShellPath
            )
        }
        evidence.append(contentsOf: probe.evidence)

        // 2. 最近一层 package.json（name/version/bin）。
        let analysisPath = (probe.resolvedPath ?? probe.executablePath).map(Self.normalizedPath)
        let metadata = nearestPackageMetadata(startingAt: analysisPath)
        if let metadata {
            evidence.append(contentsOf: metadata.evidence)
        } else if probe.executablePath != nil {
            evidence.append("package.json：向上 \(Self.packageSearchDepth) 层没有找到")
        }

        // 3. 包目录内 `.git`（git checkout 证据）。
        let gitStartDirectory = metadata?.directory ?? analysisPath.map {
            ($0 as NSString).deletingLastPathComponent
        }
        let gitEvidencePath = gitEvidence(startingDirectory: gitStartDirectory)
        if let gitEvidencePath {
            evidence.append("`.git`：\(gitEvidencePath)")
        }

        // 4. 来源判定（纯规则，输入是上面收集到的证据组合）。
        let verdict = ComponentSourceResolver.resolve(ComponentSourceEvidence(
            kind: request.kind,
            executablePath: probe.executablePath,
            resolvedPath: probe.resolvedPath,
            symlinkChain: probe.symlinkChain,
            packageDirectory: metadata?.directory,
            gitEvidencePath: gitEvidencePath,
            npmRoot: roots.npmRoot,
            npmRootEvidence: roots.npmRootEvidence,
            pnpmRoot: roots.pnpmRoot,
            pnpmRootEvidence: roots.pnpmRootEvidence,
            environment: environment,
            homeDirectory: homeDirectory
        ))
        evidence.append(contentsOf: verdict.evidence)

        // 5. 版本：已知版本 → `--version` → package.json（#6 的优先级）。
        var version = request.knownVersion
        var versionConfidence: DetectionConfidence = version == nil ? .unknown : .verified
        if let known = request.knownVersion {
            evidence.append("版本 \(known)：由调用方已解析（依赖诊断或 Info.plist），本识别器不重复执行命令")
        } else if request.runsVersionCommand, probe.isPresent, let executablePath = probe.executablePath {
            if let output = trimmed(commandRunner.run([executablePath, "--version"], environment: commandEnvironment)),
               let parsed = SemanticVersion.firstVersion(in: output) {
                version = parsed.description
                versionConfidence = .verified
                evidence.append("`--version` 输出可解析：\(parsed.description)")
            } else {
                evidence.append("`--version` 没有可解析的版本输出（命令可能无法执行：PATH 里缺少 node）")
            }
        }
        if version == nil, let packageVersion = metadata?.version {
            version = packageVersion
            versionConfidence = .verified
            evidence.append("package.json version=\(packageVersion)")
        }
        if version == nil {
            versionConfidence = .unknown
            if let metadata {
                if metadata.parseFailed {
                    evidence.append("未验证原因：package.json 无法解析，也没有其它版本证据")
                } else {
                    evidence.append("未验证原因：package.json 缺少可用的 version，也没有其它版本证据")
                }
            } else {
                evidence.append("未验证原因：没有可解析的版本证据（--version / package.json / pi list 都没有结果）")
            }
        }

        // 6. 包名核对：与期望包名不一致时只能算推断。
        var nameConfidence: DetectionConfidence = .verified
        if let requested = request.packageName, let found = metadata?.name, requested != found {
            nameConfidence = .inferred
            evidence.append("未验证原因：package.json name=\(found) 与期望包名 \(requested) 不一致")
        }

        // 7. 建议命令只来自静态清单，且只对“已验证的 npm/pnpm 全局”给出。
        let suggestedCommand = Self.suggestedCommand(
            kind: request.kind,
            source: verdict.source,
            confidence: verdict.confidence
        )
        if let guidance = InstallCommandManifest.updateGuidance(for: request.kind, source: verdict.source),
           guidance.command == nil {
            evidence.append("更新指引：\(guidance.note)")
        }
        if suggestedCommand == nil {
            if verdict.source.isPackageManagerManaged {
                evidence.append("未给出更新命令：来源 \(verdict.source.displayName) 但没有对应的静态命令条目")
            } else {
                evidence.append("未给出更新命令：来源 \(verdict.source.displayName) 不支持包管理器命令，请按来源文档更新")
            }
        }

        let confidence = DetectionConfidence.weakest([
            probe.isPresent ? .verified : .unknown,
            versionConfidence,
            verdict.confidence,
            nameConfidence
        ])

        return ComponentInstallation(
            kind: request.kind,
            packageName: metadata?.name ?? request.packageName,
            version: version,
            executablePath: probe.executablePath,
            resolvedPath: probe.resolvedPath,
            symlinkChain: probe.symlinkChain,
            packageJSONPath: metadata?.path,
            source: verdict.source,
            confidence: confidence,
            evidence: evidence,
            suggestedCommand: suggestedCommand
        )
    }

    /// Pi 扩展包条目：`pi list` 给出包名/版本；路径与来源只在 npm/pnpm 全局
    /// root 下能找到同名包目录时才给出，否则保持 unknown。
    private func piPackageInstallation(
        entry: PiPackageEntry,
        roots: PackageManagerRoots
    ) -> ComponentInstallation {
        var evidence: [String] = ["`pi list` 报告：\(entry.name)\(entry.version.map { "@\($0)" } ?? "")"]
        var packageDirectory: String?
        var source: InstallSource = .unknown
        var sourceConfidence: DetectionConfidence = .unknown
        var sourceEvidence: [String] = []

        let rootCandidates: [(root: String?, source: InstallSource, evidence: String?)] = [
            (roots.pnpmRoot, .pnpmGlobal, roots.pnpmRootEvidence),
            (roots.npmRoot, .npmGlobal, roots.npmRootEvidence)
        ]
        for candidate in rootCandidates {
            guard let root = candidate.root, !root.isEmpty else { continue }
            let directory = (root as NSString).appendingPathComponent(entry.name)
            guard pathExists(directory) else { continue }
            packageDirectory = directory
            source = candidate.source
            sourceConfidence = .verified
            if let rootEvidence = candidate.evidence {
                sourceEvidence.append("\(candidate.source.displayName)：\(rootEvidence)")
            }
            sourceEvidence.append("包目录 \(directory) 在 \(candidate.source.displayName) 全局 root 下")
            break
        }
        evidence.append(contentsOf: sourceEvidence)

        var packageName: String? = entry.name
        var packageVersion: String?
        var executablePath: String?
        var packageJSONPath: String?
        var packageJSONEvidence: [String] = []
        if let packageDirectory {
            if let metadata = metadata(inDirectory: packageDirectory) {
                packageJSONPath = metadata.path
                packageJSONEvidence = metadata.evidence
                if let name = metadata.name { packageName = name }
                packageVersion = metadata.version
                if metadata.binTargets.count == 1, let bin = metadata.binTargets.first {
                    let candidate = (metadata.directory as NSString).appendingPathComponent(bin.value)
                    if pathExists(candidate) {
                        executablePath = candidate
                        packageJSONEvidence.append("package.json bin 指向可执行文件：\(bin.key) → \(bin.value)")
                    }
                }
            } else {
                packageJSONEvidence.append("package.json：包目录 \(packageDirectory) 内没有可读的 package.json")
            }
        } else {
            evidence.append("npm/pnpm 全局 root 下没有找到同名包目录：路径与来源无法确认")
        }
        evidence.append(contentsOf: packageJSONEvidence)

        let version = entry.version ?? packageVersion
        if version == nil {
            evidence.append("未验证原因：`pi list` 与 package.json 都没有给出可用版本")
        }

        let suggestedCommand = Self.suggestedCommand(
            kind: .piPackage,
            source: source,
            confidence: sourceConfidence
        )

        return ComponentInstallation(
            kind: .piPackage,
            packageName: packageName,
            version: version,
            executablePath: executablePath,
            resolvedPath: executablePath,
            symlinkChain: [],
            packageJSONPath: packageJSONPath,
            source: source,
            confidence: DetectionConfidence.weakest([
                version == nil ? .unknown : .verified,
                sourceConfidence
            ]),
            evidence: evidence,
            suggestedCommand: suggestedCommand
        )
    }

    private static func unknownPiPackage(evidence: [String]) -> ComponentInstallation {
        return ComponentInstallation(
            kind: .piPackage,
            packageName: nil,
            version: nil,
            executablePath: nil,
            resolvedPath: nil,
            symlinkChain: [],
            packageJSONPath: nil,
            source: .unknown,
            confidence: .unknown,
            evidence: evidence,
            suggestedCommand: nil
        )
    }

    /// 建议命令：只从 `InstallCommandManifest` 的静态条目取；只有来源明确为
    /// npm/pnpm 全局（`verified`）时才给出命令。其它来源返回 nil，由界面显示
    /// “请按来源文档更新”。
    private static func suggestedCommand(
        kind: ComponentKind,
        source: InstallSource,
        confidence: DetectionConfidence
    ) -> String? {
        guard confidence == .verified, source.isPackageManagerManaged else { return nil }
        guard let entry = InstallCommandManifest.updateGuidance(for: kind, source: source) else { return nil }
        return entry.command
    }

    // MARK: - 包管理器 root

    private struct PackageManagerRoots {
        var npmRoot: String?
        var npmRootEvidence: String?
        var pnpmRoot: String?
        var pnpmRootEvidence: String?
    }

    /// `npm root -g` 为主；命令没有输出时用调用方已知的 `npm prefix -g` 推定为
    /// `<prefix>/lib/node_modules`。本类型自己不再重复执行 `npm prefix -g`：
    /// #6 的诊断已经查过一次，调用方通过 `knownNPMPrefix` 传入结果。
    /// pnpm 用 `pnpm root -g`（未安装时 runner 返回 nil，不影响其它证据）。
    private func packageManagerRoots() -> PackageManagerRoots {
        var roots = PackageManagerRoots()

        let npmRootOutput = trimmed(commandRunner.run([Self.runnerPath, "npm", "root", "-g"], environment: commandEnvironment))
            .map(Self.normalizedDirectory)
        let prefix = knownNPMPrefix.map(Self.normalizedDirectory)
        if let npmRootOutput, !npmRootOutput.isEmpty {
            roots.npmRoot = npmRootOutput
            roots.npmRootEvidence = "npm root -g → \(npmRootOutput)"
        } else if let prefix, !prefix.isEmpty {
            let derived = prefix + "/lib/node_modules"
            roots.npmRoot = derived
            roots.npmRootEvidence = "npm root -g 无输出；由已解析的 npm prefix -g → \(prefix) 推定为 \(derived)"
        } else {
            roots.npmRootEvidence = "npm root -g 无输出，也没有已知的 npm 全局前缀（命令无法执行时：合并后的工具 PATH 里找不到 npm 或 node）"
        }

        let pnpmRootOutput = trimmed(commandRunner.run([Self.runnerPath, "pnpm", "root", "-g"], environment: commandEnvironment))
            .map(Self.normalizedDirectory)
        if let pnpmRootOutput, !pnpmRootOutput.isEmpty {
            roots.pnpmRoot = pnpmRootOutput
            roots.pnpmRootEvidence = "pnpm root -g → \(pnpmRootOutput)"
        } else {
            roots.pnpmRootEvidence = "pnpm root -g 无输出（未安装、未配置全局目录，或工具 PATH 里找不到 node）"
        }
        return roots
    }

    // MARK: - 文件系统探测

    private struct ExecutableProbe {
        var executablePath: String?
        /// 存在且可执行（`.app` 包则为“存在”）。
        var isPresent: Bool
        var symlinkChain: [String]
        var resolvedPath: String?
        var evidence: [String]
    }

    private func probeExecutable(candidates: [String], names: [String], probesShellPath: Bool) -> ExecutableProbe {
        var dangling: ExecutableProbe?
        for candidate in candidates where !candidate.isEmpty {
            if fileSystem.isExecutableFile(atPath: candidate) {
                return makeProbe(path: candidate)
            }
            if dangling == nil, fileSystem.symlinkDestination(atPath: candidate) != nil {
                dangling = makeProbe(path: candidate)
            }
        }
        if probesShellPath {
            for name in names {
                guard let path = trimmed(commandRunner.run([Self.shellPath, "-lc", "command -v \(name) 2>/dev/null"], environment: commandEnvironment)) else { continue }
                if fileSystem.isExecutableFile(atPath: path) {
                    return makeProbe(path: path)
                }
                if dangling == nil, fileSystem.symlinkDestination(atPath: path) != nil {
                    dangling = makeProbe(path: path)
                }
            }
        }
        if let dangling { return dangling }
        let candidateText = candidates.isEmpty ? "（无）" : candidates.joined(separator: "、")
        return ExecutableProbe(
            executablePath: nil,
            isPresent: false,
            symlinkChain: [],
            resolvedPath: nil,
            evidence: [
                probesShellPath
                    ? "可执行文件：候选路径 \(candidateText) 与 `command -v` 都没有结果"
                    : "可执行文件：候选路径 \(candidateText) 都没有结果（调用方已经解析过 `command -v`，不重复执行）"
            ]
        )
    }

    private func makeProbe(path: String) -> ExecutableProbe {
        let walked = followSymlinks(from: path)
        let executableBit = fileSystem.isExecutableFile(atPath: path)
        var evidence: [String] = []
        if executableBit {
            evidence.append("可执行文件：\(path)（可执行位已确认）")
        } else {
            evidence.append("可执行文件：\(path)（符号链接存在，但可执行位未确认）")
        }
        if walked.chain.count > 1 {
            evidence.append("符号链接链：\(walked.chain.joined(separator: " → "))")
        } else {
            evidence.append("不是符号链接")
        }
        if let danglingTarget = walked.danglingTarget {
            evidence.append("符号链接链悬空：\(danglingTarget) 不存在，resolvedPath 无法确定")
        }
        return ExecutableProbe(
            executablePath: path,
            // 可执行位确认，或链接链能走到真实文件，才算“存在”。
            isPresent: executableBit || walked.resolvedPath != nil,
            symlinkChain: walked.chain,
            resolvedPath: walked.resolvedPath,
            evidence: evidence
        )
    }

    private func makeApplicationProbe(path: String) -> ExecutableProbe {
        let walked = followSymlinks(from: path)
        let exists = pathExists(path)
        var evidence: [String] = [
            "应用包：\(path)（\(exists ? "存在" : "不存在")）"
        ]
        if walked.chain.count > 1 {
            evidence.append("符号链接链：\(walked.chain.joined(separator: " → "))")
        }
        return ExecutableProbe(
            executablePath: path,
            isPresent: exists,
            symlinkChain: walked.chain,
            resolvedPath: exists ? (walked.resolvedPath ?? path) : nil,
            evidence: evidence
        )
    }

    /// 完整符号链接链：从 `path` 开始逐跳读取链接目标（相对目标按链接所在目录
    /// 解析），最多 `maximumSymlinkHops` 跳。悬空链返回链与悬空目标、
    /// `resolvedPath` 为 nil。
    private func followSymlinks(from path: String) -> (chain: [String], resolvedPath: String?, danglingTarget: String?) {
        var chain = [path]
        var current = path
        var hops = 0
        while hops < Self.maximumSymlinkHops {
            guard let destination = fileSystem.symlinkDestination(atPath: current) else { break }
            let next = Self.symlinkTarget(
                destination,
                relativeTo: (current as NSString).deletingLastPathComponent
            )
            chain.append(next)
            current = next
            hops += 1
            if !pathExists(current) {
                return (chain, nil, current)
            }
        }
        if hops >= Self.maximumSymlinkHops, fileSystem.symlinkDestination(atPath: current) != nil {
            return (chain, nil, nil)
        }
        let resolved = pathExists(current) ? current : fileSystem.resolvedPath(atPath: path)
        return (chain, resolved, nil)
    }

    /// 相对链接目标按链接所在目录解析；绝对目标原样保留。结果只做词法归一化
    /// （去掉 `.`/`..`），不访问磁盘，也不解析其它符号链接。
    private static func symlinkTarget(_ destination: String, relativeTo directory: String) -> String {
        let joined = destination.hasPrefix("/")
            ? destination
            : (directory as NSString).appendingPathComponent(destination)
        return normalizedDirectory(normalizedPath(joined))
    }

    /// 词法归一化路径：去掉 `.` / `..` 段，不解析符号链接、不访问磁盘。
    static func normalizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let isAbsolute = path.hasPrefix("/")
        var components: [String] = []
        for component in (path as NSString).pathComponents {
            switch component {
            case "/", ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if !isAbsolute {
                    components.append("..")
                }
            default:
                components.append(component)
            }
        }
        let joined = components.joined(separator: "/")
        if isAbsolute {
            return "/" + joined
        }
        return joined.isEmpty ? "." : joined
    }

    /// 路径是否存在（文件、目录或符号链接本体）。
    ///
    /// 复用 #6 的探针方法组合，不新增协议要求：目录用 `directoryExists`，可执行
    /// 文件用可执行位，其余文件用文本读取，链接本体用 `symlinkDestination`。
    private func pathExists(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        if fileSystem.directoryExists(atPath: path) == true { return true }
        if fileSystem.isExecutableFile(atPath: path) { return true }
        if fileSystem.readText(atPath: path) != nil { return true }
        if fileSystem.symlinkDestination(atPath: path) != nil { return true }
        return false
    }

    // MARK: - package.json 与 .git

    private struct PackageMetadata {
        var path: String
        var directory: String
        var name: String?
        var version: String?
        var binTargets: [String: String]
        var parseFailed: Bool

        var evidence: [String] {
            var lines = ["package.json：\(path)"]
            if parseFailed {
                lines.append("package.json 无法解析（不是 JSON 对象）：name/version 不可用")
                return lines
            }
            lines.append("package.json name=\(name ?? "（缺少）")，version=\(version ?? "（缺少）")")
            if !binTargets.isEmpty {
                let text = binTargets.keys.sorted().map { "\($0) → \(binTargets[$0] ?? "")" }.joined(separator: "、")
                lines.append("package.json bin：\(text)")
            }
            return lines
        }
    }

    /// 最近一层 package.json：从 `startPath` 的目录开始向上找（最多
    /// `packageSearchDepth` 层）。最近一层无法解析也算“找到了”，不再向更上层找。
    private func nearestPackageMetadata(startingAt startPath: String?) -> PackageMetadata? {
        guard let startPath, !startPath.isEmpty else { return nil }
        var directory = (startPath as NSString).deletingLastPathComponent
        var depth = 0
        while !directory.isEmpty, directory != "/", depth < Self.packageSearchDepth {
            if let metadata = metadata(inDirectory: directory) { return metadata }
            directory = (directory as NSString).deletingLastPathComponent
            depth += 1
        }
        return nil
    }

    private func metadata(inDirectory directory: String) -> PackageMetadata? {
        let candidate = (directory as NSString).appendingPathComponent("package.json")
        guard let text = fileSystem.readText(atPath: candidate) else { return nil }
        return Self.parsePackageMetadata(text: text, path: candidate, directory: directory)
    }

    private static func parsePackageMetadata(text: String, path: String, directory: String) -> PackageMetadata {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return PackageMetadata(path: path, directory: directory, name: nil, version: nil, binTargets: [:], parseFailed: true)
        }
        return PackageMetadata(
            path: path,
            directory: directory,
            name: nonEmptyString(dictionary["name"]),
            version: nonEmptyString(dictionary["version"]),
            binTargets: binTargets(dictionary["bin"]),
            parseFailed: false
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `bin` 支持字符串（单可执行文件）和对象（名字 → 相对路径）。
    private static func binTargets(_ raw: Any?) -> [String: String] {
        if let single = raw as? String {
            let trimmed = single.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [:] }
            return [(trimmed as NSString).lastPathComponent: trimmed]
        }
        guard let dictionary = raw as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in dictionary {
            guard let target = nonEmptyString(value) else { continue }
            result[key] = target
        }
        return result
    }

    /// 从包目录开始向上（最多 `packageSearchDepth` 层）找 `.git`：目录或
    /// worktree 的 `.git` 文件都算。返回最近的证据路径。
    private func gitEvidence(startingDirectory startDirectory: String?) -> String? {
        guard var directory = startDirectory, !directory.isEmpty else { return nil }
        var depth = 0
        while !directory.isEmpty, directory != "/", depth < Self.packageSearchDepth {
            let candidate = (directory as NSString).appendingPathComponent(".git")
            if fileSystem.directoryExists(atPath: candidate) == true || fileSystem.readText(atPath: candidate) != nil {
                return candidate
            }
            directory = (directory as NSString).deletingLastPathComponent
            depth += 1
        }
        return nil
    }

    // MARK: - `pi list` 解析

    /// `pi list` 的接受形态（逐行解析，忽略空行与 `#` 注释行）：
    /// - `name@1.2.3`、`@scope/name@1.2.3`
    /// - `name 1.2.3`、`@scope/name 1.2.3`
    ///
    /// 只有同时给出包名与可解析版本的整行才算一个条目；无法解析的行被计数但不
    /// 猜测。输出里没有任何可解析行时返回空数组，调用方降级为 unknown。
    static func parsePiList(_ output: String) -> [PiPackageEntry] {
        var entries: [PiPackageEntry] = []
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var name: String?
            var version: String?
            for token in line.split(whereSeparator: { $0.isWhitespace }) {
                let text = String(token)
                if let split = splitNameVersion(text) {
                    if name == nil { name = split.name }
                    if version == nil, let parsed = split.version { version = parsed }
                    continue
                }
                if version == nil, let parsed = SemanticVersion(text) {
                    version = parsed.description
                    continue
                }
                if name == nil, isPackageName(text) {
                    name = text
                }
            }
            guard let name, let version else { continue }
            entries.append(PiPackageEntry(name: name, version: version))
        }
        return entries
    }

    /// 拆 `[scope/]name@版本`；返回的版本是不可解析的字符串时也要保留，
    /// 以便调用方区分“缺少版本”与“版本形态不认识”。
    private static func splitNameVersion(_ token: String) -> PiPackageEntry? {
        guard token.contains("@"), !token.hasPrefix("@") || token.dropFirst().contains("@") else { return nil }
        guard let separator = token.lastIndex(of: "@"), separator > token.startIndex else { return nil }
        let name = String(token[token.startIndex..<separator])
        let versionText = String(token[token.index(after: separator)...])
        guard isPackageName(name), let version = SemanticVersion(versionText) else { return nil }
        return PiPackageEntry(name: name, version: version.description)
    }

    /// npm 包名形态：可选 `@scope/`，段内只允许 ASCII 字母、数字、`-`、`_`、`.`。
    static func isPackageName(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 214 else { return false }
        var body = Substring(text)
        if body.hasPrefix("@") {
            guard let slash = body.firstIndex(of: "/"), slash != body.index(after: body.startIndex) else { return false }
            let scope = body[body.index(after: body.startIndex)..<slash]
            guard isNameSegment(scope) else { return false }
            body = body[body.index(after: slash)...]
        }
        return isNameSegment(body)
    }

    private static func isNameSegment(_ text: Substring) -> Bool {
        guard !text.isEmpty else { return false }
        guard !text.hasPrefix("."), !text.hasSuffix(".") else { return false }
        return text.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_" || character == ".")
        }
    }

    // MARK: - 小工具

    private func trimmed(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func normalizedDirectory(_ path: String) -> String {
        var value = path
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    static func lineCount(of text: String) -> Int {
        text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }
}
