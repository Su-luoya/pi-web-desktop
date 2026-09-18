import Darwin
import Foundation

// MARK: - 语义化版本

/// 依赖诊断使用的语义化版本解析与比较。
///
/// 不引第三方库，只实现 Issue #6 需要的子集：可选 `v` 前缀、1–4 段数字、
/// `-prerelease` 与 `+build` 后缀。数字段逐段比较；数字段相同时带 prerelease
/// 的版本低于正式版（SemVer 2.0.0 §11），prerelease 之间只区分有无，不做
/// 逐段比较——“是否达到最低版本”的判定不受影响，结果因此是可预测的。
struct SemanticVersion: Equatable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// 第 4 段（例如 `1.2.3.4`）；只有 3 段时为 0。
    let revision: Int
    let prerelease: String?

    init(
        major: Int,
        minor: Int = 0,
        patch: Int = 0,
        revision: Int = 0,
        prerelease: String? = nil
    ) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.revision = revision
        self.prerelease = prerelease
    }

    /// 解析 `22.19.0`、`v22.19.0`、`1.2`、`1.2.3.4`、`1.2.3-rc.1+build.7`。
    /// 无法解析（空串、非数字段、超过 4 段）时返回 nil。
    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        if let plus = text.firstIndex(of: "+") {
            text = String(text[text.startIndex..<plus])
        }
        var prerelease: String?
        if let dash = text.firstIndex(of: "-") {
            prerelease = String(text[text.index(after: dash)...])
            text = String(text[text.startIndex..<dash])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            numbers.append(value)
        }
        self.init(
            major: numbers[0],
            minor: numbers.count > 1 ? numbers[1] : 0,
            patch: numbers.count > 2 ? numbers[2] : 0,
            revision: numbers.count > 3 ? numbers[3] : 0,
            prerelease: (prerelease?.isEmpty == false) ? prerelease : nil
        )
    }

    var description: String {
        var text = "\(major).\(minor).\(patch)"
        if revision != 0 { text += ".\(revision)" }
        if let prerelease { text += "-\(prerelease)" }
        return text
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.revision != rhs.revision { return lhs.revision < rhs.revision }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?): return left < right
        }
    }

    /// 从命令输出里取第一个可解析的版本，例如 `v22.19.0`、`pi-web 1.2.3`、
    /// `1.2.3 (node 22.19.0)`。取不到时返回 nil（对应诊断的 unknown）。
    static func firstVersion(in output: String) -> SemanticVersion? {
        for token in output.split(whereSeparator: { $0.isWhitespace }) {
            let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: "vV()[]{},;:=<>"))
            if let version = SemanticVersion(cleaned) { return version }
        }
        return nil
    }
}

// MARK: - 诊断模型

