import Foundation
import XCTest

// MARK: - Fakes

private final class ManagerFakeRunner: CommandRunning {
    var handler: ([String]) -> String? = { _ in nil }
    private(set) var invocations: [[String]] = []

    func run(_ arguments: [String]) -> String? {
        invocations.append(arguments)
        return handler(arguments)
    }
}

private final class ManagerFakeProcess: ServiceProcessHandle {
    var processIdentifier: pid_t
    var isRunning: Bool

    init(processIdentifier: pid_t, isRunning: Bool = true) {
        self.processIdentifier = processIdentifier
        self.isRunning = isRunning
    }
}

private enum ManagerFakeLaunchError: LocalizedError {
    case failed

    var errorDescription: String? { "fake launch failure" }
}

private final class ManagerFakeLauncher: ServiceLaunching {
    var result: Result<ServiceProcessHandle, Error> = .failure(ManagerFakeLaunchError.failed)
    private(set) var specifications: [ServiceLaunchSpecification] = []
    private(set) var logHandles: [FileHandle] = []
    private(set) var terminationHandlers: [(ServiceProcessHandle) -> Void] = []
    private(set) var launchCount = 0

    func launch(
        _ specification: ServiceLaunchSpecification,
        logHandle: FileHandle,
        onTermination: @escaping () -> Void
    ) throws -> ServiceProcessHandle {
        launchCount += 1
        specifications.append(specification)
        logHandles.append(logHandle)
        let handle = try result.get()
        terminationHandlers.append { _ in onTermination() }
        return handle
    }
}

private final class ManagerFakeScheduler: ServiceScheduling {
    /// When true (the default) `onMain` runs inline, which keeps the tests
    /// deterministic without touching the main queue.
    var runsMainInline = true
    private(set) var mainWork: [() -> Void] = []
    private(set) var backgroundWork: [() -> Void] = []
    private(set) var delayedWork: [(delay: TimeInterval, work: () -> Void)] = []
    private(set) var repeatingWork: [(interval: TimeInterval, work: () -> Void)] = []
    private(set) var repeatTokens: [ManagerFakeTimerToken] = []
    private(set) var sleeps: [TimeInterval] = []
    private var backgroundIndex = 0
    private var delayedIndex = 0

    func onMain(_ work: @escaping () -> Void) {
        if runsMainInline { work() } else { mainWork.append(work) }
    }

    func onBackground(_ work: @escaping () -> Void) {
        backgroundWork.append(work)
    }

    func after(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        delayedWork.append((delay, work))
    }

    func repeating(interval: TimeInterval, _ work: @escaping () -> Void) -> RepeatingTimerToken {
        repeatingWork.append((interval, work))
        let token = ManagerFakeTimerToken()
        repeatTokens.append(token)
        return token
    }

    func sleep(seconds: TimeInterval) {
        sleeps.append(seconds)
    }

    @discardableResult
    func runNextBackgroundWork() -> Bool {
        guard backgroundIndex < backgroundWork.count else { return false }
        let work = backgroundWork[backgroundIndex]
        backgroundIndex += 1
        work()
        return true
    }

    func runAllBackgroundWork() {
        while runNextBackgroundWork() {}
    }

    @discardableResult
    func runNextDelayedWork() -> Bool {
        guard delayedIndex < delayedWork.count else { return false }
        let work = delayedWork[delayedIndex].work
        delayedIndex += 1
        work()
        return true
    }

    @discardableResult
    func runHealthCheck() -> Bool {
        guard let token = repeatingWork.last else { return false }
        token.work()
        return true
    }
}

private final class ManagerFakeTimerToken: RepeatingTimerToken {
    private(set) var invalidateCount = 0
    func invalidate() { invalidateCount += 1 }
}

private final class ManagerFakeProbe: ServiceProbing {
    var ready = true
    private(set) var probedURLs: [URL] = []
    private(set) var timeouts: [TimeInterval] = []

    func probe(url: URL, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        probedURLs.append(url)
        timeouts.append(timeout)
        completion(ready)
    }
}

/// Deterministic stand-in for `FileManager` executable/existence lookups, so
/// the "no pi-web executable" branch does not depend on the test machine.
private final class ManagerFakeFileManager: FileManager {
    var executablePaths: Set<String> = []
    var existingPaths: Set<String> = []

    override func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }

    override func fileExists(atPath path: String) -> Bool {
        existingPaths.contains(path)
    }
}

// MARK: - Harness

