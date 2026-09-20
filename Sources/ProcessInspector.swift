import Darwin
import Foundation

/// 单次命令探测的结果。
///
/// `timedOut` / `cancelled` 存在的意义是：探针“没有返回”不等于“命令缺失或退出码
/// 非零”，诊断文本可以把前者写成可读原因（“依赖探测超时”），而不是静默把它当成
/// 普通的不可用。
struct CommandRunResult: Equatable {
    /// 命令在超时前退出（退出码 0）时的标准输出；否则 nil。空字符串也是输出。
    var output: String?
    /// 命令超过超时上限仍未退出；本次启动的子进程已尽力终止。
    var timedOut: Bool = false
    /// 调用方在命令结束前取消；本次启动的子进程已尽力终止。
    var cancelled: Bool = false
}

/// Runs a command line tool for the app. The protocol exists so process checks
/// can be exercised with canned `ps`/`lsof` output instead of real processes.
///
/// `run(_:timeout:)` 与 `cancelRunningProbe()` 都有默认实现，因此既有的假 runner
/// （测试替身）不需要改动就能继续编译；需要断言超时/取消路径的替身再实现它们。
protocol CommandRunning {
    /// Returns standard output when the command exits 0; nil when it cannot be
    /// launched or exits with a non-zero status.
    func run(_ arguments: [String]) -> String?
    /// 带超时上限的探测。默认实现退回 `run(_:)`（不提供超时能力），因此不会
    /// 把“没有超时”伪装成“有超时保证”。
    func run(_ arguments: [String], timeout: TimeInterval) -> CommandRunResult
    /// 带显式子进程环境的探测（GitHub #89）：调用方传入 `ToolPath` 合并后的
    /// 工具 PATH，让 `pi` 这类 `#!/usr/bin/env node` 脚本在应用由 Finder 启动、
    /// 进程 PATH 只有系统目录时也能找到 `node`。`nil` 表示沿用本 runner 自己的
    /// 环境（默认实现忽略该参数并转调 `run(_:)`，只关心参数的测试替身不必实现）。
    func run(_ arguments: [String], environment: [String: String]?) -> String?
    /// 环境与超时同时给出的探测（依赖诊断的常规入口）。
    func run(_ arguments: [String], environment: [String: String]?, timeout: TimeInterval) -> CommandRunResult
    /// 取消正在进行的探测（若还有）：只终止**本次启动的**子进程，不阻塞等待。
    func cancelRunningProbe()
}

extension CommandRunning {
    func run(_ arguments: [String], timeout: TimeInterval) -> CommandRunResult {
        CommandRunResult(output: run(arguments))
    }

    func run(_ arguments: [String], environment: [String: String]?) -> String? {
        run(arguments)
    }

    func run(_ arguments: [String], environment: [String: String]?, timeout: TimeInterval) -> CommandRunResult {
        // 没有专门实现“环境 + 超时”的 runner（例如只模拟超时的测试替身）带回退到
        // 不带环境的超时入口：忽略环境也必须保留超时语义，否则“挂住的探针”会被
        // 静默当成普通失败。生产 runner 自己实现了这一条。
        run(arguments, timeout: timeout)
    }

    func cancelRunningProbe() {}
}

/// 探针的线程约定：命令探针（`--version`、`command -v`、`ps`/`lsof`）是同步阻塞
/// 调用，不得在 UI 线程执行。任何由 UI 触发的探测都经过这里移到后台队列，完成
/// 后再回到主队列更新界面。
///
/// `queue` 与 `deliverOnMain` 可注入：测试用可控替身即可断言“工作不在调用线程
/// 执行、结果只经交付点送达”，不需要真实命令、窗口或真实主队列。
///
/// 取消不属于这层的职责：需要取消时调用方直接对同一个 runner 调
/// `cancelRunningProbe()`（它只终止本次启动的子进程）。
enum CommandProbeDispatch {
    static func runOffMain<Value>(
        queue: DispatchQueue = .global(qos: .userInitiated),
        deliverOnMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
        work: @escaping () -> Value,
        completion: @escaping (Value) -> Void
    ) {
        queue.async {
            let value = work()
            deliverOnMain { completion(value) }
        }
    }
}

/// 一次探针子进程的生命周期。
///
/// 生产实现是 `ProcessProbeProcess`；测试注入替身，因此“超时后终止本次子进程”
/// “取消路径”“不会因为输出超过管道缓冲而死锁”都能在不启动真实命令的前提下断言。
protocol ProbeProcess: AnyObject {
    /// 命令是否仍在运行。
    var isRunning: Bool { get }
    /// 退出码；只在进程结束后有意义。
    var terminationStatus: Int32 { get }
    /// 阻塞等待退出，最多 `timeout` 秒；返回是否在超时前退出。
    func waitForExit(timeout: TimeInterval) -> Bool
    /// 读走已收集的标准输出；绝不在子进程仍运行时阻塞。
    func readStandardOutput() -> Data
    /// 只对本次启动的子进程发 SIGTERM；返回是否真的发出。不阻塞等待。
    @discardableResult func terminate() -> Bool
    /// 宽限后仍未退出时只对本次启动的子进程发 SIGKILL；返回是否真的发出。
    @discardableResult func forceTerminate() -> Bool
}

