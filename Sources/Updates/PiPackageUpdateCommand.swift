/// Restricted `pi update npm:<package>` command execution and results.

import Foundation

// MARK: - 命令执行

/// 命令失败类别。固定枚举，不含子进程输出或路径。
enum PiPackageUpdateCommandFailure: String, Equatable {
    /// 根本没有执行：同一执行器实例上还有一次运行没结束（一次只跑一个命令）。
    case notAttempted
    case launchFailed
    case timedOut
    case abandoned
    case nonZeroExit

    var text: String {
        switch self {
        case .notAttempted: return "更新命令未被执行（执行器上一次运行尚未结束）"
        case .launchFailed: return "无法启动更新命令"
        case .timedOut: return "更新命令超时（已放弃等待，没有向任何进程发送信号）"
        case .abandoned: return "更新命令被放弃等待（没有向任何进程发送信号）"
        case .nonZeroExit: return "更新命令以非零退出码结束"
        }
    }
}

/// 一次命令执行的结果。`stdoutTail` / `stderrTail` 是子进程输出的有界末尾片段，
/// 只在调用方脱敏后展示或记录。
struct PiPackageUpdateCommandResult: Equatable {
    var exitCode: Int32?
    /// 本次运行没有执行（执行器忙）：`exitCode` 为 nil，`failure` 为 `.notAttempted`。
    var notAttempted: Bool
    /// 没执行的原因是「上一次命令已放弃等待、退出仍未确认」（B-1/W3）：调用方据此
    /// 给出「重启应用可恢复」的可见原因，而不是笼统的“执行器忙”。
    var awaitingAbandonedChildExit: Bool
    var launchFailed: Bool
    var timedOut: Bool
    var abandoned: Bool
    var startedAt: Date
    var finishedAt: Date
    var stdoutTail: String?
    var stderrTail: String?

    init(
        exitCode: Int32?,
        notAttempted: Bool = false,
        awaitingAbandonedChildExit: Bool = false,
        launchFailed: Bool = false,
        timedOut: Bool = false,
        abandoned: Bool = false,
        startedAt: Date,
        finishedAt: Date,
        stdoutTail: String? = nil,
        stderrTail: String? = nil
    ) {
        self.exitCode = exitCode
        self.notAttempted = notAttempted
        self.awaitingAbandonedChildExit = awaitingAbandonedChildExit
        self.launchFailed = launchFailed
        self.timedOut = timedOut
        self.abandoned = abandoned
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
    }

    /// nil 表示执行成功（退出码 0 且未超时/放弃/启动失败）。
    var failure: PiPackageUpdateCommandFailure? {
        if notAttempted { return .notAttempted }
        if abandoned { return .abandoned }
        if timedOut { return .timedOut }
        if launchFailed { return .launchFailed }
        guard let exitCode else { return .launchFailed }
        return exitCode == 0 ? nil : .nonZeroExit
    }

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

/// 更新命令执行器的注入点。生产实现是 `ProcessPiPackageUpdateCommand`。
///
/// 接口里没有任何发送信号、终止或修改进程的方法：超时与退出只“放弃等待”，
/// 子进程继续按自己的方式结束。测试注入记录调用的替身，绝不执行真实 `pi`。
protocol PiPackageUpdateRunning: AnyObject {
    /// 以参数数组执行计划里的命令。`completion` 可能在任何队列上被调用。
    func run(
        _ plan: PiPackageUpdatePlan,
        timeout: TimeInterval,
        completion: @escaping (PiPackageUpdateCommandResult) -> Void
    )
    /// 放弃等待进行中的命令。**不发送任何信号**，也不终止子进程。
    func abandon()
    /// 非阻塞读状态（GitHub #107）：是否有一次运行正在进行（含已经放弃等待、
    /// 但子进程退出还没确认的窗口）。供菜单/入口在点击之前给出可见原因，
    /// 不需要创建任何进程或阻塞调用线程。
    var isRunning: Bool { get }
    /// 非阻塞读状态（GitHub #107）：是否有已经放弃等待、但退出尚未确认的子进程。
    /// 这种窗口的拒绝要给出「重启应用即可恢复」的提示，而不是笼统的「正在运行」。
    var abandonedChildrenUnconfirmed: Bool { get }
}

/// 生产执行器：`Process` + 固定参数数组，没有 shell、没有 `sudo`、没有信号。
///
/// - 可执行文件与 argv 只来自 `PiPackageUpdatePlan`（`["update", "npm:<包名>"]`）；
/// - 环境变量白名单化（与 #20/#21 同一组键）：不把无关凭据、`npm_config_*`、
///   代理变量透传给子进程；PATH 前置 `pi` 所在目录并补上系统目录；
/// - stdout/stderr 分别合并进有界尾部片段，只用于诊断；
/// - 超时或 `abandon()` 只标记结果并停止等待：本类型不调用任何信号或终止 API。
final class ProcessPiPackageUpdateCommand: PiPackageUpdateRunning {
    /// 保留的子进程输出上限（每条流，字符）。
    static let outputTailLimit = 2000
    /// 进程结束后等两条管道读到 EOF 的宽限时间默认值（有界；超时后照常结束）。
    static let defaultPipeDrainGrace: TimeInterval = 0.5