private final class ServiceManagerHarness {
    let root: URL
    let appConfiguration: AppConfiguration
    let runner: ManagerFakeRunner
    let launcher: ManagerFakeLauncher
    let probe: ManagerFakeProbe
    let scheduler: ManagerFakeScheduler
    let manager: ServiceManager

    private(set) var states: [ServiceState] = []
    private(set) var pageMessages: [String] = []
    private(set) var startupFailures: [String] = []
    private(set) var loadRequests = 0

    init(
        configuration: ServiceConfiguration,
        alive: @escaping (pid_t) -> Bool,
        processOutput: @escaping ([String]) -> String?,
        fileManager: FileManager,
        baseEnvironment: [String: String]
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiWebDesktopTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        let logsRootURL = root.appendingPathComponent("logs", isDirectory: true)
        let defaults = UserDefaults(suiteName: "ServiceManagerTests.\(UUID().uuidString)") ?? .standard
        appConfiguration = AppConfiguration(supportURL: supportURL, logsRootURL: logsRootURL, defaults: defaults)

        runner = ManagerFakeRunner()
        runner.handler = processOutput
        launcher = ManagerFakeLauncher()
        probe = ManagerFakeProbe()
        scheduler = ManagerFakeScheduler()

        let inspector = ProcessInspector(runner: runner, fileManager: fileManager, processIsAlive: alive)
        manager = ServiceManager(
            configuration: configuration,
            appConfiguration: appConfiguration,
            processInspector: inspector,
            commandRunner: runner,
            launcher: launcher,
            probe: probe,
            scheduler: scheduler,
            environment: { baseEnvironment },
            fileManager: fileManager
        )

        manager.onStateChange = { [weak self] state in self?.states.append(state) }
        manager.onPageMessage = { [weak self] message in self?.pageMessages.append(message) }
        manager.onStartupFailure = { [weak self] message in self?.startupFailures.append(message) }
        manager.onLoadPage = { [weak self] in self?.loadRequests += 1 }
    }

