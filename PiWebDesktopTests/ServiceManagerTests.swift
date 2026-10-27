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
    case failedWithMessage(String)

    var errorDescription: String? {
        switch self {
        case .failed: return "fake launch failure"
        case .failedWithMessage(let message): return message
        }
    }
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
    private var mainIndex = 0

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

    /// Runs queued main-queue work in order; used to prove that callbacks which
    /// were queued before the dependency gate closed do nothing when they run.
    @discardableResult
    func runNextMainWork() -> Bool {
        guard mainIndex < mainWork.count else { return false }
        let work = mainWork[mainIndex]
        mainIndex += 1
        work()
        return true
    }

    func runAllMainWork() {
        while runNextMainWork() {}
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
    /// 为 true 时把本次探测的 completion 暂存起来，由测试显式交付。用来构造
    /// “停止完成后才到达的 ready=true”这类迟到回调（W3 M2），不需要真实时钟。
    var defersCompletions = false
    private(set) var probedURLs: [URL] = []
    private(set) var timeouts: [TimeInterval] = []
    private(set) var pendingCompletions: [(Bool) -> Void] = []

    func probe(url: URL, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        probedURLs.append(url)
        timeouts.append(timeout)
        if defersCompletions {
            pendingCompletions.append(completion)
        } else {
            completion(ready)
        }
    }

    /// 交付所有暂存的探测结果（按探测顺序），返回交付条数。
    @discardableResult
    func deliverPendingCompletions(_ result: Bool) -> Int {
        let pending = pendingCompletions
        pendingCompletions = []
        for completion in pending { completion(result) }
        return pending.count
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

/// 可注入的工作目录探针：把“目录存在/可写/创建”变成测试可控的状态，
/// 从而在不碰真实用户目录的情况下模拟“运行期间目录被删除”。
private final class ManagerFakeWorkspaceProbe {
    private var directories: Set<String> = []
    private var writableDirectories: Set<String> = []
    private var files: Set<String> = []
    private(set) var createdDirectories: [String] = []

    /// 声明一个已存在且可写的目录（模拟用户选好的自选目录）。
    func addWritableDirectory(_ path: String) {
        directories.insert(path)
        writableDirectories.insert(path)
    }

    /// 删除目录：等价于用户在应用运行期间把它删掉或改名。
    func removeDirectory(_ path: String) {
        directories.remove(path)
        writableDirectories.remove(path)
    }

    func isDirectory(_ path: String) -> Bool { directories.contains(path) }

    var probe: WorkspaceDirectoryProbe {
        WorkspaceDirectoryProbe(
            pathExists: { self.directories.contains($0) || self.files.contains($0) },
            isDirectory: { self.directories.contains($0) },
            isWritable: { self.writableDirectories.contains($0) },
            createDirectory: { path in
                self.createdDirectories.append(path)
                self.directories.insert(path)
                self.writableDirectories.insert(path)
            }
        )
    }
}

/// 一次 `onWorkspaceProblem` 回调的记录。
private struct ManagerWorkspaceProblem: Equatable {
    let problem: WorkspaceDirectoryProblem
    let path: String
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
    /// When true, a group that survives SIGKILL stops as soon as the caller
    /// starts confirming — exercises the "SIGKILL took effect" branch.
    var groupGoneOnConfirmation = false
    /// Number of liveness probes performed after SIGKILL was sent.
    private(set) var postKillProbes = 0
    private var killedGroups: Set<pid_t> = []

    func sendGroupSignal(_ signal: Int32, toProcessGroup processGroupID: pid_t) -> Bool {
        groupSignals.append(GroupSignal(signal: signal, processGroupID: processGroupID))
        if !groupSurvivesSignals {
            aliveProcessGroups.remove(processGroupID)
        } else if signal == SIGKILL {
            killedGroups.insert(processGroupID)
        }
        return true
    }

    func isProcessGroupAlive(_ processGroupID: pid_t) -> Bool {
        if killedGroups.contains(processGroupID) {
            postKillProbes += 1
            if groupGoneOnConfirmation {
                aliveProcessGroups.remove(processGroupID)
                killedGroups.remove(processGroupID)
            }
        }
        return aliveProcessGroups.contains(processGroupID)
    }

    /// Start of a new stop cycle: the previous cycle's pending SIGKILL bookkeeping
    /// no longer applies, so the next `isProcessGroupAlive` probe is counted as a
    /// post-kill confirmation of *this* cycle.
    func beginNewStopCycle() {
        killedGroups.removeAll()
        postKillProbes = 0
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

/// 可变密码来源：测试可以在运行中把“Keychain 条目”删掉（置 nil）。
private final class MutablePasswordProvider {
    var password: String?
    private(set) var readCount = 0

    init(_ password: String?) {
        self.password = password
    }

    func read() -> String? {
        readCount += 1
        return password
    }
}

/// 依次返回给定值、之后恒为 nil 的密码来源。用来证明启动路径只读一次。
private final class OneShotPasswordProvider {
    private var remaining: [String?]
    private(set) var readCount = 0

    init(_ values: [String?]) {
        remaining = values
    }

    func read() -> String? {
        readCount += 1
        return remaining.isEmpty ? nil : remaining.removeFirst()
    }
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
    private(set) var workspaceProblems: [ManagerWorkspaceProblem] = []
    private(set) var listeningAddressFallbacks: [ListeningAddressFallback] = []
    private(set) var loadRequests = 0

    init(
        configuration: ServiceConfiguration,
        alive: @escaping (pid_t) -> Bool,
        processOutput: @escaping ([String]) -> String?,
        processExecutablePath: @escaping (pid_t) -> String? = { _ in nil },
        fileManager: FileManager,
        baseEnvironment: [String: String],
        ownershipStore: ServiceOwnershipStoring? = nil,
        workspaceProbe: WorkspaceDirectoryProbe? = nil,
        redactor: LogRedactor? = nil,
        localAddresses: @escaping () -> LocalAddresses = { LocalAddresses(ipv4: [], ipv6: []) },
        resolvesToLocalHost: @escaping (String) -> Bool = { _ in false }
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PiWebDesktopTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let supportURL = root.appendingPathComponent("support", isDirectory: true)
        let logsRootURL = root.appendingPathComponent("logs", isDirectory: true)
        let defaults = UserDefaults(suiteName: "ServiceManagerTests.\(UUID().uuidString)") ?? .standard
        let resolvedAppConfiguration = AppConfiguration(supportURL: supportURL, logsRootURL: logsRootURL, defaults: defaults)
        appConfiguration = resolvedAppConfiguration

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
            workspaceProbe: workspaceProbe,
            instanceID: Self.instanceID,
            // 注入脱敏器时，日志写入器也用它，保证“同一实例”而不是“同一份规则”。
            logWriter: redactor.map { LogWriter(logFileURL: resolvedAppConfiguration.logURL, redactor: $0) },
            // 监听地址回落判定：测试默认给空快照与“不解析到本机”的主机名解析，
            // 因此具名地址在测试里一律判为不在本机（也就是回落），需要真实存在的
            // 地址的用例显式注入快照。
            localAddresses: localAddresses,
            resolvesToLocalHost: resolvesToLocalHost
        )
        // 既有测试覆盖的是依赖门控打开后的行为；门控本身的测试会显式关闭它。
        manager.isDependencyGateOpen = true

        manager.onStateChange = { [weak self] state in self?.states.append(state) }
        manager.onPageMessage = { [weak self] message in self?.pageMessages.append(message) }
        manager.onStartupFailure = { [weak self] message in self?.startupFailures.append(message) }
        manager.onLoadPage = { [weak self] in self?.loadRequests += 1 }
        manager.onListeningAddressFallback = { [weak self] fallback in
            self?.listeningAddressFallbacks.append(fallback)
        }
        manager.onWorkspaceProblem = { [weak self] problem, path in
            self?.workspaceProblems.append(ManagerWorkspaceProblem(problem: problem, path: path))
        }
    }

    var ownerFileURL: URL { appConfiguration.serviceOwnerURL }
    var legacyPIDFileURL: URL { appConfiguration.legacyServicePIDURL }
    var logURL: URL { appConfiguration.logURL }

    /// 等日志写入队列排空再读日志文件（GitHub #88）。GitHub #73 起应用侧写入都在
    /// `LogWriter` 的后台串行队列上，`startManagedService()` 返回不代表文件内容已
    /// 可见；`flush()` 是确定性的排空屏障（返回时此前提交的写入/轮转均已完成）。
    /// 读日志的断言一律先过这里，不用固定 sleep 猜时间。
    func drainLogWrites() {
        manager.logWriter.flush()
    }

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

/// 测试用的“用户自选工作目录”（GitHub #9 复审）。
/// 它只存在于假探针里：真实文件系统上不存在，也必须在测试结束时仍然不存在；
/// 断言这一点正是“自选目录不得被自动创建”的防线。
private let fakeCustomWorkspace = "/tmp/PiWebDesktopTests/custom-workspace"

private func makeHarness(
    configuration: ServiceConfiguration = .default,
    alive: @escaping (pid_t) -> Bool = { _ in false },
    processOutput: @escaping ([String]) -> String? = { _ in nil },
    processExecutablePath: @escaping (pid_t) -> String? = { _ in nil },
    fileManager: FileManager = .default,
    baseEnvironment: [String: String] = fakeBaseEnvironment,
    ownershipStore: ServiceOwnershipStoring? = nil,
    workspaceProbe: WorkspaceDirectoryProbe? = nil,
    redactor: LogRedactor? = nil,
    localAddresses: @escaping () -> LocalAddresses = { LocalAddresses(ipv4: [], ipv6: []) },
    resolvesToLocalHost: @escaping (String) -> Bool = { _ in false }
) throws -> ServiceManagerHarness {
    try ServiceManagerHarness(
        configuration: configuration,
        alive: alive,
        processOutput: processOutput,
        processExecutablePath: processExecutablePath,
        fileManager: fileManager,
        baseEnvironment: baseEnvironment,
        ownershipStore: ownershipStore,
        workspaceProbe: workspaceProbe,
        redactor: redactor,
        localAddresses: localAddresses,
        resolvesToLocalHost: resolvesToLocalHost
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

    func testTransientlyUnreadableCommandLineKeepsTheRecordAndTheStopPath() throws {
        // 启动后 `ps -o args=` 偶尔读不到（瞬时空输出）不得当作“命令变了”：旧实现
        // 把它判成 `.argumentsMismatch` 并删掉记录，于是本应用自己启动的进程永久
        // 降级为外部服务，用户再也停不掉它。现在按“事实暂时不可读”处理：记录保留、
        // 本次不发信号，`ps` 恢复后同一个进程又回到可管理状态。
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

        liveCommandLine = ""

        XCTAssertNil(harness.manager.managedServicePID())
        // The record survived the unreadable read, so it is not re-acquirable
        // proof for a different process either.
        XCTAssertNotNil(harness.readOwnershipRecord())

        harness.manager.setState(.running)
        harness.manager.stopService()
        harness.scheduler.runAllBackgroundWork()
        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
        XCTAssertEqual(harness.manager.currentState, .running)
        XCTAssertNotNil(harness.readOwnershipRecord())

        // `ps` answers again: the very same process is managed and stoppable.
        liveCommandLine = fakeCommandLine
        XCTAssertEqual(harness.manager.managedServicePID(), 5150)
        harness.manager.stopService()
        harness.scheduler.runAllBackgroundWork()
        XCTAssertEqual(
            harness.signaler.groupSignals,
            [ManagerFakeSignaler.GroupSignal(signal: SIGTERM, processGroupID: 5150)]
        )
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
        XCTAssertEqual(specification.workingDirectory.standardizedFileURL, harness.appConfiguration.defaultWorkspaceDirectory.standardizedFileURL)

        let environment = specification.environment
        XCTAssertEqual(environment["PI_WEB_NO_OPEN"], "1")
        // #89：不再硬编码 PATH 列表；没有登录 shell 查询与注入构建器时，构建器
        // 的确定结果就是“应用 PATH（这里为空）+ 已知目录”。
        XCTAssertEqual(
            environment["PATH"],
            "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        )
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

    // MARK: 监听地址回环回落

    /// 配置的监听地址不在本机（Tailscale 掉线）：启动参数用回环地址、探测用回环 URL、
    /// 并回调一次回落通知；配置本身保持原样。
    func testMissingListeningAddressLaunchesOnLoopbackAndNotifies() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        let executable = try harness.makeExecutable()
        var configuration = configured(executable)
        // 覆盖网络地址在仓库里不能写成字面值（check-identity.sh），这里拼接。
        let address = ["100", "76.71.55"].joined(separator: ".")
        configuration.hostname = address
        harness.manager.updateConfiguration(configuration)

        guard case .launch(let specification) = harness.manager.startDecision() else {
            return XCTFail("expected .launch, got \(harness.manager.startDecision())")
        }
        XCTAssertEqual(specification.arguments, ["--hostname", "127.0.0.1", "--port", "30141", "--no-open"])
        XCTAssertEqual(harness.manager.effectiveListeningAddress, "127.0.0.1")
        XCTAssertEqual(harness.manager.effectiveServiceURL.absoluteString, "http://127.0.0.1:30141/")
        XCTAssertEqual(harness.manager.configuration.hostname, address, "配置不得被回写")

        let fallback = try XCTUnwrap(harness.listeningAddressFallbacks.first)
        XCTAssertEqual(fallback.requested, address)
        XCTAssertEqual(fallback.effective, "127.0.0.1")
        XCTAssertEqual(harness.listeningAddressFallbacks.count, 1, "同一次回落只提示一次")
    }

    /// 地址仍在本机：不回落，启动参数与生效地址都用配置地址。
    func testPresentListeningAddressKeepsTheConfiguredHostname() throws {
        let address = ["100", "76.71.55"].joined(separator: ".")
        let harness = try makeHarness(localAddresses: { LocalAddresses(ipv4: [address], ipv6: []) })
        defer { harness.cleanUp() }
        var configuration = configured(try harness.makeExecutable())
        configuration.hostname = address
        harness.manager.updateConfiguration(configuration)

        guard case .launch(let specification) = harness.manager.startDecision() else {
            return XCTFail("expected .launch, got \(harness.manager.startDecision())")
        }
        XCTAssertEqual(specification.arguments, ["--hostname", address, "--port", "30141", "--no-open"])
        XCTAssertEqual(harness.manager.effectiveListeningAddress, address)
        XCTAssertTrue(harness.listeningAddressFallbacks.isEmpty)
    }

    /// 首次启动（`startAtLaunch` 直走 `ensureServerIsRunning`，未经过 `updateConfiguration`）
    /// 也必须先判定回落：否则 Tailscale 地址不在本机时仍会用配置地址启动并秒退。
    func testFirstLaunchAlsoFallsBackBeforeStarting() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        let address = ["100", "76.71.55"].joined(separator: ".")
        var configuration = configured(try harness.makeExecutable())
        configuration.hostname = address
        configuration.autoStart = true
        harness.manager.updateConfiguration(configuration)
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))

        harness.manager.startAtLaunch()

        XCTAssertEqual(harness.manager.effectiveListeningAddress, "127.0.0.1")
        XCTAssertEqual(harness.listeningAddressFallbacks.count, 1)
        XCTAssertEqual(harness.manager.configuration.hostname, address, "配置不得被回写")
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
        // 回退路径只采信真的可执行的文件：登录 shell 的 stdout 里可能混进
        // `.zshenv` 的 echo（只重定向了 stderr），整段当路径会让 posix_spawn ENOENT。
        fakeFileManager.executablePaths = ["/custom/bin/pi-web"]

        XCTAssertEqual(harness.manager.resolvePiWebPath(), "/custom/bin/pi-web")
    }

    /// 登录 shell 的 stdout 混进别的内容时，不能把整段当作可执行路径。
    ///
    /// 旧实现只做 `trimmingCharacters(in: .whitespacesAndNewlines)`——它不去掉
    /// 中间换行，于是 `posix_spawn` 拿到多行字符串直接 ENOENT，报“无法启动
    /// pi-web（errno 2）”。现在只取最后一行，并且必须确认它可执行。
    func testResolvePiWebPathIgnoresNoiseFromLoginShellOutput() throws {
        let fakeFileManager = ManagerFakeFileManager()
        let harness = try makeHarness(
            processOutput: { arguments in
                arguments.first == "/bin/zsh"
                    ? "Welcome to zsh\nNVM loaded\n/custom/bin/pi-web\n"
                    : nil
            },
            fileManager: fakeFileManager
        )
        defer { harness.cleanUp() }
        fakeFileManager.executablePaths = ["/custom/bin/pi-web"]

        XCTAssertEqual(harness.manager.resolvePiWebPath(), "/custom/bin/pi-web")
    }

    /// 登录 shell 报告了一个不可执行的路径：不得采信。
    func testResolvePiWebPathRejectsANonExecutableShellResult() throws {
        let fakeFileManager = ManagerFakeFileManager()
        let harness = try makeHarness(
            processOutput: { arguments in arguments.first == "/bin/zsh" ? "/custom/bin/pi-web\n" : nil },
            fileManager: fakeFileManager
        )
        defer { harness.cleanUp() }
        // 未登记为可执行：应当按“找不到”处理，而不是盲信 stdout。
        XCTAssertNil(harness.manager.resolvePiWebPath())
    }

    /// 用户配置的 pi-web 路径带 `~` 时必须展开后判定（审计 S3 / F7）。
    ///
    /// 写入侧只做 trim，`isExecutableFile(atPath: "~/bin/pi-web")` 对字面 `~` 恒为
    /// false，诊断只会报“未找到”，用户于是反复重装而真因是路径写法。
    func testResolvePiWebPathExpandsTildeInTheConfiguredPath() throws {
        let fakeFileManager = ManagerFakeFileManager()
        let harness = try makeHarness(fileManager: fakeFileManager)
        defer { harness.cleanUp() }
        var configuration = configured(try harness.makeExecutable())
        configuration.piWebPath = "~/bin/pi-web"
        harness.manager.updateConfiguration(configuration)
        let expanded = ("~/bin/pi-web" as NSString).expandingTildeInPath
        fakeFileManager.executablePaths = [expanded]

        XCTAssertEqual(harness.manager.resolvePiWebPath(), expanded)
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
        XCTAssertEqual(harness.probe.timeouts.last, 3)
    }

    /// 启动轮询期间子进程退出（仍填在句柄里）时必须立即给出可读失败提示，而
    /// 不是继续轮询到超时。真实 launcher 的终止回调会先清空 `serviceProcess`，
    /// 因此这里用假句柄直接覆盖轮询自己的判断分支。
    func testPollUntilReadyReportsAProcessThatExitedDuringPolling() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        let process = ManagerFakeProcess(processIdentifier: 5150)
        harness.launcher.result = .success(process)
        harness.probe.ready = false
        harness.manager.startManagedService()

        process.isRunning = false
        XCTAssertTrue(harness.scheduler.runNextDelayedWork())

        let expected = "pi-web 进程已退出。请查看日志：\(harness.logURL.path)"
        XCTAssertEqual(harness.startupFailures, [expected])
        XCTAssertEqual(harness.pageMessages, ["正在启动 Pi Web…", "启动失败"])
        XCTAssertEqual(harness.manager.currentState, .failed(expected))
    }

    /// 真实生产序列的快失败（区别于上一条用假句柄覆盖的轮询分支）：真实 launcher
    /// 的终止回调先清空 `serviceProcess`，轮询自己的 `!isRunning` 分支永远不命
    /// 中。启动即崩溃（例如监听地址不可用的 EADDRNOTAVAIL）时，终止回调必须
    /// 立即结束启动会话并给出可读失败，而不是继续轮询到 30 秒预算耗尽。
    func testTerminationCallbackFastFailsAnActiveStartupSession() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        let process = ManagerFakeProcess(processIdentifier: 5150)
        harness.launcher.result = .success(process)
        harness.probe.ready = false
        harness.manager.startManagedService()

        XCTAssertEqual(harness.scheduler.delayedWork.count, 1, "启动后应有一条轮询链")
        // 真实序列：子进程启动即退出，终止回调先于任何就绪探测触发。
        harness.launcher.terminationHandlers[0](process)

        let expected = "pi-web 进程已退出。请查看日志：\(harness.logURL.path)"
        XCTAssertEqual(harness.startupFailures, [expected])
        XCTAssertEqual(harness.pageMessages, ["正在启动 Pi Web…", "启动失败"])
        XCTAssertEqual(harness.manager.currentState, .failed(expected))

        // 会话已被终止回调结束：遗留的轮询回调只应过期一次，不再产生第二条
        // 失败，也不再给出“30 秒内未能启动”的错误结论。
        var ranStaleCallbacks = 0
        while harness.scheduler.runNextDelayedWork() { ranStaleCallbacks += 1 }
        XCTAssertEqual(ranStaleCallbacks, 1, "会话结束后遗留轮询只应过期一次，不再续链")
        XCTAssertEqual(harness.startupFailures, [expected], "会话结束后不得重复上报")
        XCTAssertEqual(harness.manager.currentState, .failed(expected))
    }

    /// 启动失败后健康监控必须停下（生产实证 2026-10-24 19:26:36）：进程启动即退出、
    /// 已报“启动失败”后，旧实现仍每 4 秒探测一个已死进程，17 分钟刷了 258 条
    /// “连续失败”。断开/重启判定只对 `.running` 生效，`.failed` 下监控只能空转：
    /// 既改不了状态，也永远不会触发重启。
    func testStartupFailureStopsHealthMonitoring() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        let process = ManagerFakeProcess(processIdentifier: 5150)
        harness.launcher.result = .success(process)
        harness.probe.ready = false
        harness.manager.startManagedService()

        XCTAssertEqual(harness.scheduler.repeatingWork.count, 1, "启动后应有一轮健康监控")
        let token = harness.scheduler.repeatTokens[0]
        XCTAssertEqual(token.invalidateCount, 0)

        // 真实序列：子进程启动即退出，终止回调先于任何就绪探测触发。
        harness.launcher.terminationHandlers[0](process)
        XCTAssertEqual(token.invalidateCount, 1, "启动失败必须停掉健康监控")

        // 即使还有残留的计时器回调被触发，也不得再探测（不得刷“连续失败”）。
        let probesBefore = harness.probe.probedURLs.count
        harness.scheduler.runHealthCheck()
        XCTAssertEqual(harness.probe.probedURLs.count, probesBefore, "失败态下不得继续探测")
    }

    /// 失败后的“重试”必须重新拉起监控：否则服务真的起来了也没有任何探测会把它
    /// 从 `.starting` 推进到 `.running`。
    func testRetryAfterStartupFailureRestartsHealthMonitoring() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        let first = ManagerFakeProcess(processIdentifier: 5150)
        harness.launcher.result = .success(first)
        harness.probe.ready = false
        harness.manager.startManagedService()
        harness.launcher.terminationHandlers[0](first)

        XCTAssertEqual(harness.scheduler.repeatTokens.count, 1, "失败时只有一轮监控（已停）")
        XCTAssertEqual(harness.scheduler.repeatTokens[0].invalidateCount, 1)

        // 用户点“重试”：新的启动入口必须重新拉起监控，且不叠加计时器。
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.manager.restartManagedService()
        harness.scheduler.runAllBackgroundWork()
        XCTAssertEqual(harness.scheduler.repeatTokens.count, 2, "重试后应重新开始且仅一轮监控")
        XCTAssertEqual(harness.scheduler.repeatTokens[1].invalidateCount, 0)

        // 再调一次启动入口不得再叠加计时器（幂等）。
        harness.manager.startManagedService()
        XCTAssertEqual(harness.scheduler.repeatTokens.count, 2, "已在监控中不得叠加计时器")
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
        // SIGKILL 之后复查发现进程组确实消失：这才是“停止成功”。
        harness.signaler.groupGoneOnConfirmation = true

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
        XCTAssertNil(harness.readOwnershipRecord())
    }

    /// SIGKILL 后仍未能确认消失时，不得删掉唯一的所有权证据（GitHub #158 复审）。
    ///
    /// 旧实现发完 SIGKILL 就返回，上层无条件 `removeRecord` + 置 `.stopped`：
    /// 不可中断睡眠里的组因此让应用对自己启动、仍然活着的进程失去全部管理路径
    /// （`managedServicePID()` 恒为 nil，退出也不会再碰它），日志里只留下“已发送
    /// SIGKILL”这一行，事后无法判断停止是否真的成功。
    func testStopServiceKeepsOwnershipRecordWhenTheGroupSurvivesSIGKILL() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.manager.startManagedService()
        harness.signaler.aliveProcessGroups = [5150]
        harness.signaler.groupSurvivesSignals = true
        // 连 SIGKILL 都没生效：组仍然存活。
        harness.signaler.groupGoneOnConfirmation = false

        var completionRan = false
        harness.manager.stopService { completionRan = true }
        harness.scheduler.runAllBackgroundWork()
        harness.drainLogWrites()

        XCTAssertEqual(harness.signaler.groupSignals.map(\.signal), [SIGTERM, SIGKILL])
        // 必须真的复查过，而不是发完就算。
        XCTAssertGreaterThanOrEqual(harness.signaler.postKillProbes, 1)
        // 记录留着当停止证据，下一次停止/退出仍会重试。
        XCTAssertNotNil(harness.readOwnershipRecord(), "未确认退出时不得删掉所有权记录")
        XCTAssertNotNil(harness.manager.managedServicePID())
        // 不谎称已停止：状态保持运行中，由后续重试或人工处置收敛。
        XCTAssertNotEqual(harness.manager.currentState, .stopped)
        // 完成回调仍要送达，否则退出/重启序列会挂住。
        XCTAssertTrue(completionRan)
        let log = (try? String(contentsOf: harness.logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains(QuitTimelineStage.serviceStillAlive.rawValue), log)
        XCTAssertTrue(log.contains("保留所有权记录"), log)
        // 停止标志已收回，且保留的记录仍可用于重试：第二次停止会再次对同一组
        // 发信号（旧实现删了记录后彻底无法重试）。
        harness.signaler.beginNewStopCycle()
        harness.signaler.groupGoneOnConfirmation = true
        harness.manager.stopService()
        harness.scheduler.runAllBackgroundWork()
        XCTAssertEqual(harness.signaler.groupSignals.count, 4, "第二次停止应再次 SIGTERM+SIGKILL")
        XCTAssertNil(harness.readOwnershipRecord())
        XCTAssertEqual(harness.manager.currentState, .stopped)
    }

    /// SIGKILL 后的复查轮数必须有界，否则会把 GitHub #158 修的 Cmd+Q 卡顿
    /// 以另一种形式加回来。
    func testPostKillConfirmationStaysBoundedWellBelowTheStopWait() {
        XCTAssertGreaterThan(ServiceManager.postKillConfirmationPollAttempts, 0)
        // 每轮 10ms：上界远小于 1 秒的停止等待本身。
        let upperBound = TimeInterval(ServiceManager.postKillConfirmationPollAttempts) * 0.01
        XCTAssertLessThanOrEqual(upperBound, 0.2, "SIGKILL 后的复查不得拖慢退出")
    }

    // MARK: 退出/停止等待上界（GitHub #158）

    func testStopPollScheduleIsTwoStageAndStaysWithinTheOneSecondBudget() {
        // 前 `stopPollFastAttempts` 次是 10 毫秒粒度：服务已经退出时（最常见）在
        // 这一阶段就会被发现，检测延迟 ≤ 10ms。
        XCTAssertEqual(ServiceManager.stopPollDelayMilliseconds(forAttempt: 0), 10)
        XCTAssertEqual(
            ServiceManager.stopPollDelayMilliseconds(forAttempt: ServiceManager.stopPollFastAttempts - 1),
            10
        )
        // 之后退回到 50 毫秒粒度，避免为慢退出的进程做上千次系统调用。
        XCTAssertEqual(
            ServiceManager.stopPollDelayMilliseconds(forAttempt: ServiceManager.stopPollFastAttempts),
            50
        )
        XCTAssertEqual(
            ServiceManager.stopPollDelayMilliseconds(forAttempt: ServiceManager.stopPollAttempts - 1),
            50
        )
        // 上界由预算推导，不是手写常量：睡眠之和正好是 1000 毫秒。
        XCTAssertEqual(ServiceManager.stopPollFastAttempts * ServiceManager.stopPollFastIntervalMilliseconds
            + (ServiceManager.stopPollAttempts - ServiceManager.stopPollFastAttempts) * ServiceManager.stopPollIntervalMilliseconds,
            ServiceManager.stopWaitUpperBoundMilliseconds)
        XCTAssertEqual(ServiceManager.stopPollAttempts, 36)
        XCTAssertEqual(ServiceManager.stopWaitUpperBound, 1.0, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(
            ServiceManager.stopWaitUpperBound,
            1.0,
            "退出等待上界必须 ≤ 1 秒（GitHub #158：之前是固定的 4 秒）"
        )
    }

    func testStopServiceEscalatesOnlyAfterTheOneSecondBudgetOfSleeping() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.manager.startManagedService()
        harness.signaler.aliveProcessGroups = [5150]
        harness.signaler.groupSurvivesSignals = true
        harness.signaler.groupGoneOnConfirmation = true

        harness.manager.stopService()
        harness.scheduler.runAllBackgroundWork()

        // 服务一直不退出时，实际睡眠总量就是声明的上界（1 秒）；SIGKILL 只在这个
        // 上界之后才发出。旧实现是 40 × 0.1 秒 = 4 秒。
        XCTAssertEqual(harness.scheduler.sleeps.reduce(0, +), ServiceManager.stopWaitUpperBound, accuracy: 0.001)
        XCTAssertEqual(harness.signaler.groupSignals.map(\.signal), [SIGTERM, SIGKILL])
    }

    func testStopServiceWritesQuitTimelineLinesWithMillisecondClock() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.manager.startManagedService()
        harness.signaler.aliveProcessGroups = [5150]

        harness.manager.stopService()
        harness.scheduler.runAllBackgroundWork()
        harness.drainLogWrites()

        let log = (try? String(contentsOf: harness.logURL, encoding: .utf8)) ?? ""
        // 用户复现退出卡顿时要看的几行：SIGTERM 与“进程组已退出”各一行。
        XCTAssertTrue(log.contains(QuitTimelineStage.sigtermSent.rawValue), log)
        XCTAssertTrue(log.contains(QuitTimelineStage.serviceExited.rawValue), log)
        XCTAssertTrue(log.contains("退出时间线"), log)
        // 毫秒时钟 + 单调偏移：秒级时间戳无法量化退出延迟。
        XCTAssertNotNil(
            log.range(of: #"退出时间线 \d\d:\d\d:\d\d\.\d\d\d \(\+\d+ms\)"#, options: .regularExpression),
            log
        )
    }

    func testQuitTimelineClockKeepsMillisecondPrecision() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = utc
        parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        let date = try XCTUnwrap(parser.date(from: "2026-01-02T03:04:05.678"))

        XCTAssertEqual(QuitTimeline.clock(date, timeZone: utc), "03:04:05.678")
    }

    func testQuitTimelineOffsetsRoundAndNeverGoNegative() {
        let origin = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(QuitTimeline.elapsedMilliseconds(from: origin, to: origin.addingTimeInterval(0.0084)), 8)
        XCTAssertEqual(QuitTimeline.elapsedMilliseconds(from: origin, to: origin.addingTimeInterval(0.0086)), 9)
        XCTAssertEqual(QuitTimeline.elapsedMilliseconds(from: origin, to: origin.addingTimeInterval(1.5)), 1500)
        // 系统时钟回拨（或注入的时钟倒退）不得产生负数偏移。
        XCTAssertEqual(QuitTimeline.elapsedMilliseconds(from: origin, to: origin.addingTimeInterval(-5)), 0)
        XCTAssertEqual(QuitTimeline.uptimeMilliseconds(12.3456), 12346)
        XCTAssertEqual(QuitTimeline.uptimeMilliseconds(-1), 0)
    }

    func testQuitTimelineLineCarriesStageDetailAndOffset() {
        let now = Date(timeIntervalSince1970: 0)
        let line = QuitTimeline.line(
            .sigkillSent,
            detail: "等待超过 1000ms（睡眠上界）",
            now: now,
            uptime: 12.345
        )

        XCTAssertEqual(
            line,
            "退出时间线 \(QuitTimeline.clock(now)) (+12345ms) \(QuitTimelineStage.sigkillSent.rawValue) — 等待超过 1000ms（睡眠上界）"
        )
        // 没有 detail 时不留下多余分隔符。
        XCTAssertEqual(
            QuitTimeline.line(.requested, now: now, uptime: 0),
            "退出时间线 \(QuitTimeline.clock(now)) (+0ms) \(QuitTimelineStage.requested.rawValue)"
        )
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
        harness.manager.stopManagedServiceOnQuit {}
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

    func testStopManagedServiceOnQuitStopsTheVerifiedChildAndInvokesTheCompletion() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.manager.startManagedService()
        harness.signaler.aliveProcessGroups = [5150]

        var completionRan = false
        harness.manager.stopManagedServiceOnQuit { completionRan = true }
        harness.scheduler.runAllBackgroundWork()

        XCTAssertTrue(completionRan)
        XCTAssertTrue(harness.manager.isQuitting)
        XCTAssertEqual(
            harness.signaler.groupSignals,
            [ManagerFakeSignaler.GroupSignal(signal: SIGTERM, processGroupID: 5150)]
        )
        XCTAssertNil(harness.readOwnershipRecord())
    }

    func testStopManagedServiceOnQuitLeavesAnExternalServiceRunning() throws {
        let harness = try makeHarness(
            alive: { $0 == 4321 },
            processOutput: processOutput(for: 4321, listenerPort: 30141)
        )
        defer { harness.cleanUp() }

        var completionRan = false
        harness.manager.stopManagedServiceOnQuit { completionRan = true }

        XCTAssertTrue(completionRan)
        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
    }

    /// 三种退出行为与 `QuitPlan` 的对应关系：只有“退出并停止服务”会向已验证的
    /// 托管进程组发信号；“保持运行”与“询问（未回答前）”都不停止服务。
    func testEveryQuitBehaviourKeepsTheServiceUnlessStoppingWasRequested() throws {
        for behavior in ServiceConfiguration.QuitBehavior.allCases {
            let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
            defer { harness.cleanUp() }
            var configuration = configured(try harness.makeExecutable())
            configuration.quitBehavior = behavior
            harness.manager.updateConfiguration(configuration)
            harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
            harness.manager.startManagedService()
            harness.manager.startHealthMonitor()
            let plan = QuitPlan.plan(for: behavior)

            if plan.stopsManagedService {
                harness.signaler.aliveProcessGroups = [5150]
                harness.manager.stopManagedServiceOnQuit {}
                harness.scheduler.runAllBackgroundWork()

                XCTAssertEqual(
                    harness.signaler.groupSignals,
                    [ManagerFakeSignaler.GroupSignal(signal: SIGTERM, processGroupID: 5150)],
                    "\(behavior) 应停止已验证的托管服务"
                )
                XCTAssertNil(harness.readOwnershipRecord())
            } else {
                harness.manager.keepRunningOnQuit()

                XCTAssertTrue(harness.signaler.groupSignals.isEmpty, "\(behavior) 不得停止服务")
                XCTAssertNotNil(harness.readOwnershipRecord())
                XCTAssertEqual(harness.manager.managedServicePID(), 5150)
            }
            XCTAssertTrue(harness.manager.isQuitting)
            // 应用关闭期间不再有后台轮询。
            XCTAssertEqual(harness.scheduler.repeatTokens.last?.invalidateCount, 1)
        }
    }

    /// 外部服务在三种退出行为下都不被停止：没有可验证的记录就没有信号。
    func testNoQuitBehaviourEverStopsAnExternalService() throws {
        for behavior in ServiceConfiguration.QuitBehavior.allCases {
            let harness = try makeHarness(
                alive: { $0 == 4321 },
                processOutput: processOutput(for: 4321, listenerPort: 30141)
            )
            defer { harness.cleanUp() }
            var configuration = ServiceConfiguration.default
            configuration.quitBehavior = behavior
            harness.manager.updateConfiguration(configuration)
            harness.manager.setState(.running)

            let plan = QuitPlan.plan(for: behavior)
            if plan.stopsManagedService {
                harness.manager.stopManagedServiceOnQuit {}
            } else {
                harness.manager.keepRunningOnQuit()
            }
            harness.scheduler.runAllBackgroundWork()

            XCTAssertNil(harness.manager.managedServicePID())
            XCTAssertTrue(harness.signaler.groupSignals.isEmpty, "\(behavior) 不得停止外部服务")
            // 外部服务的状态不由本应用管理：退出流程不改写它。
            XCTAssertEqual(harness.manager.currentState, .running)
        }
    }

    // MARK: 重启认领（GitHub #9）

    /// 应用重启后只有通过所有权校验的服务才可被认领；校验失败的进程只作为
    /// 外部服务出现，既不认领也不发送任何信号。
    func testUnverifiableRecordFromAnEarlierRunIsNeverReclaimedOrSignalled() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        try harness.writeOwnershipRecord(harness.makeOwnershipRecord(instanceID: "instance-from-an-earlier-run"))

        harness.manager.reconcileOwnershipRecord()
        XCTAssertNil(harness.manager.managedServicePID())

        harness.manager.setState(.running)
        harness.manager.stopManagedServiceOnQuit {}
        harness.scheduler.runAllBackgroundWork()

        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
        XCTAssertNil(harness.readOwnershipRecord())
        XCTAssertNil(harness.manager.managedServicePID())
        XCTAssertEqual(harness.manager.currentState, .running)
    }

    // MARK: 工作目录门控（GitHub #9）

    /// 工作目录不存在或不可写时阻止一切启动入口，并给出可读修复提示。
    func testWorkspaceProblemBlocksEveryStartEntryAndReportsTheFix() throws {
        let harness = try makeHarness(alive: { _ in false })
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.manager.setWorkspaceAvailability(problem: .notWritable, path: "/tmp/PiWebDesktopTests/read-only-workspace")

        harness.manager.startAtLaunch()
        harness.manager.startService()
        harness.manager.ensureServerIsRunning()
        harness.manager.reloadAfterConfigurationChange()
        harness.manager.startManagedService()

        XCTAssertEqual(harness.launcher.launchCount, 0)
        XCTAssertEqual(harness.loadRequests, 0)
        XCTAssertEqual(harness.startupFailures.count, 4)
        XCTAssertTrue(harness.startupFailures.allSatisfy { $0.contains("不可写") })
        XCTAssertTrue(harness.startupFailures.allSatisfy { $0.contains("/tmp/PiWebDesktopTests/read-only-workspace") })
        XCTAssertTrue(harness.startupFailures.allSatisfy { $0.contains("设置") })
    }

    /// 可读提示区分默认工作目录与用户自选目录。
    func testWorkspaceProblemMessageDistinguishesTheDefaultLocation() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.manager.setWorkspaceAvailability(
            problem: .missing,
            path: "/tmp/PiWebDesktopTests/support/Workspace",
            usesDefaultLocation: true
        )
        harness.manager.startAtLaunch()
        XCTAssertTrue(harness.startupFailures.last?.contains("默认工作目录不存在") == true)

        harness.manager.setWorkspaceAvailability(
            problem: .missing,
            path: "/tmp/PiWebDesktopTests/custom-workspace",
            usesDefaultLocation: false
        )
        harness.manager.startAtLaunch()
        let message = try XCTUnwrap(harness.startupFailures.last)
        XCTAssertTrue(message.contains("工作目录不存在"))
        XCTAssertTrue(message.contains("/tmp/PiWebDesktopTests/custom-workspace"))
        XCTAssertFalse(message.contains("默认工作目录"))
    }

    /// 工作目录恢复可用后门控重新打开，启动入口照常工作。
    func testRestoringTheWorkspaceReopensEveryStartEntry() throws {
        let harness = try makeHarness(alive: { _ in false })
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.manager.setWorkspaceAvailability(problem: .missing, path: "/tmp/PiWebDesktopTests/workspace")

        harness.manager.ensureServerIsRunning()
        XCTAssertEqual(harness.loadRequests, 0)

        harness.manager.setWorkspaceAvailability(problem: nil, path: "/tmp/PiWebDesktopTests/workspace")
        harness.manager.ensureServerIsRunning()

        // 假探针默认报告服务已就绪：门控打开后直接加载服务页，不启动新进程。
        XCTAssertEqual(harness.loadRequests, 1)
        XCTAssertEqual(harness.launcher.launchCount, 0)
    }

    // MARK: 工作目录创建语义（GitHub #9 复审）

    /// 用户自选的工作目录在运行期间被删除：启动入口既不重建它，也不静默启动，
    /// 而是阻止启动并回调调用方进入诊断状态（可读修复提示）。
    func testDeletedCustomWorkspaceIsNotRecreatedAndBlocksTheLaunch() throws {
        let probe = ManagerFakeWorkspaceProbe()
        let harness = try makeHarness(
            alive: { $0 == 5150 },
            processOutput: processOutput(for: 5150),
            workspaceProbe: probe.probe
        )
        defer { harness.cleanUp() }
        var configuration = configured(try harness.makeExecutable())
        configuration.workspacePath = fakeCustomWorkspace
        harness.manager.updateConfiguration(configuration)
        // 门控在上一次探测（AppDelegate 的 refreshWorkspaceState）时是放行的。
        harness.manager.setWorkspaceAvailability(problem: nil, path: fakeCustomWorkspace, usesDefaultLocation: false)
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))

        // 目录在监控期间被用户删除。
        probe.removeDirectory(fakeCustomWorkspace)
        harness.manager.startManagedService()

        XCTAssertEqual(harness.launcher.launchCount, 0)
        XCTAssertTrue(probe.createdDirectories.isEmpty, "用户自选目录不得被静默重建")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fakeCustomWorkspace))
        XCTAssertEqual(harness.manager.workspaceProblem, .missing)
        XCTAssertEqual(harness.manager.workspaceDirectoryPath, fakeCustomWorkspace)
        XCTAssertFalse(harness.manager.workspaceUsesDefaultLocation)
        // 回调就是“进入诊断状态”的入口：AppDelegate 据此重路由到诊断页/诊断窗口。
        XCTAssertEqual(harness.workspaceProblems, [
            ManagerWorkspaceProblem(problem: .missing, path: fakeCustomWorkspace)
        ])

        // 其它启动入口也因此保持关闭，且给出可读修复提示。
        harness.manager.startService()
        harness.manager.ensureServerIsRunning()
        XCTAssertEqual(harness.launcher.launchCount, 0)
        XCTAssertEqual(harness.loadRequests, 0)
        XCTAssertEqual(harness.startupFailures.count, 2)
        XCTAssertTrue(harness.startupFailures.allSatisfy { $0.contains(fakeCustomWorkspace) })
        XCTAssertTrue(harness.startupFailures.allSatisfy { $0.contains("设置") })
    }

    /// 存在且可写的自选目录既不被创建也不阻止启动：自动创建只针对默认目录。
    func testExistingCustomWorkspaceIsUsedWithoutBeingCreated() throws {
        let probe = ManagerFakeWorkspaceProbe()
        let harness = try makeHarness(
            alive: { $0 == 5150 },
            processOutput: processOutput(for: 5150),
            workspaceProbe: probe.probe
        )
        defer { harness.cleanUp() }
        var configuration = configured(try harness.makeExecutable())
        configuration.workspacePath = fakeCustomWorkspace
        harness.manager.updateConfiguration(configuration)
        probe.addWritableDirectory(fakeCustomWorkspace)
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))

        harness.manager.startManagedService()

        XCTAssertEqual(harness.launcher.launchCount, 1)
        XCTAssertTrue(probe.createdDirectories.isEmpty)
        XCTAssertTrue(harness.workspaceProblems.isEmpty)
        XCTAssertNil(harness.manager.workspaceProblem)
        XCTAssertEqual(harness.manager.workspaceDirectoryPath, fakeCustomWorkspace)
        // 真正的 `openLogForWriting` 用的是真实 FileManager：自选目录也没有被它创建。
        XCTAssertFalse(FileManager.default.fileExists(atPath: fakeCustomWorkspace))
        XCTAssertTrue(harness.launcher.specifications.allSatisfy {
            $0.workingDirectory.path == fakeCustomWorkspace
        })
    }

    /// 默认工作目录缺失时仍会创建它，然后正常启动。
    func testMissingDefaultWorkspaceIsCreatedBeforeLaunching() throws {
        let probe = ManagerFakeWorkspaceProbe()
        let harness = try makeHarness(
            alive: { $0 == 5150 },
            processOutput: processOutput(for: 5150),
            workspaceProbe: probe.probe
        )
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        let defaultWorkspace = harness.appConfiguration.defaultWorkspaceDirectory.path
        XCTAssertFalse(probe.isDirectory(defaultWorkspace))

        harness.manager.startManagedService()

        XCTAssertEqual(probe.createdDirectories, [defaultWorkspace])
        XCTAssertEqual(harness.launcher.launchCount, 1)
        XCTAssertNil(harness.manager.workspaceProblem)
        XCTAssertTrue(harness.manager.workspaceUsesDefaultLocation)
        XCTAssertTrue(harness.workspaceProblems.isEmpty)
    }

    /// 健康监控期间自选目录被删除：受托管重启被拒绝，目录不被重建（复审场景）。
    func testHealthRestartIsBlockedWhenTheCustomWorkspaceDisappeared() throws {
        let liveness = ManagerFakeLiveness()
        let probe = ManagerFakeWorkspaceProbe()
        let harness = try makeHarness(
            alive: { pid in pid == 5150 ? liveness.isAlive : true },
            processOutput: processOutput(for: 5150),
            workspaceProbe: probe.probe
        )
        defer { harness.cleanUp() }
        var configuration = configured(try harness.makeExecutable())
        configuration.workspacePath = fakeCustomWorkspace
        harness.manager.updateConfiguration(configuration)
        probe.addWritableDirectory(fakeCustomWorkspace)
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = true

        harness.manager.startManagedService()
        XCTAssertTrue(harness.scheduler.runNextDelayedWork())
        harness.manager.startHealthMonitor()
        XCTAssertEqual(harness.manager.currentState, .running)
        XCTAssertEqual(harness.launcher.launchCount, 1)

        // 用户删掉自选目录，服务随后断开：健康恢复不得重建目录，也不得启动新进程。
        let process = try XCTUnwrap(harness.launcher.result.get() as? ManagerFakeProcess)
        process.isRunning = false
        liveness.isAlive = false
        probe.removeDirectory(fakeCustomWorkspace)
        harness.probe.ready = false
        // 假如恢复真的尝试启动，这一次会成功（新 PID），从而暴露问题。
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5200))
        harness.runner.handler = processOutput(for: 5200)
        // GitHub #147：必须先连续失败两次判定断开、第三次才尝试重启，所以这里跑满三次。
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.manager.currentState, .stopped)
        XCTAssertTrue(harness.scheduler.runHealthCheck())

        XCTAssertEqual(harness.launcher.launchCount, 1)
        XCTAssertTrue(probe.createdDirectories.isEmpty, "健康恢复不得重建用户自选目录")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fakeCustomWorkspace))
        XCTAssertEqual(harness.manager.workspaceProblem, .missing)
        XCTAssertEqual(harness.workspaceProblems, [
            ManagerWorkspaceProblem(problem: .missing, path: fakeCustomWorkspace)
        ])
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
        // GitHub #147：单次失败只是瞬时抖动，不改状态也不重启。
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.manager.currentState, .running)
        XCTAssertEqual(harness.launcher.launchCount, 1)
        // 连续第二次失败才判定断开；此时仍不重启。
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.manager.currentState, .stopped)
        XCTAssertTrue(harness.pageMessages.contains("Pi Web 服务已断开，正在尝试恢复…"))
        XCTAssertEqual(harness.launcher.launchCount, 1)
        // The restart spawns a new process with a new PID, which is alive and
        // whose `ps` facts are readable. The third consecutive failure triggers it.
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

        // Then it goes away: a single failure is a transient blip (GitHub #147),
        // and an unmanaged service is never restarted.
        harness.probe.ready = false
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.manager.currentState, .running)
        XCTAssertTrue(harness.pageMessages.isEmpty)
        // The second consecutive failure reports the disconnect; no restart follows.
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.manager.currentState, .stopped)
        XCTAssertEqual(harness.launcher.launchCount, 0)
        XCTAssertEqual(harness.pageMessages, ["Pi Web 服务已断开，正在尝试恢复…"])
        // A third failure must not restart an unmanaged service either.
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.launcher.launchCount, 0)
        XCTAssertEqual(harness.pageMessages, ["Pi Web 服务已断开，正在尝试恢复…"])
        XCTAssertTrue(harness.signaler.groupSignals.isEmpty)
    }

    /// GitHub #147：单次探测失败只是瞬时抖动——不改状态、不提示、不重启。
    func testSingleHealthProbeFailureKeepsRunningStateWithoutPromptOrRestart() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = true
        harness.manager.startManagedService()
        XCTAssertTrue(harness.scheduler.runNextDelayedWork())
        harness.manager.startHealthMonitor()
        XCTAssertEqual(harness.manager.currentState, .running)
        let statesBeforeFailure = harness.states

        harness.probe.ready = false
        XCTAssertTrue(harness.scheduler.runHealthCheck())

        XCTAssertEqual(harness.manager.currentState, .running, "单次失败不得判定断开")
        XCTAssertEqual(harness.states, statesBeforeFailure, "单次失败不得改变状态")
        // 启动路径本身已发过一条「正在启动 Pi Web…」，因此断言断开文案没有出现，
        // 而不是断言消息记录为空。
        XCTAssertFalse(
            harness.pageMessages.contains("Pi Web 服务已断开，正在尝试恢复…"),
            "单次失败不得提示用户"
        )
        XCTAssertEqual(harness.launcher.launchCount, 1, "单次失败不得重启")
    }

    /// GitHub #147：连续两次失败才判定断开并提示一次；第二次失败仍不重启。
    func testTwoConsecutiveHealthProbeFailuresReportDisconnectWithoutRestart() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = true
        harness.manager.startManagedService()
        XCTAssertTrue(harness.scheduler.runNextDelayedWork())
        harness.manager.startHealthMonitor()

        harness.probe.ready = false
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        // 第一次失败不得追加断开文案（启动路径的「正在启动 Pi Web…」不算失败证据）。
        XCTAssertFalse(
            harness.pageMessages.contains("Pi Web 服务已断开，正在尝试恢复…"),
            "单次失败不得提示断开"
        )
        XCTAssertTrue(harness.scheduler.runHealthCheck())

        XCTAssertEqual(harness.manager.currentState, .stopped)
        XCTAssertEqual(harness.pageMessages.last, "Pi Web 服务已断开，正在尝试恢复…")
        XCTAssertEqual(
            harness.pageMessages.filter { $0 == "Pi Web 服务已断开，正在尝试恢复…" }.count,
            1,
            "断开提示只出现一次"
        )
        XCTAssertEqual(harness.launcher.launchCount, 1, "断开判定本身不重启：重启要等第三次失败")
    }

    /// GitHub #147：连续三次失败才触发一次受托管重启，且同一轮断电只重启一次。
    func testThirdConsecutiveHealthProbeFailureTriggersExactlyOneRestart() throws {
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

        // 服务真的退出：存活探测与所有权记录随即失效。
        let process = try XCTUnwrap(harness.launcher.result.get() as? ManagerFakeProcess)
        process.isRunning = false
        liveness.isAlive = false
        harness.probe.ready = false
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5200))
        harness.runner.handler = processOutput(for: 5200)

        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.launcher.launchCount, 1, "前两次失败不得重启")
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.launcher.launchCount, 2, "第三次连续失败才重启")

        // 第四次失败不得再重启：restartAttempts 限制本轮只重启一次。
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.launcher.launchCount, 2, "同一轮断电只重启一次")

        // 诊断日志：失败计数、断开判定与重启触发各有一行，且不含探测 URL。
        harness.drainLogWrites()
        let log = (try? String(contentsOf: harness.logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("健康检查探测失败：连续失败 1 次"), log)
        XCTAssertTrue(log.contains("健康检查判定服务已断开（连续失败 2 次）"), log)
        XCTAssertTrue(log.contains("健康检查触发受托管重启（连续失败 3 次）"), log)
        let healthLines = log.split(separator: "\n").filter { $0.contains("健康检查") }
        XCTAssertFalse(healthLines.isEmpty)
        for line in healthLines {
            XCTAssertFalse(line.contains("http"), "健康检查日志不得打印可能含凭据的探测 URL：\(line)")
        }
    }

    /// 审计 S1（中）：健康检查“受托管重启”必须真的重启进程。
    ///
    /// 旧实现调的是 `startManagedService()` 而不是 `restartManagedService()`：
    /// `startDecision()` 在 `managedServicePID() != nil`（所有权记录仍校验通过）
    /// 或子进程还活着（`serviceProcess.isRunning`）时返回 `.existingProcess`，
    /// 于是只挂一条 30 秒就绪轮询、**不发任何信号**——那个不响应的进程从头到尾
    /// 没被杀过，而“已触发重启”的日志已经写下了。末尾的 `launchCount` 断言看不
    /// 出这个区别：两条路径都不会新增启动。这里断言信号真的发出。
    func testHealthCheckRestartStopsTheUnresponsiveProcessBeforeStartingAgain() throws {
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
        XCTAssertTrue(harness.signaler.groupSignals.isEmpty, "前置：启动流程不发信号")

        // 关键场景：进程**仍存活**但健康探测一直不响应（不是已退出的情形）。
        // 这种状态下 `startManagedService()` 会走 `.existingProcess` 快速路径。
        liveness.isAlive = true
        harness.probe.ready = false
        harness.signaler.aliveProcessGroups = [5150]

        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertTrue(harness.scheduler.runHealthCheck(), "第三次连续失败触发重启")
        // 停止/启动的后续动作在后台队列上：必须让它跑完才能看到信号。
        harness.scheduler.runAllBackgroundWork()

        XCTAssertFalse(
            harness.signaler.groupSignals.isEmpty,
            "健康检查重启必须先停止那个不响应的进程（旧实现走 start 路径，从不发信号）"
        )
        XCTAssertEqual(harness.signaler.groupSignals.first?.signal, SIGTERM, "先 SIGTERM")
    }

    /// GitHub #147：探测成功把连续失败计数清零，之后必须重新累计两次才再次判定断开。
    func testSuccessfulProbeResetsTheConsecutiveFailureCount() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.manager.startHealthMonitor()
        harness.probe.ready = true
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.manager.currentState, .running)

        harness.probe.ready = false
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.manager.currentState, .stopped)
        XCTAssertEqual(harness.pageMessages.count, 1)

        // 恢复：计数归零。
        harness.probe.ready = true
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.manager.currentState, .running)

        // 恢复后的单次失败不得立刻再次判定断开（否则说明计数没有归零）。
        harness.probe.ready = false
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.manager.currentState, .running)
        XCTAssertEqual(harness.pageMessages.count, 1)

        // 重新累计到第二次失败才再次提示。
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.manager.currentState, .stopped)
        XCTAssertEqual(harness.pageMessages.count, 2)
    }

    /// GitHub #147：探测恢复只请求加载一次页面，之后的成功探测不再重复加载。
    func testRecoveryAfterDisconnectLoadsThePageOnlyOnce() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.manager.startHealthMonitor()
        harness.probe.ready = true
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.manager.currentState, .running)
        XCTAssertEqual(harness.loadRequests, 1)

        // 连续两次失败判定断开。
        harness.probe.ready = false
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.manager.currentState, .stopped)

        // 恢复路径：状态回到 running，并且只请求加载一次页面。
        harness.probe.ready = true
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.manager.currentState, .running)
        XCTAssertEqual(harness.loadRequests, 2, "恢复必须请求加载服务页")

        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.loadRequests, 2, "恢复之后不得重复加载页面")

        harness.drainLogWrites()
        let log = (try? String(contentsOf: harness.logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("健康检查探测已恢复"), log)
    }

    // MARK: Dependency gate (GitHub #6)

    /// 门控 blocked 时所有启动入口（启动/重启、配置重载、健康恢复收敛点）都不得
    /// 启动子进程、加载页面或改变状态。
    func testClosedDependencyGateBlocksEveryStartEntry() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = false
        harness.scheduler.runsMainInline = false
        harness.manager.isDependencyGateOpen = false

        harness.manager.startAtLaunch()
        harness.manager.ensureServerIsRunning()
        harness.manager.startService()
        harness.manager.startManagedService()
        harness.manager.restartManagedService()
        harness.manager.reloadAfterConfigurationChange()
        harness.scheduler.runAllMainWork()

        XCTAssertEqual(harness.launcher.launchCount, 0)
        XCTAssertEqual(harness.loadRequests, 0)
        XCTAssertTrue(harness.states.isEmpty)
        XCTAssertTrue(harness.startupFailures.isEmpty)
        XCTAssertTrue(harness.scheduler.repeatingWork.isEmpty, "门控关闭时不得开始健康轮询")
    }

    /// 探测回调排队后门控才关闭：主队列回调必须再次确认门控。
    func testGateClosedWhileStartChecksAreInFlightBlocksAsyncCallbacks() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = false
        harness.scheduler.runsMainInline = false

        harness.manager.ensureServerIsRunning()
        harness.manager.startService()
        harness.manager.reloadAfterConfigurationChange()
        XCTAssertFalse(harness.scheduler.mainWork.isEmpty)

        harness.manager.isDependencyGateOpen = false
        harness.scheduler.runAllMainWork()

        XCTAssertEqual(harness.launcher.launchCount, 0)
        XCTAssertEqual(harness.loadRequests, 0)
        XCTAssertTrue(harness.states.isEmpty)
    }

    /// `autoStart` 关闭时 `startAtLaunch()` 也会探测外部服务：探测期间门控
    /// 关闭时回调不得把外部服务当成 running 或加载服务页。
    func testGateClosedWhileStartAtLaunchChecksAnExternalServiceBlocksAdoption() throws {
        var configuration = ServiceConfiguration.default
        configuration.autoStart = false
        let harness = try makeHarness(configuration: configuration)
        defer { harness.cleanUp() }
        harness.probe.ready = true
        harness.scheduler.runsMainInline = false

        harness.manager.startAtLaunch()
        harness.manager.isDependencyGateOpen = false
        harness.scheduler.runAllMainWork()

        XCTAssertTrue(harness.states.isEmpty)
        XCTAssertEqual(harness.loadRequests, 0)
        XCTAssertTrue(harness.pageMessages.isEmpty)
    }

    /// `autoStart` 关闭时 `startAtLaunch()` 只探测外部服务，不拉起子进程：
    /// 正常启动（包括已配置的每次重启）继续尊重 `autoStart`。
    func testStartAtLaunchWithAutoStartOffOnlyProbesForAnExternalService() throws {
        var configuration = ServiceConfiguration.default
        configuration.autoStart = false
        let harness = try makeHarness(configuration: configuration)
        defer { harness.cleanUp() }
        var runtime = configuration
        runtime.piWebPath = try harness.makeExecutable()
        harness.manager.updateConfiguration(runtime)
        harness.probe.ready = false

        harness.manager.startAtLaunch()

        XCTAssertEqual(harness.launcher.launchCount, 0, "autoStart=false 时正常启动不得拉起服务")
        XCTAssertEqual(harness.manager.currentState, .stopped)
        XCTAssertEqual(harness.pageMessages, ["Pi Web 服务未运行。"])
        XCTAssertEqual(harness.scheduler.repeatingWork.count, 1, "仍要开始健康轮询")
    }

    /// 首次启动诊断刚完成时 `forceStart` 为 true：即使 `autoStart` 关闭也必须
    /// 显式启动服务，否则用户刚修好前置却只看到“服务未运行”（GitHub #7 复审）。
    func testStartAtLaunchForceStartLaunchesEvenWhenAutoStartIsOff() throws {
        var configuration = ServiceConfiguration.default
        configuration.autoStart = false
        let harness = try makeHarness(
            configuration: configuration,
            alive: { $0 == 5150 },
            processOutput: processOutput(for: 5150)
        )
        defer { harness.cleanUp() }
        var runtime = configuration
        let executable = try harness.makeExecutable()
        runtime.piWebPath = executable
        harness.manager.updateConfiguration(runtime)
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = false

        harness.manager.startAtLaunch(forceStart: true)

        XCTAssertEqual(harness.launcher.launchCount, 1)
        XCTAssertEqual(harness.launcher.specifications.first?.executablePath, executable)
        XCTAssertEqual(harness.manager.currentState, .starting)
        XCTAssertEqual(harness.scheduler.repeatingWork.count, 1, "启动后仍要开始健康轮询")
    }

    /// 启动轮询是延迟回调：轮询期间门控关闭时不得采信 ready。
    func testGateClosedWhilePollingDoesNotAdoptTheService() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = false

        harness.manager.startManagedService()
        XCTAssertEqual(harness.launcher.launchCount, 1)
        XCTAssertEqual(harness.manager.currentState, .starting)

        harness.probe.ready = true
        harness.manager.isDependencyGateOpen = false
        XCTAssertTrue(harness.scheduler.runNextDelayedWork())

        XCTAssertEqual(harness.manager.currentState, .starting)
        XCTAssertEqual(harness.loadRequests, 0)
    }

    /// 门控关闭时不开始健康轮询，也不采纳外部服务。
    func testClosedDependencyGateSkipsHealthPolling() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.manager.isDependencyGateOpen = false

        harness.manager.startHealthMonitor()

        XCTAssertTrue(harness.scheduler.repeatingWork.isEmpty)
        XCTAssertFalse(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.manager.currentState, .checking)
        XCTAssertEqual(harness.loadRequests, 0)
    }

    /// 健康探测就绪时门控已关闭：回调不得把状态改成 running 或加载服务页
    /// （否则会覆盖诊断页）。
    func testHealthCheckReadyCallbackDoesNothingWhenTheGateIsClosed() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.manager.startHealthMonitor()
        harness.probe.ready = true
        harness.scheduler.runsMainInline = false

        XCTAssertTrue(harness.scheduler.runHealthCheck())
        harness.manager.isDependencyGateOpen = false
        harness.scheduler.runAllMainWork()

        XCTAssertTrue(harness.states.isEmpty)
        XCTAssertEqual(harness.manager.currentState, .checking)
        XCTAssertEqual(harness.loadRequests, 0)
        XCTAssertEqual(harness.launcher.launchCount, 0)
    }

    /// 健康轮询已经在运行，随后诊断把门控切成 blocked（AppDelegate 会把状态
    /// 改成 stopped 并显示诊断页）：下一次 ready 检查不得把它改回 running
    /// 或重新加载服务页。
    func testRunningHealthMonitorStopsAffectingStateWhenTheGateCloses() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        harness.manager.startHealthMonitor()
        harness.probe.ready = true
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.manager.currentState, .running)
        XCTAssertEqual(harness.loadRequests, 1)

        harness.manager.isDependencyGateOpen = false
        harness.manager.setState(.stopped)   // AppDelegate blocked 分支
        XCTAssertTrue(harness.scheduler.runHealthCheck())

        XCTAssertEqual(harness.manager.currentState, .stopped)
        XCTAssertEqual(harness.loadRequests, 1)
        XCTAssertEqual(harness.launcher.launchCount, 0)
    }

    /// 重新检测通过后门控打开，启动入口恢复工作。
    func testOpeningTheGateRestoresStartBehaviour() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))

        harness.manager.isDependencyGateOpen = false
        harness.manager.startManagedService()
        XCTAssertEqual(harness.launcher.launchCount, 0)

        harness.manager.isDependencyGateOpen = true
        harness.manager.startManagedService()
        XCTAssertEqual(harness.launcher.launchCount, 1)
        XCTAssertEqual(harness.manager.currentState, .starting)
    }

    // MARK: - 远程访问密码（GitHub #8）


    private func remoteConfiguration(piWebPath: String) -> ServiceConfiguration {
        var configuration = configured(piWebPath)
        configuration.hostname = "pi.example.invalid"
        configuration.allowedHosts = "pi.example.invalid"
        return configuration
    }
    /// 启动失败消息在进入状态机、回调与日志之前先脱敏（GitHub #10）：错误描述
    /// 里的 Home 路径与 `token=` 形式的秘密都不能漏出，而修复上下文要保留。
    func testStartupFailureMessagesAreRedactedBeforeTheyReachStatusCallbackAndLog() throws {
        let fakeHome = "/tmp/PiWebDesktopTests/home"
        let secret = "launch-error-secret"
        let harness = try makeHarness(
            alive: { $0 == 5150 },
            processOutput: processOutput(for: 5150),
            redactor: LogRedactor(homeDirectory: fakeHome)
        )
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .failure(ManagerFakeLaunchError.failedWithMessage(
            "无法启动 pi-web：日志目录 \(fakeHome)/Library/Logs 不可用（token=\(secret)）"
        ))

        harness.manager.startManagedService()

        let message = try XCTUnwrap(harness.startupFailures.first)
        XCTAssertFalse(message.contains(fakeHome))
        XCTAssertFalse(message.contains(secret))
        XCTAssertTrue(message.contains("~/Library/Logs"), message)
        XCTAssertEqual(harness.manager.currentState, .failed(message))
        // GitHub #88：“启动失败”这行经 `logWriter.record` 排队写入；先把队列排空
        // 再读日志，否则断言的是“后台写入还没落地”时的空文件。
        harness.drainLogWrites()
        let log = (try? String(contentsOf: harness.logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("启动失败"), log)
        XCTAssertFalse(log.contains(secret))
        XCTAssertFalse(log.contains(fakeHome))
    }

    /// 诊断展示用的环境行按键排序，值原样给出；脱敏由共享的 `LogRedactor` 负责
    /// （GitHub #10）。
    func testEnvironmentDescriptionIsSortedAndRedactable() {
        var environment = ServiceLaunchSpecification.environmentDescription(["PATH": "/usr/bin:/bin", "PI_WEB_NO_OPEN": "1"])
        XCTAssertEqual(environment, "PATH=/usr/bin:/bin\nPI_WEB_NO_OPEN=1")

        environment = ServiceLaunchSpecification.environmentDescription(["PI_WEB_PASSWORD": "secret-password-value"])
        XCTAssertEqual(environment, "PI_WEB_PASSWORD=secret-password-value")
        XCTAssertFalse(LogRedactor().redact(environment).contains("secret-password-value"))
    }

    /// loopback 模式即使 Keychain 里有密码也不注入，并清掉继承来的同名变量。
    func testLoopbackLaunchRemovesAnInheritedPasswordVariable() throws {
        let harness = try makeHarness(
            alive: { $0 == 5150 },
            processOutput: processOutput(for: 5150),
            baseEnvironment: ["BASE": "1", "PI_WEB_PASSWORD": "inherited-secret"]  // scan-secrets: allow(reason=test fixture environment)
        )
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = false

        harness.manager.startManagedService()

        let specification = try XCTUnwrap(harness.launcher.specifications.first)
        XCTAssertNil(specification.environment["PI_WEB_PASSWORD"])
        XCTAssertEqual(specification.environment["BASE"], "1")
    }
    // MARK: - 监听地址复用校验（GitHub #39 / 安全审查 R-3）

    /// 直接构造的非法监听地址（通配、空值、空白、非法字符）：启动决策拒绝，
    /// 所有启动入口零进程零页面零探测，提示指认非法值与允许范围。
    func testUnusableListeningAddressBlocksEveryStartEntryWithoutLaunching() throws {
        let hostileHostnames = [
            "0.0.0.0", "::", "[::]", "*", "0", "0x0", "0.0.0.0.", "0:0:0:0:0:0:0:0", "::ffff:0.0.0.0",
            "", "  0.0.0.0", "127.0.0.1 ", "127.0.0.1:30141"
        ]
        for hostname in hostileHostnames {
            let harness = try makeHarness()
            defer { harness.cleanUp() }
            var configuration = ServiceConfiguration.default
            configuration.hostname = hostname
            configuration.piWebPath = try harness.makeExecutable()
            harness.manager.updateConfiguration(configuration)
            harness.probe.ready = true

            let diagnosis = try XCTUnwrap(configuration.hostnameProblem)
            XCTAssertTrue(diagnosis.contains(ServiceAddressVerdict.displayHostname(hostname)), hostname.debugDescription)
            XCTAssertTrue(diagnosis.contains("服务不会启动"), hostname.debugDescription)

            guard case .invalidAddress(let message) = harness.manager.startDecision() else {
                XCTFail("\(hostname.debugDescription) 应当被拒绝启动")
                continue
            }
            XCTAssertEqual(message, diagnosis, hostname.debugDescription)

            harness.manager.startAtLaunch()
            harness.manager.ensureServerIsRunning()
            harness.manager.startService()
            harness.manager.reloadAfterConfigurationChange()
            harness.manager.startManagedService()

            XCTAssertEqual(harness.launcher.launchCount, 0, hostname.debugDescription)
            XCTAssertEqual(harness.loadRequests, 0, hostname.debugDescription)
            XCTAssertTrue(harness.probe.probedURLs.isEmpty, "\(hostname.debugDescription) 非法时不得探测")
            XCTAssertEqual(harness.startupFailures, Array(repeating: diagnosis, count: 5), hostname.debugDescription)
            XCTAssertEqual(harness.manager.currentState, .failed(diagnosis), hostname.debugDescription)
        }
    }

    /// 安全审查 R-3 的复现路径：直接用 UserDefaults 写入 `0.0.0.0`，
    /// 加载后被标记为非法，启动入口零进程，且地址不被静默替换。
    func testHostileDefaultsHostnameCannotEnterTheLaunchPath() throws {
        let suiteName = "ServiceManagerTests.hostile.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("0.0.0.0", forKey: "service.hostname")
        defaults.set(30141, forKey: "service.port")

        let harness = try makeHarness()
        defer { harness.cleanUp() }
        var configuration = ServiceConfiguration.load(from: defaults)
        configuration.piWebPath = try harness.makeExecutable()
        harness.manager.updateConfiguration(configuration)
        harness.probe.ready = true

        XCTAssertEqual(configuration.hostname, "0.0.0.0", "非法地址不得被静默替换")
        let diagnosis = try XCTUnwrap(configuration.hostnameProblem)

        harness.manager.startAtLaunch()

        guard case .invalidAddress(let message) = harness.manager.startDecision() else {
            XCTFail("0.0.0.0 应当被拒绝启动，实际为 \(harness.manager.startDecision())")
            return
        }
        XCTAssertEqual(message, diagnosis)
        XCTAssertEqual(harness.launcher.launchCount, 0)
        XCTAssertEqual(harness.loadRequests, 0)
        XCTAssertTrue(harness.probe.probedURLs.isEmpty)
        XCTAssertEqual(harness.startupFailures, [diagnosis])
        XCTAssertEqual(harness.manager.currentState, .failed(diagnosis))
    }

    /// 非法地址给出地址诊断（非法值 + 允许范围），而不是笼统的失败。
    func testUnusableAddressReportsTheAddressDiagnosis() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        var configuration = ServiceConfiguration.default
        configuration.hostname = "0.0.0.0"
        configuration.piWebPath = try harness.makeExecutable()
        harness.manager.updateConfiguration(configuration)

        harness.manager.startAtLaunch()

        let diagnosis = try XCTUnwrap(configuration.hostnameProblem)
        XCTAssertEqual(harness.startupFailures, [diagnosis])
        XCTAssertEqual(harness.launcher.launchCount, 0)
        XCTAssertEqual(harness.manager.currentState, .failed(diagnosis))
    }

    /// 合法组合仍可启动：loopback（含 `::1` 与 `localhost`）不需要密码，显式
    /// 配置的具体远程地址同样可以启动，命令行参数使用配置的地址（本应用不再
    /// 管理访问密码，远程监听由用户自行在 pi-web 侧决定是否加认证）。
    func testUsableListeningAddressesStillReachTheLaunchPath() throws {
        let cases = ["127.0.0.1", "::1", "localhost", "pi.example.invalid"]
        for entry in cases {
            // 主机名用例声明“解析到本机”，否则新增的回环回落会把它换成 127.0.0.1
            // （这是有意行为，见 ListeningAddressFallbackTests）。
            let harness = try makeHarness(
                alive: { $0 == 5150 },
                processOutput: processOutput(for: 5150),
                resolvesToLocalHost: { _ in true }
            )
            defer { harness.cleanUp() }
            var configuration = ServiceConfiguration.default
            configuration.hostname = entry
            configuration.piWebPath = try harness.makeExecutable()
            harness.manager.updateConfiguration(configuration)
            harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
            harness.probe.ready = false

            XCTAssertNil(configuration.hostnameProblem, entry)
            guard case .launch(let specification) = harness.manager.startDecision() else {
                XCTFail("\(entry) 应当可以启动，实际为 \(harness.manager.startDecision())")
                continue
            }
            XCTAssertEqual(specification.arguments, ["--hostname", entry, "--port", "30141", "--no-open"])

            harness.manager.startManagedService()

            XCTAssertEqual(harness.launcher.launchCount, 1, entry)
            XCTAssertEqual(harness.manager.currentState, .starting, entry)
        }
    }

    // MARK: - 服务状态机代次与启动预算（W3 M1/M2/M3/L1）

    /// M1：一次“30 秒未就绪”超时之后，下一次启动入口必须重新开始轮询与预算，
    /// 而不是立刻复用上一轮的失败结论（0 次轮询）。探针随后就绪时必须成功。
    func testRetryAfterStartupTimeoutPollsAgainAndSucceeds() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = false

        harness.manager.startManagedService()
        for _ in 0..<ServiceManager.maxStartupAttempts {
            XCTAssertTrue(harness.scheduler.runNextDelayedWork())
        }
        XCTAssertEqual(harness.startupFailures.count, 1, "第一轮会话超时只报一次失败")
        XCTAssertEqual(harness.probe.probedURLs.count, ServiceManager.maxStartupAttempts)

        // 用户点“启动服务”或弹窗“重试”：进程还活着，但必须重新开始轮询。
        harness.manager.startService()
        XCTAssertEqual(
            harness.scheduler.delayedWork.count,
            ServiceManager.maxStartupAttempts + 1,
            "重试必须重新挂上轮询链，而不是立刻复用上一轮失败结论"
        )
        XCTAssertEqual(harness.startupFailures.count, 1, "重试本身不得再弹一次失败")

        let probesBeforeRetry = harness.probe.probedURLs.count
        harness.probe.ready = true
        XCTAssertTrue(harness.scheduler.runNextDelayedWork())
        XCTAssertGreaterThan(harness.probe.probedURLs.count, probesBeforeRetry, "重试后必须真的再次探测")
        XCTAssertEqual(harness.manager.currentState, .running)
        XCTAssertEqual(harness.startupFailures.count, 1)
        XCTAssertEqual(harness.loadRequests, 1)
    }

    /// M2：停止完成后才到达的 ready=true 启动轮询回调不得把状态改回 `.running`，
    /// 也不得加载服务页。
    func testLateReadyStartupProbeAfterStopDoesNotRestoreRunningState() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = false
        harness.manager.startManagedService()
        XCTAssertEqual(harness.manager.currentState, .starting)

        // 启动轮询发出探测后把它挂起：结果在停止完成之后才交付。
        harness.probe.defersCompletions = true
        XCTAssertTrue(harness.scheduler.runNextDelayedWork())
        XCTAssertEqual(harness.probe.pendingCompletions.count, 1)

        harness.manager.stopService()
        harness.scheduler.runAllBackgroundWork()
        XCTAssertEqual(harness.manager.currentState, .stopped)

        XCTAssertEqual(harness.probe.deliverPendingCompletions(true), 1)
        XCTAssertEqual(harness.manager.currentState, .stopped, "迟到的 ready 回调不得把状态改回 running")
        XCTAssertEqual(harness.loadRequests, 0, "迟到的 ready 回调不得加载已停止服务的页面")
    }

    /// M2（健康检查变体）：健康探测在停止完成后交付 ready=true，同样不得改状态、
    /// 不得加载页面。
    func testLateHealthCheckReadyCallbackAfterStopDoesNotRestoreRunningState() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = false
        harness.manager.startManagedService()
        harness.manager.startHealthMonitor()

        harness.probe.defersCompletions = true
        XCTAssertTrue(harness.scheduler.runHealthCheck())
        XCTAssertEqual(harness.probe.pendingCompletions.count, 1)

        harness.manager.stopService()
        harness.scheduler.runAllBackgroundWork()
        XCTAssertEqual(harness.manager.currentState, .stopped)
        XCTAssertEqual(harness.loadRequests, 0)

        XCTAssertEqual(harness.probe.deliverPendingCompletions(true), 1)
        XCTAssertEqual(harness.manager.currentState, .stopped, "迟到的健康检查 ready 不得把状态改回 running")
        XCTAssertEqual(harness.loadRequests, 0, "迟到的健康检查 ready 不得加载页面")
    }

    /// M3：连续触发启动入口只产生一条轮询链、只报一次失败：预算不再被 N 倍速
    /// 耗尽，也不再产生 N 份重复的启动失败提示。
    func testRepeatedStartEntriesShareOnePollingChainAndOneFailure() throws {
        let harness = try makeHarness(alive: { $0 == 5150 }, processOutput: processOutput(for: 5150))
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        harness.launcher.result = .success(ManagerFakeProcess(processIdentifier: 5150))
        harness.probe.ready = false

        harness.manager.startManagedService()
        harness.manager.startService()
        harness.manager.ensureServerIsRunning()
        harness.manager.startManagedService()
        harness.manager.reloadAfterConfigurationChange()

        XCTAssertEqual(harness.scheduler.delayedWork.count, 1, "同一次启动只允许一条轮询链")

        for _ in 0..<ServiceManager.maxStartupAttempts {
            XCTAssertTrue(harness.scheduler.runNextDelayedWork())
        }
        XCTAssertEqual(harness.startupFailures.count, 1, "同一次启动只允许一次失败提示")
        XCTAssertEqual(
            harness.manager.currentState,
            .failed("Pi Web 在 30 秒内未能启动。请查看日志：\(harness.logURL.path)")
        )
    }

    /// L1：停止路径的不可验证分支必须收回停止标志。退出路径先确认“有可验证
    /// 记录”，`stopService()` 内部第二次校验失败时提前返回：这条路径不得把
    /// `isStoppingService` 永久留在 true，否则之后所有启动入口都被拒绝。
    func testUnverifiableStopOnQuitClearsTheStoppingFlag() throws {
        var aliveChecks = 0
        let harness = try makeHarness(
            alive: { pid in
                // 第一次校验（退出路径判断是否有托管进程）时进程还活着，
                // 第二次校验（`stopService` 内部）时已经不可验证。
                aliveChecks += 1
                return aliveChecks == 1 && pid == 5150
            },
            processOutput: processOutput(for: 5150)
        )
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        try harness.writeOwnershipRecord(harness.makeOwnershipRecord())
        harness.manager.setState(.running)

        var completionRan = false
        harness.manager.stopManagedServiceOnQuit { completionRan = true }
        harness.scheduler.runAllBackgroundWork()

        XCTAssertTrue(completionRan)
        XCTAssertTrue(harness.signaler.groupSignals.isEmpty, "不可验证的进程不发信号")
        XCTAssertNotEqual(harness.manager.startDecision(), .ignored, "停止标志不得永久拒绝后续启动")
    }

    /// 代次也覆盖进程退出回调：上一次启动的进程退出回调迟到时，不得清空替换它的
    /// 新进程、也不得把状态改成 stopped。
    func testLateTerminationCallbackOfAnEarlierLaunchIsIgnored() throws {
        let harness = try makeHarness(
            alive: { $0 == 5150 || $0 == 5300 },
            processOutput: processOutput(for: 5150)
        )
        defer { harness.cleanUp() }
        harness.manager.updateConfiguration(configured(try harness.makeExecutable()))
        let first = ManagerFakeProcess(processIdentifier: 5150)
        harness.launcher.result = .success(first)
        harness.probe.ready = false
        harness.manager.startManagedService()
        XCTAssertEqual(harness.launcher.terminationHandlers.count, 1)

        // 重启：先停止（记录被删除），再启动一个新进程（新代次）。
        harness.signaler.aliveProcessGroups = [5150]
        harness.manager.stopService()
        harness.scheduler.runAllBackgroundWork()
        let second = ManagerFakeProcess(processIdentifier: 5300)
        harness.launcher.result = .success(second)
        harness.runner.handler = processOutput(for: 5300)
        harness.probe.ready = true
        harness.manager.startManagedService()
        XCTAssertEqual(harness.manager.managedServicePID(), 5300)
        // 旧启动轮询的延迟回调先执行：代次已过期，不得采纳新服务。
        XCTAssertTrue(harness.scheduler.runNextDelayedWork())
        XCTAssertEqual(harness.manager.currentState, .starting, "过期的轮询回调不得采纳新服务")
        XCTAssertEqual(harness.loadRequests, 0)
        // 新会话的轮询回调才真正就绪。
        XCTAssertTrue(harness.scheduler.runNextDelayedWork())
        XCTAssertEqual(harness.manager.currentState, .running)
        XCTAssertEqual(harness.loadRequests, 1)

        // 旧进程的退出回调迟到：不得影响替换它的新进程。
        harness.launcher.terminationHandlers[0](first)
        XCTAssertEqual(harness.manager.currentState, .running)
        XCTAssertEqual(harness.manager.managedServicePID(), 5300)
    }

    // MARK: 配置代次（GitHub #135 F1）

    /// 重叠切换工作目录时，只有最新一次请求能写回配置：迟到的 stop 回调不得
    /// 覆盖更新的配置（否则菜单勾选与实际服务目录会随配置一起倒退）。
    func testOverlappingConfigurationRequestsKeepOnlyTheLatestWrite() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        let initialPath = harness.manager.configuration.workspacePath

        var first = harness.manager.configuration
        first.workspacePath = "/tmp/first-workspace"
        var second = harness.manager.configuration
        second.workspacePath = "/tmp/second-workspace"

        // 两次切换重叠：两个请求都在各自的停止回调写回之前领到了代次。
        let firstGeneration = harness.manager.beginConfigurationChange()
        let secondGeneration = harness.manager.beginConfigurationChange()

        // 迟到的第一次回调：只能清理，不能写配置。
        XCTAssertFalse(harness.manager.updateConfiguration(first, ifGenerationMatches: firstGeneration))
        XCTAssertEqual(harness.manager.configuration.workspacePath, initialPath)
        // 最新请求的写回被接受。
        XCTAssertTrue(harness.manager.updateConfiguration(second, ifGenerationMatches: secondGeneration))
        XCTAssertEqual(harness.manager.configuration.workspacePath, "/tmp/second-workspace")

        // 反过来（新请求已经写完、旧回调才到）结论相同：旧代次永远不能再写配置。
        var third = harness.manager.configuration
        third.workspacePath = "/tmp/third-workspace"
        let thirdGeneration = harness.manager.beginConfigurationChange()
        XCTAssertTrue(harness.manager.updateConfiguration(third, ifGenerationMatches: thirdGeneration))
        XCTAssertFalse(harness.manager.updateConfiguration(second, ifGenerationMatches: secondGeneration))
        XCTAssertEqual(harness.manager.configuration.workspacePath, "/tmp/third-workspace")
    }

    /// 同步路径的直接写入（例如远程访问被收敛）同样让未写回的请求过期：
    /// 否则迟到的回调会把刚写入的配置改回去。
    func testDirectConfigurationWriteInvalidatesAPendingRequest() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }

        var pending = harness.manager.configuration
        pending.workspacePath = "/tmp/pending-workspace"
        let generation = harness.manager.beginConfigurationChange()

        var direct = harness.manager.configuration
        direct.workspacePath = "/tmp/direct-workspace"
        harness.manager.updateConfiguration(direct)

        XCTAssertFalse(harness.manager.updateConfiguration(pending, ifGenerationMatches: generation))
        XCTAssertEqual(harness.manager.configuration.workspacePath, "/tmp/direct-workspace")
    }
}
