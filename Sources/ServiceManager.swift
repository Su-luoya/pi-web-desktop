import Foundation

/// Service lifecycle state, shown in the status menu and in diagnostics.
enum ServiceState: Equatable {
    case checking
    case starting
    case running
    case stopped
    case failed(String)

    /// Base text used by the status menu, matching the pre-split behaviour:
    /// `.running` is shown without an ownership suffix.
    var displayText: String {
        switch self {
        case .checking: return "正在检查"
        case .starting: return "正在启动"
        case .running: return "正在运行"
        case .stopped: return "已停止"
        case .failed(let message): return "失败：\(message)"
        }
    }

    /// Diagnostics copy only: a running service is labelled by ownership, as the
    /// pre-split `statusDescription()` did for "复制诊断信息". The status menu must
    /// use `displayText` instead.
    static func statusText(for state: ServiceState, managedPID: pid_t?) -> String {
        guard case .running = state else { return state.displayText }
        return managedPID == nil ? "正在运行（外部服务）" : "正在运行（本应用管理）"
    }
}

/// Scheduling and clock primitives used by `ServiceManager`.
///
/// Injected so the state machine can be exercised without timers, delays or
/// background threads: the production implementation below maps one-to-one onto
/// the timers and dispatch queues the app used before the split.
protocol ServiceScheduling: AnyObject {
    /// Runs work on the main queue.
    func onMain(_ work: @escaping () -> Void)
    /// Runs work off the main thread (blocking process waits).
    func onBackground(_ work: @escaping () -> Void)
    /// Runs work on the main queue after `delay` seconds.
    func after(_ delay: TimeInterval, _ work: @escaping () -> Void)
    /// Starts a repeating timer on the main run loop and returns its token.
    func repeating(interval: TimeInterval, _ work: @escaping () -> Void) -> RepeatingTimerToken
    /// Blocking sleep, only called from background work.
    func sleep(seconds: TimeInterval)
}

protocol RepeatingTimerToken: AnyObject {
    func invalidate()
}

final class DispatchServiceScheduler: ServiceScheduling {
    func onMain(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    func onBackground(_ work: @escaping () -> Void) {
        DispatchQueue.global().async(execute: work)
    }

    func after(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func repeating(interval: TimeInterval, _ work: @escaping () -> Void) -> RepeatingTimerToken {
        TimerRepeatingToken(timer: Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in work() })
    }

    func sleep(seconds: TimeInterval) {
        usleep(useconds_t(seconds * 1_000_000))
    }
}

private final class TimerRepeatingToken: RepeatingTimerToken {
    private let timer: Timer

    init(timer: Timer) {
        self.timer = timer
    }

    func invalidate() {
        timer.invalidate()
    }
}

/// Probes the service HTTP endpoint. Injected so tests never touch the network.
protocol ServiceProbing: AnyObject {
    func probe(url: URL, timeout: TimeInterval, completion: @escaping (Bool) -> Void)
}

final class URLSessionServiceProbe: ServiceProbing {
    func probe(url: URL, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = timeout
        sessionConfiguration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: sessionConfiguration)
        session.dataTask(with: request) { _, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion((200..<500).contains(status))
            session.finishTasksAndInvalidate()
        }.resume()
    }
}

/// Everything needed to launch the managed pi-web process. Built by a pure
/// factory so tests can assert the exact command line and environment.
struct ServiceLaunchSpecification: Equatable {
    var executablePath: String
    var arguments: [String]
    var workingDirectory: URL
    var environment: [String: String]

    static func make(
        configuration: ServiceConfiguration,
        piWebPath: String,
        appConfiguration: AppConfiguration,
        baseEnvironment: [String: String]
    ) -> ServiceLaunchSpecification {
        var environment = baseEnvironment
        environment["PI_WEB_NO_OPEN"] = "1"
        if !configuration.allowedHosts.isEmpty {
            environment["PI_WEB_ALLOWED_HOSTS"] = configuration.allowedHosts
        } else {
            environment.removeValue(forKey: "PI_WEB_ALLOWED_HOSTS")
        }
        environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
            workingDirectory: appConfiguration.serviceWorkingDirectory,
            environment: environment
        )
    }

    /// Canonical argument list for a configuration. The launcher and the
    /// ownership record share it, so `argumentsDigest` always describes what
    /// the app would actually launch.
    static func arguments(configuration: ServiceConfiguration) -> [String] {
        ["--hostname", configuration.hostname, "--port", String(configuration.port), "--no-open"]
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
/// stdin is `/dev/null`; stdout and stderr are the rotated log file; the child
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
    /// Launch this specification.
    case launch(ServiceLaunchSpecification)
}

