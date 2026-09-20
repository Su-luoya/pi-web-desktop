import Foundation

// MARK: - 工具 PATH

/// 子进程工具 PATH 的单一来源（GitHub #89）。
///
/// 背景：应用从 Finder / Dock 启动时，进程环境里的 `PATH` 往往只有
/// `/usr/bin:/bin:/usr/sbin:/sbin`。npm 全局安装的 `pi`、`pi-web`、`npm` 都是带
/// `#!/usr/bin/env node` shebang 的脚本，而 `node` 通常在 `/opt/homebrew/bin`、
/// nvm / fnm / asdf 的版本目录或 `~/.local/bin` 里。于是“路径能解析、版本探测
/// exit 127”这条链路会把 Pi CLI 记成 unknown，并让服务启动被门控挡住。
///
/// 本类型把「应用 PATH → 登录 shell PATH → 已知目录 → node 目录 → npm 全局
/// prefix 的 bin 目录」的合并收成一份实现：顺序固定、去重，只生产 PATH 值，
/// 绝不新引入或转发密钥类环境变量。

/// PATH resolution used to find tools in login shells.

enum ToolPath {
    /// `/usr/bin/env`：解析 `node` / `npm` 时用的固定路径，不依赖应用 PATH。
    static let runnerPath = "/usr/bin/env"

    /// 固定已知目录：Homebrew（Apple Silicon 与 Intel 两种前缀的 `bin`/`sbin`）、
    /// MacPorts（`/opt/local/bin`）。顺序固定：先 arm64 Homebrew，再 Intel 前缀，
    /// 最后 MacPorts（GitHub #89 追加要求）。
    static let knownAbsoluteDirectories = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
        "/opt/local/bin"
    ]

    /// 相对 Home 的已知目录（构建时展开为绝对路径）。
    static let knownHomeRelativeDirectories = [
        ".local/bin",
        ".npm-global/bin",
        ".bun/bin",
        ".cargo/bin"
    ]

    /// 系统目录：放在已知目录之后兜底；应用 PATH 里通常已经包含它们。
    static let systemDirectories = [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    /// 凭据类环境变量键名（与 `LogRedactor` 的敏感键词表同一组词）。
    ///
    /// 构建器只生产 PATH 值；探测子进程的环境会先去掉这些键，因此凭据既不会
    /// 被本类型引入，也不会被转发给子进程。
    static let credentialKeyWords = [
        "token",
        "password",
        "passwd",
        "secret",
        "api_key",
        "api-key",
        "apikey",
        "private_key",
        "privatekey",
        "credential"
    ]

    /// 键名是否属于凭据类（大小写不敏感，命中词表里任意一个词即可）。
    static func isCredentialKey(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return credentialKeyWords.contains { lowered.contains($0) }
    }

    /// 目录字符串规范化：去空白、去尾斜杠；空串返回 nil。
    static func normalizedDirectory(_ path: String?) -> String? {
        guard let path else { return nil }
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized.isEmpty ? nil : normalized
    }

    /// PATH 字符串 → 目录数组（丢掉空项，保留顺序与重复项）。
    static func directories(inPath path: String?) -> [String] {
        guard let path else { return [] }
        return path
            .split(separator: ":", omittingEmptySubsequences: true)
            .compactMap { normalizedDirectory(String($0)) }
    }

    /// 去重合并多组目录：组内顺序保留，第一次出现的目录位置就是它的位置。
    static func uniqueDirectories(_ groups: [[String]]) -> [String] {
        var result: [String] = []
        for group in groups {
            for entry in group {
                guard let directory = normalizedDirectory(entry), !result.contains(directory) else { continue }
                result.append(directory)
            }
        }
        return result
    }

    /// 已知目录（展开 Home）：Homebrew、`/usr/local/bin`、Home 下的工具目录，
    /// 最后是系统目录。
    static func knownDirectories(homeDirectory: String) -> [String] {
        var directories = knownAbsoluteDirectories
        if let home = normalizedDirectory(homeDirectory), home != "/" {
            directories.append(contentsOf: knownHomeRelativeDirectories.map { "\(home)/\($0)" })
        }
        directories.append(contentsOf: systemDirectories)
        return directories
    }

    /// 合并后的 PATH 字符串：`prioritizing` 排在最前（例如工具自己所在目录），
    /// 其余按构建顺序接在后面并去重。
    static func path(prioritizing leading: [String], directories: [String]) -> String {
        uniqueDirectories([leading, directories]).joined(separator: ":")
    }

    /// 可执行文件的候选目录：顺序固定、不重复（GitHub #89 追加要求）。
    ///
    /// 1. “经典三处”保持最优先（回归基线）：`/opt/homebrew/bin`、`/usr/local/bin`、
    ///    `~/.npm-global/bin`；
    /// 2. 其余已知安装目录（Homebrew `sbin`、`/usr/local/sbin`、MacPorts
    ///    `/opt/local/bin`、`~/.local/bin`、`~/.bun/bin`、`~/.cargo/bin`、系统目录）；
    /// 3. 额外的工具 PATH 目录（应用 PATH + 登录 shell PATH + node/npm 目录）。
    static func candidateDirectories(homeDirectory: String, additional: [String] = []) -> [String] {
        let home = normalizedDirectory(homeDirectory)
        var directories = ["/opt/homebrew/bin", "/usr/local/bin"]
        if let home, home != "/" {
            directories.append("\(home)/.npm-global/bin")
        }
        directories.append(contentsOf: knownDirectories(homeDirectory: homeDirectory))
        directories.append(contentsOf: additional)
        return uniqueDirectories([directories])
    }

    /// 可执行文件的候选路径（`<目录>/<名字>`），顺序与 `candidateDirectories` 一致。
    static func executableCandidates(
        named name: String,
        homeDirectory: String,
        additionalDirectories: [String] = []
    ) -> [String] {
        candidateDirectories(homeDirectory: homeDirectory, additional: additionalDirectories)
            .map { "\($0)/\(name)" }
    }
}

