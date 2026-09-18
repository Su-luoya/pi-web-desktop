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

/// Records every signal the manager sends.
///
/// `ServiceSignaling` has no single-PID API, so "the app sent TERM/KILL to a
/// specific PID" cannot even be expressed in these tests.
private final class ManagerFakeSignaler: ServiceSignaling {
    struct GroupSignal: Equatable {
        let signal: Int32
        let processGroupID: pid_t
    }

    private(set) var groupSignals: [GroupSignal] = []
    /// Process groups the fake `kill(-pgid, 0)` probe reports as alive.
    var aliveProcessGroups: Set<pid_t> = []
    /// When true the group survives signals, which exercises the SIGKILL path.
    var groupSurvivesSignals = false

    func sendGroupSignal(_ signal: Int32, toProcessGroup processGroupID: pid_t) {
        groupSignals.append(GroupSignal(signal: signal, processGroupID: processGroupID))
        if !groupSurvivesSignals {
            aliveProcessGroups.remove(processGroupID)
        }
    }

    func isProcessGroupAlive(_ processGroupID: pid_t) -> Bool {
        aliveProcessGroups.contains(processGroupID)
    }
}

private struct ManagerOwnershipWriteError: Error {}

/// Mutable liveness flag so tests can "kill" a fake child mid-test.
private final class ManagerFakeLiveness {
    var isAlive = true
}

/// Simulates an ownership record that cannot be written to disk.
private final class ManagerFailingOwnershipStore: ServiceOwnershipStoring {
    func loadRecord(from url: URL) -> ServiceOwnershipRecord? { nil }
    func save(_ record: ServiceOwnershipRecord, to url: URL) throws { throw ManagerOwnershipWriteError() }
    func removeRecord(at url: URL) {}
}

// MARK: - Harness

private let fakeLaunchedAt = "Wed Jul 30 12:00:00 2025"
private let fakeExecutable = "/opt/homebrew/bin/pi-web"
/// What the launched pi-web reports through `ps -o args=`. The npm install is
/// a `#!/usr/bin/env node` script, so argv[0] is the interpreter.
private let fakeCommandLine = "node /opt/homebrew/bin/pi-web --hostname 127.0.0.1 --port 30141 --no-open"

/// Simulates `ps -o <format> -p <pid>` (and `lsof` for `listenerPort`) output
/// for one PID. `liveCommandLine` is a closure so a test can change the command
/// line the process reports after a launch.
private func processOutput(
    for pid: pid_t,
    command: String = fakeExecutable,
    launchedAt: String = fakeLaunchedAt,
    processGroupID: pid_t? = nil,
    liveCommandLine: @escaping () -> String = { fakeCommandLine },
    listenerPort: Int? = nil
) -> ([String]) -> String? {
    { arguments in
        if let listenerPort, arguments.contains("-iTCP:\(listenerPort)") { return "\(pid)\n" }
        guard let pidIndex = arguments.firstIndex(of: "-p"), pidIndex + 1 < arguments.count,
              arguments[pidIndex + 1] == "\(pid)",
              let formatIndex = arguments.firstIndex(of: "-o"), formatIndex + 1 < arguments.count else { return nil }
        switch arguments[formatIndex + 1] {
        case "command=": return "node \(command) --hostname 127.0.0.1 --port 30141 --no-open\n"
        case "comm=": return "\(command)\n"
        case "pgid=": return "\(processGroupID ?? pid)\n"
        case "lstart=": return "\(launchedAt)\n"
        case "args=": return "\(liveCommandLine())\n"
        default: return nil
        }
    }
}

private final class ServiceManagerHarness {
    static let instanceID = "test-instance"

    let root: URL
    let appConfiguration: AppConfiguration
    let runner: ManagerFakeRunner
    let launcher: ManagerFakeLauncher
    let probe: ManagerFakeProbe
    let scheduler: ManagerFakeScheduler
    let signaler: ManagerFakeSignaler
    let store: ServiceOwnershipStoring
    let manager: ServiceManager

