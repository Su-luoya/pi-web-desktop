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
            arguments: ["--hostname", configuration.hostname, "--port", String(configuration.port), "--no-open"],
            workingDirectory: appConfiguration.serviceWorkingDirectory,
            environment: environment
        )
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

/// The only place in the app that starts a real `Process`.
final class SystemServiceLauncher: ServiceLaunching {
    func launch(
        _ specification: ServiceLaunchSpecification,
        logHandle: FileHandle,
        onTermination: @escaping () -> Void
    ) throws -> ServiceProcessHandle {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: specification.executablePath)
        process.arguments = specification.arguments
        process.currentDirectoryURL = specification.workingDirectory
        process.environment = specification.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { _ in onTermination() }
        try process.run()
        return SystemServiceProcess(process: process)
    }
}

final class SystemServiceProcess: ServiceProcessHandle {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    var processIdentifier: pid_t { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
}

/// What `startManagedService()` should do for the current configuration and
/// process state. Pure with respect to the injected runner/probe.
enum ServiceStartDecision: Equatable {
    /// A stop is in flight; starting now would race with it.
    case ignored
    /// A managed process is already running; keep polling it instead.
    case existingProcess
    /// No pi-web executable could be resolved.
    case missingExecutable
    /// Launch this specification.
    case launch(ServiceLaunchSpecification)
}

/// Owns the service lifecycle: start, stop, restart, health polling, retries,
/// log redirection, managed PID bookkeeping and quit behaviour.
///
/// All UI presentation is delegated through the callbacks below; AppDelegate
/// only coordinates and shows state. Every side effect (commands, process
/// launch, HTTP probe, timers, sleep) goes through an injected dependency so the
/// state machine and the ownership checks are unit-testable.
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
    static let listenerStopAttempts = 30
    static let externalRestartDelay: TimeInterval = 1
    static let maxLogBytes = 10 * 1024 * 1024

    private(set) var configuration: ServiceConfiguration
    private(set) var currentState: ServiceState = .checking

    /// True once a quit sequence started. AppDelegate drives this through
    /// `beginQuitting()` / `keepRunningOnQuit()` / `stopAllServices(completion:)`.
    private(set) var isQuitting = false