// MARK: - PATH 构建器

/// 纯值的 PATH 构建器：输入全部注入，输出只有目录列表、PATH 字符串与子进程
/// 环境，因此可以在测试里断言顺序、去重与“不含凭据键”。
///
/// 合并顺序（固定，遇到重复目录时保留第一次出现的位置）：
/// 1. `leadingDirectories`（需要抢占优先级的目录，例如工具自己所在目录）；
/// 2. 应用进程环境里的 `PATH`；
/// 3. 登录 shell 报告的 `PATH`（由注入的查询器提供，超时与单次缓存在实现方）；
/// 4. 已知目录（`/opt/homebrew/bin`、`/opt/homebrew/sbin`、`/usr/local/bin`、
///    `~/.local/bin`、`~/.npm-global/bin`、`~/.bun/bin`、`~/.cargo/bin`，以及
///    系统目录兜底）；探针回答“不存在”的目录会被丢掉；
/// 5. 解析出的 node 可执行文件所在目录；
/// 6. npm 全局 prefix 的 `bin` 目录。
struct ToolPathBuilder {
    var appEnvironment: [String: String]
    var homeDirectory: String
    /// 排在最前的目录；默认空。
    var leadingDirectories: [String] = []
    /// 登录 shell PATH 查询器；默认不查询（返回 nil），即只用应用 PATH 与已知目录。
    var loginShellPath: () -> String? = { nil }
    /// 目录可用性探针；nil 表示无法判定（此时保留该目录，只增不减）。
    var directoryIsUsable: ((String) -> Bool?)?
    /// 已解析的 node 可执行文件（其所在目录会被补进 PATH）。
    var nodeExecutablePath: String?
    /// 已解析的 npm 全局 prefix（其 `bin` 目录会被补进 PATH）。
    var npmPrefix: String?

    /// 已知目录里“确认不存在”的那些会被丢掉；无法判定时保留。
    private func usableKnownDirectories() -> [String] {
        ToolPath.knownDirectories(homeDirectory: homeDirectory).filter { directory in
            guard let directoryIsUsable else { return true }
            return directoryIsUsable(directory) != false
        }
    }

