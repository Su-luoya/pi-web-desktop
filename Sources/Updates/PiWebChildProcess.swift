/// Pi Web install result types and the POSIX child process spawner.

import Darwin
import Foundation

// MARK: - 安装执行

/// 安装失败类别。固定枚举，不含子进程输出或路径。
enum PiWebUpdateInstallFailure: String, Equatable {
    case launchFailed
    case timedOut
    case cancelled
    case nonZeroExit
    /// 本次调用被整体拒绝：已经有一次安装正在进行，未启动第二个子进程（W2A A-2）。
    case alreadyRunning

    var text: String {
        switch self {
        case .launchFailed: return "无法启动安装进程"
        case .timedOut: return "安装超时"
        case .cancelled: return "安装被取消"
        case .nonZeroExit: return "安装命令以非零退出码结束"
        case .alreadyRunning: return "已有安装正在进行"
        }
    }
}

/// 一次安装执行的结果。`outputTail` 是子进程输出的有界末尾片段，只用于诊断；
/// 展示/记录前必须经过 `LogRedactor`。
struct PiWebUpdateInstallResult: Equatable {
    var exitCode: Int32?
    var timedOut: Bool
    var cancelled: Bool
    var launchFailed: Bool
    /// 本次调用因为已有安装正在进行而被拒绝：没有启动任何子进程（W2A A-2）。
    var alreadyRunning: Bool
    var startedAt: Date
    var finishedAt: Date
    var outputTail: String?
    /// 停止等待时对本次子进程实际做了什么（超时/取消才非 nil）：用于记录「已放弃」
    /// 状态与日志，让人知道“超时”不等于“进程已经结束”。
    var childProcessAction: UpdateAbandonedAttempt.ChildProcessAction?
    /// 取消请求落在「子进程已退出、只是在等管道读到 EOF」的收尾窗口内（F5，GitHub #121）：
    /// 这种情况不会写「已取消」，结果按真实退出码投递；此标记用于如实区分
    /// 「取消落在收尾窗口内」与「没来得及取消」。
    var cancelRequestedDuringFinish: Bool

    init(
        exitCode: Int32?,
        timedOut: Bool = false,
        cancelled: Bool = false,
        launchFailed: Bool = false,
        alreadyRunning: Bool = false,
        startedAt: Date,
        finishedAt: Date,
        outputTail: String? = nil,
        childProcessAction: UpdateAbandonedAttempt.ChildProcessAction? = nil,
        cancelRequestedDuringFinish: Bool = false
    ) {
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.launchFailed = launchFailed
        self.alreadyRunning = alreadyRunning
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outputTail = outputTail
        self.childProcessAction = childProcessAction
        self.cancelRequestedDuringFinish = cancelRequestedDuringFinish
    }

    /// nil 表示执行成功（退出码 0 且未超时/取消）。超时与取消优先于退出码。
    var failure: PiWebUpdateInstallFailure? {
        if alreadyRunning { return .alreadyRunning }
        if cancelled { return .cancelled }
        if timedOut { return .timedOut }
        if launchFailed { return .launchFailed }
        guard let exitCode else { return .launchFailed }
        return exitCode == 0 ? nil : .nonZeroExit
    }

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

/// 安装器抽象。生产实现是 `ProcessPiWebUpdateInstaller`；测试注入记录调用的
/// 替身，绝不执行真实 npm 或访问网络。
protocol PiWebUpdateInstalling: AnyObject {
    /// 以参数数组执行安装命令。超时按失败处理，并在结果里标记；`completion`
    /// 可能在任何队列上被调用。
    func install(
        _ plan: PiWebUpdateInstallPlan,
        timeout: TimeInterval,
        completion: @escaping (PiWebUpdateInstallResult) -> Void
    )
    /// 取消进行中的安装（若还有）。取消按失败处理：只终止**本次启动的**子进程组
    /// （至多一次，尽力而为），绝不触碰任何 Pi 进程。
    func cancel()
    /// 是否有安装正在进行（供 UI 门控）。同一实现同一时间最多执行一次安装；
    /// 重叠调用会被拒绝并回调 `PiWebUpdateInstallFailure.alreadyRunning`。
    var isRunning: Bool { get }
}

// MARK: - 子进程启动（独立进程组）

/// 一次 Pi Web 安装子进程的启动规格。只有可执行文件、argv 与（已白名单化的）
/// 环境；没有 shell 字符串、没有工作目录、没有额外继承的 fd。
struct PiWebChildProcessSpecification: Equatable {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]
}

