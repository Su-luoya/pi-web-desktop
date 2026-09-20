/// Restricted `pi update --self` child process execution and its results.

import Foundation

// MARK: - 命令执行

/// 命令失败类别。固定枚举，不含子进程输出或路径。
enum PiCLIUpdateCommandFailure: String, Equatable {
    case launchFailed
    case timedOut
    case abandoned
    case nonZeroExit
    /// 同一个执行器上已有命令在跑：本次调用被拒绝，没有启动第二个子进程。
    case alreadyRunning

    var text: String {
        switch self {
        case .launchFailed: return "无法启动更新命令"
        case .timedOut: return "更新命令超时（已放弃等待，没有向任何进程发送信号）"
        case .abandoned: return "更新命令被放弃等待（没有向任何进程发送信号）"
        case .nonZeroExit: return "更新命令以非零退出码结束"
        case .alreadyRunning: return "已有更新命令正在运行"
        }
    }
}

/// 一次命令执行的结果。`stdoutTail` / `stderrTail` 是子进程输出的有界末尾片段，
/// 只在调用方脱敏后展示或记录。
struct PiCLIUpdateCommandResult: Equatable {
    var exitCode: Int32?
    var launchFailed: Bool
    var timedOut: Bool
    var abandoned: Bool
    /// 本次调用被拒绝：同一个执行器上的上一轮还没结束（或还没结束过），没有启动
    /// 第二个子进程。
    var alreadyRunning: Bool
    var startedAt: Date
    var finishedAt: Date
    var stdoutTail: String?
    var stderrTail: String?

    init(
        exitCode: Int32?,
        launchFailed: Bool = false,
        timedOut: Bool = false,
        abandoned: Bool = false,
        alreadyRunning: Bool = false,
        startedAt: Date,
        finishedAt: Date,
        stdoutTail: String? = nil,
        stderrTail: String? = nil
    ) {
        self.exitCode = exitCode
        self.launchFailed = launchFailed
        self.timedOut = timedOut
        self.abandoned = abandoned
        self.alreadyRunning = alreadyRunning
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
    }

    /// nil 表示执行成功（退出码 0 且未超时/放弃/启动失败）。
    var failure: PiCLIUpdateCommandFailure? {
        if alreadyRunning { return .alreadyRunning }
        if abandoned { return .abandoned }
        if timedOut { return .timedOut }
        if launchFailed { return .launchFailed }
        guard let exitCode else { return .launchFailed }
        return exitCode == 0 ? nil : .nonZeroExit
    }

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

/// 更新命令执行器的注入点。生产实现是 `ProcessPiCLIUpdateCommand`。
///
/// 接口里没有任何发送信号、终止或修改进程的方法：超时与退出只“放弃等待”，
/// 子进程继续按自己的方式结束。测试注入记录调用的替身，绝不执行真实 `pi`。
protocol PiCLIUpdateRunning: AnyObject {
    /// 以参数数组执行计划里的命令。`completion` 可能在任何队列上被调用。
    func run(
        _ plan: PiCLIUpdatePlan,
        timeout: TimeInterval,
        completion: @escaping (PiCLIUpdateCommandResult) -> Void
    )
    /// 放弃等待进行中的命令。**不发送任何信号**，也不终止子进程。
    func abandon()
    /// 是否有命令正在运行（供 UI 门控）。
    var isRunning: Bool { get }
}

/// 生产执行器：`Process` + 固定参数数组，没有 shell、没有 `sudo`、没有信号。
///
/// - 可执行文件与 argv 只来自 `PiCLIUpdatePlan`（`["update", "--self"]`）；
/// - 环境变量白名单化（与 #20 的 npm 路径同一组键）：不把无关凭据、
///   `npm_config_*`、代理变量透传给子进程；PATH 前置 `pi` 所在目录并补上系统目录，
///   因为 npm 安装的 `pi` 是 `#!/usr/bin/env node` 脚本；
/// - stdout/stderr 分别合并进有界尾部片段，只用于诊断；
/// - 超时或 `abandon()` 只标记结果并停止等待：本类型不调用任何信号或终止 API；
/// - 可重入（W3B F1）：每一轮 `run` 的状态都在独立的 `Attempt` 里，轮与轮之间
///   不共享「终态」标志——生产里这个执行器是单例，上一轮结束后必须能再跑一轮。
final class ProcessPiCLIUpdateCommand: PiCLIUpdateRunning {
    /// 保留的子进程输出上限（每条流，字符）。
    static let outputTailLimit = 2000
    /// 进程结束后等两条管道读到 EOF 的宽限时间（有界；超时后照常结束）。
    /// `readabilityHandler` 是异步投递的，不等就可能丢掉最后一段输出（正是失败
    /// 原因所在）；但也不能无限等（子进程可能留下持有写端的孩子）。
    static let defaultPipeDrainGrace: TimeInterval = 0.5
    /// 超时落在「进程已结束、只是结束回调还没轮到」窗口里时的有界让出次数与间隔
    /// （与扩展包执行器同一处理，B-2）。
    static let timeoutRetryDelay: TimeInterval = 0.2
    static let maxTimeoutRetries = 5

