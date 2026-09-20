/// Service launch specification, POSIX child process handling and spawn errors.

import Foundation

/// Everything needed to launch the managed pi-web process. Built by a pure
/// factory so tests can assert the exact command line and environment.
struct ServiceLaunchSpecification: Equatable {
    var executablePath: String
    var arguments: [String]
    var workingDirectory: URL
    var environment: [String: String]

    /// 构造启动规格。`remoteAccessPassword` 必须是调用方在本次启动操作中已经用于
    /// 校验的那一个值（一次读取、随决策传递）：本方法不再读 Keychain，因此不会
    /// 出现“校验时有效、构造环境时失效却仍然启动”的 fail-open 窗口。
    static func make(
        configuration: ServiceConfiguration,
        piWebPath: String,
        appConfiguration: AppConfiguration,
        baseEnvironment: [String: String],
        remoteAccessPassword: String? = nil,
        toolPathProvider: ToolPathProvider? = nil
    ) -> ServiceLaunchSpecification {
        var environment = baseEnvironment
        environment["PI_WEB_NO_OPEN"] = "1"
        // 远程访问密码只通过子进程环境传递：不进入命令行、UserDefaults、日志、
        // 诊断文本或错误消息。loopback 模式、缺少密码和读取失败都只会清掉继承
        // 来的同名变量，绝不退化成无认证的远程监听。
        if !RemoteAccessPolicy.isLoopbackHostname(configuration.hostname),
           let remoteAccessPassword,
           !remoteAccessPassword.isEmpty {
            environment["PI_WEB_PASSWORD"] = remoteAccessPassword
        } else {
            environment.removeValue(forKey: "PI_WEB_PASSWORD")
        }
        if !configuration.allowedHosts.isEmpty {
            environment["PI_WEB_ALLOWED_HOSTS"] = configuration.allowedHosts
        } else {
            environment.removeValue(forKey: "PI_WEB_ALLOWED_HOSTS")
        }
        // PATH 不再硬编码（GitHub #89）：由应用级工具 PATH 构建器给出——应用 PATH
        // → 登录 shell PATH → 已知目录 → node 目录 → npm prefix/bin，与依赖探测、
        // 组件识别、更新子进程共用同一个实例，因此三处 PATH 完全一致。
        environment["PATH"] = resolvedToolPath(toolPathProvider, baseEnvironment: baseEnvironment)
        let proxyURL = configuration.httpProxy
        let httpsProxyURL = configuration.httpsProxy
        for (key, value) in [("HTTP_PROXY", proxyURL), ("http_proxy", proxyURL), ("HTTPS_PROXY", httpsProxyURL), ("https_proxy", httpsProxyURL)] {
            if value.isEmpty { environment.removeValue(forKey: key) } else { environment[key] = value }
        }
        if configuration.noProxy.isEmpty {
            environment.removeValue(forKey: "NO_PROXY")
            environment.removeValue(forKey: "no_proxy")
        } else {
            environment["NO_PROXY"] = configuration.noProxy
            environment["no_proxy"] = configuration.noProxy
        }
        return ServiceLaunchSpecification(
            executablePath: piWebPath,
            arguments: arguments(configuration: configuration),
            workingDirectory: appConfiguration.workspaceDirectory(for: configuration),
            environment: environment
        )
    }

    /// 启动环境的 PATH：注入的构建器优先，其次是纯静态兜底（应用环境 + 已知目录）。
    /// 两条路径都只产出目录列表，不引入任何新变量，也不执行任何命令。
    private static func resolvedToolPath(
        _ provider: ToolPathProvider?,
        baseEnvironment: [String: String]
    ) -> String {
        if let provider { return provider.path() }
        return ToolPathBuilder(
            appEnvironment: baseEnvironment,
            // Home 只从传入的环境推断：调用方没给 HOME 时不猜真实用户目录，
            // 仍然保留 Homebrew / `/usr/local` / 系统目录兜底。
            homeDirectory: baseEnvironment["HOME"] ?? ""
        ).path()
    }

    /// Canonical argument list for a configuration. The launcher and the
    /// ownership record share it, so `argumentsDigest` always describes what
    /// the app would actually launch.
    static func arguments(configuration: ServiceConfiguration) -> [String] {
        ["--hostname", configuration.hostname, "--port", String(configuration.port), "--no-open"]
    }

    /// 诊断展示用：把子进程环境整理成按键排序的 `KEY=value` 行。值原样给出，
    /// 调用方必须用共用的 `LogRedactor` 脱敏后再展示或复制（GitHub #10）。
    static func environmentDescription(_ environment: [String: String]) -> String {
        environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }.joined(separator: "\n")
    }
}

/// Handle for a launched service process.
protocol ServiceProcessHandle: AnyObject {
    var processIdentifier: pid_t { get }
    var isRunning: Bool { get }
}

