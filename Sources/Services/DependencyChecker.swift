/// Startup dependency checker together with its timed command runner.

import Darwin
import Foundation

// MARK: - 诊断检查器

/// 给依赖探针加统一超时上限的包装器。
///
/// `DependencyChecker` 的每条命令（`--version`、`npm prefix -g`、登录 shell 的
/// `command -v`）都经这里执行：超过上限按“不可用”（nil）返回，并记下是哪条探针
/// 超时了，诊断文本因此能写出可读原因（“依赖探测超时”），而不是让服务门控
/// 永远停在检查中。同一个包装器会作为 `commandRunner` 交给组件安装识别，因此
/// 那条路径也受同一上限约束。
///
/// 并发说明：一次依赖检查在同一个后台队列上串行执行，包装器不需要额外加锁。
final class TimedProbeCommandRunner: CommandRunning {
    private let base: CommandRunning
    private let timeout: TimeInterval
    private(set) var timedOutArguments: [[String]] = []

    init(base: CommandRunning, timeout: TimeInterval) {
        self.base = base
        self.timeout = timeout
    }

    func run(_ arguments: [String]) -> String? {
        let result = base.run(arguments, timeout: timeout)
        if result.timedOut { timedOutArguments.append(arguments) }
        return result.output
    }

    func run(_ arguments: [String], timeout: TimeInterval) -> CommandRunResult {
        let result = base.run(arguments, timeout: timeout)
        if result.timedOut { timedOutArguments.append(arguments) }
        return result
    }

    func run(_ arguments: [String], environment: [String: String]?) -> String? {
        run(arguments, environment: environment, timeout: timeout).output
    }

    func run(_ arguments: [String], environment: [String: String]?, timeout: TimeInterval) -> CommandRunResult {
        let result = base.run(arguments, environment: environment, timeout: timeout)
        if result.timedOut { timedOutArguments.append(arguments) }
        return result
    }

    func cancelRunningProbe() {
        base.cancelRunningProbe()
    }

    /// 清空本次检查的累计状态（`DependencyChecker.run()` 入口调用）。
    func reset() {
        timedOutArguments.removeAll()
    }

    /// 是否有超时探针的参数**完全等于** `expected`（登录 shell 探测用）。
    func didTimeOut(arguments expected: [String]) -> Bool {
        timedOutArguments.contains { $0 == expected }
    }