    private let stateQueue = DispatchQueue(label: "io.github.su-luoya.pi-web-desktop.pi-cli-update-command")
    private let clock: () -> Date
    private let baseEnvironment: [String: String]
    private let redact: (String) -> String
    private let recordAbandonedAttempt: (UpdateAbandonedAttempt) -> Void
    /// 等两条管道读到 EOF 的宽限时间；可注入，让「放弃等待落在排水窗口里」的
    /// 场景能在测试里确定地复现（B-3）。
    private let pipeDrainGrace: TimeInterval

    /// 当前正在执行的一轮；nil 表示空闲。每次 `run` 新建一份，后来者不能覆盖它
    /// （W2A A-1/A-2），上一轮彻底结束后也必须能换成新的一份（W3B F1）。只在
    /// stateQueue 上访问。
    private var attempt: Attempt?
    /// 已放弃等待、但退出尚未确认的子进程数量（W3B F1）：只要它大于 0 就拒绝新的
    /// 一轮，避免两个 `pi update --self` 同时跑。只在 stateQueue 上访问。
    private var abandonedChildrenInFlight = 0
    /// 放弃等待后仍在等退出确认的子进程：保留 `Attempt`（进而保留 `Process`），
    /// 否则 `terminationHandler` 会随对象释放一起消失，退出永远无法确认，
    /// `abandonedChildrenInFlight` 就永久泄漏了。只在 stateQueue 上访问。
    private var unconfirmedAttempts: [ObjectIdentifier: Attempt] = [:]
    /// 已放弃等待、但仍在排空管道的 Pipe：读端保持打开直到子进程退出，子进程
    /// 后续写 stdout/stderr 不会收到 SIGPIPE / EPIPE（W2A A-3）。只在 stateQueue
    /// 上访问。保留 `Pipe` 本身是为了不让它的析构提前关掉读端。
    private var drainingPipes: [ObjectIdentifier: Pipe] = [:]
    /// 结果投递队列：`completion` 不在 `stateQueue` 上执行（与 installer 同一处理，
    /// 见 W2A A-5）：否则回调里的长耗时工作会把 `abandon()` 排在后面。使用**串行**
    /// 队列（W3B F4）：回调按完成顺序投递，不再依赖并发全局队列的调度。
    private let deliveryQueue = DispatchQueue(
        label: "io.github.su-luoya.pi-web-desktop.pi-cli-update-command-delivery",
        qos: .userInitiated
    )

