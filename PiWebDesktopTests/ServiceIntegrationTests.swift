import Darwin
import Foundation
import XCTest

// MARK: - 本地 HTTP 测试服务器

/// 只监听 `127.0.0.1` 的极简 HTTP 服务器，供服务集成测试使用。
///
/// 它把每个请求计数后返回 `200 OK`，因此测试可以用生产的
/// `URLSessionServiceProbe` 做真实健康检查，而不接触任何外部主机。服务器只做
/// `accept`/`recv`/`send`，不解析请求内容；`stop()` 通过一个一次性 loopback 连接
/// 唤醒阻塞中的 `accept`，并等待监听描述符关闭，使端口在测试结束时立即释放。
private final class IntegrationHTTPServer {
    enum ServerError: Error, Equatable {
        case socketUnavailable(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case nameUnavailable(Int32)
        case readinessTimeout
    }

    private let listener: Int32
    private let queue = DispatchQueue(label: "PiWebDesktopTests.IntegrationHTTPServer")
    private let lock = NSLock()
    private let stoppedSemaphore = DispatchSemaphore(value: 0)
    private var running = true
    private var ready = false
    private var stopRequested = false
    private var requests = 0

    let port: Int

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ServerError.socketUnavailable(errno) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw ServerError.bindFailed(code)
        }
        guard listen(descriptor, 8) == 0 else {
            let code = errno
            close(descriptor)
            throw ServerError.listenFailed(code)
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &length)
            }
        }
        guard named == 0 else {
            let code = errno
            close(descriptor)
            throw ServerError.nameUnavailable(code)
        }

        listener = descriptor
        port = Int(UInt16(bigEndian: actual.sin_port))
        queue.async { [weak self] in self?.acceptLoop() }
    }

    /// 已完成处理的请求数；健康检查成功时至少为 1。
    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// accept 循环是否已经开始。
    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    /// 有界等待 accept 循环就绪。`listen(2)` 在 `init` 里就已完成，即使循环还没
    /// 拿到 CPU，内核也会把连接放进 backlog；显式等待是把“服务器可用”变成测试的
    /// 前置条件，而不是依赖调度顺序（CI 上出现过 connection refused 抖动）。
    func waitUntilReady(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isReady { return true }
            usleep(20_000)
        }
        return isReady
    }

    /// 关闭监听并等待 accept 循环退出，保证测试之间不留下占用端口的线程。
    func stop() {
        lock.lock()
        if stopRequested {
            lock.unlock()
            return
        }
        stopRequested = true
        running = false
        lock.unlock()

        wakeAcceptLoop()
        _ = stoppedSemaphore.wait(timeout: .now() + 5)
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// 一次 loopback 连接：既让 `accept` 返回，也不发送任何请求数据。
    private func wakeAcceptLoop() {
        let wake = socket(AF_INET, SOCK_STREAM, 0)
        guard wake >= 0 else { return }
        defer { close(wake) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(wake, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    private func acceptLoop() {
        lock.lock()
        ready = true
        lock.unlock()
        defer {
            close(listener)
            stoppedSemaphore.signal()
        }
        while true {
            var clientAddress = sockaddr()
            var clientLength = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(listener, &clientAddress, &clientLength)
            guard isRunning else {
                if client >= 0 { close(client) }
                return
            }
            guard client >= 0 else { continue }
            respond(on: client)
        }
    }

    private func respond(on client: Int32) {
        defer { close(client) }
        // 只读到请求头结束，足够让 URLSession 拿到一个完整响应。
        var buffer = [UInt8](repeating: 0, count: 1024)
        var received = 0
        while received < buffer.count {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return recv(client, base.advanced(by: received), raw.count - received, 0)
            }
            guard count > 0 else { break }
            received += count
            if let request = String(bytes: buffer[0..<received], encoding: .utf8),
               request.contains("\r\n\r\n") {
                break
            }
        }

        lock.lock()
        requests += 1
        lock.unlock()

        let body = "ok"
        let response = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/plain\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n"
            + "\r\n"
            + body
        var data = Array(response.utf8)
        var sent = 0
        while sent < data.count {
            let count = data.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return send(client, base.advanced(by: sent), raw.count - sent, 0)
            }
            guard count > 0 else { break }
            sent += count
        }
    }
}

// MARK: - fixtures

/// 建好本地 HTTP 服务器并确认 accept 循环已经启动。监听描述符在 `init` 里就已就绪，
/// 但显式等待能把“服务器可用”变成测试的前置条件，而不是依赖线程调度顺序。
private func makeReadyIntegrationServer() throws -> IntegrationHTTPServer {
    let server = try IntegrationHTTPServer()
    guard server.waitUntilReady() else {
        server.stop()
        throw IntegrationHTTPServer.ServerError.readinessTimeout
    }
    return server
}

/// 一次集成测试用到的全部临时状态。
///
/// 所有文件（假 `pi`/`pi-web`/`node` 可执行脚本、假 Home、运行目录、日志目录、
/// 记录文件）都建在同一个临时目录里，`cleanUp()` 删除整个目录。测试期间不会写
/// 真实 UserDefaults、`~/Library`、`~/.pi` 或用户 Keychain。
private final class IntegrationFixture {
    let root: URL
    let homeURL: URL
    let supportURL: URL
    let logsRootURL: URL
    let workspaceURL: URL
    let piPath: String
    let nodePath: String
    let piWebPath: String
    /// 假 `pi-web` 记录服务启动参数与环境变量的文件。
    let piWebRecordURL: URL
    /// 假 `pi-web` 收到 `--version` 时追加调用的文件。
    let piWebVersionRecordURL: URL
    /// 假 `pi` 记录调用参数的文件。
    let piRecordURL: URL
    /// 出现这个文件时，假服务退出。
    let exitSentinelURL: URL

    private let defaultsName: String
    private let defaults: UserDefaults

    init() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .appendingPathComponent("PiWebDesktopIntegration-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        homeURL = root.appendingPathComponent("home", isDirectory: true)
        supportURL = root.appendingPathComponent("support", isDirectory: true)
        logsRootURL = root.appendingPathComponent("logs", isDirectory: true)
        workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        piWebRecordURL = root.appendingPathComponent("pi-web-launch-record.txt")
        piWebVersionRecordURL = root.appendingPathComponent("pi-web-version-record.txt")
        piRecordURL = root.appendingPathComponent("pi-invocation-record.txt")
        exitSentinelURL = root.appendingPathComponent("pi-web-exit-sentinel")

        let toolsURL = homeURL.appendingPathComponent("tools", isDirectory: true)
        let binURL = toolsURL.appendingPathComponent("bin", isDirectory: true)
        let npmGlobalBinURL = homeURL
            .appendingPathComponent(".npm-global", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let piConfigURL = homeURL
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)

        for directory in [homeURL, supportURL, logsRootURL, workspaceURL, toolsURL, binURL, npmGlobalBinURL, piConfigURL] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // 假 pi-web 的 package.json：DependencyChecker 沿真实路径向上读取它。
        try #"{"name":"@agegr/pi-web","version":"1.2.3"}"#
            .write(to: toolsURL.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        piPath = npmGlobalBinURL.appendingPathComponent("pi").path
        nodePath = npmGlobalBinURL.appendingPathComponent("node").path
        piWebPath = binURL.appendingPathComponent("pi-web").path

        // 先完成全部存储属性初始化，下面才能调用实例方法写脚本。
        defaultsName = "PiWebDesktopIntegration.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName) ?? .standard

        try writeExecutable(at: URL(fileURLWithPath: nodePath), contents: Self.fakeNodeScript)
        try writeExecutable(at: URL(fileURLWithPath: piPath), contents: fakePiScript())
        try writeExecutable(at: URL(fileURLWithPath: piWebPath), contents: fakePiWebScript())
    }

    var appConfiguration: AppConfiguration {
        AppConfiguration(supportURL: supportURL, logsRootURL: logsRootURL, defaults: defaults)
    }

    /// 传给 `ServiceManager` 的子进程基础环境。
    ///
    /// 只包含测试自己的键：没有真实 `HOME`、代理或任何从当前进程继承的凭据，
    /// 假服务因此能证明“环境变量确实按启动规格传递”，而不是碰巧被继承。
    var baseEnvironment: [String: String] {
        [
            "INTEGRATION_BASE": "1",
            "PI_WEB_FAKE_RECORD": piWebRecordURL.path,
            "PI_WEB_FAKE_EXIT_FILE": exitSentinelURL.path
        ]
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: 可执行脚本

    private func writeExecutable(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static let fakeNodeScript = #"""
    #!/bin/bash
    printf '%s\n' "v22.19.0"
    exit 0
    """#

    private func fakePiScript() -> String {
        #"""
        #!/bin/bash
        printf '%s\n' "$*" >> "\#(piRecordURL.path)"
        case "${1:-}" in
          --version) printf '%s\n' "0.9.0" ;;
        esac
        exit 0
        """#
    }

    private func fakePiWebScript() -> String {
        #"""
        #!/bin/bash
        # 假 pi-web：`--version` 只回答版本；被应用托管启动时记录 argv 与环境
        # 变量，然后保持运行，直到退出哨兵文件出现。
        if [ "${1:-}" = "--version" ]; then
          printf '%s\n' "$*" >> "\#(piWebVersionRecordURL.path)"
          printf '%s\n' "1.2.3"
          exit 0
        fi

        {
          printf 'pid=%s\n' "$$"
          index=0
          for argument in "$@"; do
            index=$((index + 1))
            printf 'arg%s=%s\n' "$index" "$argument"
          done
          printf 'cwd=%s\n' "$PWD"
          printf 'PI_WEB_NO_OPEN=%s\n' "${PI_WEB_NO_OPEN:-unset}"
          printf 'PI_WEB_PASSWORD_SET=%s\n' "$(if [ -n "${PI_WEB_PASSWORD:-}" ]; then printf yes; else printf no; fi)"
          printf 'INTEGRATION_BASE=%s\n' "${INTEGRATION_BASE:-unset}"
          printf 'PATH=%s\n' "${PATH:-unset}"
        } > "$PI_WEB_FAKE_RECORD"

        while [ ! -f "$PI_WEB_FAKE_EXIT_FILE" ]; do
          sleep 0.1
        done
        exit "${PI_WEB_FAKE_EXIT_CODE:-0}"
        """#
    }

    // MARK: 记录读取

    struct LaunchRecord {
        var processIdentifier: pid_t
        var arguments: [String]
        var environment: [String: String]
    }

    func readPiWebLaunchRecord() throws -> LaunchRecord {
        let text = try String(contentsOf: piWebRecordURL, encoding: .utf8)
        var processIdentifier: pid_t = 0
        var arguments: [String] = []
        var environment: [String: String] = [:]
        for line in text.split(whereSeparator: { $0.isNewline }) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...])
            if key == "pid" {
                processIdentifier = pid_t(value) ?? 0
            } else if key.hasPrefix("arg") {
                arguments.append(value)
            } else {
                environment[key] = value
            }
        }
        return LaunchRecord(processIdentifier: processIdentifier, arguments: arguments, environment: environment)
    }

    func readPiInvocationRecord() throws -> String {
        try String(contentsOf: piRecordURL, encoding: .utf8)
    }

    func readPiWebVersionRecord() throws -> String {
        try String(contentsOf: piWebVersionRecordURL, encoding: .utf8)
    }

    // MARK: 无关进程（诱饵）

    /// 独立的诱饵进程：它只记录收到的 TERM/INT，存活本身就证明应用没有把信号
    /// 发给不属于自己的进程（SIGKILL 无法记录，但会让进程消失）。
    func makeDecoyProcess() throws -> IntegrationDecoyProcess {
        try IntegrationDecoyProcess(root: root)
    }
}

/// 一个与受管服务无关的进程。测试自己启动它、也在测试结束时自己结束它。
private final class IntegrationDecoyProcess {
    private let process: Process
    private let markerURL: URL

    init(root: URL) throws {
        markerURL = root.appendingPathComponent("decoy-signals.txt")
        let scriptURL = root.appendingPathComponent("decoy.sh")
        let script = #"""
        #!/bin/bash
        trap 'printf "%s\n" TERM >> "$DECOY_MARKER"; exit 0' TERM
        trap 'printf "%s\n" INT >> "$DECOY_MARKER"; exit 0' INT
        while true; do
          sleep 0.2
        done
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        process = Process()
        process.executableURL = scriptURL
        process.arguments = []
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "DECOY_MARKER": markerURL.path
        ]
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    /// 诱饵是否收到过 TERM/INT。
    var receivedTerminationSignal: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    /// 只结束测试自己启动的进程。
    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

// MARK: - 真实命令 runner

/// 真的执行命令，但把 `npm prefix -g` 当作“未安装”返回。
///
/// 集成测试需要真实执行 fixture 里的假可执行文件，也必须证明没有去问本机的
/// npm、没有访问网络：所有调用都被记录下来，`npm` 查询被显式短路为 nil，
/// 结果与“本机没装 npm”完全一致。
private final class IntegrationCommandRunner: CommandRunning {
    private let base = SystemCommandRunner()
    private(set) var invocations: [[String]] = []

    func run(_ arguments: [String]) -> String? {
        invocations.append(arguments)
        // npm/pnpm 查询显式短路：fixture 测试不执行真实 npm/pnpm，也不访问网络。
        if Self.shortCircuitedInvocations.contains(arguments) {
            return nil
        }
        return base.run(arguments)
    }

    /// 不交给真实二叉的只读命令（#6 的 npm 前缀与 #16 的 npm/pnpm 全局 root）。
    static let shortCircuitedInvocations: [[String]] = [
        ["/usr/bin/env", "npm", "prefix", "-g"],
        ["/usr/bin/env", "npm", "root", "-g"],
        ["/usr/bin/env", "pnpm", "root", "-g"]
    ]
}

/// 真实文件系统探针 + 两个测试接缝：Home 指向 fixture，可执行文件只认 fixture
/// 内部的路径，因此本机装了什么工具都不会影响结果。
private struct IntegrationHomeFileSystemProbe: DependencyFileSystemProbing {
    let homeDirectory: String
    let allowedExecutablePrefix: String
    private let system = SystemDependencyFileSystemProbe()

    init(homeDirectory: String, allowedExecutablePrefix: String) {
        self.homeDirectory = homeDirectory
        self.allowedExecutablePrefix = allowedExecutablePrefix
    }

    func isExecutableFile(atPath path: String) -> Bool {
        path.hasPrefix(allowedExecutablePrefix) && system.isExecutableFile(atPath: path)
    }

    func symlinkDestination(atPath path: String) -> String? {
        system.symlinkDestination(atPath: path)
    }

    func resolvedPath(atPath path: String) -> String? {
        system.resolvedPath(atPath: path)
    }

    func readText(atPath path: String) -> String? {
        system.readText(atPath: path)
    }

    func homeDirectoryPath() -> String {
        homeDirectory
    }

    func directoryExists(atPath path: String) -> Bool? {
        system.directoryExists(atPath: path)
    }

    func isReadableDirectory(atPath path: String) -> Bool? {
        system.isReadableDirectory(atPath: path)
    }
}

/// 端口只做提示：集成测试用固定结果，不绑定真实端口。
private struct IntegrationStaticPortProbe: DependencyPortProbing {
    let availability: Bool?

    func isPortAvailable(host: String, port: Int) -> Bool? {
        availability
    }
}

// MARK: - 服务管理器 harness

/// 收集 `ServiceManager` 回调，供断言在真实定时器/线程下轮询。
private final class IntegrationRecorder {
    private let lock = NSLock()
    private var stateList: [ServiceState] = []
    private var pageMessageList: [String] = []
    private var startupFailureList: [String] = []
    private var pageLoadCount = 0

    var states: [ServiceState] { locked { stateList } }
    var pageMessages: [String] { locked { pageMessageList } }
    var startupFailures: [String] { locked { startupFailureList } }
    var pageLoads: Int { locked { pageLoadCount } }

    var latestState: ServiceState? { states.last }
    var isRunning: Bool { latestState == .running }
    var isStopped: Bool { latestState == .stopped }

    var failureMessage: String? {
        guard case .failed(let message)? = latestState else { return nil }
        return message
    }

    func record(state: ServiceState) {
        lock.lock()
        stateList.append(state)
        lock.unlock()
    }

    func record(pageMessage: String) {
        lock.lock()
        pageMessageList.append(pageMessage)
        lock.unlock()
    }

    func record(startupFailure: String) {
        lock.lock()
        startupFailureList.append(startupFailure)
        lock.unlock()
    }

    func recordPageLoad() {
        lock.lock()
        pageLoadCount += 1
        lock.unlock()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// 用注入的临时目录 + 真实的 launcher/probe/scheduler/inspector 组装
/// `ServiceManager`。它会启动真实子进程、做真实 HTTP 健康检查，但所有路径都在
/// fixture 内，且不读取任何用户配置。
private final class IntegrationServiceHarness {
    let fixture: IntegrationFixture
    let recorder: IntegrationRecorder
    let manager: ServiceManager
    let port: Int

    init(
        fixture: IntegrationFixture,
        port: Int,
        environment: [String: String],
        instanceID: String = "integration-instance"
    ) {
        self.fixture = fixture
        self.port = port

        var configuration = ServiceConfiguration.default
        configuration.hostname = "127.0.0.1"
        configuration.port = port
        configuration.piWebPath = fixture.piWebPath
        configuration.workspacePath = fixture.workspaceURL.path

        let recorder = IntegrationRecorder()
        self.recorder = recorder

        let manager = ServiceManager(
            configuration: configuration,
            appConfiguration: fixture.appConfiguration,
            processInspector: ProcessInspector(),
            commandRunner: SystemCommandRunner(),
            launcher: SystemServiceLauncher(),
            probe: URLSessionServiceProbe(),
            scheduler: DispatchServiceScheduler(),
            environment: { environment },
            fileManager: .default,
            ownershipStore: FileServiceOwnershipStore(),
            signaler: POSIXServiceSignaler(),
            remoteAccessPassword: { nil },
            instanceID: instanceID
        )
        self.manager = manager

        manager.onStateChange = { [recorder] state in recorder.record(state: state) }
        manager.onPageMessage = { [recorder] message in recorder.record(pageMessage: message) }
        manager.onStartupFailure = { [recorder] message in recorder.record(startupFailure: message) }
        manager.onLoadPage = { [recorder] in recorder.recordPageLoad() }
        manager.isDependencyGateOpen = true
        manager.setWorkspaceAvailability(
            problem: nil,
            path: fixture.workspaceURL.path,
            usesDefaultLocation: false
        )
    }

    /// 测试结束时的安全网：先走应用的停止路径；如果仍有本测试启动的进程存活
    /// （例如断言在中间失败），再把这个测试自己启动的进程组结束掉。
    func stopServiceAndKillLeftovers() {
        manager.stopHealthMonitor()
        manager.stopService()
        _ = waitForIntegrationCondition(timeout: 5) {
            guard let launch = try? fixture.readPiWebLaunchRecord() else { return true }
            return !IntegrationProcess.isAlive(launch.processIdentifier)
        }
        if let launch = try? fixture.readPiWebLaunchRecord(), IntegrationProcess.isAlive(launch.processIdentifier) {
            IntegrationProcess.terminateProcessGroup(launch.processIdentifier)
            _ = waitForIntegrationCondition { !IntegrationProcess.isAlive(launch.processIdentifier) }
        }
    }
}

// MARK: - helpers

private enum IntegrationProcess {
    static func isAlive(_ pid: pid_t) -> Bool {
        pid > 1 && kill(pid, 0) == 0
    }

    /// 只用于结束测试自己启动的进程组。
    static func terminateProcessGroup(_ processGroupID: pid_t) {
        guard processGroupID > 1 else { return }
        _ = kill(-processGroupID, SIGTERM)
    }
}

/// 轮询条件并让主线程 run loop 继续派发 `ServiceManager` 的 `onMain` 回调。
private func waitForIntegrationCondition(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return condition()
}

private func unusedLoopbackPort() -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return 0 }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { return 0 }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &actual) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            getsockname(descriptor, socketAddress, &length)
        }
    }
    guard named == 0 else { return 0 }
    return Int(UInt16(bigEndian: actual.sin_port))
}