    private let appConfiguration: AppConfiguration
    private let processInspector: ProcessInspector
    private let commandRunner: CommandRunning
    private let launcher: ServiceLaunching
    private let probe: ServiceProbing
    private let scheduler: ServiceScheduling
    private let environment: () -> [String: String]
    private let fileManager: FileManager

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
        fileManager: FileManager = .default
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
    }

    // MARK: - Configuration

    func updateConfiguration(_ configuration: ServiceConfiguration) {
        self.configuration = configuration
    }

    func setState(_ state: ServiceState) {
        currentState = state
        onStateChange?(state)
    }

    // MARK: - Ownership and dependency lookup

    /// PID of the app-managed pi-web instance: the running child process first,
    /// then a live PID-file record whose process still looks like pi-web.
    /// Stale or foreign records are removed by `ProcessInspector`.
    func managedServicePID() -> pid_t? {
        if let process = serviceProcess, process.isRunning { return process.processIdentifier }
        return processInspector.managedServicePID(pidFileURL: appConfiguration.managedPIDURL)
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
        if configuration.autoStart {
            ensureServerIsRunning()
        } else {
            checkServer { [weak self] ready in
                guard let self else { return }
                self.scheduler.onMain {
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
        checkServer { [weak self] ready in
            guard let self else { return }
            self.scheduler.onMain {
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
    /// managed one.
    func startService() {
        checkServer { [weak self] ready in
            guard let self else { return }
            self.scheduler.onMain {
                if ready {
                    self.setState(.running)
                    self.requestLoad()
                } else {
                    self.startManagedService()
                }
            }
        }
    }

    func startManagedService() {
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
                didLaunchService = true
                startupAttempts = 0
                try "\(process.processIdentifier)\n".write(to: appConfiguration.managedPIDURL, atomically: true, encoding: .utf8)
                setState(.starting)
                onPageMessage?("正在启动 Pi Web…")
                pollUntilReady()
            } catch {
                reportStartupFailure("无法启动 pi-web：\(error.localizedDescription)")
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

    func stopService(completion: (() -> Void)? = nil) {
        isStoppingService = true
        guard let pid = managedServicePID() else {
            isStoppingService = false
            setState(.stopped)
            completion?()
            return
        }
        scheduler.onBackground { [weak self] in
            guard let self else { return }
            _ = self.commandRunner.run(["/bin/kill", "-TERM", "\(pid)"])
            for _ in 0..<Self.stopPollAttempts {
                guard self.processInspector.isProcessAlive(pid) else { break }
                self.scheduler.sleep(seconds: Self.stopPollInterval)
            }
            if self.processInspector.isProcessAlive(pid) {
                _ = self.commandRunner.run(["/bin/kill", "-KILL", "\(pid)"])
            }
            self.scheduler.onMain {
                self.serviceProcess = nil
                self.didLaunchService = false
                self.isStoppingService = false
                try? self.fileManager.removeItem(at: self.appConfiguration.managedPIDURL)
                self.setState(.stopped)
                completion?()
            }
        }
    }

    func restartManagedService() {
        stopService { [weak self] in self?.startManagedService() }
    }

    func stopExternalListener() {
        guard let listener = processInspector.listenerPID(port: configuration.port),
              processInspector.isPiWebProcess(listener) else { return }
        let parent = processInspector.parentProcess(of: listener)
        let candidate = parent > 1 && processInspector.isPiWebProcess(parent) ? parent : listener
        _ = commandRunner.run(["/bin/kill", "-TERM", "\(candidate)"])
        setState(.stopped)
    }

    func stopExternalListenerAndStart() {
        stopExternalListener()
        scheduler.after(Self.externalRestartDelay) { [weak self] in self?.startManagedService() }
    }

    /// Stops the managed service and then any remaining pi-web listener, then
    /// calls `completion` on the main queue. AppDelegate terminates afterwards.
    func stopAllServices(completion: @escaping () -> Void) {
        beginQuitting()
        isStoppingService = true
        let finish = { [weak self] in
            guard let self else {
                completion()
                return
            }
            self.stopRemainingListener(completion: completion)
        }
        if managedServicePID() != nil {
            stopService(completion: finish)
        } else {
            finish()
        }
    }

    private func stopRemainingListener(completion: @escaping () -> Void) {
        guard let listener = processInspector.listenerPID(port: configuration.port),
              processInspector.isPiWebProcess(listener) else {
            isStoppingService = false
            completion()
            return
        }
        let parent = processInspector.parentProcess(of: listener)
        let candidate = parent > 1 && processInspector.isPiWebProcess(parent) ? parent : listener
        _ = commandRunner.run(["/bin/kill", "-TERM", "\(candidate)"])
        if candidate != listener { _ = commandRunner.run(["/bin/kill", "-TERM", "\(listener)"]) }
        waitForServerToStop(candidate: candidate, listener: listener, attempt: 0, completion: completion)
    }

    private func waitForServerToStop(candidate: pid_t, listener: pid_t, attempt: Int, completion: @escaping () -> Void) {
        checkServer { [weak self] ready in
            guard let self else {
                completion()
                return
            }
            self.scheduler.onMain {
                if !ready {
                    self.isStoppingService = false
                    completion()
                } else if attempt < Self.listenerStopAttempts {
                    self.scheduler.after(Self.stopPollInterval) {
                        self.waitForServerToStop(candidate: candidate, listener: listener, attempt: attempt + 1, completion: completion)
                    }
                } else {
                    // 明确选择“退出并停止”时，同时结束包装进程和实际监听进程。
                    _ = self.commandRunner.run(["/bin/kill", "-KILL", "\(candidate)"])
                    if candidate != listener { _ = self.commandRunner.run(["/bin/kill", "-KILL", "\(listener)"]) }
                    self.isStoppingService = false
                    completion()
                }
            }
        }
    }

    // MARK: - Quit behaviour

    /// Starts a quit sequence: no further health restarts, no state flicker from
    /// a terminating child process.
    func beginQuitting() {
        isQuitting = true
        stopHealthMonitor()
    }

    /// "退出但保持服务运行": keep the child alive, do not remove its PID file.
    func keepRunningOnQuit() {
        beginQuitting()
        isStoppingService = false
        closeLog()
    }

    // MARK: - Health monitoring

    func startHealthMonitor() {
        healthToken?.invalidate()
        healthToken = scheduler.repeating(interval: Self.healthCheckInterval) { [weak self] in
            guard let self, !self.isQuitting, !self.isStoppingService else { return }
            self.checkServer { ready in
                self.scheduler.onMain {
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
    /// saved.
    func reloadAfterConfigurationChange() {
        checkServer { [weak self] ready in
            guard let self else { return }
            self.scheduler.onMain {
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