    /// 一次 `run` 调用的全部可变状态。每轮独立一份：重叠调用不会覆盖上一轮的
    /// process / 回调 / 定时器，也不会留下跨轮的「终态」标志（W3B F1）。
    private final class Attempt {
        let plan: PiCLIUpdatePlan
        let timeout: TimeInterval
        let completion: (PiCLIUpdateCommandResult) -> Void
        let startedAt: Date
        var process: Process?
        var timer: DispatchSourceTimer?
        var drainTimer: DispatchSourceTimer?
        var timedOut = false
        var abandoned = false
        var stdoutTail = ""
        var stderrTail = ""
        var stdoutDecoder = IncrementalUTF8Decoder()
        var stderrDecoder = IncrementalUTF8Decoder()
        var stdoutDrained = false
        var stderrDrained = false
        /// 本轮是否已经写过「已放弃」记录（至多一条）。
        var didRecordAbandonedAttempt = false
        /// 进程已经结束、但还在等管道读完时的暂存结果。
        var pendingFinish: (exitCode: Int32?, launchFailed: Bool)?
        /// 已放弃等待、但退出尚未确认（计入 `abandonedChildrenInFlight`）。
        var abandonedUnconfirmed = false
        /// 是否已经收到进程退出通知（决定「不确定」计数由谁结清）。
        var exitNotified = false
        /// 本轮是否已经走到终态（结果已经或即将投递）。
        var finished = false
        /// 超时落在「进程已结束、退出通知还没到」窗口里的让出次数（B-2，有界）。
        var timeoutRetries = 0

        init(
            plan: PiCLIUpdatePlan,
            timeout: TimeInterval,
            completion: @escaping (PiCLIUpdateCommandResult) -> Void,
            startedAt: Date
        ) {
            self.plan = plan
            self.timeout = timeout
            self.completion = completion
            self.startedAt = startedAt
        }
    }

    init(
        clock: @escaping () -> Date = { Date() },
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        redact: @escaping (String) -> String = { LogRedactor().redact($0) },
        recordAbandonedAttempt: @escaping (UpdateAbandonedAttempt) -> Void = { _ in },
        pipeDrainGrace: TimeInterval = ProcessPiCLIUpdateCommand.defaultPipeDrainGrace
    ) {
        self.clock = clock
        self.baseEnvironment = baseEnvironment
        self.redact = redact
        self.recordAbandonedAttempt = recordAbandonedAttempt
        self.pipeDrainGrace = pipeDrainGrace
    }

    func run(
        _ plan: PiCLIUpdatePlan,
        timeout: TimeInterval,
        completion: @escaping (PiCLIUpdateCommandResult) -> Void
    ) {
        stateQueue.async { [weak self] in
            self?.startLocked(plan, timeout: timeout, completion: completion)
        }
    }

    func abandon() {
        stateQueue.async { [weak self] in
            guard let self, let attempt = self.attempt else { return }
            // B-3：放弃等待落在「进程已结束、只是在等管道读到 EOF」的宽限窗口里时，
            // 并不算放弃等待：子进程已经退出、结果会照常投递。此时写一条
            // `finishedAt == nil` 的「已放弃」记录是失实的历史，登记也无人结清。
            guard !attempt.finished, attempt.pendingFinish == nil,
                  attempt.process?.isRunning != false else { return }
            attempt.abandoned = true
            self.markAbandonedUnconfirmedLocked(attempt)
            self.recordAbandonedAttemptLocked(attempt, reason: .abandonedWaiting)
            self.finishLocked(attempt, exitCode: nil)
        }
    }

    /// 是否有命令正在运行（供 UI 门控）。已经放弃等待、但子进程退出还没确认时
    /// 也算「进行中」：这段时间里不会再启动第二轮的 `pi update --self`（W3B F1）。
    var isRunning: Bool {
        stateQueue.sync { attempt != nil || abandonedChildrenInFlight > 0 }
    }

    /// 已经放弃等待、但子进程退出还没确认（W3B F3）：这种窗口下的拒绝必须给出
    /// 「重启应用即可恢复」的可见提示，而不是一句「正在运行」之后静默置灰。
    var abandonedChildrenUnconfirmed: Bool {
        stateQueue.sync { abandonedChildrenInFlight > 0 }
    }

    // MARK: - 内部（全部在 stateQueue 上执行）