/// 启动后的子进程句柄。
///
/// `processGroupIdentifier` 只有在 `usesOwnProcessGroup == true` 时才可信：那时
/// 子进程是**它自己的新进程组**的组长（组 id = 子进程 pid）。降级启动
/// （无法设置进程组属性）时子进程留在应用自己的进程组里，句柄标记 false，超时
/// **不得**发送任何信号（否则会波及应用自己与其它进程）。
struct PiWebChildProcessHandle: Equatable {
    var processIdentifier: pid_t
    var processGroupIdentifier: pid_t
    var usesOwnProcessGroup: Bool
    /// 子进程 stdout + stderr 的读端描述符；-1 表示没有可读输出（测试替身）。
    var outputDescriptor: Int32
}

/// 启动/等待/读取/终止子进程的注入点。
///
/// 生产实现是 `POSIXPiWebUpdateChildSpawner`。测试注入替身来断言：
/// 1. `spawn` 的规格（argv 与环境）；
/// 2. 启动属性确实要求“新建独立进程组”（见 `PiWebUpdateSpawnPolicy`）；
/// 3. 超时/取消时**只出现一次** `terminateOwnProcessGroup` 调用，且参数是本次
///    子进程 pid / 进程组，绝不会是任何 Pi 进程或其它 pid。
protocol PiWebUpdateChildSpawning: AnyObject {
    func spawn(_ specification: PiWebChildProcessSpecification) throws -> PiWebChildProcessHandle
    /// 阻塞等待子进程结束并回收；返回退出码（-1 表示无法确定）。
    func waitForExit(_ handle: PiWebChildProcessHandle) -> Int32
    /// 只对本次启动、且已确认在它自己新进程组里的子进程组发送一次终止信号
    /// （`SIGTERM`，尽力而为）。返回是否真的发出了信号；降级句柄一律返回 false，
    /// 不调用任何信号 API。
    func terminateOwnProcessGroup(_ handle: PiWebChildProcessHandle) -> Bool
}

/// `posix_spawn` 启动属性的唯一来源：让本次子进程成为**新的独立进程组**的组长。
///
/// 语义：`POSIX_SPAWN_SETPGROUP` + `pgroup = 0` ⇒ 子进程的进程组 id 等于它自己的
/// pid，因此后续信号只可能落在这一个组上。顺序是先 `setpgroup` 再 `setflags`：
/// 任一步失败都保证 `SETPGROUP` 标志不存在，子进程不会进入一个组 id 未定义的
/// 进程组（降级为普通启动，句柄标记 `usesOwnProcessGroup == false`）。
enum PiWebUpdateSpawnPolicy {
    /// 传给 `posix_spawnattr_setpgroup` 的值：0 = 新建进程组，组 id = 子进程 pid。
    static let newProcessGroup: pid_t = 0
    /// 完整属性：独立进程组 + 其余 fd 默认 close-on-exec（只保留文件动作显式
    /// 重定向的 0/1/2）。
    static var flags: Int16 {
        Int16(POSIX_SPAWN_SETPGROUP) | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
    }
    /// 降级属性：没有独立进程组，但 fd 卫生保持不变。
    static var degradedFlags: Int16 {
        Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
    }

    /// 把“新独立进程组”写进属性；成功返回 true。失败时属性保持未设置状态。
    @discardableResult
    static func apply(to attributes: inout posix_spawnattr_t?) -> Bool {
        guard posix_spawnattr_setpgroup(&attributes, newProcessGroup) == 0 else { return false }
        return posix_spawnattr_setflags(&attributes, flags) == 0
    }
}