// MARK: - 依赖诊断集成测试（真实可执行脚本 + 真实文件系统）

/// 使用 fixture 里的假 `pi`/`pi-web`/`node` 脚本和真实 `SystemCommandRunner`
/// 运行 `DependencyChecker`：验证版本解析、安装来源推断与 Home 脱敏在真实进程和
/// 真实磁盘上仍然成立，同时不读取真实 `~/.pi`、不调用 npm。
final class DependencyCheckerIntegrationTests: XCTestCase {
    func testRealFakeExecutablesAreParsedAndRedacted() throws {
        let fixture = try IntegrationFixture()
        defer { fixture.cleanUp() }

        let runner = IntegrationCommandRunner()
        let checker = DependencyChecker(
            commandRunner: runner,
            fileSystem: IntegrationHomeFileSystemProbe(
                homeDirectory: fixture.homeURL.path,
                allowedExecutablePrefix: fixture.homeURL.path + "/"
            ),
            system: DependencySystemProbe(
                architecture: { "arm64" },
                operatingSystemVersion: { OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0) }
            ),
            configuredPiWebPath: fixture.piWebPath,
            portProbe: IntegrationStaticPortProbe(availability: true)
        )

        let report = checker.run()

        XCTAssertTrue(report.canStartService, "fixture 的三条硬性前置都必须通过: \(report.blockingFindings)")