/// 安装来源推断结果，取值与 Issue #6 的 `npm-global / homebrew / local-path /
/// unknown` 一一对应。
enum DependencyInstallSource: String, Equatable {
    case homebrew = "homebrew"
    case npmGlobal = "npm-global"
    case localPath = "local-path"
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
    }

    enum Status: String, Equatable {
        case ok
        case missing
        case outdated
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
        fileprivate static func weakest(_ values: [Confidence]) -> Confidence {
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
}

/// 整体诊断结果。
struct DependencyReport: Equatable {
    var findings: [DependencyFinding]

    func finding(for kind: DependencyFinding.Kind) -> DependencyFinding? {
        findings.first { $0.kind == kind }
    }

    /// 阻塞服务启动的诊断项：Node.js 未达到最低版本（缺失/过旧/无法确定）或
    /// pi、pi-web 缺失。系统项只做提示，不阻塞启动；pi/pi-web 存在但版本无法
    /// 解析不阻塞（可执行文件已确认存在）。
    var blockingFindings: [DependencyFinding] {
        findings.filter { finding in
            switch finding.kind {
            case .system:
                return false
            case .node:
                return finding.status != .ok
            case .piCLI, .piWeb:
                return finding.status == .missing
            }
        }
    }

    /// pi 与 pi-web 都存在且 Node.js 版本满足最低要求时才为 true。
    /// 缺少任一条目（例如空报告）时为 false，门控默认关闭。
    var canStartService: Bool {
        guard let pi = finding(for: .piCLI),
              let piWeb = finding(for: .piWeb),
              let node = finding(for: .node) else { return false }
        return pi.status != .missing && piWeb.status != .missing && node.status == .ok
    }
}

// MARK: - 文件系统与系统探针

/// 依赖诊断的文件系统探针。
///
/// 诊断只通过这个协议读盘；测试注入假实现，因此不会触碰真实用户目录、npm
/// 缓存或网络。
protocol DependencyFileSystemProbing {
    func isExecutableFile(atPath path: String) -> Bool
    /// 一层的符号链接目标；不是符号链接或读取失败时返回 nil。
    func symlinkDestination(atPath path: String) -> String?
    /// 完整解析符号链接后的真实路径；路径不存在时返回 nil。
    func resolvedPath(atPath path: String) -> String?
    /// 读取 UTF-8 文本；不存在或不可读时返回 nil。
    func readText(atPath path: String) -> String?
    func homeDirectoryPath() -> String
}

/// 生产实现：只使用 `FileManager` 和标准 URL 解析，Apple 系统框架以内。
struct SystemDependencyFileSystemProbe: DependencyFileSystemProbing {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func isExecutableFile(atPath path: String) -> Bool {
        fileManager.isExecutableFile(atPath: path)
    }

    func symlinkDestination(atPath path: String) -> String? {
        try? fileManager.destinationOfSymbolicLink(atPath: path)
    }

    func resolvedPath(atPath path: String) -> String? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    func readText(atPath path: String) -> String? {
        guard let data = fileManager.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func homeDirectoryPath() -> String {
        fileManager.homeDirectoryForCurrentUser.path
    }
}

/// 系统探针：处理器架构与 macOS 版本。测试注入固定值。
struct DependencySystemProbe {
    var architecture: () -> String
    var operatingSystemVersion: () -> OperatingSystemVersion

    static let live = DependencySystemProbe(
        architecture: { machineArchitecture() },
        operatingSystemVersion: { ProcessInfo.processInfo.operatingSystemVersion }
    )

    /// `uname(2)` 的 machine 字段；Apple Silicon 上为 `arm64`。
    static func machineArchitecture() -> String {
        var name = utsname()
        guard uname(&name) == 0 else { return "unknown" }
        // 在闭包内复制出有效字节，闭包外只使用这份副本。
        let bytes = withUnsafeBytes(of: &name.machine) { raw -> [UInt8] in
            Array(raw.prefix { $0 != 0 })
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - 路径脱敏

/// Home 路径脱敏：只把注入的 Home 前缀替换为 `~`，其他路径原样保留。
struct DependencyPathRedactor {
    let homeDirectory: String

    init(homeDirectory: String) {
        var normalized = homeDirectory
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        self.homeDirectory = normalized
    }

    func redact(_ path: String) -> String {
        guard !homeDirectory.isEmpty, homeDirectory != "/" else { return path }
        if path == homeDirectory { return "~" }
        if path.hasPrefix(homeDirectory + "/") {
            return "~/" + String(path.dropFirst(homeDirectory.count + 1))
        }
        return path
    }
}

// MARK: - 诊断检查器

/// 依赖与环境诊断（GitHub #6）。
///
/// 只做只读探测：版本查询、本地 `npm prefix -g` 查询和文件系统读取。它不安装、
/// 不升级、不联网、不调用 `sudo`，也不读取任何认证内容。修复建议只来自
/// `InstallCommandManifest` 的静态常量，由用户自己复制执行。
struct DependencyChecker {
    static let minimumMacOSVersion = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
    static var minimumNodeVersion: SemanticVersion { InstallCommandManifest.minimumNodeVersion }

    static let shellPath = "/bin/zsh"
    static let runnerPath = "/usr/bin/env"
    static let piWebPackageName = "@agegr/pi-web"
    /// package.json 向上查找的最大层数。
    static let packageSearchDepth = 6

    private let commandRunner: CommandRunning
    private let fileSystem: DependencyFileSystemProbing
    private let system: DependencySystemProbe
    private let configuredPiWebPath: String

    init(
        commandRunner: CommandRunning = SystemCommandRunner(),
        fileSystem: DependencyFileSystemProbing = SystemDependencyFileSystemProbe(),
        system: DependencySystemProbe = .live,
        configuredPiWebPath: String = ""
    ) {
        self.commandRunner = commandRunner
        self.fileSystem = fileSystem
        self.system = system
        self.configuredPiWebPath = configuredPiWebPath
    }

    /// 运行全部检查。顺序固定：系统、Node.js、Pi CLI、Pi Web。
    func run() -> DependencyReport {
        let redactor = DependencyPathRedactor(homeDirectory: fileSystem.homeDirectoryPath())
        let npmPrefix = localNPMPrefix()
        return DependencyReport(findings: [
            makeSystemFinding(),
            makeNodeFinding(npmPrefix: npmPrefix, redactor: redactor),
            makePiFinding(npmPrefix: npmPrefix, redactor: redactor),
            makePiWebFinding(npmPrefix: npmPrefix, redactor: redactor)
        ])
    }

    // MARK: - 探针

    /// 本地 `npm prefix -g`（只读、不联网）；npm 不存在时返回 nil。
    private func localNPMPrefix() -> String? {
        trimmed(commandRunner.run([Self.runnerPath, "npm", "prefix", "-g"])).map(normalizedDirectory)
    }

    private func trimmed(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func normalizedDirectory(_ path: String) -> String {
        var normalized = path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    /// 已知安装位置的候选路径，最后退回登录 shell 的 `command -v`。
    private func defaultCandidates(named name: String) -> [String] {
        var candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        let home = normalizedDirectory(fileSystem.homeDirectoryPath())
        if !home.isEmpty {
            candidates.append("\(home)/.npm-global/bin/\(name)")
        }
        return candidates
    }

    private func resolveExecutable(named name: String, candidates: [String]) -> String? {
        for candidate in candidates where fileSystem.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let shellResult = trimmed(commandRunner.run([Self.shellPath, "-lc", "command -v \(name) 2>/dev/null"]))
        guard let path = shellResult, fileSystem.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// 符号链接目标与完整真实路径。`resolvedPath` 与 `path` 相同表示没有符号链接。
    private func executableEvidence(at path: String) -> (resolvedPath: String?, symlinkTarget: String?) {
        (fileSystem.resolvedPath(atPath: path), fileSystem.symlinkDestination(atPath: path))
    }

    /// 按 Issue #6 的固定优先级推断安装来源：
    /// Homebrew Cellar → npm 全局（npm 前缀命中 `lib/node_modules`）→ npm 全局
    /// （npm 前缀命中 `bin`，只能算推断）→ `~/.npm-global` → Homebrew 前缀 →
    /// 用户目录下的本地路径 → unknown。
    private func installSource(
        path: String,
        resolvedPath: String?,
        npmPrefix: String?,
        homeDirectory: String
    ) -> (source: DependencyInstallSource, verified: Bool) {
        let resolved = resolvedPath ?? path
        let home = normalizedDirectory(homeDirectory)

        if resolved.contains("/Cellar/") {
            return (.homebrew, true)
        }
        if let npmPrefix, !npmPrefix.isEmpty {
            let modulesPrefix = npmPrefix + "/lib/node_modules/"
            if resolved.hasPrefix(modulesPrefix) || path.hasPrefix(modulesPrefix) {
                return (.npmGlobal, true)
            }
            let binPrefix = npmPrefix + "/bin/"
            if resolved.hasPrefix(binPrefix) || path.hasPrefix(binPrefix) {
                return (.npmGlobal, false)
            }
        }
        if !home.isEmpty,
           path.hasPrefix(home + "/.npm-global/") || resolved.hasPrefix(home + "/.npm-global/") {
            return (.npmGlobal, false)
        }
        if resolved.hasPrefix("/opt/homebrew/") || resolved.hasPrefix("/usr/local/") {
            return (.homebrew, false)
        }
        if !home.isEmpty, path.hasPrefix(home + "/") || resolved.hasPrefix(home + "/") {
            return (.localPath, false)
        }
        return (.unknown, false)
    }

    /// 从可执行文件的真实路径向上找 `package.json`，只读 `name` / `version`。
    private func packageMetadata(resolvedPath: String?) -> (name: String?, version: String?) {
        guard let resolvedPath, !resolvedPath.isEmpty else { return (nil, nil) }
        var directory = (resolvedPath as NSString).deletingLastPathComponent
        var depth = 0
        while !directory.isEmpty, directory != "/", depth < Self.packageSearchDepth {
            let candidate = (directory as NSString).appendingPathComponent("package.json")
            if let text = fileSystem.readText(atPath: candidate),
               let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data),
               let dictionary = object as? [String: Any] {
                let name = (dictionary["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let version = (dictionary["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (name?.isEmpty == false ? name : nil, version?.isEmpty == false ? version : nil)
            }
            directory = (directory as NSString).deletingLastPathComponent
            depth += 1
        }
        return (nil, nil)
    }

    // MARK: - 检查项

    /// 系统只做提示：不是 Apple Silicon 记 missing，macOS 低于 14 记 outdated。
    private func makeSystemFinding() -> DependencyFinding {
        let architecture = trimmed(system.architecture()) ?? "unknown"
        let osVersion = system.operatingSystemVersion()
        let osText = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let status: DependencyFinding.Status
        if architecture != "arm64" {
            status = .missing
        } else if !Self.isAtLeast(osVersion, Self.minimumMacOSVersion) {
            status = .outdated
        } else {
            status = .ok
        }
        return DependencyFinding(
            kind: .system,
            status: status,
            path: nil,
            resolvedPath: nil,
            symlinkTarget: nil,
            version: "macOS \(osText) (\(architecture))",
            installSource: .unknown,
            confidence: .verified,
            remediationID: nil,
            packageName: nil,
            packageVersion: nil
        )
    }

    private func makeNodeFinding(npmPrefix: String?, redactor: DependencyPathRedactor) -> DependencyFinding {
        let path = resolveExecutable(named: "node", candidates: defaultCandidates(named: "node"))
        var versionOutput = path.flatMap { trimmed(commandRunner.run([$0, "--version"])) }
        if versionOutput == nil {
            versionOutput = trimmed(commandRunner.run([Self.runnerPath, "node", "--version"]))
        }
        let version = versionOutput.flatMap { SemanticVersion.firstVersion(in: $0) }
        let source = installSource(
            path: path ?? "",
            resolvedPath: path.flatMap { fileSystem.resolvedPath(atPath: $0) },
            npmPrefix: npmPrefix,
            homeDirectory: fileSystem.homeDirectoryPath()
        )

        let status: DependencyFinding.Status
        let statusEvidence: DependencyFinding.Confidence
        let remediationID: String?
        if let version {
            if version < Self.minimumNodeVersion {
                status = .outdated
                remediationID = InstallCommandManifest.node.id
            } else {
                status = .ok
                remediationID = nil
            }
            statusEvidence = .verified
        } else if path == nil && versionOutput == nil {
            status = .missing
            statusEvidence = .unknown
            remediationID = InstallCommandManifest.node.id
        } else {
            status = .unknown
            statusEvidence = .inferred
            remediationID = InstallCommandManifest.node.id
        }

        let sourceEvidence: DependencyFinding.Confidence
        if path == nil {
            sourceEvidence = .unknown
        } else {
            sourceEvidence = source.verified ? .verified : (source.source == .unknown ? .unknown : .inferred)
        }

        return DependencyFinding(
            kind: .node,
            status: status,
            path: path.map { redactor.redact($0) },
            resolvedPath: path.flatMap { fileSystem.resolvedPath(atPath: $0) }.map { redactor.redact($0) },
            symlinkTarget: path.flatMap { fileSystem.symlinkDestination(atPath: $0) }.map { redactor.redact($0) },
            version: version?.description,
            installSource: source.source,
            confidence: .weakest([statusEvidence, sourceEvidence]),
            remediationID: remediationID,
            packageName: nil,
            packageVersion: nil
        )
    }

    private func makePiFinding(npmPrefix: String?, redactor: DependencyPathRedactor) -> DependencyFinding {
        guard let path = resolveExecutable(named: "pi", candidates: defaultCandidates(named: "pi")) else {
            return missingFinding(kind: .piCLI, remediationID: InstallCommandManifest.piCLI.id)
        }
        let evidence = executableEvidence(at: path)
        let version = trimmed(commandRunner.run([path, "--version"]))
            .flatMap { SemanticVersion.firstVersion(in: $0) }
        let source = installSource(
            path: path,
            resolvedPath: evidence.resolvedPath,
            npmPrefix: npmPrefix,
            homeDirectory: fileSystem.homeDirectoryPath()
        )
        let sourceEvidence: DependencyFinding.Confidence =
            source.verified ? .verified : (source.source == .unknown ? .unknown : .inferred)
        return DependencyFinding(
            kind: .piCLI,
            status: version == nil ? .unknown : .ok,
            path: redactor.redact(path),
            resolvedPath: evidence.resolvedPath.map { redactor.redact($0) },
            symlinkTarget: evidence.symlinkTarget.map { redactor.redact($0) },
            version: version?.description,
            installSource: source.source,
            confidence: .weakest([version == nil ? .inferred : .verified, sourceEvidence]),
            remediationID: version == nil ? InstallCommandManifest.piCLI.id : nil,
            packageName: nil,
            packageVersion: nil
        )
    }

    private func makePiWebFinding(npmPrefix: String?, redactor: DependencyPathRedactor) -> DependencyFinding {
        let configured = configuredPiWebPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: String?
        if configured.isEmpty {
            path = resolveExecutable(named: "pi-web", candidates: defaultCandidates(named: "pi-web"))
        } else {
            // 用户显式配置的路径优先：不可执行时按缺失报告，而不是悄悄改用别的副本。
            path = fileSystem.isExecutableFile(atPath: configured) ? configured : nil
        }
        guard let path else {
            return missingFinding(kind: .piWeb, remediationID: InstallCommandManifest.piWeb.id)
        }

        let evidence = executableEvidence(at: path)
        let metadata = packageMetadata(resolvedPath: evidence.resolvedPath)
        let cliVersion = trimmed(commandRunner.run([path, "--version"]))
            .flatMap { SemanticVersion.firstVersion(in: $0) }
        let packageVersion = metadata.version.flatMap { SemanticVersion($0) }
        let version = cliVersion ?? packageVersion
        let source = installSource(
            path: path,
            resolvedPath: evidence.resolvedPath,
            npmPrefix: npmPrefix,
            homeDirectory: fileSystem.homeDirectoryPath()
        )
        let sourceEvidence: DependencyFinding.Confidence =
            source.verified ? .verified : (source.source == .unknown ? .unknown : .inferred)
        // package.json 缺失不影响结论；name 与预期不符时身份证据只能算推断。
        var evidences: [DependencyFinding.Confidence] = [version == nil ? .inferred : .verified, sourceEvidence]
        if let packageName = metadata.name {
            evidences.append(packageName == Self.piWebPackageName ? .verified : .inferred)
        }
        return DependencyFinding(
            kind: .piWeb,
            status: version == nil ? .unknown : .ok,
            path: redactor.redact(path),
            resolvedPath: evidence.resolvedPath.map { redactor.redact($0) },
            symlinkTarget: evidence.symlinkTarget.map { redactor.redact($0) },
            version: version?.description,
            installSource: source.source,
            confidence: .weakest(evidences),
            remediationID: version == nil ? InstallCommandManifest.piWeb.id : nil,
            packageName: metadata.name,
            packageVersion: metadata.version
        )
    }

    private func missingFinding(kind: DependencyFinding.Kind, remediationID: String) -> DependencyFinding {
        DependencyFinding(
            kind: kind,
            status: .missing,
            path: nil,
            resolvedPath: nil,
            symlinkTarget: nil,
            version: nil,
            installSource: .unknown,
            confidence: .unknown,
            remediationID: remediationID,
            packageName: nil,
            packageVersion: nil
        )
    }

    static func isAtLeast(_ version: OperatingSystemVersion, _ minimum: OperatingSystemVersion) -> Bool {
        if version.majorVersion != minimum.majorVersion { return version.majorVersion > minimum.majorVersion }
        if version.minorVersion != minimum.minorVersion { return version.minorVersion > minimum.minorVersion }
        return version.patchVersion >= minimum.patchVersion
    }
}

// MARK: - 纯文本呈现（无 AppKit）

/// 诊断结果的纯文本呈现，供诊断窗口和测试共用。
///
/// 只消费已经脱敏的 `DependencyReport`，URL 只从静态清单读取并去掉 userinfo、
/// query 与 fragment，因此文本里不会出现真实用户名、Home 绝对路径、凭据、
/// token 或查询参数。
enum DependencyReportPresenter {
    struct Row: Equatable {
        let title: String
        let status: String
        let path: String
        let version: String
        let source: String
        let confidence: String
    }

    static func title(for kind: DependencyFinding.Kind) -> String {
        switch kind {
        case .system: return "系统"
        case .node: return "Node.js"
        case .piCLI: return "Pi CLI"
        case .piWeb: return "Pi Web"
        }
    }

    static func statusText(for status: DependencyFinding.Status) -> String {
        switch status {
        case .ok: return "正常"
        case .missing: return "缺失"
        case .outdated: return "版本过旧"
        case .unknown: return "无法确定"
        }
    }

    static func sourceText(for source: DependencyInstallSource) -> String {
        switch source {
        case .homebrew: return "Homebrew"
        case .npmGlobal: return "npm 全局"
        case .localPath: return "本地路径"
        case .unknown: return "未知"
        }
    }

    static func confidenceText(for confidence: DependencyFinding.Confidence) -> String {
        switch confidence {
        case .verified: return "已验证"
        case .inferred: return "推断"
        case .unknown: return "未知"
        }
    }

    static func rows(for report: DependencyReport) -> [Row] {
        report.findings.map { finding in
            Row(
                title: title(for: finding.kind),
                status: statusText(for: finding.status),
                path: finding.path ?? (finding.kind == .system ? "—" : "未找到"),
                version: finding.version ?? "未知",
                source: sourceText(for: finding.installSource),
                confidence: confidenceText(for: finding.confidence)
            )
        }
    }

    static func summaryText(for report: DependencyReport) -> String {
        var lines = [report.canStartService ? "结论：可以启动 Pi Web 服务。" : "结论：缺少硬性前置，服务启动已暂停。"]
        for finding in report.findings {
            lines.append("")
            lines.append("\(title(for: finding.kind))：\(statusText(for: finding.status))")
            if let path = finding.path {
                lines.append("  路径：\(path)")
            }
            if let resolvedPath = finding.resolvedPath, resolvedPath != finding.path {
                lines.append("  真实路径：\(resolvedPath)")
            }
            if let symlinkTarget = finding.symlinkTarget {
                lines.append("  符号链接目标：\(symlinkTarget)")
            }
            lines.append("  版本：\(finding.version ?? "未知")")
            lines.append("  安装来源：\(sourceText(for: finding.installSource))")
            lines.append("  可信度：\(confidenceText(for: finding.confidence))")
            if finding.kind == .piWeb {
                if let name = finding.packageName {
                    let version = finding.packageVersion.map { "@\($0)" } ?? ""
                    lines.append("  package.json：\(name)\(version)")
                } else {
                    lines.append("  package.json：未找到")
                }
            }
            if let remediationID = finding.remediationID,
               let entry = InstallCommandManifest.entry(withID: remediationID) {
                lines.append("  修复：\(entry.title)（\(sanitize(url: entry.documentationURL))）")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 诊断提示页用的短结论。
    static func blockingSummary(for report: DependencyReport) -> String {
        let blocking = report.blockingFindings
        guard !blocking.isEmpty else { return "依赖检查未通过。" }
        let descriptions = blocking.map { finding in
            "· \(title(for: finding.kind))：\(statusText(for: finding.status))"
        }
        return (["以下前置未满足："] + descriptions + ["请在“依赖与环境诊断”窗口中复制安装命令，安装后点击“重新检测”。"])
            .joined(separator: "\n")
    }

    /// 只包含当前诊断引用到的修复项，保持 `InstallCommandManifest` 的固定顺序。
    static func remediationEntries(for report: DependencyReport) -> [InstallCommandManifest.Entry] {
        var seen = Set<String>()
        var entries: [InstallCommandManifest.Entry] = []
        for finding in report.findings {
            guard let remediationID = finding.remediationID,
                  !seen.contains(remediationID),
                  let entry = InstallCommandManifest.entry(withID: remediationID) else { continue }
            seen.insert(remediationID)
            entries.append(entry)
        }
        return entries
    }

    /// 供“复制安装命令”使用的文本；没有需要修复的条目时返回空串。
    static func installCommandsText(for report: DependencyReport) -> String {
        let entries = remediationEntries(for: report)
        guard !entries.isEmpty else { return "" }
        return entries.map { entry in
            var lines = [entry.title]
            if let command = entry.command {
                lines.append("  \(command)")
            }
            lines.append("  说明：\(entry.note)")
            lines.append("  文档：\(sanitize(url: entry.documentationURL))")
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    /// 去掉 URL 里的 userinfo、query 和 fragment，避免把凭据或追踪参数带进
    /// 诊断文本。无法解析时原样返回。
    static func sanitize(url text: String) -> String {
        guard var components = URLComponents(string: text) else { return text }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? text
    }
}
