import Darwin
import Foundation

// MARK: - 语义化版本

/// 依赖诊断使用的语义化版本解析与比较。
///
/// 不引第三方库，只实现 Issue #6 需要的子集：可选 `v` 前缀、1–4 段数字、
/// `-prerelease` 与 `+build` 后缀。数字段逐段比较；数字段相同时带 prerelease
/// 的版本低于正式版（SemVer 2.0.0 §11）。prerelease 之间按 §11 的标识符规则
/// 比较：数字标识符按数值、字母数字标识符按 ASCII 顺序、数字标识符低于字母
/// 数字标识符、前缀相同时标识符更少者更低。GitHub #17 的更新检查依赖这条
/// 规则区分 `alpha.1` / `alpha.2` / `beta.1` / 正式版，结果因此是可预测的。
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
        case let (left?, right?): return Self.prereleasePrecedes(left, right)
        }
    }

    /// SemVer 2.0.0 §11 的 prerelease 先后关系。
    ///
    /// `alpha.2` < `alpha.10`（数字标识符按数值比较），`alpha.2` < `beta.1`
    /// （字母数字标识符按 ASCII 顺序），`alpha.1` < `alpha.1.1`（前缀相同、
    /// 标识符更少者更低），`1.0.0-1` < `1.0.0-alpha`（数字标识符低于字母数字）。
    /// 大小写按 ASCII 顺序处理，不做不区分大小写的回退（与 SemVer 一致）。
    static func prereleasePrecedes(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".", omittingEmptySubsequences: false)
        let right = rhs.split(separator: ".", omittingEmptySubsequences: false)
        for index in 0..<min(left.count, right.count) {
            let leftPart = String(left[index])
            let rightPart = String(right[index])
            if leftPart == rightPart { continue }
            let leftNumber = Int(leftPart)
            let rightNumber = Int(rightPart)
            switch (leftNumber, rightNumber) {
            case let (leftValue?, rightValue?):
                if leftValue != rightValue { return leftValue < rightValue }
                continue
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return leftPart < rightPart
            }
        }
        return left.count < right.count
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
    /// 路径是否存在且是目录；探针无法判定时返回 nil。只回答存在性。
    func directoryExists(atPath path: String) -> Bool?
    /// 目录（或文件）是否可读；探针无法判定时返回 nil。
    /// 只读权限位，不列目录、不读取任何文件内容。
    func isReadableDirectory(atPath path: String) -> Bool?
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

    func directoryExists(atPath path: String) -> Bool? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    /// `isReadableFile` 只查询访问权限，不会列出目录内容；Pi 配置目录因此只被
    /// 判断“存在/可读”，认证文件内容永远不会进入诊断。
    func isReadableDirectory(atPath path: String) -> Bool? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        return fileManager.isReadableFile(atPath: path)
    }
}

/// 默认服务端口的本地可用性探针。
///
/// 只在本机创建、绑定并关闭一个 TCP socket：不连接任何远端、不发送数据、
/// 不调用外部命令、不解析域名。返回值语义：
/// - `true`：绑定成功，端口可用；
/// - `false`：`EADDRINUSE`，端口已被其他进程占用；
/// - `nil`：无法判定（主机不是字面量地址、端口非法或其他绑定错误）。
protocol DependencyPortProbing {
    func isPortAvailable(host: String, port: Int) -> Bool?
}

/// 生产实现：`bind(2)` 一个 loopback/字面量地址上的 TCP socket。
struct SystemDependencyPortProbe: DependencyPortProbing {
    func isPortAvailable(host: String, port: Int) -> Bool? {
        guard (1...65535).contains(port) else { return nil }
        let address = Self.normalizedHost(host)

        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socketAddress.sin_family = sa_family_t(AF_INET)
            socketAddress.sin_port = in_port_t(UInt16(port).bigEndian)
            socketAddress.sin_addr = ipv4
            return Self.canBind(family: AF_INET, address: &socketAddress, length: socklen_t(MemoryLayout<sockaddr_in>.size))
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, address, &ipv6) == 1 {
            var socketAddress = sockaddr_in6()
            socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            socketAddress.sin6_port = in_port_t(UInt16(port).bigEndian)
            socketAddress.sin6_addr = ipv6
            return Self.canBind(family: AF_INET6, address: &socketAddress, length: socklen_t(MemoryLayout<sockaddr_in6>.size))
        }

