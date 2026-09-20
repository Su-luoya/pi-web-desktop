import Darwin
import Foundation

/// 单次命令探测的结果。
///
/// `timedOut` / `cancelled` 存在的意义是：探针“没有返回”不等于“命令缺失或退出码
/// 非零”，诊断文本可以把前者写成可读原因（“依赖探测超时”），而不是静默把它当成
/// 普通的不可用。

/// Command probe protocols and the cancellable process implementation.

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