    /// 进程已经不在运行、但结束回调还没轮到状态队列时，超时计时最多再让出的轮数与间隔（B-2）：
    /// 退出码是比超时更可信的证据，但要保持有界，不会因为等不到回调而永久挂住。
    static let timeoutRetryDelay: TimeInterval = 0.2
    static let maxTimeoutRetries = 5

    private let stateQueue = DispatchQueue(label: "io.github.su-luoya.pi-web-desktop.pi-package-update-command")
    /// 结果投递队列（F1，GitHub #121）：`stateQueue` 上跑着协调器的整条安装后同步链
    /// （版本探测、验证探针、写历史），在主线程读 `isRunning` 就要等它跑完。结果改在
    /// 这个队列上回调，让协调器的长耗时工作离开 `stateQueue`（与 Pi Web / Pi CLI 同型）。
    private let deliveryQueue = DispatchQueue(label: "io.github.su-luoya.pi-web-desktop.pi-package-update-delivery")
    private let clock: () -> Date
    private let baseEnvironment: [String: String]
    private let redact: (String) -> String
    private let recordAbandonedAttempt: (UpdateAbandonedAttempt) -> Void
    /// 等管道读到 EOF 的宽限时间（可注入；生产用默认 0.5s）。
    private let pipeDrainGrace: TimeInterval

    private var process: Process?
    private var plan: PiPackageUpdatePlan?
    private var timeout: TimeInterval = 0
    private var timer: DispatchSourceTimer?
    private var drainTimer: DispatchSourceTimer?
    private var completion: ((PiPackageUpdateCommandResult) -> Void)?
    /// 本轮运行是否已有结果（每次 `run` 开始时复位，不是实例级的一次性标记）。
    private var finished = false
    /// 是否有一次运行正在进行：忙时拒绝新的 `run`，但必须如实回调结果。
    private var running = false
    /// 已经放弃等待（超时 / `abandon()`）、但退出尚未确认的子进程：`count` 就是「在飞」
    /// 计数。放弃路径不发送任何信号，子进程可能在放弃之后继续运行，因此在它的退出被
    /// 确认之前，新的 `run` 一律按「忙」拒绝（否则两个 `npm i -g` 会并发写同一个 prefix）。
    /// 按身份登记，保证同一条退出通知恰好结清一次；跨轮次保留，`resetRunStateLocked()`
    /// 不得清空（清空会让门控失效）。
    private var abandonedProcesses: [Process] = []
    private var timedOut = false
    private var abandoned = false
    private var startedAt: Date?
    private var stdoutTail = ""
    private var stderrTail = ""
    /// 两条管道的增量 UTF-8 解码器（F2，GitHub #121）：一次读把多字节字符截断时，
    /// 未收齐的尾部留到下一块，不再丢弃整块文本。
    private var stdoutDecoder = IncrementalUTF8Decoder()
    private var stderrDecoder = IncrementalUTF8Decoder()
    private var stdoutDrained = false
    private var stderrDrained = false
    /// 本轮运行的两条管道读端：用来忽略上一轮运行残留的管道回调（状态按轮次隔离）。
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    /// 本次命令是否已经写过「已放弃」记录（至多一条）。
    private var didRecordAbandonedAttempt = false
    /// 本轮超时计时为了让出「退出码还没到」而重排的次数（有界）。
    private var timeoutRetries = 0
    private var pendingFinish: (exitCode: Int32?, launchFailed: Bool)?