        let node = try XCTUnwrap(report.finding(for: .node))
        XCTAssertEqual(node.status, .ok)
        XCTAssertEqual(node.version, "22.19.0")
        XCTAssertEqual(node.path, "~/.npm-global/bin/node")
        XCTAssertEqual(node.installSource, .npmGlobal)

        let pi = try XCTUnwrap(report.finding(for: .piCLI))
        XCTAssertEqual(pi.status, .ok)
        XCTAssertEqual(pi.version, "0.9.0")
        XCTAssertEqual(pi.path, "~/.npm-global/bin/pi")
        XCTAssertEqual(pi.installSource, .npmGlobal)

        let piWeb = try XCTUnwrap(report.finding(for: .piWeb))
        XCTAssertEqual(piWeb.status, .ok)
        XCTAssertEqual(piWeb.version, "1.2.3")
        XCTAssertEqual(piWeb.path, "~/tools/bin/pi-web")
        XCTAssertEqual(piWeb.packageName, "@agegr/pi-web")
        XCTAssertEqual(piWeb.packageVersion, "1.2.3")
        XCTAssertEqual(piWeb.installSource, .localPath)
        XCTAssertEqual(piWeb.confidence, .inferred)

        let configuration = try XCTUnwrap(report.finding(for: .piConfigDirectory))
        XCTAssertEqual(configuration.status, .ok)