    var pidFileURL: URL { appConfiguration.managedPIDURL }
    var logURL: URL { appConfiguration.logURL }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func writePIDRecord(_ pid: pid_t) throws {
        // The app always creates the support directory before writing its PID
        // files; mirror that so the harness can seed a record directly.
        try FileManager.default.createDirectory(at: pidFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(pid)\n".write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    func readPIDRecord() -> String? {
        try? String(contentsOf: pidFileURL, encoding: .utf8)
    }

    /// Creates a real executable file in the temporary root.
    @discardableResult
    func makeExecutable(named name: String = "pi-web") throws -> String {
        let url = root.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}

private let fakeBaseEnvironment = [
    "BASE": "1",
    "HTTP_PROXY": "http://stale.invalid:8080",
    "NO_PROXY": "stale.invalid"
]

private func makeHarness(
    configuration: ServiceConfiguration = .default,
    alive: @escaping (pid_t) -> Bool = { _ in false },
    processOutput: @escaping ([String]) -> String? = { _ in nil },
    fileManager: FileManager = .default
) throws -> ServiceManagerHarness {
    try ServiceManagerHarness(
        configuration: configuration,
        alive: alive,
        processOutput: processOutput,
        fileManager: fileManager,
        baseEnvironment: fakeBaseEnvironment
    )
}

private func configured(_ piWebPath: String) -> ServiceConfiguration {
    var configuration = ServiceConfiguration.default
    configuration.piWebPath = piWebPath
    return configuration
}

/// Simulates `ps -o command=|ppid= -p <pid>` output for one PID.
private func processOutput(for pid: pid_t, command: String) -> ([String]) -> String? {
    { arguments in
        guard let index = arguments.firstIndex(of: "-p"), index + 1 < arguments.count,
              arguments[index + 1] == "\(pid)" else { return nil }
        return arguments.contains("command=") ? "\(command)\n" : "1\n"
    }
}

// MARK: - Tests

final class ServiceManagerTests: XCTestCase {
    // MARK: Status text

    func testStatusTextLabelsOwnershipOnlyForRunningStates() {
        XCTAssertEqual(ServiceState.statusText(for: .checking, managedPID: nil), "正在检查")
        XCTAssertEqual(ServiceState.statusText(for: .starting, managedPID: 5150), "正在启动")
        XCTAssertEqual(ServiceState.statusText(for: .running, managedPID: 5150), "正在运行（本应用管理）")
        XCTAssertEqual(ServiceState.statusText(for: .running, managedPID: nil), "正在运行（外部服务）")
        XCTAssertEqual(ServiceState.statusText(for: .stopped, managedPID: 5150), "已停止")
        XCTAssertEqual(ServiceState.statusText(for: .failed("原因"), managedPID: nil), "失败：原因")
    }

    // MARK: Ownership

    func testStalePIDRecordIsDropped() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        try harness.writePIDRecord(4321)

        XCTAssertNil(harness.manager.managedServicePID())
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.pidFileURL.path))
    }

    func testForeignProcessRecordIsDropped() throws {
        let harness = try makeHarness(
            alive: { $0 == 4321 },
            processOutput: processOutput(for: 4321, command: "node /opt/homebrew/bin/other-server")
        )
        defer { harness.cleanUp() }
        try harness.writePIDRecord(4321)

        XCTAssertNil(harness.manager.managedServicePID())
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.pidFileURL.path))
    }

    func testMatchingProcessRecordIsReturned() throws {
        let harness = try makeHarness(
            alive: { $0 == 4321 },
            processOutput: processOutput(for: 4321, command: "node /opt/homebrew/bin/pi-web --hostname 127.0.0.1 --port 30141")
        )
        defer { harness.cleanUp() }
        try harness.writePIDRecord(4321)

        XCTAssertEqual(harness.manager.managedServicePID(), 4321)
        XCTAssertEqual(harness.readPIDRecord(), "4321\n")
    }

    func testRunningChildProcessWinsOverAPIDFileRecord() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.manager.startManagedService()

        // A stale record must not shadow the process the app is actually running.
        try harness.writePIDRecord(4242)
        XCTAssertEqual(harness.manager.managedServicePID(), 5150)
        XCTAssertEqual(harness.readPIDRecord(), "4242\n")
    }

    // MARK: Start decisions

    func testStartDecisionLaunchesTheConfiguredExecutable() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        let executable = try harness.makeExecutable()
        harness.manager.updateConfiguration(configured(executable))

        guard case .launch(let specification) = harness.manager.startDecision() else {
            return XCTFail("expected .launch, got \(harness.manager.startDecision())")
        }
        XCTAssertEqual(specification.executablePath, executable)
        XCTAssertEqual(specification.arguments, ["--hostname", "127.0.0.1", "--port", "30141", "--no-open"])
        XCTAssertEqual(specification.workingDirectory.standardizedFileURL, harness.appConfiguration.serviceWorkingDirectory.standardizedFileURL)

        let environment = specification.environment
        XCTAssertEqual(environment["PI_WEB_NO_OPEN"], "1")
        XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(environment["BASE"], "1")
        XCTAssertNil(environment["PI_WEB_ALLOWED_HOSTS"])
        // Empty proxy settings remove inherited values instead of forwarding them.
        XCTAssertNil(environment["HTTP_PROXY"])
        XCTAssertNil(environment["http_proxy"])
        XCTAssertNil(environment["HTTPS_PROXY"])
        XCTAssertNil(environment["https_proxy"])
        XCTAssertEqual(environment["NO_PROXY"], "localhost,127.0.0.1,::1")
        XCTAssertEqual(environment["no_proxy"], "localhost,127.0.0.1,::1")
    }

    func testStartDecisionAppliesProxyAndAllowedHosts() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        let executable = try harness.makeExecutable()
        var configuration = configured(executable)
        configuration.allowedHosts = "pi.example.invalid"
        configuration.httpProxy = "http://proxy.example.invalid:8443"
        configuration.httpsProxy = "https://proxy.example.invalid:8443"
        configuration.noProxy = ""
        harness.manager.updateConfiguration(configuration)

        guard case .launch(let specification) = harness.manager.startDecision() else {
            return XCTFail("expected .launch")
        }
        let environment = specification.environment
        XCTAssertEqual(environment["PI_WEB_ALLOWED_HOSTS"], "pi.example.invalid")
        XCTAssertEqual(environment["HTTP_PROXY"], "http://proxy.example.invalid:8443")
        XCTAssertEqual(environment["http_proxy"], "http://proxy.example.invalid:8443")
        XCTAssertEqual(environment["HTTPS_PROXY"], "https://proxy.example.invalid:8443")
        XCTAssertEqual(environment["https_proxy"], "https://proxy.example.invalid:8443")
        XCTAssertNil(environment["NO_PROXY"])
        XCTAssertNil(environment["no_proxy"])
    }

    func testStartDecisionReportsMissingExecutable() throws {
        let fakeFileManager = ManagerFakeFileManager()
        let harness = try makeHarness(fileManager: fakeFileManager)
        defer { harness.cleanUp() }

        XCTAssertEqual(harness.manager.startDecision(), .missingExecutable)
        XCTAssertNil(harness.manager.resolvePiWebPath())
    }

    func testResolvePiWebPathFallsBackToShellLookup() throws {
        let fakeFileManager = ManagerFakeFileManager()
        let harness = try makeHarness(
            processOutput: { arguments in arguments.first == "/bin/zsh" ? "/custom/bin/pi-web\n" : nil },
            fileManager: fakeFileManager
        )
        defer { harness.cleanUp() }

        XCTAssertEqual(harness.manager.resolvePiWebPath(), "/custom/bin/pi-web")
    }

    func testStartDecisionIsIgnoredWhileStopping() throws {
        let harness = try makeHarness(
            alive: { $0 == 4321 },
            processOutput: processOutput(for: 4321, command: "node /opt/homebrew/bin/pi-web")
        )
        defer { harness.cleanUp() }
        try harness.writePIDRecord(4321)

        harness.manager.stopService()
        XCTAssertEqual(harness.manager.startDecision(), .ignored)
    }

    func testStartDecisionReusesARunningManagedProcess() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        let process = ManagerFakeProcess(processIdentifier: 5150)
        harness.launcher.result = .success(process)
        harness.manager.startManagedService()

        XCTAssertEqual(harness.manager.startDecision(), .existingProcess)
    }

    // MARK: Starting

    func testStartManagedServiceLaunchesPollsAndWritesPIDFile() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        let executable = try harness.makeExecutable()
        harness.manager.updateConfiguration(configured(executable))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = false

        harness.manager.startManagedService()

        XCTAssertEqual(harness.launcher.launchCount, 1)
        XCTAssertEqual(harness.launcher.specifications.first?.executablePath, executable)
        XCTAssertEqual(harness.launcher.logHandles.count, 1)
        XCTAssertEqual(harness.readPIDRecord(), "5150\n")
        XCTAssertEqual(harness.manager.currentState, .starting)
        XCTAssertEqual(harness.pageMessages, ["正在启动 Pi Web…"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.logURL.path))
        XCTAssertEqual(harness.scheduler.delayedWork.count, 1)
        XCTAssertEqual(harness.scheduler.delayedWork.first?.delay, 0.2)
    }

    func testPollUntilReadyLoadsThePageOnceTheProbeSucceeds() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = false
        harness.manager.startManagedService()

        harness.probe.ready = true
        XCTAssertTrue(harness.scheduler.runNextDelayedWork())

        XCTAssertEqual(harness.manager.currentState, .running)
        XCTAssertEqual(harness.loadRequests, 1)
        XCTAssertEqual(harness.probe.probedURLs.last?.absoluteString, "http://127.0.0.1:30141/")
        XCTAssertEqual(harness.probe.timeouts.last, 1)
    }

    func testMissingExecutableReportsTheInstallHint() throws {
        let harness = try makeHarness(fileManager: ManagerFakeFileManager())
        defer { harness.cleanUp() }

        harness.manager.startManagedService()

        XCTAssertEqual(harness.startupFailures, ["找不到 pi-web。请确认已执行 npm install -g @agegr/pi-web@latest。"])
        XCTAssertEqual(harness.pageMessages, ["启动失败"])
        XCTAssertEqual(harness.manager.currentState, .failed("找不到 pi-web。请确认已执行 npm install -g @agegr/pi-web@latest。"))
        XCTAssertEqual(harness.launcher.launchCount, 0)
    }

    func testLaunchFailureIsReportedAsAStartupFailure() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .failure(ManagerFakeLaunchError.failed)

        harness.manager.startManagedService()

        XCTAssertEqual(harness.startupFailures.count, 1)
        XCTAssertEqual(harness.startupFailures.first?.hasPrefix("无法启动 pi-web："), true)
        XCTAssertEqual(harness.startupFailures.first?.contains("fake launch failure"), true)
        XCTAssertEqual(harness.pageMessages, ["启动失败"])
        if case .failed = harness.manager.currentState {} else {
            XCTFail("expected .failed, got \(harness.manager.currentState)")
        }
    }

    // MARK: Stopping

    func testStopServiceTerminatesTheChildAndRemovesThePIDFile() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.manager.startManagedService()

        var completionRan = false
        harness.manager.stopService { completionRan = true }
        harness.scheduler.runAllBackgroundWork()

        XCTAssertTrue(harness.runner.invocations.contains(["/bin/kill", "-TERM", "5150"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.pidFileURL.path))
        XCTAssertEqual(harness.manager.currentState, .stopped)
        XCTAssertTrue(completionRan)
        XCTAssertNil(harness.manager.managedServicePID())
    }

    func testStopServiceWithoutAManagedProcessJustResetsTheState() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }

        var completionRan = false
        harness.manager.stopService { completionRan = true }

        XCTAssertEqual(harness.manager.currentState, .stopped)
        XCTAssertTrue(completionRan)
        XCTAssertEqual(harness.scheduler.backgroundWork.count, 0)
        XCTAssertTrue(harness.runner.invocations.isEmpty)
    }

    func testStopExternalListenerIgnoresForeignProcesses() throws {
        let harness = try makeHarness(
            alive: { $0 == 4321 },
            processOutput: { arguments in
                if arguments.contains("-iTCP:30141") { return "4321\n" }
                if arguments.contains("command=") { return "node /usr/local/bin/other-server\n" }
                return nil
            }
        )
        defer { harness.cleanUp() }

        harness.manager.stopExternalListener()

        XCTAssertTrue(harness.runner.invocations.contains(["/usr/sbin/lsof", "-nP", "-t", "-iTCP:30141", "-sTCP:LISTEN"]))
        XCTAssertFalse(harness.runner.invocations.contains(["/bin/kill", "-TERM", "4321"]))
        XCTAssertEqual(harness.manager.currentState, .checking)
    }

    func testStopExternalListenerTerminatesAPiWebListener() throws {
        let harness = try makeHarness(
            alive: { $0 == 4321 },
            processOutput: { arguments in
                if arguments.contains("-iTCP:30141") { return "4321\n" }
                if arguments.contains("command=") { return "node /opt/homebrew/bin/pi-web\n" }
                return nil
            }
        )
        defer { harness.cleanUp() }

        harness.manager.stopExternalListener()

        XCTAssertTrue(harness.runner.invocations.contains(["/bin/kill", "-TERM", "4321"]))
        XCTAssertEqual(harness.manager.currentState, .stopped)
    }

    // MARK: Quit behaviour

    func testKeepRunningOnQuitKeepsTheServiceAndItsPIDFile() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.manager.startManagedService()
        harness.manager.startHealthMonitor()

        harness.manager.keepRunningOnQuit()

        XCTAssertTrue(harness.manager.isQuitting)
        XCTAssertEqual(harness.readPIDRecord(), "5150\n")
        XCTAssertTrue(harness.manager.managedServicePID() == 5150)
        XCTAssertEqual(harness.scheduler.repeatTokens.last?.invalidateCount, 1)
        XCTAssertTrue(harness.scheduler.backgroundWork.isEmpty)
    }

    func testStopAllServicesStopsTheChildAndInvokesTheCompletion() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.manager.startManagedService()

        var completionRan = false
        harness.manager.stopAllServices { completionRan = true }
        harness.scheduler.runAllBackgroundWork()

        XCTAssertTrue(completionRan)
        XCTAssertTrue(harness.manager.isQuitting)
        XCTAssertTrue(harness.runner.invocations.contains(["/bin/kill", "-TERM", "5150"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.pidFileURL.path))
    }

    // MARK: Health monitoring

    func testHealthMonitorRestartsAManagedServiceThatDisappeared() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = true
        harness.manager.startManagedService()
        XCTAssertTrue(harness.scheduler.runNextDelayedWork())
        harness.manager.startHealthMonitor()
        XCTAssertEqual(harness.manager.currentState, .running)
        XCTAssertEqual(harness.loadRequests, 1)

        let process = try XCTUnwrap(harness.launcher.result.get() as? ManagerFakeProcess)
        process.isRunning = false
        harness.probe.ready = false
        XCTAssertTrue(harness.scheduler.runHealthCheck())

        XCTAssertEqual(harness.states.suffix(2), [.stopped, .starting])
        XCTAssertTrue(harness.pageMessages.contains("Pi Web 服务已断开，正在尝试恢复…"))
        XCTAssertEqual(harness.launcher.launchCount, 2)
    }

    func testHealthMonitorKeepsAnExternalServiceUntouched() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.manager.startHealthMonitor()

        // Ready: the app adopts the external service and loads the page.
        harness.probe.ready = true
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.manager.currentState, .running)

        // Then it goes away: an unmanaged service is never restarted.
        harness.probe.ready = false
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.manager.currentState, .stopped)
        XCTAssertEqual(harness.launcher.launchCount, 0)
        XCTAssertEqual(harness.pageMessages, ["Pi Web 服务已断开，正在尝试恢复…"])
    }
}