    init(
        clock: @escaping () -> Date = { Date() },
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        redact: @escaping (String) -> String = { LogRedactor().redact($0) },
        recordAbandonedAttempt: @escaping (UpdateAbandonedAttempt) -> Void = { _ in },
        pipeDrainGrace: TimeInterval = ProcessPiPackageUpdateCommand.defaultPipeDrainGrace
    ) {
        self.clock = clock
        self.baseEnvironment = baseEnvironment
        self.redact = redact
        self.recordAbandonedAttempt = recordAbandonedAttempt
        self.pipeDrainGrace = pipeDrainGrace
    }

    func run(
        _ plan: PiPackageUpdatePlan,
        timeout: TimeInterval,
        completion: @escaping (PiPackageUpdateCommandResult) -> Void
    ) {
        stateQueue.async { [weak self] in
            self?.startLocked(plan, timeout: timeout, completion: completion)
        }
    }

    /// 是否有一次运行正在进行（供 UI 门控，GitHub #107）。已经放弃等待、但子进程
    /// 退出还没确认时也算「进行中」：这段时间里不会再启动第二次运行。
    var isRunning: Bool {
        stateQueue.sync { running || !abandonedProcesses.isEmpty }
    }

    /// 已经放弃等待、但子进程退出还没确认（GitHub #107）：这种窗口下的拒绝要给出
    /// 「重启应用即可恢复」的可见提示，而不是一句「正在运行」之后静默置灰。
    var abandonedChildrenUnconfirmed: Bool {
        stateQueue.sync { !abandonedProcesses.isEmpty }
    }

    func abandon() {
        stateQueue.async { [weak self] in
            guard let self, self.running, !self.finished else { return }
            // B-3：放弃等待落在「进程已结束、只是在等管道读到 EOF」的宽限窗口里时，
            // 并不算放弃等待：子进程已经退出、结果会照常投递。此时写一条
            // `finishedAt == nil` 的「已放弃」记录是失实的历史，登记也永远无人结清。
            guard self.pendingFinish == nil, self.process?.isRunning != false else { return }
            self.abandoned = true
            self.recordAbandonedAttemptLocked(reason: .abandonedWaiting)
            self.finishLocked(exitCode: nil)
        }
    }

    // MARK: - 内部（全部在 stateQueue 上执行）