/// Launches the managed service process. Injected so the start decision can be
/// tested without spawning a real process.
protocol ServiceLaunching: AnyObject {
    /// Launches `specification` with stdout/stderr redirected to `logHandle`.
    /// Since GitHub #73 that handle is the write end of a pipe owned by
    /// `LogWriter`; the app-side reader redacts and appends the output, so
    /// rotation never invalidates what the child writes to.
    /// `onTermination` is installed before the process runs so a fast exit is
    /// never missed; it may be called on any thread.
    func launch(
        _ specification: ServiceLaunchSpecification,
        logHandle: FileHandle,
        onTermination: @escaping () -> Void
    ) throws -> ServiceProcessHandle
}

/// The only place in the app that starts a real service process.
///
/// `posix_spawn` replaces `Process` for one reason: the child must become the
/// leader of its own process group (`POSIX_SPAWN_SETPGROUP` with `pgroup = 0`).
/// That group is what the ownership record stores and what stop signals target,
/// so helper processes of the service are covered and a single recycled PID is
/// never signalled on its own.
///
/// stdin is `/dev/null`; stdout and stderr are the write end of the
/// `LogWriter` pipe (the log file itself is only written by the app); the child
/// environment and working directory match the previous `Process` behaviour.
final class SystemServiceLauncher: ServiceLaunching {
    func launch(
        _ specification: ServiceLaunchSpecification,
        logHandle: FileHandle,
        onTermination: @escaping () -> Void
    ) throws -> ServiceProcessHandle {
        let pid = try spawn(specification, logHandle: logHandle)
        // There is no Foundation `Process` object to attach a termination
        // handler to, so reap the child on a background queue and report its
        // exit exactly once. Reaping also keeps a zombie from looking alive.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            onTermination()
        }
        return POSIXServiceProcess(processIdentifier: pid)
    }

    private func spawn(_ specification: ServiceLaunchSpecification, logHandle: FileHandle) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var status = posix_spawn_file_actions_init(&fileActions)
        guard status == 0 else { throw ServiceSpawnError.fileActionsUnavailable(status) }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        status = posix_spawnattr_init(&attributes)
        guard status == 0 else { throw ServiceSpawnError.attributesUnavailable(status) }
        defer { posix_spawnattr_destroy(&attributes) }

        // `POSIX_SPAWN_SETPGROUP` makes the child a process group leader.
        // `POSIX_SPAWN_CLOEXEC_DEFAULT` keeps unrelated descriptors out of the
        // child; the file actions below are what keeps stdin/stdout/stderr.
        let flags = Int16(POSIX_SPAWN_SETPGROUP) | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        status = posix_spawnattr_setflags(&attributes, flags)
        guard status == 0 else { throw ServiceSpawnError.attributesUnavailable(status) }
        // pgroup 0: the child's process group id becomes its own pid.
        status = posix_spawnattr_setpgroup(&attributes, 0)
        guard status == 0 else { throw ServiceSpawnError.attributesUnavailable(status) }

        let rawNullDevice = open("/dev/null", O_RDONLY)
        guard rawNullDevice >= 0 else { throw ServiceSpawnError.standardDescriptorsUnavailable(errno) }
        // Owned by this function and always closed again; when `open` handed
        // out fd 0-2 those descriptors were closed before, so closing them
        // restores the previous state instead of leaking a descriptor.
        defer { close(rawNullDevice) }
        guard let nullDevice = SpawnFileDescriptor.aboveStandardError(rawNullDevice) else {
            throw ServiceSpawnError.standardDescriptorsUnavailable(EMFILE)
        }
        defer { nullDevice.closeIfDuplicate() }
        guard let logDevice = SpawnFileDescriptor.aboveStandardError(logHandle.fileDescriptor) else {
            throw ServiceSpawnError.standardDescriptorsUnavailable(EMFILE)
        }
        defer { logDevice.closeIfDuplicate() }
        status = posix_spawn_file_actions_adddup2(&fileActions, nullDevice.descriptor, STDIN_FILENO)
        guard status == 0 else { throw ServiceSpawnError.standardDescriptorsUnavailable(status) }
        status = posix_spawn_file_actions_adddup2(&fileActions, logDevice.descriptor, STDOUT_FILENO)
        guard status == 0 else { throw ServiceSpawnError.standardDescriptorsUnavailable(status) }
        status = posix_spawn_file_actions_adddup2(&fileActions, logDevice.descriptor, STDERR_FILENO)
        guard status == 0 else { throw ServiceSpawnError.standardDescriptorsUnavailable(status) }
        if nullDevice.isDuplicate {
            status = posix_spawn_file_actions_addclose(&fileActions, nullDevice.descriptor)
            guard status == 0 else { throw ServiceSpawnError.standardDescriptorsUnavailable(status) }
        }
        if logDevice.isDuplicate {
            status = posix_spawn_file_actions_addclose(&fileActions, logDevice.descriptor)
            guard status == 0 else { throw ServiceSpawnError.standardDescriptorsUnavailable(status) }
        }

        // `posix_spawn` has no portable working-directory action. `addchdir`
        // needs macOS 26 while the app targets macOS 14, so the `_np` variant
        // is the only usable one here.
        let workingDirectory = specification.workingDirectory.path
        if !workingDirectory.isEmpty {
            status = posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory)
            guard status == 0 else { throw ServiceSpawnError.workingDirectoryUnavailable(status) }
        }

        var arguments = try duplicateCStrings([specification.executablePath] + specification.arguments)
        defer { freeCStrings(arguments) }
        var environment = try duplicateCStrings(
            specification.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        )
        defer { freeCStrings(environment) }

        var pid: pid_t = 0
        status = posix_spawn(&pid, specification.executablePath, &fileActions, &attributes, &arguments, &environment)
        guard status == 0 else { throw ServiceSpawnError.spawnFailed(status) }
        guard pid > 1 else { throw ServiceSpawnError.spawnFailed(ECHILD) }
        return pid
    }

    /// NULL-terminated C string array. A failed allocation throws instead of
    /// silently truncating argv, and every element is released by the caller.
    private func duplicateCStrings(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = []
        result.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let duplicated = strdup(string) else {
                freeCStrings(result)
                throw ServiceSpawnError.spawnFailed(ENOMEM)
            }
            result.append(duplicated)
        }
        result.append(nil)
        return result
    }

    private func freeCStrings(_ strings: [UnsafeMutablePointer<CChar>?]) {
        for pointer in strings { free(pointer) }
    }
}