    private(set) var states: [ServiceState] = []
    private(set) var pageMessages: [String] = []
    private(set) var startupFailures: [String] = []
    private(set) var loadRequests = 0

    init(
        configuration: ServiceConfiguration,
        alive: @escaping (pid_t) -> Bool,
        processOutput: @escaping ([String]) -> String?,
        processExecutablePath: @escaping (pid_t) -> String? = { _ in nil },
        fileManager: FileManager,
        baseEnvironment: [String: String],
        ownershipStore: ServiceOwnershipStoring? = nil
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
        signaler = ManagerFakeSignaler()
        store = ownershipStore ?? FileServiceOwnershipStore(fileManager: fileManager)

        let inspector = ProcessInspector(
            runner: runner,
            processIsAlive: alive,
            processExecutablePath: processExecutablePath
        )
        manager = ServiceManager(
            configuration: configuration,
            appConfiguration: appConfiguration,
            processInspector: inspector,
            commandRunner: runner,
            launcher: launcher,
            probe: probe,
            scheduler: scheduler,
            environment: { baseEnvironment },
            fileManager: fileManager,
            ownershipStore: store,
            signaler: signaler,
            instanceID: Self.instanceID
        )

        manager.onStateChange = { [weak self] state in self?.states.append(state) }
        manager.onPageMessage = { [weak self] message in self?.pageMessages.append(message) }
        manager.onStartupFailure = { [weak self] message in self?.startupFailures.append(message) }
        manager.onLoadPage = { [weak self] in self?.loadRequests += 1 }
    }

    var ownerFileURL: URL { appConfiguration.serviceOwnerURL }
    var legacyPIDFileURL: URL { appConfiguration.legacyServicePIDURL }
    var logURL: URL { appConfiguration.logURL }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func readOwnershipRecord() -> ServiceOwnershipRecord? {
        store.loadRecord(from: ownerFileURL)
    }

    func writeOwnershipRecord(_ record: ServiceOwnershipRecord) throws {
        try store.save(record, to: ownerFileURL)
    }

    func makeOwnershipRecord(
        pid: pid_t = 5150,
        processGroupID: pid_t = 5150,
        launchedAt: String = fakeLaunchedAt,
        resolvedExecutable: String = fakeExecutable,
        resolvedExecutableSource: ServiceExecutableSource = .psComm,
        argumentsDigest: String? = nil,
        port: Int = 30141,
        instanceID: String = ServiceManagerHarness.instanceID
    ) -> ServiceOwnershipRecord {
        ServiceOwnershipRecord(
            pid: pid,
            processGroupID: processGroupID,
            launchedAt: launchedAt,
            resolvedExecutable: resolvedExecutable,
            resolvedExecutableSource: resolvedExecutableSource,
            argumentsDigest: argumentsDigest ?? ServiceOwnershipRecord.commandDigest(ofCommandText: fakeCommandLine),
            port: port,
            instanceID: instanceID,
            recordedAt: "2025-07-30T12:00:00Z"
        )
    }

    func writeLegacyPIDRecord(_ pid: pid_t) throws {
        // Older builds created the support directory before writing their PID
        // files; mirror that so the harness can seed a record directly.
        try FileManager.default.createDirectory(at: legacyPIDFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "\(pid)\n".write(to: legacyPIDFileURL, atomically: true, encoding: .utf8)
    }

    func readLegacyPIDRecord() -> String? {
        try? String(contentsOf: legacyPIDFileURL, encoding: .utf8)
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
    processExecutablePath: @escaping (pid_t) -> String? = { _ in nil },
    fileManager: FileManager = .default,
    ownershipStore: ServiceOwnershipStoring? = nil
) throws -> ServiceManagerHarness {
    try ServiceManagerHarness(
        configuration: configuration,
        alive: alive,
        processOutput: processOutput,
        processExecutablePath: processExecutablePath,
        fileManager: fileManager,
        baseEnvironment: fakeBaseEnvironment,
        ownershipStore: ownershipStore
    )
}

private func configured(_ piWebPath: String) -> ServiceConfiguration {
    var configuration = ServiceConfiguration.default
    configuration.piWebPath = piWebPath
    return configuration
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

    // MARK: Ownership records

    func testLegacyPIDRecordIsRemovedAndNeverAdopted() throws {
        let harness = try makeHarness(alive: { $0 == 4321 })
        defer { harness.cleanUp() }
        try harness.writeLegacyPIDRecord(4321)

        harness.manager.reconcileOwnershipRecord()

        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.legacyPIDFileURL.path))
        XCTAssertNil(harness.manager.managedServicePID())
        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
    }

