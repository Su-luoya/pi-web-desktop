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
    /// 最近一次正在进行的探针（取消时发信号的对象）。
    private var activeProcess: ProbeProcess?
    /// 每个进行中的探针各自一个 token：取消标记按 token 记账。
    ///
    /// 旧实现用一个共享布尔：新探针注册时无条件把它清零，于是并发时 A 的取消
    /// 意图会被 B 注册清掉，B 也可能读到 A 留下的 true 把一次正常探测报成
    /// cancelled（诊断导出在后台跑 `ps`、主线程菜单校验同时也跑 `ps`，用的是
    /// 同一个实例）。按 token 记账后，取消只影响“取消那一刻真的在跑”的探针。
    private var nextRunToken: UInt64 = 0
    private var runningTokens: Set<UInt64> = []
    private var cancelledTokens: Set<UInt64> = []

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
        let token = nextRunToken
        nextRunToken &+= 1
        runningTokens.insert(token)
        activeProcess = process
        lock.unlock()
        defer {
            lock.lock()
            // token 在这里回收：`wasCancelled` 已经在下面读过了，所以不会丢。
            runningTokens.remove(token)
            cancelledTokens.remove(token)
            if activeProcess === process {
                activeProcess = nil
            }
            lock.unlock()
        }

        let exited = process.waitForExit(timeout: timeout)
        lock.lock()
        // 只看自己这个 token 的标记：并发探针之间不得串味。
        let wasCancelled = cancelledTokens.contains(token)
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
        // 取消“现在真的在跑”的全部探针，不碰之后才启动的。
        cancelledTokens.formUnion(runningTokens)
        let process = activeProcess
        lock.unlock()
        // 只对本次启动的子进程发 SIGTERM；不按名字或进程组发信号。
        _ = process?.terminate()
    }
}