    /// 合并后的目录列表（顺序固定、已去重）。
    func directories() -> [String] {
        var groups: [[String]] = [
            leadingDirectories,
            ToolPath.directories(inPath: appEnvironment["PATH"]),
            ToolPath.directories(inPath: loginShellPath()),
            usableKnownDirectories()
        ]
        if let nodeDirectory = nodeExecutablePath.flatMap({
            ToolPath.normalizedDirectory(($0 as NSString).deletingLastPathComponent)
        }) {
            groups.append([nodeDirectory])
        }
        if let npmPrefix,
           let npmBin = ToolPath.normalizedDirectory((npmPrefix as NSString).appendingPathComponent("bin")) {
            groups.append([npmBin])
        }
        return ToolPath.uniqueDirectories(groups)
    }

    /// 子进程可用的 PATH 字符串。
    func path() -> String {
        directories().joined(separator: ":")
    }

    /// 合并后的 PATH 字符串，且把额外的 `leading` 目录排在最前（用于“服务/工具
    /// 自己所在目录优先”的场景，例如启动 pi-web、执行 npm）。
    func path(prioritizing leading: [String]) -> String {
        ToolPath.uniqueDirectories([leading, directories()]).joined(separator: ":")
    }

    /// 探测 / 工具子进程环境（GitHub #89）：应用环境去掉凭据类键，PATH 换成
    /// 上面构建的结果。除了 PATH 之外不新增任何键，也不把凭据转发给子进程。
    func probeEnvironment() -> [String: String] {
        // 局部名避开方法名 `environment(overridingPathOf:)`（同类型内名子遮蔽）。
        var result = appEnvironment.filter { !ToolPath.isCredentialKey($0.key) }
        result["PATH"] = path()
        return result
    }

    /// 保留 `base` 的其它键，只替换 PATH：用于服务启动、更新子进程这类已经有
    /// 自己白名单语义的场景（只增路径，不增变量）。
    func environment(overridingPathOf base: [String: String]) -> [String: String] {
        var result = base
        result["PATH"] = path()
        return result
    }
}

// MARK: - 登录 shell PATH 查询

/// 用户登录 shell 的解析（GitHub #89 追加要求）。
///
/// 解析优先级（不写死 `zsh`）：
/// 1. 用户数据库里的登录 shell（`getpwuid(getuid()).pw_shell`，与
///    `dscl . -read ~ UserShell` 同一个数据源，不需要额外子进程）；
/// 2. 应用环境里的 `$SHELL`（Finder 启动时通常是 launchd 给出的值）；
/// 3. `/bin/zsh`，最后 `/bin/sh`。
///
/// 只有“绝对路径 + 可执行”的候选会被采用；都无法判定时用 `/bin/zsh`。
/// 日志与界面不会展示未采用的候选。
enum LoginShellResolver {
    static let fallbackShellPath = "/bin/zsh"

    /// 用户数据库（passwd/Directory Service）里的登录 shell。
    static func userDatabaseShellPath() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        return String(cString: shell)
    }

    static func shellPath(
        environment: [String: String],
        fileIsExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        userDatabaseShellPath: () -> String? = LoginShellResolver.userDatabaseShellPath
    ) -> String {
        let candidates = [userDatabaseShellPath(), environment["SHELL"], fallbackShellPath, "/bin/sh"]
        for candidate in candidates {
            guard let candidate, candidate.hasPrefix("/"), fileIsExecutable(candidate) else { continue }
            return candidate
        }
        return fallbackShellPath
    }
}