        // 主机名（例如 `localhost`）不做 DNS 解析：无法判定时不猜测端口状态。
        return nil
    }

    private static func normalizedHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "localhost" { return "127.0.0.1" }
        return trimmed
    }

    private static func canBind<Address>(family: Int32, address: inout Address, length: socklen_t) -> Bool? {
        let descriptor = socket(family, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        if result == 0 { return true }
        return errno == EADDRINUSE ? false : nil
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
    /// 上游包名的单一来源在 `InstallCommandManifest`。
    static var piWebPackageName: String { InstallCommandManifest.piWebPackageName }
    /// Pi 配置目录相对 Home 的路径；只检查存在与可读，不读取内容。
    static let piConfigurationDirectoryRelativePath = ".pi/agent"
    /// package.json 向上查找的最大层数。
    static let packageSearchDepth = 6

    private let commandRunner: CommandRunning
    private let fileSystem: DependencyFileSystemProbing
    private let system: DependencySystemProbe
    private let configuredPiWebPath: String
    private let serviceHostname: String
    private let servicePort: Int
    private let portProbe: DependencyPortProbing
    private let environment: [String: String]
    private let applicationInstallation: ApplicationInstallationProbe

    init(
        commandRunner: CommandRunning = SystemCommandRunner(),
        fileSystem: DependencyFileSystemProbing = SystemDependencyFileSystemProbe(),
        system: DependencySystemProbe = .live,
        configuredPiWebPath: String = "",
        serviceHostname: String = ServiceConfiguration.defaultHostname,
        servicePort: Int = ServiceConfiguration.defaultPort,
        portProbe: DependencyPortProbing = SystemDependencyPortProbe(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationInstallation: ApplicationInstallationProbe = .none
    ) {
        self.commandRunner = commandRunner
        self.fileSystem = fileSystem
        self.system = system
        self.configuredPiWebPath = configuredPiWebPath
        self.serviceHostname = serviceHostname
        self.servicePort = servicePort
        self.portProbe = portProbe
        self.environment = environment
        self.applicationInstallation = applicationInstallation
    }

    /// 运行全部检查。顺序固定：系统、Node.js、Pi CLI、Pi Web、默认端口、Pi 配置目录，
    /// 最后附上组件安装识别（GitHub #16；复用同一组探针与已解析的版本）。
    func run() -> DependencyReport {
        let redactor = DependencyPathRedactor(homeDirectory: fileSystem.homeDirectoryPath())
        let npmPrefix = localNPMPrefix()
        let piPath = resolvePiExecutable()
        let piWebPath = resolvePiWebExecutable()
        let piFinding = makePiFinding(path: piPath, npmPrefix: npmPrefix, redactor: redactor)
        let piWebFinding = makePiWebFinding(path: piWebPath, npmPrefix: npmPrefix, redactor: redactor)
        return DependencyReport(
            findings: [
                makeSystemFinding(),
                makeNodeFinding(npmPrefix: npmPrefix, redactor: redactor),
                piFinding,
                piWebFinding,
                makePortFinding(),
                makePiConfigurationDirectoryFinding(redactor: redactor)
            ],
            components: componentInstallations(
                redactor: redactor,
                npmPrefix: npmPrefix,
                piPath: piPath,
                piWebPath: piWebPath,
                piFinding: piFinding,
                piWebFinding: piWebFinding
            )
        )
    }

    // MARK: - 路径选择的身份证据

    /// 为一个候选 pi-web 路径收集只读身份证据：可执行位、`--version` 解析出的
    /// 版本，以及沿真实路径向上找到的 package.json 名称。
    ///
    /// 只做“执行 `--version` + 读 package.json 的 name”这两件只读的事：不安装、
    /// 不联网、不写配置、不读取任何认证内容。可执行位本身不是身份（`/bin/echo`
    /// 也可执行），所以调用方必须再用版本或包名校验。
    func piWebIdentityEvidence(atPath path: String) -> PiWebIdentityEvidence {
        guard fileSystem.isExecutableFile(atPath: path) else {
            return PiWebIdentityEvidence(isExecutable: false, version: nil, packageName: nil)
        }
        let metadata = packageMetadata(resolvedPath: fileSystem.resolvedPath(atPath: path))
        let version = trimmed(commandRunner.run([path, "--version"]))
            .flatMap { SemanticVersion.firstVersion(in: $0) }?
            .description
        return PiWebIdentityEvidence(
            isExecutable: true,
            version: version,
            packageName: metadata.name
        )
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
            // `uname` 失败时 architecture 是占位值，不能声称已验证。
            confidence: architecture == "unknown" ? .unknown : .verified,
            remediationID: nil,
            packageName: nil,
            packageVersion: nil
        )
    }

    /// Node 探针结果：路径与版本必须同源（版本必须由该路径自己产出）。
    private struct NodeProbe {
        var path: String?
        var version: SemanticVersion?
    }

    /// 解析 node，并只采信“该路径自己”报告的版本。
    ///
    /// 候选路径（含登录 shell 的 `command -v`）存在时只使用它的 `--version`：
    /// 如果它不可运行，就不允许用另一个 node 的版本把它放行。候选路径完全不存在
    /// 时，才按进程 PATH 重新解析（`/usr/bin/env node -p process.execPath`），并
    /// 把真正产出该版本的可执行路径记入报告；解析不出路径就不采信版本。
    private func resolveNode() -> NodeProbe {
        if let path = resolveExecutable(named: "node", candidates: defaultCandidates(named: "node")) {
            return NodeProbe(path: path, version: version(of: path))
        }
        guard let path = trimmed(commandRunner.run([Self.runnerPath, "node", "-p", "process.execPath"])),
              fileSystem.isExecutableFile(atPath: path) else {
            return NodeProbe(path: nil, version: nil)
        }
        return NodeProbe(path: path, version: version(of: path))
    }

    private func version(of executablePath: String) -> SemanticVersion? {
        trimmed(commandRunner.run([executablePath, "--version"]))
            .flatMap { SemanticVersion.firstVersion(in: $0) }
    }

    private func makeNodeFinding(npmPrefix: String?, redactor: DependencyPathRedactor) -> DependencyFinding {
        let probe = resolveNode()
        let path = probe.path
        let version = probe.version
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
        } else if path == nil {
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

    /// Pi CLI 的可执行文件路径（只读解析；找不到时 nil）。
    private func resolvePiExecutable() -> String? {
        resolveExecutable(named: "pi", candidates: defaultCandidates(named: "pi"))
    }

    /// Pi Web 的候选路径：用户显式配置的路径优先，否则退回默认候选与
    /// 登录 shell 的 `command -v`。
    private func piWebCandidates() -> [String] {
        let configured = configuredPiWebPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty ? defaultCandidates(named: "pi-web") : [configured]
    }

    /// Pi Web 的可执行文件路径。用户显式配置的路径不可执行时按缺失报告，
    /// 不悄悄改用其它副本。
    private func resolvePiWebExecutable() -> String? {
        let configured = configuredPiWebPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if configured.isEmpty {
            return resolveExecutable(named: "pi-web", candidates: defaultCandidates(named: "pi-web"))
        }
        return fileSystem.isExecutableFile(atPath: configured) ? configured : nil
    }

    private func makePiFinding(
        path: String?,
        npmPrefix: String?,
        redactor: DependencyPathRedactor
    ) -> DependencyFinding {
        guard let path else {
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

    private func makePiWebFinding(
        path: String?,
        npmPrefix: String?,
        redactor: DependencyPathRedactor
    ) -> DependencyFinding {
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

    // MARK: - 组件安装识别（GitHub #16）

    /// 组件安装识别：复用同一组注入探针（命令、文件系统、环境变量），并沿用
    /// `pi`/`pi-web` 的 finding 已解析的版本，因此不会重复执行 `--version`。
    /// 结果在返回前完成 Home 脱敏（`~`）。
    private func componentInstallations(
        redactor: DependencyPathRedactor,
        npmPrefix: String?,
        piPath: String?,
        piWebPath: String?,
        piFinding: DependencyFinding,
        piWebFinding: DependencyFinding
    ) -> [ComponentInstallation] {
        let detector = ComponentInstallationDetector(
            commandRunner: commandRunner,
            fileSystem: fileSystem,
            environment: environment,
            homeDirectory: fileSystem.homeDirectoryPath(),
            knownNPMPrefix: npmPrefix
        )
        // 候选路径直接用已经解析出的可执行文件；`probesShellPath: false` 表示
        // 不再重复执行 `command -v`（`resolveExecutable` 已经做过）。
        var requests: [ComponentInstallationDetector.ComponentDetectionRequest] = [
            ComponentInstallationDetector.ComponentDetectionRequest(
                kind: .piCLI,
                packageName: InstallCommandManifest.piCLIPackageName,
                executableNames: ["pi"],
                candidates: piPath.map { [$0] } ?? defaultCandidates(named: "pi"),
                knownVersion: piFinding.version,
                probesShellPath: false
            ),
            ComponentInstallationDetector.ComponentDetectionRequest(
                kind: .piWeb,
                packageName: Self.piWebPackageName,
                executableNames: ["pi-web"],
                candidates: piWebPath.map { [$0] } ?? piWebCandidates(),
                knownVersion: piWebFinding.version,
                probesShellPath: false
            )
        ]
        // 应用自身：默认不检测（`.none`），只有 app target 传入 `.current`。
        if let bundlePath = applicationInstallation.bundlePath {
            requests.append(ComponentInstallationDetector.ComponentDetectionRequest(
                kind: .desktopApp,
                packageName: nil,
                executableNames: [],
                candidates: [bundlePath],
                knownVersion: applicationInstallation.version,
                runsVersionCommand: false,
                isApplicationBundle: true
            ))
        }
        var components = detector.detectAll(requests)
        components.append(contentsOf: detector.detectPiPackages(piExecutablePath: piPath))
        return components.map { $0.redacted(using: redactor) }
    }

    /// 默认服务端口是否可用。只做本地 `bind(2)`，不连接网络、不调用命令。
    /// 占用只提示不阻塞：占用者可能就是已有的 Pi Web 服务，应用会直接复用。
    private func makePortFinding() -> DependencyFinding {
        let available = portProbe.isPortAvailable(host: serviceHostname, port: servicePort)
        let status: DependencyFinding.Status
        let confidence: DependencyFinding.Confidence
        switch available {
        case .some(true):
            status = .ok
            confidence = .verified
        case .some(false):
            status = .occupied
            confidence = .verified
        case .none:
            status = .unknown
            confidence = .unknown
        }
        return DependencyFinding(
            kind: .port,
            status: status,
            path: "\(serviceHostname):\(servicePort)",
            resolvedPath: nil,
            symlinkTarget: nil,
            version: nil,
            installSource: .system,
            confidence: confidence,
            remediationID: nil,
            packageName: nil,
            packageVersion: nil
        )
    }

    /// Pi 配置目录（`~/.pi/agent`）的存在与可读性。
    ///
    /// 只向文件系统探针询问“是否存在/是否可读”，不列目录、不读取目录里的任何
    /// 文件，因此认证内容永远不会进入诊断报告。缺失或不可读只做提示，不阻塞
    /// 启动，也没有修复命令（首次运行 Pi CLI 会自行创建该目录）。
    private func makePiConfigurationDirectoryFinding(redactor: DependencyPathRedactor) -> DependencyFinding {
        let home = normalizedDirectory(fileSystem.homeDirectoryPath())
        let rawPath = home.isEmpty
            ? Self.piConfigurationDirectoryRelativePath
            : "\(home)/\(Self.piConfigurationDirectoryRelativePath)"
        let displayPath = redactor.redact(rawPath)

        func finding(status: DependencyFinding.Status, confidence: DependencyFinding.Confidence) -> DependencyFinding {
            DependencyFinding(
                kind: .piConfigDirectory,
                status: status,
                path: displayPath,
                resolvedPath: nil,
                symlinkTarget: nil,
                version: nil,
                installSource: .localPath,
                confidence: confidence,
                remediationID: nil,
                packageName: nil,
                packageVersion: nil
            )
        }

        guard let exists = fileSystem.directoryExists(atPath: rawPath) else {
            return finding(status: .unknown, confidence: .unknown)
        }
        guard exists else {
            return finding(status: .missing, confidence: .verified)
        }
        guard let readable = fileSystem.isReadableDirectory(atPath: rawPath) else {
            return finding(status: .unknown, confidence: .unknown)
        }
        return finding(status: readable ? .ok : .unreadable, confidence: .verified)
    }

    private func missingFinding(kind: DependencyFinding.Kind, remediationID: String? = nil) -> DependencyFinding {
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
        case .port: return "默认端口"
        case .piConfigDirectory: return "Pi 配置目录"
        }
    }

    static func statusText(for status: DependencyFinding.Status) -> String {
        switch status {
        case .ok: return "正常"
        case .missing: return "缺失"
        case .outdated: return "版本过旧"
        case .occupied: return "被占用"
        case .unreadable: return "不可读"
        case .unknown: return "无法确定"
        }
    }

    static func sourceText(for source: DependencyInstallSource) -> String {
        switch source {
        case .homebrew: return "Homebrew"
        case .npmGlobal: return "npm 全局"
        case .localPath: return "本地路径"
        case .system: return "系统"
        case .unknown: return "未知"
        }
    }

    /// 路径列文本：没有路径时区分“不适用”（系统/端口/配置目录）与“未找到”（可执行文件）。
    static func pathText(for finding: DependencyFinding) -> String {
        if let path = finding.path { return path }
        switch finding.kind {
        case .system, .port, .piConfigDirectory: return "—"
        case .node, .piCLI, .piWeb: return "未找到"
        }
    }

    /// 版本列文本：端口与配置目录没有版本概念，用“—”而不是“未知”。
    static func versionText(for finding: DependencyFinding) -> String {
        if let version = finding.version { return version }
        switch finding.kind {
        case .system, .node, .piCLI, .piWeb: return "未知"
        case .port, .piConfigDirectory: return "—"
        }
    }

    static func confidenceText(for confidence: DependencyFinding.Confidence) -> String {
        switch confidence {
        case .verified: return "已验证"
        case .inferred: return "推断"
        case .unknown: return "未知"
        }
    }

    // MARK: - 组件安装呈现（GitHub #16）

    /// 组件安装的单行摘要（诊断状态页用）：每项都给出路径、包名、版本、来源、
    /// 可信度与建议命令，缺值用占位符。
    static func componentSummaryLines(for report: DependencyReport) -> [String] {
        report.components.map { "· " + $0.summaryLine }
    }

    /// 组件安装块（诊断窗口用）：路径、包名、版本、来源、可信度、建议命令与证据。
    /// 只消费已经脱敏的 `ComponentInstallation`，不执行任何命令。
    static func componentInstallationsText(for report: DependencyReport) -> String {
        guard !report.components.isEmpty else { return "" }
        var lines = ["组件安装（只展示，应用不会执行更新命令）："]
        for component in report.components {
            lines.append("· \(component.kind.displayName)（\(component.kind.rawValue)）")
            lines.append("  路径：\(component.executablePath ?? "未找到")")
            if let resolved = component.resolvedPath, resolved != component.executablePath {
                lines.append("  真实路径：\(resolved)")
            }
            if component.symlinkChain.count > 1 {
                lines.append("  符号链接链：\(component.symlinkChain.joined(separator: " → "))")
            }
            lines.append("  包名：\(component.packageName ?? "未找到")")
            lines.append("  版本：\(component.version ?? "未知")")
            if let packageJSONPath = component.packageJSONPath {
                lines.append("  package.json：\(packageJSONPath)")
            }
            lines.append("  来源：\(component.source.displayName)（\(component.source.rawValue)）")
            lines.append("  可信度：\(component.confidence.displayName)")
            if let command = component.suggestedCommand {
                lines.append("  建议命令：\(command)")
            } else if let guidance = InstallCommandManifest.updateGuidance(for: component.kind, source: component.source) {
                lines.append("  建议命令：无；\(guidance.note)")
            } else {
                lines.append("  建议命令：无；请按来源文档更新。")
            }
            if !component.evidence.isEmpty {
                lines.append("  证据：")
                lines.append(contentsOf: component.evidence.map { "    - \($0)" })
            }
        }
        return lines.joined(separator: "\n")
    }

    static func rows(for report: DependencyReport) -> [Row] {
        report.findings.map { finding in
            Row(
                title: title(for: finding.kind),
                status: statusText(for: finding.status),
                path: pathText(for: finding),
                version: versionText(for: finding),
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
            lines.append("  版本：\(versionText(for: finding))")
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
            if let nextStep = nextStepText(for: finding) {
                lines.append("  下一步：\(nextStep)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 单个诊断项的下一步操作提示；不需要提示时返回 nil。
    ///
    /// 端口与 Pi 配置目录永远返回 nil 到“修复命令”路径：它们不阻塞启动，
    /// 文本里只给可读说明，不会让应用去安装、创建或读取任何东西。
    static func nextStepText(for finding: DependencyFinding) -> String? {
        switch finding.kind {
        case .system:
            return finding.status == .ok ? nil : "系统项只做提示，不阻塞启动。"
        case .node:
            return finding.status == .ok ? nil : "安装或升级 Node.js 到最低版本，然后点击“重新检测”。"
        case .piCLI:
            guard finding.status != .ok else { return nil }
            return "安装 Pi CLI（命令见诊断窗口的“复制安装命令”），然后点击“重新检测”。"
        case .piWeb:
            switch finding.status {
            case .ok:
                return nil
            case .missing:
                return "安装 Pi Web，或在诊断窗口点击“选择 pi-web 路径…”指定已安装的可执行文件。"
            default:
                return "已找到 pi-web，但版本无法解析；不影响启动。"
            }
        case .port:
            switch finding.status {
            case .occupied:
                return "端口被占用不会阻塞启动；如果占用者是已有的 Pi Web 服务，应用会直接使用它，否则请在“设置”里更换端口。"
            case .unknown:
                return "无法确认端口占用情况，不影响启动。"
            default:
                return nil
            }
        case .piConfigDirectory:
            switch finding.status {
            case .missing:
                return "尚未创建 Pi 配置目录（~/\(DependencyChecker.piConfigurationDirectoryRelativePath)）：先运行一次 Pi CLI；应用不会创建该目录，也不会读取其中的认证文件。"
            case .unreadable, .unknown:
                return "无法确认 Pi 配置目录的存在与可读性；不影响启动，应用不会读取目录内容。"
            default:
                return nil
            }
        }
    }

    /// 首次启动诊断状态页正文（WebView 与诊断窗口共用）。
    ///
    /// 只输出已脱敏的报告字段和静态文案；不包含 URL 查询参数、凭据或真实
    /// 用户绝对路径。硬性前置缺失时列出缺失项与下一步操作；就绪但首次设置
    /// 尚未完成时说明如何进入主窗口。
    static func statusPageText(for report: DependencyReport, setupIncomplete: Bool) -> String {
        var lines: [String] = []
        if report.canStartService {
            lines.append("结论：硬性前置已满足。")
            if setupIncomplete {
                lines.append("首次设置尚未完成：请点击“开始使用 Pi Web”，或在诊断窗口点击“重新检测”后进入主窗口。")
            } else {
                lines.append("服务可以启动。")
            }
        } else {
            lines.append("结论：缺少硬性前置，服务启动已暂停。应用会保留窗口，不会退出。")
        }

        lines.append("")
        lines.append("诊断结果：")
        for finding in report.findings {
            // 每一项都输出完整的五个字段，缺值用占位符，不因 nil 省略整行。
            let fields = [
                "· \(title(for: finding.kind))：\(statusText(for: finding.status))",
                "路径：\(pathText(for: finding))",
                "版本：\(versionText(for: finding))",
                "来源：\(sourceText(for: finding.installSource))",
                "可信度：\(confidenceText(for: finding.confidence))"
            ]
            lines.append(fields.joined(separator: "  "))
        }

        let componentLines = componentSummaryLines(for: report)
        if !componentLines.isEmpty {
            lines.append("")
            lines.append("组件安装（只展示，应用不会执行更新命令）：")
            lines.append(contentsOf: componentLines)
        }

        let hints = report.findings.compactMap { finding -> String? in
            guard let nextStep = nextStepText(for: finding) else { return nil }
            return "· \(title(for: finding.kind))：\(nextStep)"
        }
        if !hints.isEmpty {
            lines.append("")
            lines.append("下一步：")
            lines.append(contentsOf: hints)
        }
        return lines.joined(separator: "\n")
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