    private func startLocked(
        _ plan: PiCLIUpdatePlan,
        timeout: TimeInterval,
        completion: @escaping (PiCLIUpdateCommandResult) -> Void
    ) {
        let startedAt = clock()
        // 真正重叠（或上一轮放弃等待后子进程还没退出）时整体拒绝这一次调用：不启动
        // 第二个子进程，也不覆盖正在跑的那份状态。拒绝同样要有终态回调，否则调用方
        // 永远等不到结果（W2A A-1）；上一轮彻底结束（退出已确认）后可以再次调用
        // （W3B F1：生产里这个执行器是单例，一轮结束后必须能再跑一轮）。
        guard attempt == nil, abandonedChildrenInFlight == 0 else {
            deliver(
                PiCLIUpdateCommandResult(
                    exitCode: nil,
                    alreadyRunning: true,
                    startedAt: startedAt,
                    finishedAt: startedAt
                ),
                to: completion
            )
            return
        }
        let attempt = Attempt(
            plan: plan,
            timeout: timeout,
            completion: completion,
            startedAt: startedAt
        )
        self.attempt = attempt

        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.executablePath)
        process.arguments = plan.arguments
        process.environment = PiCLIUpdateEnvironment.environment(
            base: baseEnvironment,
            executablePath: plan.executablePath
        )
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, weak attempt] handle in
            let data = handle.availableData
            guard let attempt else { return }
            self?.receive(data, toStdout: true, from: handle, attempt: attempt)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self, weak attempt] handle in
            let data = handle.availableData
            guard let attempt else { return }
            self?.receive(data, toStdout: false, from: handle, attempt: attempt)
        }
        process.terminationHandler = { [weak self, weak attempt] finishedProcess in
            self?.stateQueue.async {
                guard let self, let attempt else { return }
                attempt.exitNotified = true
                self.settleAbandonedChildLocked(attempt)
                self.finishLocked(attempt, exitCode: finishedProcess.terminationStatus)
            }
        }
        attempt.process = process
        do {
            try process.run()
        } catch {
            finishLocked(attempt, exitCode: nil, launchFailed: true)
            return
        }
        scheduleTimeoutLocked(attempt)
    }

    /// - Parameter delay: 非 nil 表示这是让出后的重排（用固定间隔），否则用本轮超时值。
    private func scheduleTimeoutLocked(_ attempt: Attempt, after delay: TimeInterval? = nil) {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + max(0.05, delay ?? attempt.timeout))
        timer.setEventHandler { [weak self, weak timer] in
            // 只有这一轮仍是当前轮、且这个计时器还是本轮计时器时才收尾：已结束、
            // 已被替换或已被重排的旧定时器不会动别人。
            guard let self, let timer, self.attempt === attempt, attempt.timer === timer,
                  !attempt.finished else { return }
            // B-2：进程已经结束（只是在等管道读到 EOF 的宽限期）时超时计时不再算数，
            // 否则会把正常退出的命令记成超时，并写下一条不实的「已放弃」记录。
            guard attempt.pendingFinish == nil else { return }
            // B-2 补充：进程已经不在运行、只是结束回调还没轮到状态队列时，先让出一小段
            // 时间等退出码到达（有界）——否则会把已经退出的命令记成超时。
            if attempt.process?.isRunning == false, attempt.timeoutRetries < Self.maxTimeoutRetries {
                attempt.timeoutRetries += 1
                self.scheduleTimeoutLocked(attempt, after: Self.timeoutRetryDelay)
                return
            }
            // 超时只放弃等待：不发送信号、不终止子进程；同时写一条「已放弃」记录。
            attempt.timedOut = true
            self.markAbandonedUnconfirmedLocked(attempt)
            self.recordAbandonedAttemptLocked(attempt, reason: .timedOut)
            self.finishLocked(attempt, exitCode: nil)
        }
        timer.resume()
        attempt.timer = timer
    }

    /// 写一条「已放弃」记录（GitHub #62）：组件、脱敏命令摘要、开始时间、超时值、
    /// 结束时间未知（`finishedAt == nil`）与实际动作“没有发送任何信号”。
    private func recordAbandonedAttemptLocked(_ attempt: Attempt, reason: UpdateAbandonedAttempt.Reason) {
        guard !attempt.didRecordAbandonedAttempt else { return }
        attempt.didRecordAbandonedAttempt = true
        let plan = attempt.plan
        let recordedAt = clock()
        recordAbandonedAttempt(UpdateAbandonedAttempt(
            componentKind: .piCLI,
            packageName: nil,
            reason: reason,
            commandSummary: UpdateAbandonedAttempt.makeCommandSummary(
                executablePath: plan.executablePath,
                arguments: plan.arguments,
                redactingWith: redact
            ),
            startedAt: attempt.startedAt,
            timeout: attempt.timeout,
            finishedAt: nil,
            source: plan.source,
            recordedAt: recordedAt,
            childProcessAction: .waitedWithoutSignals,
            derivedProcessesConfirmedEnded: nil
        ))
    }

    /// 管道回调统一入口：空数据 = 读到 EOF，标记已经读完（可能触发暂存的结束）。
    private func receive(_ data: Data, toStdout: Bool, from handle: FileHandle, attempt: Attempt) {
        stateQueue.async { [weak self] in
            guard let self, !attempt.finished else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                if toStdout {
                    attempt.stdoutDrained = true
                    self.appendDecoded(
                        attempt.stdoutDecoder.decode(Data(), final: true),
                        toStdout: true,
                        attempt: attempt
                    )
                } else {
                    attempt.stderrDrained = true
                    self.appendDecoded(
                        attempt.stderrDecoder.decode(Data(), final: true),
                        toStdout: false,
                        attempt: attempt
                    )
                }
                self.completePendingLocked(attempt)
                return
            }
            let text = toStdout
                ? attempt.stdoutDecoder.decode(data)
                : attempt.stderrDecoder.decode(data)
            self.appendDecoded(text, toStdout: toStdout, attempt: attempt)
        }
    }

    private func appendDecoded(_ text: String, toStdout: Bool, attempt: Attempt) {
        guard !text.isEmpty else { return }
        if toStdout {
            attempt.stdoutTail = Self.bounded(attempt.stdoutTail + text)
        } else {
            attempt.stderrTail = Self.bounded(attempt.stderrTail + text)
        }
    }

    private static func bounded(_ text: String, limit: Int = ProcessPiCLIUpdateCommand.outputTailLimit) -> String {
        guard text.count > limit else { return text }
        return String(text.suffix(limit))
    }

    /// 记一次「放弃等待但退出未确认」：结清之前一直拒绝新一轮（W3B F1，与 installer
    /// 的 A-2 口径一致）。
    private func markAbandonedUnconfirmedLocked(_ attempt: Attempt) {
        guard !attempt.abandonedUnconfirmed else { return }
        attempt.abandonedUnconfirmed = true
        unconfirmedAttempts[ObjectIdentifier(attempt)] = attempt
        abandonedChildrenInFlight += 1
    }

    /// 退出已确认：把这一轮从「不确定」集合里摘掉，同时释放对 `Process` 的保留
    /// （它已经不需要再监视了）。晚到的退出通知同样要结清。
    private func settleAbandonedChildLocked(_ attempt: Attempt) {
        guard attempt.abandonedUnconfirmed else { return }
        attempt.abandonedUnconfirmed = false
        unconfirmedAttempts[ObjectIdentifier(attempt)] = nil
        abandonedChildrenInFlight = max(0, abandonedChildrenInFlight - 1)
    }

    private func finishLocked(_ attempt: Attempt, exitCode: Int32?, launchFailed: Bool = false) {
        guard !attempt.finished, attempt.pendingFinish == nil else { return }
        // 正常结束时先等两条管道读到 EOF（有界），保证尾部输出不丢；
        // 超时/放弃路径直接结束：不做任何阻塞，也不向任何进程发送信号。
        if exitCode != nil, !(attempt.stdoutDrained && attempt.stderrDrained) {
            attempt.pendingFinish = (exitCode, launchFailed)
            scheduleDrainDeadlineLocked(attempt)
            return
        }
        completeLocked(attempt, exitCode: exitCode, launchFailed: launchFailed)
    }

    /// 管道读完且进程已结束时，用暂存的结果完成。
    private func completePendingLocked(_ attempt: Attempt) {
        guard let pending = attempt.pendingFinish, !attempt.finished,
              attempt.stdoutDrained, attempt.stderrDrained else { return }
        attempt.pendingFinish = nil
        completeLocked(attempt, exitCode: pending.exitCode, launchFailed: pending.launchFailed)
    }

    /// 等管道读完的宽限计时：到期还没有 EOF 就照常结束（只是尾部可能少一段）。
    private func scheduleDrainDeadlineLocked(_ attempt: Attempt) {
        guard attempt.drainTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + pipeDrainGrace)
        timer.setEventHandler { [weak self] in
            guard let self,
                  let pending = attempt.pendingFinish,
                  !attempt.finished else { return }
            attempt.pendingFinish = nil
            self.completeLocked(attempt, exitCode: pending.exitCode, launchFailed: pending.launchFailed)
        }
        timer.resume()
        attempt.drainTimer = timer
    }

    private func completeLocked(_ attempt: Attempt, exitCode: Int32?, launchFailed: Bool) {
        guard !attempt.finished else { return }
        attempt.finished = true
        attempt.timer?.cancel()
        attempt.timer = nil
        attempt.drainTimer?.cancel()
        attempt.drainTimer = nil
        appendDecoded(
            attempt.stdoutDecoder.decode(Data(), final: true),
            toStdout: true,
            attempt: attempt
        )
        appendDecoded(
            attempt.stderrDecoder.decode(Data(), final: true),
            toStdout: false,
            attempt: attempt
        )
        // 退出通知已经到过（例如放弃等待正好落在「进程已结束、还在等管道读完」的
        // 窗口里）就必须在这里结清「不确定」计数：那一刻不会再有第二次退出通知。
        if attempt.exitNotified {
            settleAbandonedChildLocked(attempt)
        }
        // 不关闭管道读端：超时/放弃等待后子进程可能还在跑，读端一关它下一次写
        // stdout/stderr 就会死于 SIGPIPE / EPIPE（W2A A-3）。这里只把两条流交给
        // 排空逻辑读到 EOF（流已经读到 EOF 的不需要再管）。
        if let process = attempt.process {
            if let pipe = process.standardOutput as? Pipe, !attempt.stdoutDrained {
                drainOutput(pipe)
            }
            if let pipe = process.standardError as? Pipe, !attempt.stderrDrained {
                drainOutput(pipe)
            }
        }
        let finishedAt = clock()
        let result = PiCLIUpdateCommandResult(
            exitCode: exitCode,
            launchFailed: launchFailed,
            timedOut: attempt.timedOut,
            abandoned: attempt.abandoned,
            startedAt: attempt.startedAt,
            finishedAt: finishedAt,
            stdoutTail: attempt.stdoutTail.isEmpty ? nil : attempt.stdoutTail,
            stderrTail: attempt.stderrTail.isEmpty ? nil : attempt.stderrTail
        )
        if self.attempt === attempt {
            self.attempt = nil
        }
        // 有意保留 `attempt.process`：放弃等待的那一轮靠它继续等退出通知
        // （terminationHandler 挂在 Process 上，对象一释放通知就没了，
        // `abandonedChildrenInFlight` 会永久泄漏）。正常结束的那一轮随 `attempt`
        // 一起释放。
        deliver(result, to: attempt.completion)
    }

    /// 在 stateQueue 之外投递结果（callback 里可能有长耗时工作；见 W2A A-5）。
    private func deliver(
        _ result: PiCLIUpdateCommandResult,
        to completion: @escaping (PiCLIUpdateCommandResult) -> Void
    ) {
        deliveryQueue.async { completion(result) }
    }

    /// 保持读端打开，把剩余输出读到 EOF 再释放：被放弃等待的子进程不会因为读端
    /// 已关而死亡（W2A A-3）。
    private func drainOutput(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        let key = ObjectIdentifier(pipe)
        drainingPipes[key] = pipe
        handle.readabilityHandler = { [weak self] fileHandle in
            guard fileHandle.availableData.isEmpty else { return }
            fileHandle.readabilityHandler = nil
            self?.stateQueue.async { [weak self] in
                self?.drainingPipes[key] = nil
            }
        }
    }
}