    /// 是否有超时探针的某个参数**恰好等于** `argument`（`npm`、
    /// `process.execPath` 这类固定参数用）。
    func didTimeOut(argument: String) -> Bool {
        timedOutArguments.contains { $0.contains(argument) }
    }
}

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

    let commandRunner: TimedProbeCommandRunner
    private let probeTimeout: TimeInterval
    private let fileSystem: DependencyFileSystemProbing
    private let system: DependencySystemProbe
    private let configuredPiWebPath: String
    private let serviceHostname: String
    private let servicePort: Int
    private let portProbe: DependencyPortProbing
    private let environment: [String: String]
    private let applicationInstallation: ApplicationInstallationProbe
    /// 应用级工具 PATH（GitHub #89）：注入时与 `ServiceManager` 的启动环境、
    /// 更新子进程共用同一个实例；未注入时按本次检查的注入探针自建（每个
    /// 检查实例最多执行一次登录 shell 查询与一次 npm prefix 查询）。
    let toolPathProvider: ToolPathProvider?
    /// 登录 shell PATH 查询器（注入用）；nil 时用注入的 `commandRunner` 执行
    /// `/bin/zsh -lc 'printf %s "$PATH"'`（超时 + 单次缓存）。
    private let loginShellPath: (() -> String?)?

    init(
        commandRunner: CommandRunning = SystemCommandRunner(),
        fileSystem: DependencyFileSystemProbing = SystemDependencyFileSystemProbe(),
        system: DependencySystemProbe = .live,
        configuredPiWebPath: String = "",
        serviceHostname: String = ServiceConfiguration.defaultHostname,
        servicePort: Int = ServiceConfiguration.defaultPort,
        portProbe: DependencyPortProbing = SystemDependencyPortProbe(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationInstallation: ApplicationInstallationProbe = .none,
        probeTimeout: TimeInterval = SystemCommandRunner.defaultTimeout,
        toolPathProvider: ToolPathProvider? = nil,
        loginShellPath: (() -> String?)? = nil
    ) {
        let probeRunner = TimedProbeCommandRunner(base: commandRunner, timeout: probeTimeout)
        self.commandRunner = probeRunner
        self.probeTimeout = probeTimeout
        self.fileSystem = fileSystem
        self.system = system
        self.configuredPiWebPath = configuredPiWebPath
        self.serviceHostname = serviceHostname
        self.servicePort = servicePort
        self.portProbe = portProbe
        self.environment = environment
        self.applicationInstallation = applicationInstallation
        self.toolPathProvider = toolPathProvider
        self.loginShellPath = loginShellPath
    }

    /// 运行全部检查。顺序固定：系统、Node.js、Pi CLI、Pi Web、默认端口、Pi 配置目录，
    /// 最后附上组件安装识别（GitHub #16；复用同一组探针与已解析的版本）。
    ///
    /// 所有命令探测与版本解析都用同一个 `ToolPathProvider` 构建出来的子进程环境
    /// （GitHub #89）：应用 PATH + 登录 shell PATH + 已知目录 + node 目录 +
    /// npm prefix/bin，因此 `#!/usr/bin/env node` 脚本不会再因为应用从 Finder
    /// 启动时 PATH 最小而 exit 127。
    func run() -> DependencyReport {
        // 每次检查都重新累计超时探针，避免上一次检查的结论影响这一次。
        commandRunner.reset()
        let redactor = DependencyPathRedactor(homeDirectory: fileSystem.homeDirectoryPath())
        let context = probeContext()
        let npmPrefix = context.npmPrefix
        let piPath = resolvePiExecutable(in: context)
        let piWebPath = resolvePiWebExecutable(in: context)
        let piFinding = makePiFinding(path: piPath, npmPrefix: npmPrefix, redactor: redactor, context: context)
        let piWebFinding = makePiWebFinding(path: piWebPath, npmPrefix: npmPrefix, redactor: redactor, context: context)
        return DependencyReport(
            findings: [
                makeSystemFinding(),
                makeNodeFinding(npmPrefix: npmPrefix, redactor: redactor, context: context),
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
                piWebFinding: piWebFinding,
                context: context
            )
        )
    }

    // MARK: - 工具 PATH（GitHub #89）

    /// 一次检查共用的探测上下文：PATH 只构建一次，命令探测与版本解析都用同一份
    /// 子进程环境，候选路径也从同一份目录列表推导。
    private struct ProbeContext {
        var provider: ToolPathProvider
        var environment: [String: String]
        var toolDirectories: [String]
        var npmPrefix: String?
    }

    private func probeContext() -> ProbeContext {
        let provider = toolPathProvider ?? makeToolPathProvider()
        return ProbeContext(
            provider: provider,
            environment: provider.probeEnvironment(),
            toolDirectories: provider.directories(),
            npmPrefix: provider.resolvedNPMPrefix()
        )
    }

    /// 未注入应用级 provider 时，用本次检查的探针自建一个：登录 shell 与 node /
    /// npm 解析都走注入的 `commandRunner` 与文件系统探针，因此测试不会碰真实命令。
    private func makeToolPathProvider() -> ToolPathProvider {
        let shellQuery: () -> String?
        if let loginShellPath {
            shellQuery = loginShellPath
        } else {
            let query = LoginShellPathQuery(runner: commandRunner, environment: environment)
            shellQuery = { query.path() }
        }
        return ToolPathProvider(
            environment: environment,
            homeDirectory: fileSystem.homeDirectoryPath(),
            commandRunner: commandRunner,
            directoryIsUsable: { fileSystem.directoryExists(atPath: $0) },
            fileIsExecutable: { fileSystem.isExecutableFile(atPath: $0) },
            loginShellPath: shellQuery,
            nodePathResolver: { bootstrap in self.resolveNodePath(using: bootstrap) },
            npmPrefixResolver: { bootstrap in self.localNPMPrefix(environment: bootstrap.environment) }
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
        let resolvedVersion: String? = trimmed(commandRunner.run([path, "--version"], environment: probeContext().environment))
            .flatMap { SemanticVersion.firstVersion(in: $0) }?
            .description
        return PiWebIdentityEvidence(
            isExecutable: true,
            version: resolvedVersion,
            packageName: metadata.name
        )
    }

    // MARK: - 探针

    /// 本地 `npm prefix -g`（只读、不联网）；npm 不存在时返回 nil。
    /// 子进程环境由工具 PATH 构建器提供，否则 GUI 启动的应用里 `env npm` 也会
    /// exit 127（npm 同样是 `#!/usr/bin/env node` 脚本）。
    private func localNPMPrefix(environment: [String: String]? = nil) -> String? {
        trimmed(commandRunner.run([Self.runnerPath, "npm", "prefix", "-g"], environment: environment))
            .map(normalizedDirectory)
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
    ///
    /// `toolDirectories` 是工具 PATH 构建器的合并结果（登录 shell PATH、应用 PATH、
    /// 其它已知目录、node 目录、npm prefix/bin）；它只作为候选“追加”在既有的
    /// Homebrew → `/usr/local` → `~/.npm-global` 优先级之后，因此顺序不会倒退。
    /// 可执行文件候选路径（GitHub #89 追加要求）：顺序固定、不重复。
    ///
    /// 1. 经典三处保持最优先（回归基线）：`/opt/homebrew/bin`、`/usr/local/bin`、
    ///    `~/.npm-global/bin`；
    /// 2. 其余已知安装目录按 `ToolPath.knownDirectories` 的固定顺序补齐：
    ///    Homebrew 的 `sbin`（arm64 / Intel）、`/usr/local/sbin`、MacPorts
    ///    `/opt/local/bin`、`~/.local/bin`、`~/.bun/bin`、`~/.cargo/bin`，最后系统目录；
    /// 3. 工具 PATH（应用 PATH + 登录 shell PATH + node 目录 + npm prefix/bin）里的目录。
    private func defaultCandidates(named name: String, toolDirectories: [String] = []) -> [String] {
        // 单一来源在 `ToolPath`（GitHub #89 追加要求）：固定顺序、不重复，
        // 已包含 Homebrew（arm64/Intel）、MacPorts、用户级前缀与系统目录。
        ToolPath.executableCandidates(
            named: name,
            homeDirectory: fileSystem.homeDirectoryPath(),
            additionalDirectories: toolDirectories
        )
    }

    private func resolveExecutable(named name: String, candidates: [String], environment: [String: String]? = nil) -> String? {
        for candidate in candidates where fileSystem.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // 查找走登录 shell（与用户 shell 的 PATH 一致），并带上合并后的工具
        // 环境：`command -v` 本身是 shell 内建，不需要 node，但让同一次查找的
        // 子进程环境与后续 `--version` 探测一致，避免“找得到却跑不起来”。
        let shellResult = trimmed(
            commandRunner.run(Self.shellLookupArguments(named: name), environment: environment)
        )
        guard let path = shellResult, fileSystem.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// 登录 shell 的 `command -v` 探测参数。`resolveExecutable` 与超时归因共用
    /// 同一个形状，两处因此不会漂移。
    private static func shellLookupArguments(named name: String) -> [String] {
        [shellPath, "-lc", "command -v \(name) 2>/dev/null"]
    }

    /// 解析该组件时用到的探针里是否有超时的：登录 shell 的 `command -v <name>`、
    /// 候选路径自己的 `--version`，以及 node 特有的“按进程 PATH 回退”探测
    /// （`process.execPath`）。
    private func didTimeOut(named name: String, paths: [String?], includesNodePathProbe: Bool = false) -> Bool {
        if commandRunner.didTimeOut(arguments: Self.shellLookupArguments(named: name)) { return true }
        if includesNodePathProbe, commandRunner.didTimeOut(argument: "process.execPath") { return true }
        return paths.compactMap { $0 }.contains { commandRunner.didTimeOut(arguments: [$0, "--version"]) }
    }

    /// 探针超时的统一可读原因；写进诊断项的 `detail` 与“下一步”。
    private var probeTimeoutDetail: String {
        "依赖探测超时：命令在 \(Int(probeTimeout)) 秒上限内没有返回"
    }

    /// 状态不是 `ok` 时的可读原因：超时解释优先，其次是工具 PATH / 版本输出诊断。
    /// 两者都没有时返回 nil（不制造噪声）。
    private func probeDetail(timedOut: Bool, diagnosis: String?) -> String? {
        if timedOut { return probeTimeoutDetail }
        guard let diagnosis, !diagnosis.isEmpty else { return nil }
        return diagnosis
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
                // 局部名避开方法名 `version(of:environment:)`（同一类型内的名子遮蔽）。
                let packageVersion = (dictionary["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (name?.isEmpty == false ? name : nil, packageVersion?.isEmpty == false ? packageVersion : nil)
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

    /// 解析 node 可执行文件（不查版本）。
    ///
    /// 候选路径（含登录 shell 的 `command -v`）存在时只使用它；候选路径完全不存在
    /// 时，才按 bootstrap 的进程 PATH 重新解析（`/usr/bin/env node -p process.execPath`）
    /// 并确认可执行位。版本只在 `makeNodeFinding` 里对最终路径查一次，保证
    /// 路径与版本同源；解析不出路径就不采信任何版本。
    private func resolveNodePath(using bootstrap: ToolPathProvider.Bootstrap) -> String? {
        if let path = resolveExecutable(
            named: "node",
            candidates: defaultCandidates(named: "node", toolDirectories: bootstrap.directories),
            environment: bootstrap.environment
        ) {
            return path
        }
        guard let path = trimmed(commandRunner.run([Self.runnerPath, "node", "-p", "process.execPath"], environment: bootstrap.environment)),
              fileSystem.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    private func version(of executablePath: String, environment: [String: String]? = nil) -> SemanticVersion? {
        trimmed(commandRunner.run([executablePath, "--version"], environment: environment))
            .flatMap { SemanticVersion.firstVersion(in: $0) }
    }

    private func makeNodeFinding(npmPrefix: String?, redactor: DependencyPathRedactor, context: ProbeContext) -> DependencyFinding {
        // 路径来自工具 PATH 的解析（候选优先，其次进程 PATH 回退）；版本只由该
        // 路径自己产出——不可运行就不允许用另一个 node 的版本把它放行。
        let path = context.provider.resolvedNodePath()
        // 显式写 `self.` 与显式类型：局部变量名不得遮蔽方法名 `version(of:environment:)`，
        // 否则 Xcode（SWIFT_VERSION 5.0）会报 “type of expression is ambiguous”。
        let resolvedVersion: SemanticVersion? = path.flatMap {
            self.version(of: $0, environment: context.environment)
        }
        let source = installSource(
            path: path ?? "",
            resolvedPath: path.flatMap { fileSystem.resolvedPath(atPath: $0) },
            npmPrefix: npmPrefix,
            homeDirectory: fileSystem.homeDirectoryPath()
        )

        let status: DependencyFinding.Status
        let statusEvidence: DependencyFinding.Confidence
        let remediationID: String?
        if let resolvedVersion {
            if resolvedVersion < Self.minimumNodeVersion {
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

        var diagnosis: String?
        if resolvedVersion == nil {
            if path == nil {
                diagnosis = "命令无法执行：PATH 中找不到 node（已尝试合并后的工具 PATH、已知目录与登录 shell）"
            } else {
                diagnosis = "`node --version` 无输出或非零退出；路径存在但版本无法作为证据"
            }
        }

        return DependencyFinding(
            kind: .node,
            status: status,
            path: path.map { redactor.redact($0) },
            resolvedPath: path.flatMap { fileSystem.resolvedPath(atPath: $0) }.map { redactor.redact($0) },
            symlinkTarget: path.flatMap { fileSystem.symlinkDestination(atPath: $0) }.map { redactor.redact($0) },
            version: resolvedVersion?.description,
            installSource: source.source,
            confidence: .weakest([statusEvidence, sourceEvidence]),
            remediationID: remediationID,
            packageName: nil,
            packageVersion: nil,
            // 状态不是 ok 时给原因：超时优先（它解释了失败的机制），否则是
            // GitHub #89 的“命令无法执行 / 版本输出不可用”诊断。
            detail: status == .ok
                ? nil
                : probeDetail(
                    timedOut: didTimeOut(named: "node", paths: [path], includesNodePathProbe: true),
                    diagnosis: diagnosis
                )
        )
    }

    /// Pi CLI 的可执行文件路径（只读解析；找不到时 nil）。候选列表来自工具 PATH。
    private func resolvePiExecutable(in context: ProbeContext) -> String? {
        resolveExecutable(
            named: "pi",
            candidates: defaultCandidates(named: "pi", toolDirectories: context.toolDirectories),
            environment: context.environment
        )
    }

    /// Pi Web 的候选路径：用户显式配置的路径优先，否则退回默认候选与
    /// 登录 shell 的 `command -v`。
    private func piWebCandidates(in context: ProbeContext) -> [String] {
        let configured = configuredPiWebPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return configured.isEmpty
            ? defaultCandidates(named: "pi-web", toolDirectories: context.toolDirectories)
            : [configured]
    }

    /// Pi Web 的可执行文件路径。用户显式配置的路径不可执行时按缺失报告，
    /// 不悄悄改用其它副本。
    private func resolvePiWebExecutable(in context: ProbeContext) -> String? {
        let configured = configuredPiWebPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if configured.isEmpty {
            return resolveExecutable(
                named: "pi-web",
                candidates: defaultCandidates(named: "pi-web", toolDirectories: context.toolDirectories),
                environment: context.environment
            )
        }
        return fileSystem.isExecutableFile(atPath: configured) ? configured : nil
    }

    private func makePiFinding(
        path: String?,
        npmPrefix: String?,
        redactor: DependencyPathRedactor,
        context: ProbeContext
    ) -> DependencyFinding {
        guard let path else {
            // 路径没解析出来也可能是登录 shell 探测超时；把可读原因写进该项，
            // 否则用户只会看到“缺失”并被建议安装，而实际上是探测没返回。
            return missingFinding(
                kind: .piCLI,
                remediationID: InstallCommandManifest.piCLI.id,
                detail: didTimeOut(named: "pi", paths: []) ? probeTimeoutDetail : nil
            )
        }
        let evidence = executableEvidence(at: path)
        // 显式调用 + 显式类型：避免局部名 `version` 遮蔽方法名（同 #89 的 Xcode 报错）。
        let resolvedVersion: SemanticVersion? = self.version(of: path, environment: context.environment)
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
            status: resolvedVersion == nil ? .unknown : .ok,
            path: redactor.redact(path),
            resolvedPath: evidence.resolvedPath.map { redactor.redact($0) },
            symlinkTarget: evidence.symlinkTarget.map { redactor.redact($0) },
            version: resolvedVersion?.description,
            installSource: source.source,
            confidence: .weakest([resolvedVersion == nil ? .inferred : .verified, sourceEvidence]),
            remediationID: resolvedVersion == nil ? InstallCommandManifest.piCLI.id : nil,
            packageName: nil,
            packageVersion: nil,
            detail: resolvedVersion == nil
                ? probeDetail(
                    timedOut: didTimeOut(named: "pi", paths: [path]),
                    diagnosis: versionProbeDiagnosis(name: "pi", context: context)
                )
                : nil
        )
    }

    private func makePiWebFinding(
        path: String?,
        npmPrefix: String?,
        redactor: DependencyPathRedactor,
        context: ProbeContext
    ) -> DependencyFinding {
        guard let path else {
            return missingFinding(
                kind: .piWeb,
                remediationID: InstallCommandManifest.piWeb.id,
                detail: didTimeOut(named: "pi-web", paths: []) ? probeTimeoutDetail : nil
            )
        }

        let evidence = executableEvidence(at: path)
        let metadata = packageMetadata(resolvedPath: evidence.resolvedPath)
        // 显式调用 + 显式类型：`version` 不能作为局部名（它与方法名 `version(of:environment:)`
        // 同名，Xcode 在 789/893 行的等价写法上报 type of expression is ambiguous）。
        let cliVersion: SemanticVersion? = self.version(of: path, environment: context.environment)
        let packageVersion = metadata.version.flatMap { SemanticVersion($0) }
        let resolvedVersion: SemanticVersion? = cliVersion ?? packageVersion
        let source = installSource(
            path: path,
            resolvedPath: evidence.resolvedPath,
            npmPrefix: npmPrefix,
            homeDirectory: fileSystem.homeDirectoryPath()
        )
        let sourceEvidence: DependencyFinding.Confidence =
            source.verified ? .verified : (source.source == .unknown ? .unknown : .inferred)
        // package.json 缺失不影响结论；name 与预期不符时身份证据只能算推断。
        var evidences: [DependencyFinding.Confidence] = [resolvedVersion == nil ? .inferred : .verified, sourceEvidence]
        if let packageName = metadata.name {
            evidences.append(packageName == Self.piWebPackageName ? .verified : .inferred)
        }
        var diagnosis: String?
        // 只在版本真的拿不到时记录原因：pi-web 不支持 `--version`（以退出码 1
        // 结束）是已知行为，package.json 能补上版本时不算失败，否则会在健康的
        // 机器上白噪声一条诊断。
        if resolvedVersion == nil {
            diagnosis = versionProbeDiagnosis(name: "pi-web", context: context)
        }
        return DependencyFinding(
            kind: .piWeb,
            status: resolvedVersion == nil ? .unknown : .ok,
            path: redactor.redact(path),
            resolvedPath: evidence.resolvedPath.map { redactor.redact($0) },
            symlinkTarget: evidence.symlinkTarget.map { redactor.redact($0) },
            version: resolvedVersion?.description,
            installSource: source.source,
            confidence: .weakest(evidences),
            remediationID: resolvedVersion == nil ? InstallCommandManifest.piWeb.id : nil,
            packageName: metadata.name,
            packageVersion: metadata.version,
            detail: resolvedVersion == nil
                ? probeDetail(
                    timedOut: didTimeOut(named: "pi-web", paths: [path]),
                    diagnosis: diagnosis
                )
                : nil
        )
    }

    /// 版本探测失败的可读原因（GitHub #89）：不再只留一个 `.unknown`。
    /// 文本只由静态文案与工具名组成，不含路径、凭据、`sudo` 或 URL。
    private func versionProbeDiagnosis(name: String, context: ProbeContext) -> String {
        if context.provider.resolvedNodePath() == nil {
            return "命令无法执行：合并后的工具 PATH 里找不到 node；`\(name)` 是 `#!/usr/bin/env node` 脚本，没有 node 时会以 127 退出"
        }
        return "`\(name) --version` 无输出或非零退出；已经找到 node，但版本输出不能作为身份证据"
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
        piWebFinding: DependencyFinding,
        context: ProbeContext
    ) -> [ComponentInstallation] {
        let detector = ComponentInstallationDetector(
            commandRunner: commandRunner,
            fileSystem: fileSystem,
            environment: environment,
            homeDirectory: fileSystem.homeDirectoryPath(),
            knownNPMPrefix: npmPrefix,
            // `npm root -g` / `pnpm root -g` / `pi list` 都是 `#!/usr/bin/env node`
            // 脚本：用同一份工具 PATH，否则组件识别也会因为找不到 node 而降级。
            commandEnvironment: context.environment
        )
        // 候选路径直接用已经解析出的可执行文件；`probesShellPath: false` 表示
        // 不再重复执行 `command -v`（`resolveExecutable` 已经做过）。
        var requests: [ComponentInstallationDetector.ComponentDetectionRequest] = [
            ComponentInstallationDetector.ComponentDetectionRequest(
                kind: .piCLI,
                packageName: InstallCommandManifest.piCLIPackageName,
                executableNames: ["pi"],
                candidates: piPath.map { [$0] } ?? defaultCandidates(named: "pi", toolDirectories: context.toolDirectories),
                knownVersion: piFinding.version,
                probesShellPath: false
            ),
            ComponentInstallationDetector.ComponentDetectionRequest(
                kind: .piWeb,
                packageName: Self.piWebPackageName,
                executableNames: ["pi-web"],
                candidates: piWebPath.map { [$0] } ?? piWebCandidates(in: context),
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

    private func missingFinding(
        kind: DependencyFinding.Kind,
        remediationID: String? = nil,
        detail: String? = nil
    ) -> DependencyFinding {
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
            packageVersion: nil,
            detail: detail
        )
    }

    static func isAtLeast(_ version: OperatingSystemVersion, _ minimum: OperatingSystemVersion) -> Bool {
        if version.majorVersion != minimum.majorVersion { return version.majorVersion > minimum.majorVersion }
        if version.minorVersion != minimum.minorVersion { return version.minorVersion > minimum.minorVersion }
        return version.patchVersion >= minimum.patchVersion
    }
}

// MARK: - 启动门控快路径缓存存储（GitHub #169）

/// 缓存文件的读写接缝：生产环境用 `FileManager`，测试用内存替身。
/// 缓存只是“上次结论的副本”，读写失败都不影响本次检查结论。
protocol DependencyGateCacheFileIO {
    /// 读取整个文件；不存在、不可读或读取失败时返回 nil。
    func read(from url: URL) -> Data?
    /// 原子写入（必要时创建父目录）；返回是否成功。
    @discardableResult
    func write(_ data: Data, to url: URL) -> Bool
}

/// 生产实现：`FileManager` + 原子写入，父目录按需创建。
struct SystemDependencyGateCacheFileIO: DependencyGateCacheFileIO {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func read(from url: URL) -> Data? {
        fileManager.contents(atPath: url.path)
    }

    @discardableResult
    func write(_ data: Data, to url: URL) -> Bool {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// 启动门控快路径缓存的落盘存储。
///
/// 文件是支持目录下的独立 JSON（路径来自 `AppConfiguration.dependencyGateCacheURL`），
/// 不写用户偏好设置、不进仓库。两个方向都以“返回 nil / false”表示失败：缓存永远
/// 不能把启动卡住，也不能改变本次结论。
struct DependencyGateCacheStore {
    var url: URL
    var fileIO: DependencyGateCacheFileIO = SystemDependencyGateCacheFileIO()

    /// 读缓存：nil 表示没有可用缓存（缺失、读不到或不可解析），调用方按完整检查
    /// 处理（fail-closed）。
    func load() -> DependencyGateCache? {
        guard let data = fileIO.read(from: url) else { return nil }
        let decoder = JSONDecoder()
        // `writtenAt` 用 ISO8601：跨版本可读，日志里也能直接看出缓存写入时间。
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DependencyGateCache.self, from: data)
    }

    /// 写缓存：返回是否成功。失败只影响下一次启动的速度。
    @discardableResult
    func save(_ cache: DependencyGateCache) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cache) else { return false }
        return fileIO.write(data, to: url)
    }
}