/// Owns the service lifecycle: start, stop, restart, health polling, retries,
/// log redirection, verified ownership bookkeeping and quit behaviour.
///
/// Ownership is defined by the on-disk `ServiceOwnershipRecord` written after a
/// launch. A service is only ever stopped when that record still verifies
/// against this app instance and the live process; an external service (or a
/// record that fails any check) is read-only for this app and never receives a
/// signal.
///
/// All UI presentation is delegated through the callbacks below; AppDelegate
/// only coordinates and shows state. Every side effect (commands, process
/// launch, HTTP probe, timers, sleep, signals) goes through an injected
/// dependency so the state machine and the ownership checks are unit-testable.
final class ServiceManager {
    // MARK: - UI callbacks (AppDelegate owns presentation)

    var onStateChange: ((ServiceState) -> Void)?
    var onLoadPage: (() -> Void)?
    var onPageMessage: ((String) -> Void)?
    var onStartupFailure: ((String) -> Void)?

    // MARK: - Timing (unchanged from the pre-split implementation)

    static let maxStartupAttempts = 150
    static let startupPollInterval: TimeInterval = 0.2
    static let healthCheckInterval: TimeInterval = 4
    static let probeTimeout: TimeInterval = 1
    static let stopPollAttempts = 40
    static let stopPollInterval: TimeInterval = 0.1
    static let maxLogBytes = 10 * 1024 * 1024

    private(set) var configuration: ServiceConfiguration
    private(set) var currentState: ServiceState = .checking

    /// 依赖诊断门控（GitHub #6）。
    ///
    /// 为 false 时任何启动入口（启动/重启、配置变更重载、启动重试、健康恢复）
    /// 都不得启动子进程、加载服务页或把状态改成 running；异步回调执行前会再次
    /// 确认这个门控。默认关闭：`AppDelegate` 在依赖诊断完成前保持关闭，
    /// `DependencyReport.canStartService` 为 true 时打开、为 false 时重新关闭。
    var isDependencyGateOpen = false

    /// True once a quit sequence started. AppDelegate drives this through
    /// `beginQuitting()` / `keepRunningOnQuit()` / `stopAllServices(completion:)`.
    private(set) var isQuitting = false

    /// Identifier of this app instance. It is part of every ownership record,
    /// so a record written by an earlier launch can never be adopted again.
    let instanceID: String

    private let appConfiguration: AppConfiguration
    private let processInspector: ProcessInspector
    private let commandRunner: CommandRunning
    private let launcher: ServiceLaunching
    private let probe: ServiceProbing
    private let scheduler: ServiceScheduling
    private let environment: () -> [String: String]
    private let fileManager: FileManager
    private let ownershipStore: ServiceOwnershipStoring
    private let signaler: ServiceSignaling

    private var serviceProcess: ServiceProcessHandle?
    private var launchGeneration = 0
    private var logHandle: FileHandle?
    private var healthToken: RepeatingTimerToken?
    private var startupAttempts = 0
    private var didLaunchService = false
    private var restartAttempts = 0
    private var isStoppingService = false

    init(
        configuration: ServiceConfiguration,
        appConfiguration: AppConfiguration,
        processInspector: ProcessInspector,
        commandRunner: CommandRunning = SystemCommandRunner(),
        launcher: ServiceLaunching = SystemServiceLauncher(),
        probe: ServiceProbing = URLSessionServiceProbe(),
        scheduler: ServiceScheduling = DispatchServiceScheduler(),
        environment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
        fileManager: FileManager = .default,
        ownershipStore: ServiceOwnershipStoring = FileServiceOwnershipStore(),
        signaler: ServiceSignaling = POSIXServiceSignaler(),
        instanceID: String = UUID().uuidString
    ) {
        self.configuration = configuration
        self.appConfiguration = appConfiguration
        self.processInspector = processInspector
        self.commandRunner = commandRunner
        self.launcher = launcher
        self.probe = probe
        self.scheduler = scheduler
        self.environment = environment
        self.fileManager = fileManager
        self.ownershipStore = ownershipStore
        self.signaler = signaler
        self.instanceID = instanceID
    }

    // MARK: - Configuration

    func updateConfiguration(_ configuration: ServiceConfiguration) {
        self.configuration = configuration
    }