/// 启动路径的失败原因。错误描述里只有 errno 与系统文案，不含路径或凭据。
enum PiWebUpdateSpawnError: LocalizedError, Equatable {
    case fileActionsUnavailable(Int32)
    case attributesUnavailable(Int32)
    case standardDescriptorsUnavailable(Int32)
    case spawnFailed(Int32)

    var errorDescription: String? {
        let reason: String
        let code: Int32
        switch self {
        case .fileActionsUnavailable(let value):
            reason = "无法准备文件重定向"
            code = value
        case .attributesUnavailable(let value):
            reason = "无法设置启动属性"
            code = value
        case .standardDescriptorsUnavailable(let value):
            reason = "无法重定向标准输入输出"
            code = value
        case .spawnFailed(let value):
            reason = "启动安装进程失败"
            code = value
        }
        return "\(reason)（errno \(code)：\(String(cString: strerror(code)))）"
    }
}

/// 生产启动器：`posix_spawn` + 参数数组 + 白名单环境 + 新独立进程组。
///
/// 只做四件事：启动一个子进程、回收它、返回它的输出读端、以及（仅在超时/取消时）
/// 对它**自己的**进程组发送一次 `SIGTERM`。没有 shell、没有 `sudo`、没有 `Process`
/// 对象，也没有对任何其它 pid / 进程组的信号调用。
final class POSIXPiWebUpdateChildSpawner: PiWebUpdateChildSpawning {
    func spawn(_ specification: PiWebChildProcessSpecification) throws -> PiWebChildProcessHandle {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var status = posix_spawn_file_actions_init(&fileActions)
        guard status == 0 else { throw PiWebUpdateSpawnError.fileActionsUnavailable(status) }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        status = posix_spawnattr_init(&attributes)
        guard status == 0 else { throw PiWebUpdateSpawnError.attributesUnavailable(status) }
        defer { posix_spawnattr_destroy(&attributes) }

        // 独立进程组（尽力而为）。失败时按现状降级：照常启动，但句柄标记 false，
        // 超时只放弃等待、绝不发送信号。
        let usesOwnProcessGroup = PiWebUpdateSpawnPolicy.apply(to: &attributes)
        if !usesOwnProcessGroup {
            status = posix_spawnattr_setflags(&attributes, PiWebUpdateSpawnPolicy.degradedFlags)
            guard status == 0 else { throw PiWebUpdateSpawnError.attributesUnavailable(status) }
        }

        // stdin 为 /dev/null；stdout/stderr 合并进一个管道，父进程读有界尾部。
        // 所有临时 fd 都由本函数显式管理：`ownedDescriptor` 把 0-2 的 fd 复制到
        // stderr 之上并关掉原件，因此“谁负责关闭”在每个分支上都唯一。
        let rawNullDevice = open("/dev/null", O_RDONLY)
        guard rawNullDevice >= 0 else {
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(errno)
        }
        guard let nullDevice = Self.ownedDescriptor(rawNullDevice) else {
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(errno)
        }
        defer { close(nullDevice) }

        var rawPipe: [Int32] = [-1, -1]
        guard pipe(&rawPipe) == 0 else {
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(errno)
        }
        guard let readDescriptor = Self.ownedDescriptor(rawPipe[0]) else {
            close(rawPipe[1])
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(errno)
        }
        guard let writeDescriptor = Self.ownedDescriptor(rawPipe[1]) else {
            close(readDescriptor)
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(errno)
        }

        status = posix_spawn_file_actions_adddup2(&fileActions, nullDevice, STDIN_FILENO)
        guard status == 0 else {
            close(readDescriptor)
            close(writeDescriptor)
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(status)
        }
        status = posix_spawn_file_actions_adddup2(&fileActions, writeDescriptor, STDOUT_FILENO)
        guard status == 0 else {
            close(readDescriptor)
            close(writeDescriptor)
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(status)
        }
        status = posix_spawn_file_actions_adddup2(&fileActions, writeDescriptor, STDERR_FILENO)
        guard status == 0 else {
            close(readDescriptor)
            close(writeDescriptor)
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(status)
        }
        // 管道写端与 /dev/null 只在子进程里以 0/1/2 的形式存在：把临时 fd 显式
        // 关掉，子进程不会多继承任何描述符（外层的 close 只关父进程这一侧）。
        status = posix_spawn_file_actions_addclose(&fileActions, writeDescriptor)
        guard status == 0 else {
            close(readDescriptor)
            close(writeDescriptor)
            throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(status)
        }
        if nullDevice != STDIN_FILENO {
            status = posix_spawn_file_actions_addclose(&fileActions, nullDevice)
            guard status == 0 else {
                close(readDescriptor)
                close(writeDescriptor)
                throw PiWebUpdateSpawnError.standardDescriptorsUnavailable(status)
            }
        }

        var arguments = try Self.duplicateCStrings([specification.executablePath] + specification.arguments)
        defer { Self.freeCStrings(arguments) }
        var environment = try Self.duplicateCStrings(
            specification.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        )
        defer { Self.freeCStrings(environment) }

        var pid: pid_t = 0
        status = posix_spawn(&pid, specification.executablePath, &fileActions, &attributes, &arguments, &environment)
        guard status == 0, pid > 1 else {
            close(readDescriptor)
            close(writeDescriptor)
            throw PiWebUpdateSpawnError.spawnFailed(status == 0 ? ECHILD : status)
        }
        // 父进程这一侧立刻关掉写端：只有子进程还持有时，读到 EOF 才表示它结束了。
        close(writeDescriptor)
        return PiWebChildProcessHandle(
            processIdentifier: pid,
            // 降级时组 id 不可信：写 0，任何发送信号的路径都会先拒绝它。
            processGroupIdentifier: usesOwnProcessGroup ? pid : 0,
            usesOwnProcessGroup: usesOwnProcessGroup,
            outputDescriptor: readDescriptor
        )
    }