/// 登录 shell 的 PATH 查询（GitHub #89：全应用只做一次）。
///
/// 只执行 `<登录 shell> -lc 'printf '<标记>'%s' "$PATH"'`：本机只读、不联网、
/// 不写文件，只取 PATH 的值，不读取任何 shell 配置文件的内容（配置文件由用户
/// 自己的 shell 自己加载，这是登录 shell 的固有行为）。
///
/// 输出用固定标记解析：rc 文件自己打印的内容会被忽略，不会污染 PATH 值。
/// 结果单次缓存；超时、失败与空输出都当成“没有结果”。
///
/// 当登录 shell 查询拿不到值时，可选再试一次**交互式**查询（`-ilc`）：覆盖
/// “PATH 只配在 `~/.zshrc` 这类非登录 shell 的 rc 里”的情况。交互式 rc 可能有
/// 副作用或很慢，因此只在登录查询失败后触发一次，并同样受超时约束。
final class LoginShellPathQuery {
    /// 兼容旧断言：默认退回的登录 shell。实际优先使用用户自己的登录 shell。
    static let shellPath = LoginShellResolver.fallbackShellPath
    /// 输出标记：只有标记之后的内容才是 PATH，rc 自己的输出被忽略。
    static let marker = "__PI_WEB_TOOL_PATH__"
    static let command = "printf '__PI_WEB_TOOL_PATH__%s' \"$PATH\""
    /// 查询超时（秒）：登录 shell 的配置可能很慢，但不能让诊断无限等待。
    static let timeout: TimeInterval = 3

    private let lock = NSLock()
    private let runner: CommandRunning
    private let environment: [String: String]
    private let fileIsExecutable: (String) -> Bool
    private let userDatabaseShellPath: () -> String?
    private let loginShellPath: String?
    private let interactiveFallback: Bool
    private var cached: String??

    init(
        runner: CommandRunning = SystemCommandRunner(timeout: LoginShellPathQuery.timeout),
        environment: [String: String]? = nil,
        timeout: TimeInterval = LoginShellPathQuery.timeout,
        shellPath: String? = nil,
        interactiveFallback: Bool = true,
        fileIsExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        userDatabaseShellPath: @escaping () -> String? = LoginShellResolver.userDatabaseShellPath
    ) {
        // 生产 runner 自身支持有界等待；注入的替身（测试）按原样使用，不额外包装。
        let system = runner as? SystemCommandRunner
        if let system {
            self.runner = SystemCommandRunner(timeout: timeout, environment: system.environment)
        } else {
            self.runner = runner
        }
        // 解析登录 shell 用的环境与查询子进程保持一致：没有显式传入时沿用 runner
        // 自己的环境（测试注入 fixture 的 HOME/PATH 时，两者必须一致，否则会在
        // 真实 HOME 里跑 shell，把测试变成对宿主机 shell 的隐式依赖）。
        self.environment = environment ?? system?.environment ?? ProcessInfo.processInfo.environment
        self.fileIsExecutable = fileIsExecutable
        self.userDatabaseShellPath = userDatabaseShellPath
        self.loginShellPath = shellPath
        self.interactiveFallback = interactiveFallback
    }