    func testOwnershipRecordFromAnEarlierInstanceIsRemovedWithoutSignals() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        try harness.writeOwnershipRecord(harness.makeOwnershipRecord(instanceID: "instance-from-an-earlier-run"))

        harness.manager.reconcileOwnershipRecord()

        XCTAssertNil(harness.readOwnershipRecord())
        XCTAssertNil(harness.manager.managedServicePID())
        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
    }

    func testStaleOwnershipRecordIsRemovedWithoutSignals() throws {
        let harness = try makeHarness(alive: { _ in false })
        defer { harness.cleanUp() }
        try harness.writeOwnershipRecord(harness.makeOwnershipRecord())

        XCTAssertNil(harness.manager.managedServicePID())
        XCTAssertNil(harness.readOwnershipRecord())
        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
    }

    func testMatchingOwnershipRecordIsAdopted() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        try harness.writeOwnershipRecord(harness.makeOwnershipRecord())

        XCTAssertEqual(harness.manager.managedServicePID(), 5150)
        XCTAssertNotNil(harness.readOwnershipRecord())
    }

    func testReusedPIDWithADifferentLaunchTimeIsNeverSignalled() throws {
        // PID reuse: the recorded process is gone and this PID now belongs to a
        // different process that happens to look like pi-web.
        let harness = try makeHarness(
            alive: { $0 == 5150 },
            processOutput: processOutput(for: 5150, launchedAt: "Wed Jul 30 13:00:00 2025")
        )
        defer { harness.cleanUp() }
        try harness.writeOwnershipRecord(harness.makeOwnershipRecord())

        XCTAssertNil(harness.manager.managedServicePID())

        harness.manager.setState(.running)
        harness.manager.stopService()
        harness.scheduler.runAllBackgroundWork()

        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
        XCTAssertNil(harness.readOwnershipRecord())
        // An external service is not "stopped" by this app: the previous state
        // stays visible instead of claiming the service is gone.
        XCTAssertEqual(harness.manager.currentState, .running)
    }

    func testUnverifiableProcessFactsAreNeverSignalledAndKeepTheRecord() throws {
        // `ps` cannot read the process (for example another user's process):
        // nothing can be proven, so nothing is signalled and the record stays
        // for a later check.
        let harness = try makeHarness(alive: { $0 == 5150 })
        defer { harness.cleanUp() }
        try harness.writeOwnershipRecord(harness.makeOwnershipRecord())

        harness.manager.setState(.running)
        harness.manager.stopService()
        harness.scheduler.runAllBackgroundWork()

        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
        XCTAssertNotNil(harness.readOwnershipRecord())
        XCTAssertEqual(harness.manager.currentState, .running)
    }

    func testChangedLiveCommandLineMakesTheServiceExternalAndSendsNoSignal() throws {
        // The record was written for the command line read at launch. If the
        // live process now reports a different one, it is no longer provably
        // the process this app launched, so it becomes external and no signal
        // may be sent.
        var liveCommandLine = fakeCommandLine
        let harness = try makeHarness(
            alive: { $0 == 5150 },
            processOutput: processOutput(for: 5150, liveCommandLine: { liveCommandLine })
        )
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = false
        harness.manager.startManagedService()
        XCTAssertEqual(harness.manager.managedServicePID(), 5150)

        liveCommandLine = "node /opt/homebrew/bin/pi-web --hostname 0.0.0.0 --port 30141 --no-open"

        XCTAssertNil(harness.manager.managedServicePID())
        harness.manager.stopService()
        harness.scheduler.runAllBackgroundWork()

        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
        XCTAssertNil(harness.readOwnershipRecord())
        XCTAssertEqual(harness.manager.currentState, .starting)
    }

    func testChangedResolvedExecutableMakesTheServiceExternalAndSendsNoSignal() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        var record = harness.makeOwnershipRecord()
        record.resolvedExecutable = "/opt/homebrew/bin/other-server"
        try harness.writeOwnershipRecord(record)

        XCTAssertNil(harness.manager.managedServicePID())
        harness.manager.setState(.running)
        harness.manager.stopService()
        harness.scheduler.runAllBackgroundWork()

        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
        XCTAssertNil(harness.readOwnershipRecord())
        XCTAssertEqual(harness.manager.currentState, .running)
    }

    func testProcPidPathProvenanceIsRecordedWhenAvailable() throws {
        let harness = try makeHarness(
            alive: { $0 == 5150 },
            processOutput: processOutput(for: 5150),
            processExecutablePath: { pid in pid == 5150 ? "/opt/homebrew/bin/node" : nil }
        )
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = false

        harness.manager.startManagedService()

        let record = try XCTUnwrap(harness.readOwnershipRecord())
        XCTAssertEqual(record.resolvedExecutable, "/opt/homebrew/bin/node")
        XCTAssertEqual(record.resolvedExecutableSource, .procPidPath)
        XCTAssertEqual(harness.manager.managedServicePID(), 5150)
    }

    func testStartManagedServiceWithoutArgumentsProvenanceIsRejectedAndTerminated() throws {
        // `ps -o args=` yields nothing, so the command line cannot be proven:
        // the launch is terminated instead of being adopted unverified.
        let harness = try makeHarness(
            alive: { $0 == 5150 },
            processOutput: processOutput(for: 5150, liveCommandLine: { "" })
        )
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))

        harness.manager.startManagedService()
        harness.scheduler.runAllBackgroundWork()

        XCTAssertNil(harness.readOwnershipRecord())
        XCTAssertNil(harness.manager.managedServicePID())
        XCTAssertEqual(
            harness.signaler.groupSignals,
            [ManagerFakeSignaler.GroupSignal(signal: SIGTERM, processGroupID: 5150)]
        )
        XCTAssertEqual(harness.startupFailures.count, 1)
        XCTAssertTrue(harness.startupFailures.first?.hasPrefix("无法登记 pi-web 的所有权信息") == true)
    }

    func testStartManagedServiceWritesAVerifiableOwnershipRecord() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        let executable = try harness.makeExecutable()
        harness.manager.updateConfiguration(configured(executable))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = false

        harness.manager.startManagedService()

        let record = try XCTUnwrap(harness.readOwnershipRecord())
        XCTAssertEqual(record.pid, 5150)
        XCTAssertEqual(record.processGroupID, 5150)
        XCTAssertEqual(record.launchedAt, fakeLaunchedAt)
        XCTAssertEqual(record.resolvedExecutable, fakeExecutable)
        XCTAssertEqual(record.resolvedExecutableSource, .psComm)
        XCTAssertEqual(
            record.argumentsDigest,
            ServiceOwnershipRecord.commandDigest(ofCommandText: fakeCommandLine)
        )
        XCTAssertEqual(record.port, 30141)
        XCTAssertEqual(record.instanceID, ServiceManagerHarness.instanceID)
        XCTAssertEqual(harness.manager.managedServicePID(), 5150)
        XCTAssertEqual(harness.manager.startDecision(), .existingProcess)
    }

    func testOwnershipRecordWriteFailureTerminatesTheFreshGroupAndBlocksASecondLaunch() throws {
        let harness = try makeHarness(
            alive: { $0 == 5150 },
            processOutput: processOutput(for: 5150),
            ownershipStore: ManagerFailingOwnershipStore()
        )
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))

        harness.manager.startManagedService()

        // The record could not be written: the fresh process group is killed
        // and no ownership record exists.
        XCTAssertEqual(harness.launcher.launchCount, 1)
        XCTAssertNil(harness.readOwnershipRecord())
        XCTAssertNil(harness.manager.managedServicePID())
        // A second start must not spawn another service while the unrecorded
        // launch is still alive.
        harness.manager.startManagedService()
        XCTAssertEqual(harness.launcher.launchCount, 1)

        harness.scheduler.runAllBackgroundWork()

        // Group-only signal, startup failure reported, nothing adopted.
        XCTAssertEqual(
            harness.signaler.groupSignals,
            [ManagerFakeSignaler.GroupSignal(signal: SIGTERM, processGroupID: 5150)]
        )
        XCTAssertEqual(harness.startupFailures.count, 1)
        XCTAssertTrue(harness.startupFailures.first?.hasPrefix("无法登记 pi-web 的所有权信息") == true)
        if case .failed = harness.manager.currentState {} else {
            XCTFail("expected .failed, got \(harness.manager.currentState)")
        }
        // The fake child survived the signal, so it still blocks a new launch.
        XCTAssertEqual(harness.manager.startDecision(), .existingProcess)
    }

    func testNonLeaderChildIsTerminatedInsteadOfBeingAdopted() throws {
        // A child that is not its own process group leader cannot be
        // verified, so it is terminated rather than kept as a half-managed
        // service.
        let harness = try makeHarness(
            alive: { $0 == 5150 },
            processOutput: processOutput(for: 5150, processGroupID: 4000)
        )
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))

        harness.manager.startManagedService()
        harness.scheduler.runAllBackgroundWork()

        XCTAssertNil(harness.readOwnershipRecord())
        XCTAssertNil(harness.manager.managedServicePID())
        // The signal still targets the child's real group (its own pid).
        XCTAssertEqual(
            harness.signaler.groupSignals,
            [ManagerFakeSignaler.GroupSignal(signal: SIGTERM, processGroupID: 5150)]
        )
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
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        try harness.writeOwnershipRecord(harness.makeOwnershipRecord())
        XCTAssertEqual(harness.manager.managedServicePID(), 5150)

        harness.manager.stopService()
        XCTAssertEqual(harness.manager.startDecision(), .ignored)
    }

    // MARK: Starting

    func testStartManagedServiceLaunchesPollsAndReportsTheStartingState() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        let executable = try harness.makeExecutable()
        harness.manager.updateConfiguration(configured(executable))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = false

        harness.manager.startManagedService()

        XCTAssertEqual(harness.launcher.launchCount, 1)
        XCTAssertEqual(harness.launcher.specifications.first?.executablePath, executable)
        XCTAssertEqual(harness.launcher.logHandles.count, 1)
        XCTAssertEqual(harness.manager.currentState, .starting)
        XCTAssertEqual(harness.pageMessages, ["正在启动 Pi Web…"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.logURL.path))
        XCTAssertEqual(harness.scheduler.delayedWork.count, 1)
        XCTAssertEqual(harness.scheduler.delayedWork.first?.delay, 0.2)
    }

    func testPollUntilReadyLoadsThePageOnceTheProbeSucceeds() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
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

    func testStopServiceSendsOneGroupSignalAndRemovesTheRecord() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.manager.startManagedService()
        harness.signaler.aliveProcessGroups = [5150]

        var completionRan = false
        harness.manager.stopService { completionRan = true }
        harness.scheduler.runAllBackgroundWork()

        // Exactly one SIGTERM, to the process group, and no SIGKILL because the
        // group disappeared within the bounded wait.
        XCTAssertEqual(
            harness.signaler.groupSignals,
            [ManagerFakeSignaler.GroupSignal(signal: SIGTERM, processGroupID: 5150)]
        )
        XCTAssertTrue(harness.scheduler.sleeps.isEmpty)
        XCTAssertNil(harness.readOwnershipRecord())
        XCTAssertEqual(harness.manager.currentState, .stopped)
        XCTAssertTrue(completionRan)
        XCTAssertNil(harness.manager.managedServicePID())
    }

    func testStopServiceEscalatesToTheSameProcessGroupAfterTheBoundedWait() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.manager.startManagedService()
        harness.signaler.aliveProcessGroups = [5150]
        harness.signaler.groupSurvivesSignals = true

        harness.manager.stopService()
        harness.scheduler.runAllBackgroundWork()

        XCTAssertEqual(
            harness.signaler.groupSignals,
            [
                ManagerFakeSignaler.GroupSignal(signal: SIGTERM, processGroupID: 5150),
                ManagerFakeSignaler.GroupSignal(signal: SIGKILL, processGroupID: 5150)
            ]
        )
        XCTAssertEqual(harness.scheduler.sleeps.count, ServiceManager.stopPollAttempts)
        XCTAssertEqual(harness.manager.currentState, .stopped)
    }

    func testStopServiceWithoutAVerifiedRecordSendsNothingAndKeepsTheState() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }

        var completionRan = false
        harness.manager.stopService { completionRan = true }

        XCTAssertEqual(harness.manager.currentState, .checking)
        XCTAssertTrue(completionRan)
        XCTAssertEqual(harness.scheduler.backgroundWork.count, 0)
        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
        XCTAssertTrue(harness.runner.invocations.isEmpty)
    }

    func testExternalServiceStopKeepsTheRunningStateAndSendsNoSignal() throws {
        // The app adopted an external service (its health probe answered).
        // Confirming "stop" for it must not kill it and must not pretend it
        // is gone.
        let harness = try makeHarness(
            alive: { $0 == 4321 },
            processOutput: processOutput(for: 4321, listenerPort: 30141)
        )
        defer { harness.cleanUp() }
        harness.manager.setState(.running)

        var completionRan = false
        harness.manager.stopService { completionRan = true }
        harness.scheduler.runAllBackgroundWork()

        XCTAssertTrue(completionRan)
        XCTAssertEqual(harness.manager.currentState, .running)
        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
        XCTAssertTrue(harness.scheduler.backgroundWork.isEmpty)
        XCTAssertNil(harness.readOwnershipRecord())
    }

    func testExternalListenerIsNeverSignalled() throws {
        // An unrelated process listens on the configured port and even looks
        // like pi-web. Without an ownership record it stays untouched.
        let harness = try makeHarness(
            alive: { $0 == 4321 },
            processOutput: processOutput(for: 4321, listenerPort: 30141)
        )
        defer { harness.cleanUp() }
        harness.manager.setState(.running)

        harness.manager.stopService()
        harness.manager.stopAllServices {}
        harness.scheduler.runAllBackgroundWork()

        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
        XCTAssertFalse(harness.runner.invocations.contains { $0.first == "/bin/kill" })
        XCTAssertFalse(harness.runner.invocations.contains { $0.contains("-TERM") || $0.contains("-KILL") })
        XCTAssertNil(harness.readOwnershipRecord())
        XCTAssertEqual(harness.manager.currentState, .running)
    }

    func testRecordedPortChangeMakesTheRunningServiceExternal() throws {
        // The user switched ports; the running process no longer matches what
        // the app would launch, so it is external and never signalled.
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        try harness.writeOwnershipRecord(harness.makeOwnershipRecord(port: 30141))

        var configuration = ServiceConfiguration.default
        configuration.port = 30142
        harness.manager.updateConfiguration(configuration)
        harness.manager.setState(.running)

        harness.manager.stopService()
        harness.scheduler.runAllBackgroundWork()

        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
        XCTAssertNil(harness.readOwnershipRecord())
        XCTAssertEqual(harness.manager.currentState, .running)
    }

    // MARK: Quit behaviour

    func testKeepRunningOnQuitKeepsTheOwnershipRecord() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.manager.startManagedService()
        harness.manager.startHealthMonitor()

        harness.manager.keepRunningOnQuit()

        XCTAssertTrue(harness.manager.isQuitting)
        XCTAssertNotNil(harness.readOwnershipRecord())
        XCTAssertEqual(harness.manager.managedServicePID(), 5150)
        XCTAssertEqual(harness.scheduler.repeatTokens.last?.invalidateCount, 1)
        XCTAssertTrue(harness.scheduler.backgroundWork.isEmpty)
        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
    }

    func testStopAllServicesStopsTheVerifiedChildAndInvokesTheCompletion() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.manager.startManagedService()
        harness.signaler.aliveProcessGroups = [5150]

        var completionRan = false
        harness.manager.stopAllServices { completionRan = true }
        harness.scheduler.runAllBackgroundWork()

        XCTAssertTrue(completionRan)
        XCTAssertTrue(harness.manager.isQuitting)
        XCTAssertEqual(
            harness.signaler.groupSignals,
            [ManagerFakeSignaler.GroupSignal(signal: SIGTERM, processGroupID: 5150)]
        )
        XCTAssertNil(harness.readOwnershipRecord())
    }

    func testStopAllServicesLeavesAnExternalServiceRunning() throws {
        let harness = try makeHarness(
            alive: { $0 == 4321 },
            processOutput: processOutput(for: 4321, listenerPort: 30141)
        )
        defer { harness.cleanUp() }

        var completionRan = false
        harness.manager.stopAllServices { completionRan = true }

        XCTAssertTrue(completionRan)
        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
    }

    // MARK: Spawn descriptors

    func testSpawnDescriptorAboveStandardErrorIsPassedThrough() throws {
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        XCTAssertGreaterThan(descriptor, STDERR_FILENO)

        let guarded = try XCTUnwrap(SpawnFileDescriptor.aboveStandardError(descriptor))

        XCTAssertEqual(guarded.descriptor, descriptor)
        XCTAssertFalse(guarded.isDuplicate)
        // Closing a pass-through descriptor must leave the caller's fd open.
        guarded.closeIfDuplicate()
        XCTAssertEqual(write(descriptor, "x", 1), 1)
        XCTAssertNil(SpawnFileDescriptor.aboveStandardError(-1))
    }

    func testSpawnDescriptorAtOrBelowStandardErrorIsDuplicatedAboveIt() throws {
        // A descriptor that `open` handed out as 0/1/2 must not be passed to
        // `posix_spawn` directly, because closing it would clobber the child's
        // stdin/stdout/stderr. It is copied above stderr instead. fd 1 is used
        // here because it is guaranteed to be open and only the copy is ever
        // closed.
        let guarded = try XCTUnwrap(SpawnFileDescriptor.aboveStandardError(STDOUT_FILENO))

        XCTAssertGreaterThan(guarded.descriptor, STDERR_FILENO)
        XCTAssertTrue(guarded.isDuplicate)
        guarded.closeIfDuplicate()
        // The caller's descriptor survived the copy being closed.
        XCTAssertEqual(write(STDOUT_FILENO, "", 0), 0)
    }

    // MARK: Health monitoring

    func testHealthMonitorRestartsAManagedServiceThatDisappeared() throws {
        // The liveness probe follows the fake child, so the ownership record
        // stops verifying exactly like a real dead process.
        let liveness = ManagerFakeLiveness()
        let harness = try makeHarness(
            alive: { pid in pid == 5150 ? liveness.isAlive : true },
            processOutput: processOutput(for: 5150)
        )
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
        liveness.isAlive = false
        harness.probe.ready = false
        // The restart spawns a new process with a new PID, which is alive and
        // whose `ps` facts are readable.
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5200))
        harness.runner.handler = processOutput(for: 5200)
        XCTAssertTrue(harness.scheduler.runHealthCheck())

        XCTAssertEqual(harness.states.suffix(2), [.stopped, .starting])
        XCTAssertTrue(harness.pageMessages.contains("Pi Web 服务已断开，正在尝试恢复…"))
        XCTAssertEqual(harness.launcher.launchCount, 2)
        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
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
        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
    }
}