/// 启动探针子进程时的固定错误（参数为空）。
enum ProbeProcessError: Error, Equatable {
    case missingExecutable
}

/// `Process` 包装：标准输出用非阻塞读排空（子进程写出超过管道缓冲也不会把双方
/// 锁死），等待有超时上限；超时后的信号只发给这个子进程自己的 pid，不按名字、
/// 进程组或“所有子进程”发信号。
final class ProcessProbeProcess: ProbeProcess {
    private let process: Process
    private let readHandle: FileHandle
    private var collected = Data()

    init(arguments: [String], environment: [String: String]? = nil) throws {
        guard let executable = arguments.first, !executable.isEmpty else {
            throw ProbeProcessError.missingExecutable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        if let environment { process.environment = environment }
        // 子进程的 stdin 固定为 /dev/null：交互式登录 shell 的 rc 文件即使读
        // stdin 也不会阻塞应用（GitHub #89 的 PATH 查询）。
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        self.process = process
        self.readHandle = pipe.fileHandleForReading
        try process.run()
        // 非阻塞：等待循环里主动排空管道，不让 64 KiB 的管道缓冲把子进程卡住。
        let descriptor = readHandle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32 { process.terminationStatus }

    func waitForExit(timeout: TimeInterval) -> Bool {
        let bounded = max(0, timeout)
        let deadline = Date().addingTimeInterval(bounded)
        while true {
            drainOutput()
            if !process.isRunning { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func readStandardOutput() -> Data {
        drainOutput()
        return collected
    }

    @discardableResult
    func terminate() -> Bool {
        guard process.isRunning else { return false }
        process.terminate()
        return true
    }

    @discardableResult
    func forceTerminate() -> Bool {
        let pid = process.processIdentifier
        guard pid > 1, process.isRunning else { return false }
        return kill(pid, SIGKILL) == 0
    }

    /// 排空当前可读的标准输出；EOF 或 EAGAIN 都结束本轮，不阻塞。
    private func drainOutput() {
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                read(readHandle.fileDescriptor, raw.baseAddress, raw.count)
            }
            guard count > 0 else { return }
            collected.append(contentsOf: buffer[0..<count])
        }
    }
}

/// 生产命令执行器。
///
/// 每条命令都在**有界时间**内返回：超过上限时只终止本次启动的子进程（SIGTERM，
/// 宽限后 SIGKILL），结果标记为 `timedOut`，绝不把“探针挂住”变成调用方的永久
/// 等待（依赖门控因此不会永久停在“正在检查”）。
///
/// 兼容旧行为：`run(_:)` 仍然只在退出码为 0 时返回标准输出，否则返回 nil；差异是
/// 现在多了超时上限，并且超时/取消可以从 `run(_:timeout:)` 的结果里区分出来。
/// `timeout`、宽限时间与子进程启动/等待（`spawn`）都可注入，因此超时与取消路径
/// 的测试不需要启动真实命令。
final class SystemCommandRunner: CommandRunning {
    /// 探针命令的默认超时上限。诊断探针都是毫秒级命令（`pi-web --version` 实测
    /// 约 55 ms，`ps`/`lsof` 约 20–50 ms），10 秒留出足够余量，同时保证一个挂住
    /// 的登录 shell 不会让依赖门控永久关闭且 UI 无提示。
    static let defaultTimeout: TimeInterval = 10
    /// 超时后等待 SIGTERM 生效的宽限时间；仍未退出才补一次 SIGKILL。
    static let terminationGrace: TimeInterval = 0.5

    private let timeout: TimeInterval
    private let terminationGrace: TimeInterval
    /// 默认的子进程环境；nil 表示继承应用进程环境（旧行为）。
    let environment: [String: String]?
    private let spawn: ([String], [String: String]?) throws -> ProbeProcess
    private let lock = NSLock()
    /// 最近一次正在进行的探针与它的取消标记；取消只针对这一次子进程。
    private var activeProcess: ProbeProcess?
    private var activeIsCancelled = false

    init(
        timeout: TimeInterval = SystemCommandRunner.defaultTimeout,
        terminationGrace: TimeInterval = SystemCommandRunner.terminationGrace,
        environment: [String: String]? = nil,
        spawn: (([String], [String: String]?) throws -> ProbeProcess)? = nil
    ) {
        self.timeout = timeout
        self.terminationGrace = terminationGrace
        self.environment = environment
        self.spawn = spawn ?? { arguments, environment in
            try ProcessProbeProcess(arguments: arguments, environment: environment)
        }
    }

    func run(_ arguments: [String]) -> String? {
        run(arguments, environment: environment, timeout: timeout).output
    }

    func run(_ arguments: [String], environment explicitEnvironment: [String: String]?) -> String? {
        run(arguments, environment: explicitEnvironment, timeout: timeout).output
    }

    func run(_ arguments: [String], timeout: TimeInterval) -> CommandRunResult {
        run(arguments, environment: environment, timeout: timeout)
    }

    func run(_ arguments: [String], environment explicitEnvironment: [String: String]?, timeout: TimeInterval) -> CommandRunResult {
        let process: ProbeProcess
        do {
            process = try spawn(arguments, explicitEnvironment)
        } catch {
            return CommandRunResult(output: nil)
        }
        lock.lock()
        activeProcess = process
        activeIsCancelled = false
        lock.unlock()
        defer {
            lock.lock()
            if activeProcess === process {
                activeProcess = nil
                activeIsCancelled = false
            }
            lock.unlock()
        }

        let exited = process.waitForExit(timeout: timeout)
        lock.lock()
        let wasCancelled = activeIsCancelled
        lock.unlock()
        if wasCancelled {
            // 取消只表示“不再等”；不再等宽限、不再补 SIGKILL，退出由子进程自己决定。
            return CommandRunResult(output: nil, cancelled: true)
        }
        if !exited {
            process.terminate()
            if !process.waitForExit(timeout: terminationGrace) {
                process.forceTerminate()
            }
            return CommandRunResult(output: nil, timedOut: true)
        }
        guard process.terminationStatus == 0 else { return CommandRunResult(output: nil) }
        return CommandRunResult(output: String(data: process.readStandardOutput(), encoding: .utf8))
    }

    func cancelRunningProbe() {
        lock.lock()
        let process = activeProcess
        if process != nil { activeIsCancelled = true }
        lock.unlock()
        // 只对本次启动的子进程发 SIGTERM；不按名字或进程组发信号。
        _ = process?.terminate()
    }
}

/// Process, listener and managed-instance inspection.
///
/// Commands are executed through the injected `CommandRunning`; the parsing
/// rules are pure static functions so they can be tested with fake `ps`/`lsof`
/// output. Liveness checks are injectable for the same reason.
///
/// This type only reports facts. The decision whether a process belongs to the
/// app lives in `ServiceOwnershipVerifier`, and no signal path may treat a
/// command line as ownership proof.
struct ProcessInspector {
    static let processCommand = "/bin/ps"
    static let listenerCommand = "/usr/sbin/lsof"

    private let runner: CommandRunning
    private let processIsAlive: (pid_t) -> Bool
    private let processExecutablePath: (pid_t) -> String?

    init(
        runner: CommandRunning = SystemCommandRunner(),
        processIsAlive: @escaping (pid_t) -> Bool = ProcessInspector.defaultProcessIsAlive,
        processExecutablePath: @escaping (pid_t) -> String? = ProcessInspector.defaultProcessExecutablePath
    ) {
        self.runner = runner
        self.processIsAlive = processIsAlive
        self.processExecutablePath = processExecutablePath
    }

    // MARK: - Pure parsing

    /// `kill(pid, 0)` liveness probe. PIDs 0 and 1 are never treated as app-owned.
    static func defaultProcessIsAlive(_ pid: pid_t) -> Bool {
        pid > 1 && kill(pid, 0) == 0
    }

    /// Real executable image path through libproc (`proc_pidpath`).
    ///
    /// This is stronger evidence than `ps -o comm=` and resolves the actual
    /// binary behind symlinks and shebang scripts. It only works for the
    /// current user's processes; other users' processes make it fail, which
    /// callers treat as "fall back to `ps -o comm=`".
    static func defaultProcessExecutablePath(_ pid: pid_t) -> String? {
        guard pid > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// Parses a PID record file (`app.pid`, or the legacy `service.pid` while
    /// it is being removed). Invalid values and PIDs below 2 are rejected,
    /// matching the previous inline checks.
    static func parsePIDRecord(_ text: String?) -> pid_t? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let pid = pid_t(trimmed), pid > 1 else { return nil }
        return pid
    }

    /// Parses `lsof -t` output: the first line is the listener, later lines are
    /// ignored exactly like the previous `split(...).first` implementation.
    static func parseListenerPID(_ output: String?) -> pid_t? {
        let firstLine = output?
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let pid = pid_t(firstLine), pid > 1 else { return nil }
        return pid
    }

    /// `ps -o command=` output without surrounding whitespace; nil when empty.
    static func parseProcessDescription(_ output: String?) -> String? {
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parses `ps -o pgid=` output. Values below 2 are rejected, matching the
    /// "never signal PID 0, 1 or a negative value" rule.
    static func parseProcessGroupID(_ output: String?) -> pid_t? {
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let processGroupID = pid_t(trimmed), processGroupID > 1 else { return nil }
        return processGroupID
    }

    /// Parses `ps -o lstart=` output. Whitespace runs are collapsed so the
    /// value is stable regardless of the column spacing `ps` chooses.
    static func parseProcessStartTime(_ output: String?) -> String? {
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Parses `ps -o comm=` output: the executable path of a PID.
    static func parseResolvedExecutable(_ output: String?) -> String? {
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parses `ps -o args=` output: the command line the process reports.
    ///
    /// Whitespace runs are collapsed to single spaces, which is the same
    /// normalization used for the recorded digest. `ps` does not preserve
    /// quoting, so argument boundaries inside the text are not recoverable
    /// (see docs/security-ownership.md).
    static func parseCommandLine(_ output: String?) -> String? {
        let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Commands

    func isProcessAlive(_ pid: pid_t) -> Bool {
        processIsAlive(pid)
    }

    /// Human readable command line for a PID, or "未知" when `ps` has nothing.
    func processDescription(of pid: pid_t) -> String {
        Self.parseProcessDescription(runner.run([Self.processCommand, "-o", "command=", "-p", "\(pid)"])) ?? "未知"
    }

    /// `ps -o pgid=` for a PID, or nil when `ps` cannot read the process (for
    /// example another user's process without `sudo`).
    func processGroupID(of pid: pid_t) -> pid_t? {
        Self.parseProcessGroupID(runner.run([Self.processCommand, "-o", "pgid=", "-p", "\(pid)"]))
    }

    /// `ps -o lstart=` for a PID, or nil when `ps` cannot read the process.
    /// The value has a one-second granularity, which limits PID-reuse
    /// detection (see docs/security-ownership.md).
    func processLaunchTime(of pid: pid_t) -> String? {
        Self.parseProcessStartTime(runner.run([Self.processCommand, "-o", "lstart=", "-p", "\(pid)"]))
    }

    /// `ps -o comm=` for a PID, or nil when `ps` cannot read the process.
    func resolvedExecutable(of pid: pid_t) -> String? {
        Self.parseResolvedExecutable(runner.run([Self.processCommand, "-o", "comm=", "-p", "\(pid)"]))
    }

    /// `ps -o args=` for a PID (normalized), or nil when `ps` cannot read the
    /// process or reports nothing. This is the live argv the ownership record
    /// is verified against.
    func commandLine(of pid: pid_t) -> String? {
        Self.parseCommandLine(runner.run([Self.processCommand, "-o", "args=", "-p", "\(pid)"]))
    }

    /// Executable identity for a PID: `proc_pidpath` first, `ps -o comm=` as a
    /// fallback. The provenance is returned with the path so records can mark
    /// weak evidence.
    func resolvedExecutableInfo(of pid: pid_t) -> (path: String, source: ServiceExecutableSource)? {
        if let path = processExecutablePath(pid), !path.isEmpty {
            return (path, .procPidPath)
        }
        guard let fallback = resolvedExecutable(of: pid) else { return nil }
        return (fallback, .psComm)
    }

    /// Facts needed to verify an ownership record.
    ///
    /// `pgid`, `lstart` and an executable identity are required; `commandLine`
    /// may be empty when `ps -o args=` yields nothing, and the verifier then
    /// treats the record as a mismatch (an empty argv is not ownership proof).
    func processFacts(of pid: pid_t) -> ServiceProcessFacts? {
        guard pid > 1,
              let processGroupID = processGroupID(of: pid),
              let launchedAt = processLaunchTime(of: pid),
              let executable = resolvedExecutableInfo(of: pid) else { return nil }
        return ServiceProcessFacts(
            pid: pid,
            processGroupID: processGroupID,
            launchedAt: launchedAt,
            resolvedExecutable: executable.path,
            resolvedExecutableSource: executable.source,
            commandLine: commandLine(of: pid) ?? ""
        )
    }

    /// PID listening on the configured TCP port, when there is one.
    func listenerPID(port: Int) -> pid_t? {
        Self.parseListenerPID(runner.run([Self.listenerCommand, "-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]))
    }

    /// Diagnostics form of `listenerPID(port:)`: "无" when no listener exists.
    func listenerPIDDescription(port: Int) -> String {
        listenerPID(port: port).map(String.init) ?? "无"
    }

    /// `ps` description of the current listener, or "无" when no listener exists.
    func listenerProcessDescription(port: Int) -> String {
        guard let pid = listenerPID(port: port) else { return "无" }
        return processDescription(of: pid)
    }
}