    private func startLocked(
        _ plan: PiPackageUpdatePlan,
        timeout: TimeInterval,
        completion: @escaping (PiPackageUpdateCommandResult) -> Void
    ) {
        // B-1：同一实例一次只跑一个命令。忙时拒绝本次运行，但拒绝也必须回调
        // 结果（`.notAttempted`）——绝不能静默 return 让调用方永远等不到 completion。
        // W3：放弃等待（超时/abandon）之后旧子进程可能还活着，在它的退出被确认之前
        // 同样按「忙」拒绝，不新增子进程、也不覆盖旧回调与计时器。
        guard !running, abandonedProcesses.isEmpty else {
            let now = clock()
            let refused = PiPackageUpdateCommandResult(
                exitCode: nil,
                notAttempted: true,
                // B-1/W3：旧子进程已放弃等待但退出还没确认时，拒绝的理由不是笼统的
                // “执行器忙”，而是「重启应用可恢复」的未确认窗口。
                awaitingAbandonedChildExit: !abandonedProcesses.isEmpty,
                startedAt: now,
                finishedAt: now
            )
            // F1：拒绝也走 `deliveryQueue`，与正常结果同一投递语义。
            deliveryQueue.async { completion(refused) }
            return
        }
        resetRunStateLocked()
        running = true
        self.completion = completion
        self.plan = plan
        self.timeout = timeout
        self.startedAt = clock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.environment = PiPackageUpdateEnvironment.environment(
            base: baseEnvironment,
            piExecutablePath: plan.executablePath
        )
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // 记录本轮管道的读端：回调里用它判断事件是否属于本轮运行。
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.receive(data, toStdout: true, from: handle)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.receive(data, toStdout: false, from: handle)
        }
        process.terminationHandler = { [weak self] finishedProcess in
            self?.stateQueue.async {
                guard let self else { return }
                // 退出确认要结清「放弃等待」登记：晚到的退出通知同样要清账，否则门控会
                // 永久拒绝后续运行（W3）。
                self.settleAbandonedChildLocked(finishedProcess)
                // 上一轮运行残留的结束回调不得替本轮收尾（B-1：状态按轮次隔离）。
                guard finishedProcess === self.process else { return }
                self.finishLocked(exitCode: finishedProcess.terminationStatus)
            }
        }
        self.process = process
        do {
            try process.run()
        } catch {
            finishLocked(exitCode: nil, launchFailed: true)
            return
        }
        scheduleTimeoutLocked(timeout)
    }

    /// 每次运行独立的状态（B-1）：结束/超时/放弃标记、输出片段与暂存结果都在
    /// 新一轮开始时复位，否则第二次运行会被当成「已完成」而静默丢弃。
    private func resetRunStateLocked() {
        process = nil
        plan = nil
        timeout = 0
        // 防御性：先取消再释放。当前调用点都在 `completeLocked` 之后（计时器已取消并
        // 置空），但顺序反了会让「cancel 过的计时器还持有 handler」这类问题不可见。
        timer?.cancel()
        timer = nil
        drainTimer?.cancel()
        drainTimer = nil
        completion = nil
        finished = false
        timedOut = false
        abandoned = false
        startedAt = nil
        stdoutTail = ""
        stderrTail = ""
        stdoutDecoder = IncrementalUTF8Decoder()
        stderrDecoder = IncrementalUTF8Decoder()
        stdoutHandle = nil
        stderrHandle = nil
        stdoutDrained = false
        stderrDrained = false
        didRecordAbandonedAttempt = false
        timeoutRetries = 0
        pendingFinish = nil
    }