    /// 登录 shell 报告的 PATH；查询失败、超时或输出为空时返回 nil。
    func path() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let shell = loginShellPath ?? LoginShellResolver.shellPath(
            environment: environment,
            fileIsExecutable: fileIsExecutable,
            userDatabaseShellPath: userDatabaseShellPath
        )
        var result = Self.parse(output: runner.run([shell, "-lc", Self.command]))
        if result == nil, interactiveFallback {
            // 代价评估：交互式 rc 可能有副作用、可能很慢，所以只在登录查询拿不到值的
            // 时候试一次，并且同样有超时；拿不到值就是值，不会阻塞诊断页。
            result = Self.parse(output: runner.run([shell, "-ilc", Self.command]))
        }
        cached = .some(result)
        return result
    }

    /// 从命令输出里取出标记之后的 PATH 值（纯函数，可单测）。
    static func parse(output: String?) -> String? {
        guard let output, let range = output.range(of: marker, options: .backwards) else { return nil }
        let value = output[range.upperBound...].split(separator: "\n").first.map(String.init) ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - 应用级 PATH 提供者

/// 应用级工具 PATH 提供者（GitHub #89）。
///
/// 依赖探测（`DependencyChecker` / `ComponentInstallation`）、更新子进程与服务
/// 启动环境共用同一个实例：解析一次、缓存一次，PATH 因此只有一份来源。
///
/// 解析分两段：先构建不含 node/npm prefix 的 bootstrap（应用 PATH + 登录 shell
/// PATH + 已知目录），再用注入的解析器得到 node 可执行文件与 npm 全局 prefix，
/// 最后把它们补进 PATH 的末尾。
final class ToolPathProvider {
    /// bootstrap 快照：解析 node / npm prefix 之前的目录、PATH 与子进程环境。
    struct Bootstrap {
        var directories: [String]
        var environment: [String: String]
        var path: String
    }

    /// 用 bootstrap 解析 node 可执行文件 / npm 全局 prefix；无法解析时返回 nil。
    typealias BootstrapResolver = (Bootstrap) -> String?

    /// 目录是否可用；nil 表示无法判定（保留该目录）。
    static func defaultDirectoryIsUsable(_ path: String) -> Bool? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    /// 文件是否存在且可执行。
    static func defaultFileIsExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    private let environment: [String: String]
    private let homeDirectory: String
    private let leadingDirectories: [String]
    private let directoryIsUsable: (String) -> Bool?
    private let loginShellPath: () -> String?
    private let nodePathResolver: BootstrapResolver
    private let npmPrefixResolver: BootstrapResolver

    private let lock = NSLock()
    private var cachedBootstrap: Bootstrap?
    private var didResolve = false
    private var cachedNodePath: String?
    private var cachedNPMPrefix: String?

    init(
        environment: [String: String],
        homeDirectory: String,
        commandRunner: CommandRunning = SystemCommandRunner(),
        leadingDirectories: [String] = [],
        directoryIsUsable: @escaping (String) -> Bool? = ToolPathProvider.defaultDirectoryIsUsable,
        fileIsExecutable: @escaping (String) -> Bool = ToolPathProvider.defaultFileIsExecutable,
        loginShellPath: (() -> String?)? = nil,
        interactiveLoginShellFallback: Bool = true,
        nodePathResolver: BootstrapResolver? = nil,
        npmPrefixResolver: BootstrapResolver? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.leadingDirectories = leadingDirectories
        self.directoryIsUsable = directoryIsUsable
        // 默认查询器在本次提供者内只创建一次，因此登录 shell 最多执行一次。
        let query = LoginShellPathQuery(
            runner: commandRunner,
            environment: environment,
            interactiveFallback: interactiveLoginShellFallback,
            fileIsExecutable: fileIsExecutable
        )
        self.loginShellPath = loginShellPath ?? { query.path() }
        let executableProbe = fileIsExecutable
        self.nodePathResolver = nodePathResolver ?? { bootstrap in
            if let output = commandRunner.run(
                [ToolPath.runnerPath, "node", "-p", "process.execPath"],
                environment: bootstrap.environment
            ) {
                let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty, executableProbe(path) { return path }
            }
            for directory in bootstrap.directories {
                let candidate = (directory as NSString).appendingPathComponent("node")
                if executableProbe(candidate) { return candidate }
            }
            return nil
        }
        self.npmPrefixResolver = npmPrefixResolver ?? { bootstrap in
            let output = commandRunner.run(
                [ToolPath.runnerPath, "npm", "prefix", "-g"],
                environment: bootstrap.environment
            )
            return ToolPath.normalizedDirectory(output)
        }
    }

    /// 生产默认入口：应用进程环境 + `zsh` 登录 shell + 文件系统探针。
    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        commandRunner: CommandRunning = SystemCommandRunner(),
        homeDirectory: String = NSHomeDirectory(),
        leadingDirectories: [String] = []
    ) -> ToolPathProvider {
        ToolPathProvider(
            environment: environment,
            homeDirectory: homeDirectory,
            commandRunner: commandRunner,
            leadingDirectories: leadingDirectories
        )
    }

    /// bootstrap 目录、PATH 与子进程环境（不含 node/npm prefix 两段）。
    func bootstrap() -> Bootstrap {
        lock.lock()
        defer { lock.unlock() }
        return bootstrapLocked()
    }

    /// 解析后的最终构建器（含 node 目录与 npm prefix/bin）。
    func builder() -> ToolPathBuilder {
        lock.lock()
        defer { lock.unlock() }
        resolveLocked()
        return builderLocked()
    }

    /// 解析后的 PATH 字符串。
    func path() -> String {
        builder().path()
    }

    /// 解析后的 PATH，并把额外目录排在最前（例如工具自己所在目录）。
    func path(prioritizing leading: [String]) -> String {
        builder().path(prioritizing: leading)
    }

    /// 解析后的目录列表。
    func directories() -> [String] {
        builder().directories()
    }

    /// 探测 / 工具子进程环境：应用环境去掉凭据类键 + 解析后的 PATH。
    func probeEnvironment() -> [String: String] {
        builder().probeEnvironment()
    }

    /// 保留 `base` 的其它键，只替换 PATH（服务启动、更新子进程等场景）。
    func environment(overridingPathOf base: [String: String]) -> [String: String] {
        builder().environment(overridingPathOf: base)
    }

    /// 解析出的 node 可执行文件；解析不出时 nil。
    func resolvedNodePath() -> String? {
        lock.lock()
        defer { lock.unlock() }
        resolveLocked()
        return cachedNodePath
    }

    /// 解析出的 npm 全局 prefix；解析不出时 nil。
    func resolvedNPMPrefix() -> String? {
        lock.lock()
        defer { lock.unlock() }
        resolveLocked()
        return cachedNPMPrefix
    }

    // MARK: - 内部（调用方已持锁）

    private func bootstrapLocked() -> Bootstrap {
        if let cachedBootstrap { return cachedBootstrap }
        let builder = ToolPathBuilder(
            appEnvironment: environment,
            homeDirectory: homeDirectory,
            leadingDirectories: leadingDirectories,
            loginShellPath: loginShellPath,
            directoryIsUsable: directoryIsUsable,
            nodeExecutablePath: nil,
            npmPrefix: nil
        )
        let directories = builder.directories()
        var probeEnvironment = environment.filter { !ToolPath.isCredentialKey($0.key) }
        probeEnvironment["PATH"] = directories.joined(separator: ":")
        let bootstrap = Bootstrap(
            directories: directories,
            environment: probeEnvironment,
            path: directories.joined(separator: ":")
        )
        cachedBootstrap = bootstrap
        return bootstrap
    }

    /// 两个解析器各自最多调用一次；解析失败只留下 nil，不抛错也不阻塞。
    ///
    /// `didResolve` 在调用解析器之前置位：即使解析器意外回调本提供者，也只会
    /// 读到“还没解析出结果”的 nil，不会递归加锁。
    private func resolveLocked() {
        guard !didResolve else { return }
        didResolve = true
        let bootstrap = bootstrapLocked()
        cachedNPMPrefix = npmPrefixResolver(bootstrap)
        cachedNodePath = nodePathResolver(bootstrap)
    }

    private func builderLocked() -> ToolPathBuilder {
        ToolPathBuilder(
            appEnvironment: environment,
            homeDirectory: homeDirectory,
            leadingDirectories: leadingDirectories,
            loginShellPath: loginShellPath,
            directoryIsUsable: directoryIsUsable,
            nodeExecutablePath: cachedNodePath,
            npmPrefix: cachedNPMPrefix
        )
    }
}

// MARK: - 带固定环境的执行器

/// 给命令执行器套上固定的子进程环境（GitHub #89）。
///
/// 应用级 runner 因此与依赖探测、组件识别共用同一份 PATH；环境已由构建器去掉
/// 凭据类键，只覆盖 PATH 与既有键，不新增变量。
struct ToolEnvironmentCommandRunner: CommandRunning {
    var base: CommandRunning
    var environment: [String: String]

    func run(_ arguments: [String]) -> String? {
        base.run(arguments, environment: environment)
    }

    func run(_ arguments: [String], environment: [String: String]?) -> String? {
        base.run(arguments, environment: environment ?? self.environment)
    }
}
