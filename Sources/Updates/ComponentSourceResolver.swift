/// Install-source evidence gathering and the pure source resolver.

import Foundation

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