    func setState(_ state: ServiceState) {
        currentState = state
        onStateChange?(state)
    }

    /// 允许启动服务与加载服务页的前置条件：依赖门控打开，且不在停止/退出流程中。
    private var isStartPermitted: Bool {
        isDependencyGateOpen && !isStoppingService && !isQuitting
    }

    // MARK: - Ownership and dependency lookup

    /// PID of a service this app instance launched and can still verify.
    ///
    /// External services and unverifiable records return nil. No signal path
    /// may run in that case. The record itself is the only authority: a child
    /// handle without a record is unhosted as well.
    func managedServicePID() -> pid_t? {
        verifiedOwnershipRecord()?.pid
    }

    /// Expectation a stored record must satisfy for the current configuration.
    func ownershipExpectation() -> ServiceOwnershipExpectation {
        ServiceOwnershipExpectation(
            port: configuration.port,
            instanceID: instanceID
        )
    }

    /// The stored ownership record, but only when it verifies against this app
    /// instance and the live process.
    ///
    /// Mismatched records are removed without sending any signal, and the
    /// process they point at counts as external. A record that cannot be
    /// checked right now (for example because `ps` failed) is kept for a later
    /// check, but the answer is still "not managed", so no signal is sent.
    func verifiedOwnershipRecord() -> ServiceOwnershipRecord? {
        guard let record = ownershipStore.loadRecord(from: appConfiguration.serviceOwnerURL) else { return nil }
        let verdict = ServiceOwnershipVerifier.verify(
            record: record,
            expectation: ownershipExpectation(),
            processIsAlive: { self.processInspector.isProcessAlive($0) },
            facts: { self.processInspector.processFacts(of: $0) }
        )
        if verdict.shouldRemoveRecord {
            ownershipStore.removeRecord(at: appConfiguration.serviceOwnerURL)
        }
        guard case .managed = verdict else { return nil }
        return record
    }

    /// Startup reconciliation for records left behind by an earlier run.
    ///
    /// The legacy single-PID file is removed immediately: a PID alone is not
    /// ownership. A `service-owner.json` from an earlier app instance also
    /// fails verification (the instance identifier differs), so it is dropped
    /// and the still-running service is treated as external. Nothing is
    /// signalled in either case.
    func reconcileOwnershipRecord() {
        try? fileManager.removeItem(at: appConfiguration.legacyServicePIDURL)
        _ = verifiedOwnershipRecord()
    }