    private func scheduleTimeoutLocked(_ timeout: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + max(0.05, timeout))
        // 弱捕获计时器自身：身份判定不能靠强引用自己（timer → handler → timer 会形成
        // 引用环，`cancel()` 后计时器永不析构）。触发时计时器必然还活着，比较身份即可。
        timer.setEventHandler { [weak self, weak timer] in
            // 只认本轮运行的计时器：上一轮残留的触发不得影响本轮。
            guard let self, let timer, self.timer === timer, !self.finished else { return }
            // B-2：进程已经结束（只是在等管道读到 EOF 的宽限期）时超时计时不再算数，
            // 否则会把正常退出的命令记成超时，并写下一条不实的「已放弃」记录。
            guard self.pendingFinish == nil else { return }
            // B-2 补充：进程已经不在运行、只是结束回调还没轮到状态队列时，先让出一小段
            // 时间等退出码到达（有界）——否则会把已经退出的命令记成超时并写下一条
            // 「已放弃」记录；多次让出后仍然只看到超时，才按超时处理。
            if self.process?.isRunning == false, self.timeoutRetries < Self.maxTimeoutRetries {
                self.timeoutRetries += 1
                self.scheduleTimeoutLocked(Self.timeoutRetryDelay)
                return
            }
            // 超时只放弃等待：不发送信号、不终止子进程；同时写一条「已放弃」记录。
            self.timedOut = true
            self.recordAbandonedAttemptLocked(reason: .timedOut)
            self.finishLocked(exitCode: nil)
        }
        timer.resume()
        self.timer = timer
    }

    /// 写一条「已放弃」记录（GitHub #62）：组件是具体包名，实际动作是“没有发送
    /// 任何信号”，结束时间未知（`finishedAt == nil`）。
    private func recordAbandonedAttemptLocked(reason: UpdateAbandonedAttempt.Reason) {
        guard !didRecordAbandonedAttempt, let plan else { return }
        didRecordAbandonedAttempt = true
        let recordedAt = clock()
        recordAbandonedAttempt(UpdateAbandonedAttempt(
            componentKind: .piPackage,
            packageName: plan.packageName,
            reason: reason,
            commandSummary: UpdateAbandonedAttempt.makeCommandSummary(
                executablePath: plan.executablePath,
                arguments: plan.arguments,
                redactingWith: redact
            ),
            startedAt: startedAt ?? recordedAt,
            timeout: timeout,
            finishedAt: nil,
            source: plan.source,
            recordedAt: recordedAt,
            childProcessAction: .waitedWithoutSignals,
            derivedProcessesConfirmedEnded: nil
        ))
    }

    /// 管道回调统一入口：空数据 = 读到 EOF，标记已经读完（可能触发暂存的结束）。
    private func receive(_ data: Data, toStdout: Bool, from handle: FileHandle) {
        stateQueue.async { [weak self] in
            guard let self, !self.finished else { return }
            // 只接受本轮运行的管道事件：上一轮管道可能在结束后才把 EOF/数据投递进来。
            let currentHandle = toStdout ? self.stdoutHandle : self.stderrHandle
            guard handle === currentHandle else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                // F2：EOF 时冲刷未收齐的多字节尾部，不丢同一块里已经完整的前缀。
                self.appendDecodedLocked(
                    toStdout ? self.stdoutDecoder.decode(Data(), final: true)
                        : self.stderrDecoder.decode(Data(), final: true),
                    toStdout: toStdout
                )
                if toStdout {
                    self.stdoutDrained = true
                } else {
                    self.stderrDrained = true
                }
                self.completePendingLocked()
                return
            }
            self.appendDecodedLocked(
                toStdout ? self.stdoutDecoder.decode(data) : self.stderrDecoder.decode(data),
                toStdout: toStdout
            )
        }
    }

    /// 追加一段解码后的输出到对应的尾部（同一轮状态队列上调用）。
    private func appendDecodedLocked(_ text: String, toStdout: Bool) {
        guard !text.isEmpty else { return }
        if toStdout {
            stdoutTail = Self.bounded(stdoutTail + text)
        } else {
            stderrTail = Self.bounded(stderrTail + text)
        }
    }

    private static func bounded(_ text: String, limit: Int = ProcessPiPackageUpdateCommand.outputTailLimit) -> String {
        guard text.count > limit else { return text }
        return String(text.suffix(limit))
    }

    private func finishLocked(exitCode: Int32?, launchFailed: Bool = false) {
        guard !finished, pendingFinish == nil else { return }
        // 正常结束时先等两条管道读到 EOF（有界），保证尾部输出不丢；
        // 超时/放弃路径直接结束：不做任何阻塞，也不向任何进程发送信号。
        if exitCode != nil, !(stdoutDrained && stderrDrained) {
            pendingFinish = (exitCode, launchFailed)
            scheduleDrainDeadlineLocked()
            return
        }
        // 放弃等待（exitCode == nil 且不是启动失败）：子进程可能还在运行，先登记，
        // 等它的退出通知到达时结清；这期间新 `run` 走「忙」拒绝路径。
        // 登记点必须在这里而不是调用点：排水宽限窗口里 `abandon()` 会在这里提前
        // return（其实并不算放弃等待），那种情况子进程已经退出，登记就永远无人结清。
        if exitCode == nil, !launchFailed {
            registerAbandonedChildLocked()
        }
        completeLocked(exitCode: exitCode, launchFailed: launchFailed)
    }

    /// 放弃等待时登记子进程：在它的退出被确认之前，新的 `run` 一律按「忙」拒绝。
    /// 这是有意的保守取舍：放弃路径不发送任何信号，若子进程永不退出（或不理 TERM），
    /// 门控会一直关闭——宁可让后续批次记为「未执行」，也不并发写同一个 prefix。
    private func registerAbandonedChildLocked() {
        guard let process, !finished else { return }
        guard !abandonedProcesses.contains(where: { $0 === process }) else { return }
        abandonedProcesses.append(process)
    }

    /// 子进程退出已确认：把「放弃等待」登记恰好结清一次（晚到的退出通知同样清账）。
    private func settleAbandonedChildLocked(_ finishedProcess: Process) {
        guard let index = abandonedProcesses.firstIndex(where: { $0 === finishedProcess }) else { return }
        abandonedProcesses.remove(at: index)
    }

    /// 管道读完且进程已结束时，用暂存的结果完成。
    private func completePendingLocked() {
        guard let pending = pendingFinish, !finished, stdoutDrained, stderrDrained else { return }
        pendingFinish = nil
        completeLocked(exitCode: pending.exitCode, launchFailed: pending.launchFailed)
    }

    /// 等管道读完的宽限计时：到期还没有 EOF 就照常结束（只是尾部可能少一段）。
    private func scheduleDrainDeadlineLocked() {
        guard drainTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + pipeDrainGrace)
        // 与超时计时器同理：弱捕获避免 timer → handler → timer 引用环。
        timer.setEventHandler { [weak self, weak timer] in
            guard let self, let timer, self.drainTimer === timer, let pending = self.pendingFinish, !self.finished else { return }
            self.pendingFinish = nil
            self.completeLocked(exitCode: pending.exitCode, launchFailed: pending.launchFailed)
        }
        timer.resume()
        self.drainTimer = timer
    }

    private func completeLocked(exitCode: Int32?, launchFailed: Bool) {
        guard !finished else { return }
        finished = true
        running = false
        timer?.cancel()
        timer = nil
        drainTimer?.cancel()
        drainTimer = nil
        // L-4（GitHub #127）：与 CLI / Web 的收尾路径一致，完成时冲刷两个解码器的暂存字节。
        // 排水宽限到期结束走的就是这条路径，此前只有 EOF 路径冲刷，尾部可能少一个不完整字符。
        appendDecodedLocked(stdoutDecoder.decode(Data(), final: true), toStdout: true)
        appendDecodedLocked(stderrDecoder.decode(Data(), final: true), toStdout: false)
        if let handle = (process?.standardOutput as? Pipe)?.fileHandleForReading {
            handle.readabilityHandler = nil
        }
        if let handle = (process?.standardError as? Pipe)?.fileHandleForReading {
            handle.readabilityHandler = nil
        }
        let finishedAt = clock()
        // B-2：已经观测到退出码时不再判定为超时——退出码是更可信的证据。
        let timedOut = self.timedOut && exitCode == nil
        let result = PiPackageUpdateCommandResult(
            exitCode: exitCode,
            launchFailed: launchFailed,
            timedOut: timedOut,
            abandoned: abandoned,
            startedAt: startedAt ?? finishedAt,
            finishedAt: finishedAt,
            stdoutTail: stdoutTail.isEmpty ? nil : stdoutTail,
            stderrTail: stderrTail.isEmpty ? nil : stderrTail
        )
        let completion = self.completion
        self.completion = nil
        self.process = nil
        self.pendingFinish = nil
        // F1：在 `deliveryQueue` 上回调，不占住 `stateQueue`。
        if let completion {
            deliveryQueue.async { completion(result) }
        }
    }
}