/// A descriptor passed to `posix_spawn` that is guaranteed to be above
/// stderr.
///
/// When the app's standard descriptors are closed, `open` can hand out fd 0, 1
/// or 2. Using such a descriptor as a `dup2` source and then closing it with a
/// file action would clobber the redirection targets instead of the temporary
/// descriptor, so it is first copied above stderr with `F_DUPFD_CLOEXEC`.
struct SpawnFileDescriptor {
    let descriptor: Int32
    /// True when `descriptor` is a copy that has to be closed by this caller.
    let isDuplicate: Bool

    /// Returns `descriptor` unchanged when it is above stderr, otherwise a
    /// `F_DUPFD_CLOEXEC` copy starting at fd 3; nil when neither is possible.
    static func aboveStandardError(_ descriptor: Int32) -> SpawnFileDescriptor? {
        guard descriptor >= 0 else { return nil }
        guard descriptor <= STDERR_FILENO else {
            return SpawnFileDescriptor(descriptor: descriptor, isDuplicate: false)
        }
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard duplicate > STDERR_FILENO else {
            if duplicate >= 0 { close(duplicate) }
            return nil
        }
        return SpawnFileDescriptor(descriptor: duplicate, isDuplicate: true)
    }

    /// Closes the copy and leaves a pass-through descriptor untouched.
    func closeIfDuplicate() {
        if isDuplicate { close(descriptor) }
    }
}

/// Failure modes of the `posix_spawn` path. They surface in the existing
/// startup alert; nothing is signalled when a launch fails.
enum ServiceSpawnError: LocalizedError, Equatable {
    case fileActionsUnavailable(Int32)
    case attributesUnavailable(Int32)
    case standardDescriptorsUnavailable(Int32)
    case workingDirectoryUnavailable(Int32)
    case spawnFailed(Int32)

    var errorDescription: String? {
        let reason: String
        let code: Int32
        switch self {
        case .fileActionsUnavailable(let value):
            reason = "无法准备文件重定向"
            code = value
        case .attributesUnavailable(let value):
            reason = "无法设置进程组"
            code = value
        case .standardDescriptorsUnavailable(let value):
            reason = "无法重定向标准输入输出"
            code = value
        case .workingDirectoryUnavailable(let value):
            reason = "无法设置工作目录"
            code = value
        case .spawnFailed(let value):
            reason = "启动进程失败"
            code = value
        }
        return "\(reason)（errno \(code)：\(String(cString: strerror(code)))）"
    }
}

/// Handle for a `posix_spawn`ed child.
///
/// `isRunning` reaps an exited child so a zombie is never reported as running,
/// while the launcher's blocking waiter still calls the termination callback
/// exactly once (it observes `ECHILD` in that case).
final class POSIXServiceProcess: ServiceProcessHandle {
    private let pid: pid_t

    init(processIdentifier: pid_t) {
        pid = processIdentifier
    }

    var processIdentifier: pid_t { pid }

    var isRunning: Bool {
        var status: Int32 = 0
        switch waitpid(pid, &status, WNOHANG) {
        case pid: return false // exited and reaped here
        case 0: return true // still running
        default: return false // already reaped by the launcher's waiter
        }
    }
}

/// What `startManagedService()` should do for the current configuration and
/// process state. Pure with respect to the injected runner/probe.
enum ServiceStartDecision: Equatable {
    /// A stop is in flight; starting now would race with it.
    case ignored
    /// A managed process is already running, or a launch is in flight: keep
    /// polling/using it instead of starting a second service.
    case existingProcess
    /// No pi-web executable could be resolved.
    case missingExecutable
    /// 远程 hostname 已配置，但 Keychain 中没有可用的非空密码。
    case missingRemotePassword
    /// 监听地址不可用：通配地址、空值、前后空白或非法字符（GitHub #39 / R-3）。
    /// 关联值是包含非法值与允许范围的可读诊断。
    case invalidAddress(String)
    /// Launch this specification.
    case launch(ServiceLaunchSpecification)
}