        // 脱敏：诊断文本只出现 `~`，绝不出现 fixture 的 Home 绝对路径。
        let text = DependencyReportPresenter.summaryText(for: report)
        XCTAssertTrue(text.contains("~/.npm-global/bin/pi"))
        XCTAssertFalse(text.contains(fixture.homeURL.path))

        // 真实执行了 fixture 自己的脚本，而且没有询问 npm。
        XCTAssertTrue(try fixture.readPiInvocationRecord().contains("--version"))
        XCTAssertTrue(try fixture.readPiWebVersionRecord().contains("--version"))
        XCTAssertEqual(runner.invocations.filter { $0 == ["/usr/bin/env", "npm", "prefix", "-g"] }.count, 1)
        for invocation in runner.invocations where invocation.first?.hasPrefix(fixture.homeURL.path) != true {
            XCTAssertTrue(
                IntegrationCommandRunner.shortCircuitedInvocations.contains(invocation),
                "只允许执行 fixture 里的脚本或短路 npm/pnpm 查询: \(invocation)"
            )
        }

        // #16：组件安装识别在真实 fixture 上同样成立，且路径已脱敏。
        let piComponent = try XCTUnwrap(report.component(for: .piCLI))
        XCTAssertEqual(piComponent.packageName, InstallCommandManifest.piCLIPackageName)
        XCTAssertEqual(piComponent.version, "0.9.0")
        XCTAssertEqual(piComponent.executablePath, "~/.npm-global/bin/pi")
        XCTAssertEqual(piComponent.source, .npmGlobal)
        XCTAssertEqual(piComponent.confidence, .inferred, "没有 npm root -g 证据时只能推断")
        XCTAssertNil(piComponent.suggestedCommand, "未验证的全局来源不给包管理器命令")
        XCTAssertFalse(piComponent.evidence.contains { $0.contains(fixture.homeURL.path) }, "证据行也要脱敏")
    }
}