    func waitForExit(_ handle: PiWebChildProcessHandle) -> Int32 {
        guard handle.processIdentifier > 1 else { return -1 }
        var status: Int32 = 0
        while waitpid(handle.processIdentifier, &status, 0) == -1 {
            guard errno == EINTR else { return -1 }
        }
        return Self.exitCode(fromWaitStatus: status)
    }

    func terminateOwnProcessGroup(_ handle: PiWebChildProcessHandle) -> Bool {
        // 硬边界：只有“本次启动、已确认处在它自己的新进程组里、组 id 等于子进程
        // pid”的句柄才会被送信号。降级句柄（共享应用进程组）一律不发信号，
        // 因此不可能波及应用自己、其它进程组或任何 Pi 进程。
        guard handle.usesOwnProcessGroup,
              handle.processGroupIdentifier == handle.processIdentifier,
              handle.processIdentifier > 1 else { return false }
        return killpg(handle.processGroupIdentifier, SIGTERM) == 0
    }

    /// `waitpid` 原始状态 → 退出码：正常退出取高 8 位，被信号终止取信号号
    /// （与 Foundation `Process.terminationStatus` 的取值一致）。
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        if status & 0x7F == 0 { return (status >> 8) & 0xFF }
        return status & 0x7F
    }

    /// 保证返回的 fd 高于 stderr 且由调用方拥有；0-2 的输入先复制再关原件。
    private static func ownedDescriptor(_ descriptor: Int32) -> Int32? {
        guard descriptor >= 0 else { return nil }
        guard descriptor <= STDERR_FILENO else { return descriptor }
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        close(descriptor)
        return copy > STDERR_FILENO ? copy : nil
    }

    /// NULL 结尾的 C 字符串数组；分配失败抛错而不是静默截断。
    private static func duplicateCStrings(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = []
        result.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let duplicated = strdup(string) else {
                freeCStrings(result)
                throw PiWebUpdateSpawnError.spawnFailed(ENOMEM)
            }
            result.append(duplicated)
        }
        result.append(nil)
        return result
    }

    private static func freeCStrings(_ strings: [UnsafeMutablePointer<CChar>?]) {
        for pointer in strings { free(pointer) }
    }
}