    func resolvePiWebPath() -> String? {
        if let configured = configuration.piWebPath.nilIfEmpty {
            return fileManager.isExecutableFile(atPath: configured) ? configured : nil
        }
        let candidates = [
            "/opt/homebrew/bin/pi-web",
            "/usr/local/bin/pi-web",
            "\(fileManager.homeDirectoryForCurrentUser.path)/.npm-global/bin/pi-web"
        ]
        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return path
        }
        return commandRunner.run(["/bin/zsh", "-lc", "command -v pi-web 2>/dev/null"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    func startDecision() -> ServiceStartDecision {
        guard !isStoppingService else { return .ignored }
        if managedServicePID() != nil { return .existingProcess }
        // A launch that has not produced a record yet is still in flight (or is
        // an unrecorded child that survived cleanup). Starting another one
        // would leave two services competing for the same port.
        if let process = serviceProcess, process.isRunning { return .existingProcess }
        guard let piWebPath = configuration.piWebPath.nilIfEmpty ?? resolvePiWebPath() else {
            return .missingExecutable
        }
        return .launch(ServiceLaunchSpecification.make(
            configuration: configuration,
            piWebPath: piWebPath,
            appConfiguration: appConfiguration,
            baseEnvironment: environment()
        ))
    }

    // MARK: - Startup

    /// Initial startup path used by `applicationDidFinishLaunching`.
    func startAtLaunch() {
        // Records from earlier runs are evaluated (and cleaned) before any new
        // launch decision, so a leftover file can never be adopted.
        reconcileOwnershipRecord()
        guard isStartPermitted else { return }
        if configuration.autoStart {
            ensureServerIsRunning()
        } else {
            checkServer { [weak self] ready in
                guard let self else { return }
                self.scheduler.onMain {
                    // 与 autoStart 分支一致：探测期间门控关闭就不能再改状态或加载页面。
                    guard self.isStartPermitted else { return }
                    if ready {
                        self.setState(.running)
                        self.requestLoad()
                    } else {
                        self.setState(.stopped)
                        self.onPageMessage?("Pi Web 服务未运行。")
                    }
                }
            }
        }
        startHealthMonitor()
    }

    func ensureServerIsRunning() {
        guard isStartPermitted else { return }
        checkServer { [weak self] ready in
            guard let self else { return }
            self.scheduler.onMain {
                // 门控可能在探测期间被关掉（例如重新检测），回调必须再确认。
                guard self.isStartPermitted else { return }
                if ready {
                    self.setState(.running)
                    self.requestLoad()
                } else {
                    self.startManagedService()
                }
            }
        }
    }

    /// Menu action "启动服务": connect to a ready service, otherwise start the
    /// managed one. The dependency gate is enforced again inside the async
    /// callback and in `startManagedService()`.
    func startService() {
        guard isStartPermitted else { return }
        checkServer { [weak self] ready in
            guard let self else { return }
            self.scheduler.onMain {
                guard self.isStartPermitted else { return }
                if ready {
                    self.setState(.running)
                    self.requestLoad()
                } else {
                    self.startManagedService()
                }
            }
        }
    }

    /// 唯一的受托管启动入口：启动、重启、配置变更、重试和健康恢复都收敛到这里，
    /// 依赖门控关闭时直接返回，不产生任何进程或页面副作用。
    func startManagedService() {
        guard isStartPermitted else { return }
        switch startDecision() {
        case .ignored:
            return
        case .existingProcess:
            pollUntilReady()
            return
        case .missingExecutable:
            reportStartupFailure("找不到 pi-web。请确认已执行 npm install -g @agegr/pi-web@latest。")
            return
        case .launch(let specification):
            do {
                let handle = try openLogForWriting()
                // Token for this launch: a late termination callback from an
                // earlier process must not clear the replacement or close its log.
                launchGeneration &+= 1
                let generation = launchGeneration
                let process = try launcher.launch(specification, logHandle: handle) { [weak self] in
                    guard let self else { return }
                    self.scheduler.onMain {
                        guard self.launchGeneration == generation else { return }
                        self.serviceProcess = nil
                        self.closeLog()
                        if !self.isStoppingService && !self.isQuitting {
                            self.setState(.stopped)
                        }
                    }
                }
                serviceProcess = process
                startupAttempts = 0
                // A process without a verifiable ownership record can never be
                // managed: kill the fresh group and report the startup failure
                // instead of leaving an unmanageable service behind.
                let recorded = writeOwnershipRecord(for: specification, process: process)
                guard recorded, verifiedOwnershipRecord() != nil else {
                    abandonUnhostedLaunch(process: process)
                    return
                }
                didLaunchService = true
                setState(.starting)
                onPageMessage?("正在启动 Pi Web…")
                pollUntilReady()
            } catch {
                reportStartupFailure("无法启动 pi-web：\(error.localizedDescription)")
            }
        }
    }

    /// Records the process this launch created.
    ///
    /// A PID that is not a process group leader, unreadable `ps` facts, or a
    /// failed write all mean "unhosted": the caller terminates the fresh
    /// process group, because an unverifiable service must never survive as a
    /// half-managed child. The digest is over the normalized command text:
    /// the live `ps -o args=` text when it is readable, otherwise the canonical
    /// `executablePath + arguments` text (which a later verification then
    /// rejects, since an empty live command line is a mismatch).
    private func writeOwnershipRecord(for specification: ServiceLaunchSpecification, process: ServiceProcessHandle) -> Bool {
        guard process.processIdentifier > 1,
              let facts = processInspector.processFacts(of: process.processIdentifier),
              facts.processGroupID == process.processIdentifier else { return false }
        let commandText = facts.commandLine.isEmpty
            ? ServiceOwnershipRecord.commandText(
                executablePath: specification.executablePath,
                arguments: specification.arguments
            )
            : facts.commandLine
        let record = ServiceOwnershipRecord(
            pid: process.processIdentifier,
            processGroupID: facts.processGroupID,
            launchedAt: facts.launchedAt,
            resolvedExecutable: facts.resolvedExecutable,
            resolvedExecutableSource: facts.resolvedExecutableSource,
            argumentsDigest: ServiceOwnershipRecord.commandDigest(ofCommandText: commandText),
            port: configuration.port,
            instanceID: instanceID,
            recordedAt: ISO8601DateFormatter().string(from: Date())
        )
        do {
            try ownershipStore.save(record, to: appConfiguration.serviceOwnerURL)
            return true
        } catch {
            return false
        }
    }

    /// Terminates a launch whose ownership record was not written or did not
    /// verify immediately after the launch.
    ///
    /// This path owns the cleanup of that launch (`launchGeneration` is bumped
    /// so its termination callback is ignored), signals only the fresh process
    /// group and reports a startup failure. A child that survives the kill is
    /// kept as the current handle, so `startDecision()` still sees a live child
    /// and refuses to launch a second service.
    private func abandonUnhostedLaunch(process: ServiceProcessHandle) {
        launchGeneration &+= 1
        didLaunchService = false
        isStoppingService = true
        let processGroupID = process.processIdentifier
        scheduler.onBackground { [weak self] in
            guard let self else { return }
            self.terminate(processGroupID: processGroupID)
            self.scheduler.onMain {
                // The launch is gone and its record (if one was written before
                // the immediate verification failed) must not linger.
                self.ownershipStore.removeRecord(at: self.appConfiguration.serviceOwnerURL)
                self.closeLog()
                if self.serviceProcess === process, !process.isRunning {
                    self.serviceProcess = nil
                }
                self.isStoppingService = false
                self.reportStartupFailure(
                    "无法登记 pi-web 的所有权信息，已终止本次启动的进程。请查看日志：\(self.appConfiguration.logURL.path)"
                )
            }
        }
    }

    private func pollUntilReady() {
        startupAttempts += 1
        guard startupAttempts <= Self.maxStartupAttempts else {
            reportStartupFailure("Pi Web 在 30 秒内未能启动。请查看日志：\(appConfiguration.logURL.path)")
            return
        }
        scheduler.after(Self.startupPollInterval) { [weak self] in
            guard let self else { return }
            self.checkServer { ready in
                self.scheduler.onMain {
                    // 启动轮询是异步的：门控在轮询期间关闭时不再改状态或加载页面。
                    guard self.isStartPermitted else { return }
                    if ready {
                        self.restartAttempts = 0
                        self.setState(.running)
                        self.requestLoad()
                    } else if let process = self.serviceProcess, !process.isRunning {
                        self.reportStartupFailure("pi-web 进程已退出。请查看日志：\(self.appConfiguration.logURL.path)")
                    } else {
                        self.pollUntilReady()
                    }
                }
            }
        }
    }

    // MARK: - Stopping

    /// Stops the managed service.
    ///
    /// The verified process group gets SIGTERM, a bounded wait, then SIGKILL.
    /// Nothing is signalled unless the ownership record verifies against the
    /// live process: external services are read-only for this app, so a stop
    /// request for them completes without a signal and without changing the
    /// reported state.
    func stopService(completion: (() -> Void)? = nil) {
        // Verification happens before the stopping flag is set: an external
        // service must leave the state machine exactly as it was.
        guard let record = verifiedOwnershipRecord() else {
            completion?()
            return
        }
        isStoppingService = true
        scheduler.onBackground { [weak self] in
            guard let self else { return }
            self.terminate(processGroupID: record.processGroupID)
            self.scheduler.onMain {
                self.ownershipStore.removeRecord(at: self.appConfiguration.serviceOwnerURL)
                self.finishStopping(completion: completion)
            }
        }
    }

    /// SIGTERM to a process group, bounded wait, then SIGKILL to the same
    /// group. The wait is bounded by `stopPollAttempts`, so at most two signals
    /// are ever sent, both to the group. PIDs and groups 0 and 1 are refused.
    private func terminate(processGroupID: pid_t) {
        guard processGroupID > 1 else { return }
        signaler.sendGroupSignal(SIGTERM, toProcessGroup: processGroupID)
        for _ in 0..<Self.stopPollAttempts {
            guard signaler.isProcessGroupAlive(processGroupID) else { return }
            scheduler.sleep(seconds: Self.stopPollInterval)
        }
        if signaler.isProcessGroupAlive(processGroupID) {
            signaler.sendGroupSignal(SIGKILL, toProcessGroup: processGroupID)
        }
    }

    /// Shared end of a stop: clear the child state, reset the flag and report
    /// the stopped state. The ownership record is removed by the caller only
    /// after it was verified.
    private func finishStopping(completion: (() -> Void)?) {
        serviceProcess = nil
        didLaunchService = false
        isStoppingService = false
        setState(.stopped)
        completion?()
    }

    func restartManagedService() {
        stopService { [weak self] in self?.startManagedService() }
    }

    /// Stops the verified managed service and then calls `completion` on the
    /// main queue. AppDelegate terminates afterwards.
    ///
    /// An external listener is never touched on quit: the app cannot prove it
    /// started it, so it keeps running.
    func stopAllServices(completion: @escaping () -> Void) {
        beginQuitting()
        isStoppingService = true
        if managedServicePID() != nil {
            stopService(completion: completion)
        } else {
            isStoppingService = false
            completion()
        }
    }

    // MARK: - Quit behaviour

    /// Starts a quit sequence: no further health restarts, no state flicker from
    /// a terminating child process.
    func beginQuitting() {
        isQuitting = true
        stopHealthMonitor()
    }

    /// "退出但保持服务运行": keep the child alive and keep its ownership
    /// record. The next app instance will fail the instance check, clean the
    /// record and treat the service as external.
    func keepRunningOnQuit() {
        beginQuitting()
        isStoppingService = false
        closeLog()
    }

    // MARK: - Health monitoring

    func startHealthMonitor() {
        healthToken?.invalidate()
        healthToken = nil
        // 门控关闭时不轮询：既不采纳外部服务，也不会触发受托管重启。
        guard isStartPermitted else { return }
        healthToken = scheduler.repeating(interval: Self.healthCheckInterval) { [weak self] in
            guard let self, self.isStartPermitted else { return }
            self.checkServer { ready in
                self.scheduler.onMain {
                    // 门控 blocked 时不得改变状态或加载服务页，覆盖诊断页。
                    guard self.isStartPermitted else { return }
                    if ready {
                        if case .running = self.currentState {
                            self.restartAttempts = 0
                        } else {
                            self.setState(.running)
                            self.restartAttempts = 0
                            self.requestLoad()
                        }
                    } else if case .running = self.currentState {
                        self.setState(.stopped)
                        self.onPageMessage?("Pi Web 服务已断开，正在尝试恢复…")
                        if self.didLaunchService && self.restartAttempts < 1 {
                            self.restartAttempts += 1
                            self.startManagedService()
                        }
                    }
                }
            }
        }
    }

    func stopHealthMonitor() {
        healthToken?.invalidate()
        healthToken = nil
    }

    func checkServer(completion: @escaping (Bool) -> Void) {
        probe.probe(url: configuration.serviceURL, timeout: Self.probeTimeout, completion: completion)
    }

    /// Re-checks the (possibly changed) configuration after preferences were
    /// saved. Gated like every other start entry: while the dependency gate is
    /// closed only the state message is updated, never a launch or page load.
    func reloadAfterConfigurationChange() {
        guard isStartPermitted else { return }
        checkServer { [weak self] ready in
            guard let self else { return }
            self.scheduler.onMain {
                guard self.isStartPermitted else { return }
                if ready {
                    self.setState(.running)
                    self.requestLoad()
                } else if self.configuration.autoStart {
                    self.startManagedService()
                } else {
                    self.setState(.stopped)
                    self.onPageMessage?("设置已保存，服务尚未启动。")
                }
            }
        }
    }

    // MARK: - Logs

    /// Opens the log file for the child process, rotating it first when needed.
    private func openLogForWriting() throws -> FileHandle {
        let logURL = appConfiguration.logURL
        try fileManager.createDirectory(at: appConfiguration.serviceWorkingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        rotateLogsIfNeeded()
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        logHandle = handle
        return handle
    }

    func closeLog() {
        try? logHandle?.close()
        logHandle = nil
    }

    private func rotateLogsIfNeeded() {
        let logURL = appConfiguration.logURL
        guard let attributes = try? fileManager.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= Self.maxLogBytes else { return }

        let directory = logURL.deletingLastPathComponent()
        let base = logURL.deletingPathExtension().lastPathComponent
        let rotated = directory.appendingPathComponent("\(base).1.log")
        let previous = directory.appendingPathComponent("\(base).2.log")
        try? fileManager.removeItem(at: previous)
        try? fileManager.moveItem(at: rotated, to: previous)
        try? fileManager.moveItem(at: logURL, to: rotated)
        fileManager.createFile(atPath: logURL.path, contents: nil)
    }

    // MARK: - Presentation helpers

    private func reportStartupFailure(_ message: String) {
        setState(.failed(message))
        onPageMessage?("启动失败")
        onStartupFailure?(message)
    }

    private func requestLoad() {
        onLoadPage?()
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