// MARK: - 服务生命周期集成测试（真实子进程 + 本地 HTTP 服务器）

/// 用真实 `posix_spawn` 启动 fixture 里的假 pi-web，用真实
/// `URLSessionServiceProbe` 对本地 HTTP 服务器做健康检查，并断言停止路径只对
/// 经过验证的进程组发信号。
final class ServiceLifecycleIntegrationTests: XCTestCase {
    func testManagedServiceGetsTheServiceArgumentsAndEnvironmentAndBecomesReady() throws {
        let fixture = try IntegrationFixture()
        defer { fixture.cleanUp() }
        let server = try makeReadyIntegrationServer()
        defer { server.stop() }
        let harness = IntegrationServiceHarness(
            fixture: fixture,
            port: server.port,
            environment: fixture.baseEnvironment
        )
        defer { harness.stopServiceAndKillLeftovers() }

        harness.manager.startManagedService()

        XCTAssertTrue(waitForIntegrationCondition { harness.recorder.isRunning }, "服务应通过健康检查并进入运行状态")
        XCTAssertGreaterThanOrEqual(server.requestCount, 1, "健康检查必须真正到达本地 HTTP 服务器")
        XCTAssertGreaterThan(harness.recorder.pageLoads, 0)
        XCTAssertTrue(waitForIntegrationCondition { FileManager.default.fileExists(atPath: fixture.piWebRecordURL.path) })

        let record = try XCTUnwrap(harness.manager.verifiedOwnershipRecord())
        XCTAssertEqual(record.port, server.port)
        XCTAssertEqual(record.instanceID, harness.manager.instanceID)
        XCTAssertGreaterThan(record.pid, 1)
        XCTAssertEqual(record.processGroupID, record.pid)

        let launch = try fixture.readPiWebLaunchRecord()
        XCTAssertEqual(launch.processIdentifier, record.pid)
        XCTAssertEqual(
            launch.arguments,
            ["--hostname", "127.0.0.1", "--port", "\(server.port)", "--no-open"]
        )
        XCTAssertEqual(launch.environment["PI_WEB_NO_OPEN"], "1")
        XCTAssertEqual(launch.environment["INTEGRATION_BASE"], "1")
        XCTAssertEqual(launch.environment["PI_WEB_PASSWORD_SET"], "no")
        XCTAssertEqual(
            launch.environment["cwd"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            fixture.workspaceURL.resolvingSymlinksInPath().path
        )
        XCTAssertTrue(launch.environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
    }

    func testStoppingTheManagedServiceSignalsOnlyItsOwnProcessGroup() throws {
        let fixture = try IntegrationFixture()
        defer { fixture.cleanUp() }
        let server = try makeReadyIntegrationServer()
        defer { server.stop() }
        let harness = IntegrationServiceHarness(
            fixture: fixture,
            port: server.port,
            environment: fixture.baseEnvironment
        )
        defer { harness.stopServiceAndKillLeftovers() }
        let decoy = try fixture.makeDecoyProcess()
        defer { decoy.stop() }

        harness.manager.startManagedService()
        XCTAssertTrue(waitForIntegrationCondition { harness.recorder.isRunning })
        XCTAssertTrue(waitForIntegrationCondition { FileManager.default.fileExists(atPath: fixture.piWebRecordURL.path) })
        let launch = try fixture.readPiWebLaunchRecord()

        harness.manager.stopService()

        XCTAssertTrue(waitForIntegrationCondition { harness.recorder.isStopped }, "停止后状态应为已停止")
        XCTAssertTrue(
            waitForIntegrationCondition { !IntegrationProcess.isAlive(launch.processIdentifier) },
            "受管进程应已被终止并回收"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.appConfiguration.serviceOwnerURL.path),
            "停止后所有权记录必须被删除"
        )
        XCTAssertTrue(decoy.isRunning, "不属于应用的进程不能被结束")
        XCTAssertFalse(decoy.receivedTerminationSignal, "不属于应用的进程不能收到任何信号")
    }

    func testServiceThatExitsDuringStartupLeavesTheStartingStateWithoutClaimingOwnership() throws {
        let fixture = try IntegrationFixture()
        defer { fixture.cleanUp() }
        let decoy = try fixture.makeDecoyProcess()
        defer { decoy.stop() }

        var environment = fixture.baseEnvironment
        environment["PI_WEB_FAKE_EXIT_CODE"] = "1"
        let harness = IntegrationServiceHarness(
            fixture: fixture,
            port: unusedLoopbackPort(),
            environment: environment
        )
        defer { harness.stopServiceAndKillLeftovers() }

        harness.manager.startManagedService()

        // 退出时机由哨兵文件控制，不再用固定 sleep：先确认启动轮询已开始并且所有权
        // 已登记，再让服务退出。否则在慢 runner 上子进程可能先于登记退出，测试就
        // 变成了竞态（CI run 35413056039 就是这样失败的）。
        XCTAssertTrue(
            waitForIntegrationCondition(timeout: 5) {
                harness.recorder.latestState == .starting && harness.manager.verifiedOwnershipRecord() != nil
            },
            "服务应先进入“正在启动”并登记所有权: \(harness.recorder.states)"
        )
        let record = try XCTUnwrap(harness.manager.verifiedOwnershipRecord())
        XCTAssertTrue(harness.recorder.pageMessages.contains("正在启动 Pi Web…"))

        XCTAssertTrue(
            FileManager.default.createFile(atPath: fixture.exitSentinelURL.path, contents: Data()),
            "退出哨兵文件必须能创建"
        )
        XCTAssertTrue(
            waitForIntegrationCondition(timeout: 5) { !IntegrationProcess.isAlive(record.pid) },
            "哨兵出现后假服务必须退出"
        )

        // 服务在启动轮询期间退出：应用不得停留在“正在启动”或伪装成运行中，也
        // 不得留下可认领的所有权记录。终止回调与轮询自己的“进程已退出”分支谁先
        // 到达都允许，所以两者都接；轮询立即提示的缺口登记在 #11 报告里，
        // 不在这里制造一个与实现不一致的断言。
        XCTAssertTrue(
            waitForIntegrationCondition(timeout: 5) {
                harness.recorder.isStopped || harness.recorder.failureMessage != nil
            },
            "退出的服务必须离开“正在启动”状态: \(harness.recorder.states)"
        )
        XCTAssertFalse(harness.recorder.isRunning, "进程已退出时不能显示为运行中")
        XCTAssertTrue(
            waitForIntegrationCondition(timeout: 5) { harness.manager.verifiedOwnershipRecord() == nil },
            "退出后的服务不能留下可认领的所有权记录"
        )
        XCTAssertTrue(decoy.isRunning)
        XCTAssertFalse(decoy.receivedTerminationSignal)
    }

    func testRunningServiceDisconnectIsReportedAndRecoveryIsAttempted() throws {
        let fixture = try IntegrationFixture()
        defer { fixture.cleanUp() }
        let server = try makeReadyIntegrationServer()
        defer { server.stop() }
        let harness = IntegrationServiceHarness(
            fixture: fixture,
            port: server.port,
            environment: fixture.baseEnvironment
        )
        defer { harness.stopServiceAndKillLeftovers() }

        harness.manager.startManagedService()
        harness.manager.startHealthMonitor()

        XCTAssertTrue(waitForIntegrationCondition { harness.recorder.isRunning })
        XCTAssertTrue(waitForIntegrationCondition { FileManager.default.fileExists(atPath: fixture.piWebRecordURL.path) })
        let launch = try fixture.readPiWebLaunchRecord()

        // 服务进程还在，但 HTTP 端点消失：健康检查必须发现并给出恢复提示。
        server.stop()
        XCTAssertTrue(
            waitForIntegrationCondition(timeout: 15) {
                harness.recorder.pageMessages.contains("Pi Web 服务已断开，正在尝试恢复…")
            },
            "健康检查失败后必须报告断开并尝试恢复: \(harness.recorder.pageMessages)"
        )
        XCTAssertEqual(harness.recorder.latestState, .stopped)

        harness.manager.stopHealthMonitor()
        harness.manager.stopService()
        XCTAssertTrue(waitForIntegrationCondition { !IntegrationProcess.isAlive(launch.processIdentifier) })
        XCTAssertTrue(
            waitForIntegrationCondition {
                !FileManager.default.fileExists(atPath: fixture.appConfiguration.serviceOwnerURL.path)
            },
            "停止后所有权记录必须被删除"
        )
    }

    func testServiceWithoutAVerifiedRecordIsReadOnlyAndNeverSignalled() throws {
        let fixture = try IntegrationFixture()
        defer { fixture.cleanUp() }
        let server = try makeReadyIntegrationServer()
        defer { server.stop() }
        let harness = IntegrationServiceHarness(
            fixture: fixture,
            port: server.port,
            environment: fixture.baseEnvironment
        )
        defer { harness.stopServiceAndKillLeftovers() }
        let decoy = try fixture.makeDecoyProcess()
        defer { decoy.stop() }

        harness.manager.startManagedService()
        XCTAssertTrue(waitForIntegrationCondition { harness.recorder.isRunning })
        XCTAssertTrue(waitForIntegrationCondition { FileManager.default.fileExists(atPath: fixture.piWebRecordURL.path) })
        let launch = try fixture.readPiWebLaunchRecord()

        // 记录被删掉：进程对应用来说就是“外部服务”，只读。
        try FileManager.default.removeItem(at: fixture.appConfiguration.serviceOwnerURL)
        harness.manager.stopService()

        XCTAssertFalse(
            waitForIntegrationCondition(timeout: 1) { !IntegrationProcess.isAlive(launch.processIdentifier) },
            "没有可验证所有权的进程不能被结束"
        )
        XCTAssertTrue(harness.recorder.isRunning, "外部服务停止请求不得改变应用状态")
        XCTAssertTrue(decoy.isRunning)
        XCTAssertFalse(decoy.receivedTerminationSignal)

        // 清理：这个进程是测试自己启动的，由测试自己结束。
        IntegrationProcess.terminateProcessGroup(launch.processIdentifier)
        XCTAssertTrue(waitForIntegrationCondition { !IntegrationProcess.isAlive(launch.processIdentifier) })
    }
}
