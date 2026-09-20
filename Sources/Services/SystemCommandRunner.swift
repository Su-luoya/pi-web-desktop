/// Runs commands through `/usr/bin/env` with a timeout and no shell.

import Darwin
import Foundation

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
